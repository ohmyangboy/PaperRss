@preconcurrency import CloudKit
import Foundation
import Security

enum ICloudEngineError: Error, Sendable, Equatable {
    case notEntitled, noSystemAccount, restricted, temporarilyUnavailable, alreadySyncing
}

/// One driver / one CKSyncEngine for the private database, with two custom
/// zones. Construction is inert; only an explicitly activated iCloud account
/// can start networking. No container is initialized before entitlement checks.
actor ICloudSyncEngineDriver: CKSyncEngineDelegate, ICloudAccountSyncing {
    static let containerIdentifier = "iCloud.com.yangbukun.PaperRss"
    private let repository: ICloudRecordRepository
    private var engine: CKSyncEngine?
    private var inFlight: [CKRecord.ID: ICloudPreparedRecord] = [:]
    private var inFlightAssets: [CKRecord.ID: [ICloudAssetLease]] = [:]
    private var eventFailure: (any Error)?
    private var fetchFailure: (any Error)?
    private var sendFailure: (any Error)?
    private var automaticCallback: (@Sendable (ICloudAutomaticSyncEvent) async -> Void)?
    private var engineIsAutomatic = false
    private var lifecycleGeneration = 0
    private var needsInitialFetch = true
    private var cloudGeneration: String?
    private var systemFingerprint: String?
    private var rootVerification: (id: UUID, lifecycle: Int, fingerprint: String, task: Task<String, any Error>)?
    private var sameAccountResumeCancellation: ICloudResumeCancellation?
    private var archiveRecovery: (id: UUID, cancellation: ICloudResumeCancellation, plan: ICloudArchiveRecoveryPlan?)?

    init(repository: ICloudRecordRepository) { self.repository = repository }

    nonisolated var supportsAutomaticSync: Bool { Self.isEntitled }
    var requiresBootstrapRetry: Bool { engine == nil || eventFailure != nil }

    static var isEntitled: Bool {
        #if os(macOS)
        guard CloudSyncService.isICloudEntitled,
              let task = SecTaskCreateFromSelf(nil),
              let value = SecTaskCopyValueForEntitlement(task, "com.apple.developer.icloud-container-identifiers" as CFString, nil),
              let identifiers = value as? [String] else { return false }
        return identifiers.contains(containerIdentifier)
        #else
        return false
        #endif
    }

    static func systemUserFingerprint() async throws -> String {
        guard isEntitled else { throw ICloudEngineError.notEntitled }
        let container = CKContainer(identifier: containerIdentifier)
        switch try await container.accountStatus() {
        case .available: break
        case .noAccount: throw ICloudEngineError.noSystemAccount
        case .restricted: throw ICloudEngineError.restricted
        default: throw ICloudEngineError.temporarilyUnavailable
        }
        return fingerprint(try await container.userRecordID())
    }

    func synchronize() async throws {
        try await fetchChanges()
        try await sendChanges()
    }

    func fetchChanges() async throws {
        // The SDK coordinates concurrent automatic and explicit requests. A
        // foreground request must not turn a manual refresh into a fake error.
        let engine = try await prepareEngine()
        try await fetch(on: engine)
    }

    /// The SDK returns after all related delegate events have been processed.
    /// Then verify the ready root and system account again; a locally bound scope
    /// alone is not evidence that target recovery has finished.
    func restoreForLocalCopy() async throws -> ICloudLocalCopyRepository.Context {
        try Task.checkCancellation()
        let current = try await prepareEngine()
        let lifecycle = lifecycleGeneration
        try await fetch(on: current)
        try Task.checkCancellation()
        let epoch = try await verifyRoot(on: current)
        guard let fingerprint = systemFingerprint,
              try await validateRootSession(lifecycle: lifecycle, fingerprint: fingerprint),
              engine === current, lifecycleGeneration == lifecycle, !needsInitialFetch,
              try repository.missingZones().isEmpty else { throw ICloudLocalCopyError.unavailableTarget }
        try throwEventFailure()
        if let fetchFailure { throw fetchFailure }
        return .init(userFingerprint: fingerprint, generation: epoch)
    }

    func sendChanges() async throws {
        let engine = try await prepareEngine()
        if needsInitialFetch { try await fetch(on: engine) }
        try queuePending(on: engine)
        try await engine.sendChanges()
        guard self.engine === engine else { throw CancellationError() }
        try throwEventFailure()
        if let sendFailure { throw sendFailure }
    }

    func resumeOriginalAccount() async throws {
        guard Self.isEntitled else { throw ICloudEngineError.notEntitled }
        guard sameAccountResumeCancellation == nil, archiveRecovery == nil else { throw ICloudSameAccountResumeError.operationInProgress }
        let cancellation = ICloudResumeCancellation()
        sameAccountResumeCancellation = cancellation
        defer { if sameAccountResumeCancellation === cancellation { sameAccountResumeCancellation = nil } }
        // Invalidate the old SDK lifecycle before any protective pause is
        // released. A new engine must fetch before supplying outgoing batches.
        await detachEngine()
        try cancellation.check(); try Task.checkCancellation()
        try await ICloudSameAccountResumeCoordinator(repository: repository,
            transport: ICloudCloudResidueCloudKitTransport(repository: repository)).resume(cancellation: cancellation)
    }

    func prepareArchiveRecovery() async throws -> ICloudArchiveRecoveryPlan {
        guard Self.isEntitled else { throw ICloudEngineError.notEntitled }
        guard archiveRecovery == nil, sameAccountResumeCancellation == nil else { throw ICloudArchiveRecoveryError.operationInProgress }
        let id = UUID(), cancellation = ICloudResumeCancellation()
        archiveRecovery = (id, cancellation, nil)
        do {
            await detachEngine()
            try Task.checkCancellation(); try cancellation.check()
            let plan = try await archiveCoordinator().prepare(cancellation: cancellation)
            try Task.checkCancellation(); try cancellation.check()
            guard archiveRecovery?.id == id else { throw CancellationError() }
            archiveRecovery?.plan = plan
            return plan
        } catch {
            if archiveRecovery?.id == id { archiveRecovery = nil }
            throw error
        }
    }

    func executeArchiveRecovery(_ plan: ICloudArchiveRecoveryPlan, initializeEmptyCloudConfirmed: Bool) async throws -> AccountRecord {
        guard Self.isEntitled else { throw ICloudEngineError.notEntitled }
        guard let recovery = archiveRecovery, let approved = recovery.plan, approved.id == plan.id else {
            throw ICloudArchiveRecoveryError.staleReview
        }
        guard !approved.needsCloudInitialization || initializeEmptyCloudConfirmed else {
            throw ICloudArchiveRecoveryError.cloudInitializationConfirmationRequired
        }
        archiveRecovery?.plan = nil // One execution; the actual plan stays here.
        defer { if archiveRecovery?.id == recovery.id { archiveRecovery = nil } }
        return try await archiveCoordinator().execute(approved, initializeEmptyCloudConfirmed: initializeEmptyCloudConfirmed, cancellation: recovery.cancellation)
    }

    func discardArchiveRecovery(planID: UUID) async {
        guard archiveRecovery?.plan?.id == planID else { return }
        archiveRecovery?.cancellation.cancel()
        archiveRecovery = nil
    }

    private func archiveCoordinator() -> ICloudArchiveRecoveryCoordinator {
        .init(database: repository.database, accountID: repository.accountID,
              transport: ICloudArchiveCloudKitTransport(database: repository.database, accountID: repository.accountID))
    }

    func startAutomaticSync(onEvent: @escaping @Sendable (ICloudAutomaticSyncEvent) async -> Void) async throws {
        try await prepareAutomaticSync(onEvent: onEvent)
        try await localChangesAvailable()
    }

    func prepareAutomaticSync(onEvent: @escaping @Sendable (ICloudAutomaticSyncEvent) async -> Void) async throws {
        guard archiveRecovery == nil else { throw ICloudArchiveRecoveryError.operationInProgress }
        automaticCallback = onEvent
        if !engineIsAutomatic, engine != nil { await stop() }
    }

    func localChangesAvailable() async throws {
        let engine = try await prepareEngine()
        if needsInitialFetch { try await fetch(on: engine) }
        try queuePending(on: engine)
    }

    func inventoryPage(zone: ICloudRecordZone, cursor: Data?, limit: Int) async throws -> ICloudInventoryPage {
        let current = try await prepareEngine()
        let queryEpoch = try boundGeneration(on: current)
        let queryZone = try ICloudGenerationZone.id(zone, generation: queryEpoch)
        let foreignZones: Int
        if cursor == nil {
            let zones = try await current.database.allRecordZones()
            guard engine === current else { throw CancellationError() }
            foreignZones = try ICloudGenerationZone.foreignZoneCount(zones.map(\.zoneID), generation: queryEpoch)
        } else { foreignZones = 0 }
        try Task.checkCancellation()
        let page: (matchResults: [(CKRecord.ID, Result<CKRecord, any Error>)], queryCursor: CKQueryOperation.Cursor?)
        do {
            if let cursor {
                guard let decoded = try NSKeyedUnarchiver.unarchivedObject(ofClass: CKQueryOperation.Cursor.self, from: cursor)
                else { throw ICloudInventoryError.malformedPage }
                page = try await current.database.records(continuingMatchFrom: decoded,
                    desiredKeys: ["envelope"], resultsLimit: limit)
            } else {
                let query = CKQuery(recordType: ICloudRecordCodec.recordType,
                    predicate: NSPredicate(format: "creationDate >= %@", Date.distantPast as CVarArg))
                page = try await current.database.records(matching: query,
                    inZoneWith: queryZone, desiredKeys: ["envelope"], resultsLimit: limit)
            }
        } catch let error as CKError where error.code == .zoneNotFound {
            guard engine === current else { throw CancellationError() }
            if try repository.missingZones().contains(zone) {
                return .init(records: [], cursor: nil, envelopeBytes: 0, otherGenerationZones: foreignZones)
            }
            try repository.pause(reason: "zoneDeleted")
            throw ICloudRecordError.recoveryRequired
        }
        try Task.checkCancellation()
        guard engine === current else { throw CancellationError() }
        let epoch = try await verifyRoot(on: current)
        guard epoch == queryEpoch else { throw CancellationError() }
        _ = try repository.engineState() // Recheck capture and quarantine after the await.
        let enabled = try repository.database.read {
            try AccountRecord.fetchOne($0, key: self.repository.accountID)?.isEnabled == true
        }
        guard enabled else { throw CancellationError() }
        var metadata: [ICloudCloudRecordMetadata] = []
        var bytes = 0
        var ignored = 0
        for (_, result) in page.matchResults {
            // A partial per-record failure must not become a successful total.
            let record = try result.get()
            guard record.recordID.zoneID == queryZone else { throw ICloudInventoryError.malformedPage }
            bytes += (record["envelope"] as? Data)?.count ?? 0
            guard case .current = try ICloudGenerationIdentity.classify(record.recordID.recordName, generation: epoch) else {
                ignored += 1
                continue
            }
            let envelope = try ICloudRecordCodec.decode(record, generation: epoch)
            guard envelope.zone == zone else { throw ICloudInventoryError.malformedPage }
            let fields = ICloudRecordCodec.systemFields(record)
            metadata.append(.init(envelope: envelope, creationDate: record.creationDate, modificationDate: record.modificationDate,
                                  systemFields: fields, changeTag: record.recordChangeTag))
        }
        let next = try page.queryCursor.map {
            try NSKeyedArchiver.archivedData(withRootObject: $0, requiringSecureCoding: true)
        }
        return .init(records: metadata, cursor: next, envelopeBytes: bytes, otherGenerationRecords: ignored,
                     otherGenerationZones: foreignZones)
    }

    private func prepareEngine() async throws -> CKSyncEngine {
        guard Self.isEntitled else { throw ICloudEngineError.notEntitled }
        guard archiveRecovery == nil else { throw ICloudArchiveRecoveryError.operationInProgress }
        ICloudAssetLease.cleanUpOnce()
        // A failed apply must restart from the last successfully persisted
        // checkpoint. Advancing serialization after that failure loses data.
        if eventFailure != nil { await stop() }
        let generation = lifecycleGeneration
        if engine == nil {
            let retry = try await repository.bootstrapRetryState()
            guard generation == lifecycleGeneration else { throw CancellationError() }
            if let deadline = retry.deadline, deadline > Date() { throw ICloudBootstrapRetryError.deferred }
        }
        let serialization = try repository.engineState()
        let container = CKContainer(identifier: Self.containerIdentifier)
        switch try await container.accountStatus() {
        case .available: break
        case .noAccount: throw ICloudEngineError.noSystemAccount
        case .restricted: throw ICloudEngineError.restricted
        case .couldNotDetermine, .temporarilyUnavailable: throw ICloudEngineError.temporarilyUnavailable
        @unknown default: throw ICloudEngineError.temporarilyUnavailable
        }
        guard generation == lifecycleGeneration else { throw CancellationError() }
        let user = try await container.userRecordID()
        guard generation == lifecycleGeneration,
              try repository.database.read({ db in
                  try ICloudAutomaticSyncSignal.fetch(accountID: self.repository.accountID, in: db)?.isEnabled == true
              }) else { throw CancellationError() }
        let fingerprint = Self.fingerprint(user)
        try repository.bindSystemUserFingerprint(fingerprint)
        let epoch = try await verifyRoot(database: container.privateCloudDatabase,
            lifecycle: generation, fingerprint: fingerprint)
        guard generation == lifecycleGeneration else { throw CancellationError() }
        if engine == nil {
            let state = try serialization.map { try JSONDecoder().decode(CKSyncEngine.State.Serialization.self, from: $0) }
            var config = CKSyncEngine.Configuration(database: container.privateCloudDatabase, stateSerialization: state, delegate: self)
            config.automaticallySync = automaticCallback != nil
            engineIsAutomatic = config.automaticallySync
            cloudGeneration = epoch
            systemFingerprint = fingerprint
            engine = CKSyncEngine(config)
        }
        guard cloudGeneration == epoch, systemFingerprint == fingerprint else { throw CancellationError() }
        guard let engine else { throw ICloudRecordError.persistenceFailed }
        engine.state.remove(pendingDatabaseChanges: try ICloudGenerationZone.obsoleteDatabaseChanges(
            engine.state.pendingDatabaseChanges, generation: epoch))
        return engine
    }

    private func fetch(on engine: CKSyncEngine) async throws {
        let epoch = try boundGeneration(on: engine)
        let options = try ICloudGenerationZone.fetchOptions(.init(), generation: epoch)
        try await engine.fetchChanges(options)
        guard self.engine === engine else { throw CancellationError() }
        try throwEventFailure()
        if let fetchFailure { throw fetchFailure }
        // A serialization may be emitted before zones exist. Track zone
        // creation separately, including crashes between the two zone saves.
        guard try boundGeneration(on: engine) == epoch else { throw CancellationError() }
        engine.state.add(pendingDatabaseChanges: try repository.missingZones().map {
            .saveZone(CKRecordZone(zoneID: try ICloudGenerationZone.id($0, generation: epoch)))
        })
        needsInitialFetch = false
    }

    func stop() async {
        sameAccountResumeCancellation?.cancel()
        archiveRecovery?.cancellation.cancel()
        archiveRecovery = nil
        await detachEngine()
    }

    private func detachEngine() async {
        let previous = engine
        let assets = inFlightAssets
        engine = nil
        lifecycleGeneration &+= 1
        engineIsAutomatic = false
        needsInitialFetch = true
        cloudGeneration = nil
        systemFingerprint = nil
        rootVerification?.task.cancel()
        rootVerification = nil
        inFlight.removeAll()
        inFlightAssets.removeAll()
        eventFailure = nil
        fetchFailure = nil
        sendFailure = nil
        // Detach old state before the await. A reenabled account may create
        // another engine while cancellation finishes; never clear its leases.
        await previous?.cancelOperations()
        withExtendedLifetime(assets) {}
    }

    private static func fingerprint(_ user: CKRecord.ID) -> String {
        ICloudSyncIdentity.digest([containerIdentifier, user.recordName])
    }

    private func validateRootSession(lifecycle: Int, fingerprint: String) async throws -> Bool {
        guard lifecycle == lifecycleGeneration else { return false }
        _ = try repository.engineState()
        let container = CKContainer(identifier: Self.containerIdentifier)
        switch try await container.accountStatus() {
        case .available: break
        case .noAccount: throw ICloudEngineError.noSystemAccount
        case .restricted: throw ICloudEngineError.restricted
        default: throw ICloudEngineError.temporarilyUnavailable
        }
        let user = try await container.userRecordID()
        guard lifecycle == lifecycleGeneration else { return false }
        let current = Self.fingerprint(user)
        try repository.bindSystemUserFingerprint(current)
        guard current == fingerprint else { throw ICloudRecordError.accountChanged }
        return try repository.database.read {
            try AccountRecord.fetchOne($0, key: self.repository.accountID)?.isEnabled == true
        }
    }

    private func verifyRoot(database: CKDatabase, lifecycle: Int, fingerprint: String) async throws -> String {
        guard lifecycle == lifecycleGeneration else { throw CancellationError() }
        if let current = rootVerification, current.lifecycle == lifecycle, current.fingerprint == fingerprint {
            return try await current.task.value
        }
        let retry = try await repository.bootstrapRetryState()
        guard lifecycle == lifecycleGeneration else { throw CancellationError() }
        // Another caller can have started verification while this read awaited.
        if let current = rootVerification, current.lifecycle == lifecycle, current.fingerprint == fingerprint {
            return try await current.task.value
        }
        if let deadline = retry.deadline, deadline > Date() { throw ICloudBootstrapRetryError.deferred }
        let id = UUID()
        let task = Task { try await self.performRootVerification(database: database,
            lifecycle: lifecycle, fingerprint: fingerprint, retryRevision: retry.revision) }
        rootVerification = (id, lifecycle, fingerprint, task)
        defer { if rootVerification?.id == id { rootVerification = nil } }
        let result = try await task.value
        guard lifecycle == lifecycleGeneration else { throw CancellationError() }
        return result
    }

    private func performRootVerification(database: CKDatabase, lifecycle: Int, fingerprint: String,
                                         retryRevision: Int64) async throws -> String {
        let check: @Sendable () async throws -> Bool = { [weak self] in
            guard let self else { return false }
            return try await self.validateRootSession(lifecycle: lifecycle, fingerprint: fingerprint)
        }
        let transport = ICloudRootCloudKitTransport(database: database, validateMutation: {
            guard try await check() else { throw CancellationError() }
        })
        do {
            let epoch = try await ICloudRootCoordinator(repository: repository).ensureGeneration(using: transport, isCurrent: check)
            guard lifecycle == lifecycleGeneration else { throw CancellationError() }
            try await repository.clearBootstrapRetry(expectedRevision: retryRevision)
            guard lifecycle == lifecycleGeneration else { throw CancellationError() }
            return epoch
        } catch {
            guard lifecycle == lifecycleGeneration else { throw CancellationError() }
            if ICloudBootstrapRetryPolicy.delay(for: error, attempt: 1) != nil {
                _ = try await repository.scheduleBootstrapRetry(for: error, now: Date())
            }
            throw error
        }
    }

    private func verifyRoot(on current: CKSyncEngine) async throws -> String {
        guard engine === current, let fingerprint = systemFingerprint, let epoch = cloudGeneration else {
            throw CancellationError()
        }
        let verified = try await verifyRoot(database: current.database, lifecycle: lifecycleGeneration, fingerprint: fingerprint)
        guard engine === current, verified == epoch else { throw CancellationError() }
        return epoch
    }

    private func boundGeneration(on current: CKSyncEngine) throws -> String {
        guard engine === current, let epoch = cloudGeneration else { throw CancellationError() }
        guard try repository.boundCloudGeneration() == epoch else { throw ICloudRootError.generationChanged }
        return epoch
    }

    private func throwEventFailure() throws {
        if let eventFailure { throw eventFailure }
    }

    private func queuePending(on engine: CKSyncEngine) throws {
        let epoch = try boundGeneration(on: engine)
        let records = try repository.outgoingRecordGroups().flatMap(\.records)
        // Remove cancelled saves as soon as metadata changes, rather than
        // waiting for the SDK's next scheduled retry to request another batch.
        try removeInactiveSaves(on: engine)
        engine.state.add(pendingRecordZoneChanges: try records.map {
            .saveRecord(try ICloudRecordCodec.recordID($0.envelope, generation: epoch))
        })
        engine.state.hasPendingUntrackedChanges = !records.isEmpty
    }

    private func removeInactiveSaves(on engine: CKSyncEngine, scope: CKSyncEngine.SendChangesOptions.Scope = .all) throws {
        let epoch = try boundGeneration(on: engine)
        let obsolete = try ICloudGenerationZone.obsoleteRecordChanges(engine.state.pendingRecordZoneChanges, generation: epoch)
        engine.state.remove(pendingRecordZoneChanges: obsolete)
        let changes = try engine.state.pendingRecordZoneChanges.filter {
            guard scope.contains($0), case .saveRecord(let id) = $0 else { return false }
            return try ICloudGenerationZone.currentZone(id.zoneID, generation: epoch) != nil
        }
        let names = Set(try changes.compactMap { change -> String? in
            if case .saveRecord(let id) = change,
               case .current(let name) = try ICloudGenerationIdentity.classify(id.recordName, generation: epoch) { return name }
            return nil
        })
        let inactive = try repository.inactivePreparedRecordNames(names)
        engine.state.remove(pendingRecordZoneChanges: try changes.filter {
            if case .saveRecord(let id) = $0,
               case .current(let name) = try ICloudGenerationIdentity.classify(id.recordName, generation: epoch) { return inactive.contains(name) }
            return false
        })
    }

    func handleEvent(_ event: CKSyncEngine.Event, syncEngine: CKSyncEngine) async {
        guard engine === syncEngine, eventFailure == nil else { return }
        do {
            switch event {
            case .willFetchChanges:
                _ = try await verifyRoot(on: syncEngine)
                fetchFailure = nil
                await automaticCallback?(.started)
            case .willSendChanges:
                let epoch = try await verifyRoot(on: syncEngine)
                syncEngine.state.remove(pendingDatabaseChanges: try ICloudGenerationZone.obsoleteDatabaseChanges(
                    syncEngine.state.pendingDatabaseChanges, generation: epoch))
                sendFailure = nil
                await automaticCallback?(.started)
            case .stateUpdate(let update):
                try repository.persistEngineState(JSONEncoder().encode(update.stateSerialization))
            case .accountChange(let change):
                switch change.changeType {
                case .signIn(let currentUser):
                    try repository.bindSystemUserFingerprint(Self.fingerprint(currentUser))
                case .signOut, .switchAccounts:
                    try repository.pause(reason: "accountChanged")
                    throw ICloudRecordError.accountChanged
                @unknown default:
                    try repository.pause(reason: "accountChanged")
                    throw ICloudRecordError.accountChanged
                }
            case .fetchedDatabaseChanges(let changes):
                let epoch = try boundGeneration(on: syncEngine)
                if changes.deletions.contains(where: { $0.zoneID == ICloudCloudRootCodec.zoneID }) {
                    try repository.pause(reason: "cloudRootMissing")
                    throw ICloudRootError.rootMissing
                }
                if try changes.deletions.contains(where: { try ICloudGenerationZone.currentZone($0.zoneID, generation: epoch) != nil }) {
                    try repository.pause(reason: "zoneDeleted")
                    throw ICloudRecordError.recoveryRequired
                }
                for zone in changes.modifications {
                    if let known = try ICloudGenerationZone.currentZone(zone.zoneID, generation: epoch) {
                        try repository.markZoneInitialized(known)
                    }
                }
            case .fetchedRecordZoneChanges(let changes):
                if changes.deletions.contains(where: { $0.recordID.zoneID == ICloudCloudRootCodec.zoneID }) {
                    try repository.pause(reason: "cloudRootMissing")
                    throw ICloudRootError.rootMissing
                }
                let epoch = try await verifyRoot(on: syncEngine)
                for modification in changes.modifications where modification.record.recordID.zoneID == ICloudCloudRootCodec.zoneID {
                    try await repository.acceptCloudRoot(ICloudCloudRootCodec.decode(modification.record), expectedGeneration: epoch)
                }
                guard engine === syncEngine else { throw CancellationError() }
                if try changes.deletions.contains(where: { deletion in
                    guard try ICloudGenerationZone.currentZone(deletion.recordID.zoneID, generation: epoch) == .library else { return false }
                    if case .current = try ICloudGenerationIdentity.classify(deletion.recordID.recordName, generation: epoch) { return true }
                    return false
                }) {
                    try repository.pause(reason: "structureDeleted")
                    throw ICloudRecordError.recoveryRequired
                }
                let records = try changes.modifications.compactMap { modification -> ICloudReceivedRecord? in
                    guard try ICloudGenerationZone.currentZone(modification.record.recordID.zoneID, generation: epoch) != nil else { return nil }
                    guard case .current = try ICloudGenerationIdentity.classify(modification.record.recordID.recordName, generation: epoch) else { return nil }
                    return try ICloudRecordCodec.received(modification.record, generation: epoch)
                }
                // The SDK delivers delegate events serially and awaits this
                // transaction before any later stateUpdate can be persisted.
                try repository.receive(records)
                for deletion in changes.deletions {
                    guard let zone = try ICloudGenerationZone.currentZone(deletion.recordID.zoneID, generation: epoch) else { continue }
                    guard case .current(let name) = try ICloudGenerationIdentity.classify(deletion.recordID.recordName, generation: epoch) else { continue }
                    try repository.discardServerMetadata(recordName: name, zone: zone)
                }
                await automaticCallback?(.changed)
            case .sentRecordZoneChanges(let changes):
                let epoch = try await verifyRoot(on: syncEngine)
                let guarded = try repository.usesRetentionProtocol()
                try ICloudSaveBatchPlanner.validateSavedReceipts(Set(changes.savedRecords.map(\.recordID)),
                    inFlight: inFlight, generation: epoch, requiresArticleGuards: guarded)
                // Persist the server guard before confirming dependent saves.
                let saved = guarded ? changes.savedRecords.sorted {
                    let left = inFlight[$0.recordID]?.envelope.kind == .retention
                    let right = inFlight[$1.recordID]?.envelope.kind == .retention
                    return left && !right
                } : changes.savedRecords
                for record in saved {
                    defer { inFlightAssets.removeValue(forKey: record.recordID) }
                    guard let sent = inFlight.removeValue(forKey: record.recordID) else { throw ICloudRecordError.persistenceFailed }
                    try repository.confirm(sent, server: ICloudRecordCodec.received(record, generation: epoch))
                }
                var unhandledFailure: CKError?
                for failure in changes.failedRecordSaves {
                    switch failure.error.code {
                    case .serverRecordChanged:
                        inFlightAssets.removeValue(forKey: failure.record.recordID)
                        inFlight.removeValue(forKey: failure.record.recordID)
                        guard let server = failure.error.serverRecord else { throw ICloudRecordError.malformedRecord }
                        try repository.receive([ICloudRecordCodec.received(server, generation: epoch)])
                        syncEngine.state.add(pendingRecordZoneChanges: [.saveRecord(failure.record.recordID)])
                    case .unknownItem:
                        inFlightAssets.removeValue(forKey: failure.record.recordID)
                        inFlight.removeValue(forKey: failure.record.recordID)
                        guard let zone = try ICloudGenerationZone.currentZone(failure.record.recordID.zoneID, generation: epoch)
                        else { throw ICloudRecordError.identityMismatch }
                        guard case .current(let name) = try ICloudGenerationIdentity.classify(failure.record.recordID.recordName, generation: epoch)
                        else { throw ICloudRecordError.identityMismatch }
                        try repository.discardServerMetadata(recordName: name, zone: zone)
                        syncEngine.state.add(pendingRecordZoneChanges: [.saveRecord(failure.record.recordID)])
                    case .zoneNotFound:
                        try repository.pause(reason: "zoneMissing")
                        throw ICloudRecordError.recoveryRequired
                    case .batchRequestFailed where guarded:
                        inFlightAssets.removeValue(forKey: failure.record.recordID)
                        inFlight.removeValue(forKey: failure.record.recordID)
                        syncEngine.state.add(pendingRecordZoneChanges: [.saveRecord(failure.record.recordID)])
                    default:
                        // Keep the sent snapshot and asset alive: the SDK may
                        // retry the same record without requesting a new batch.
                        unhandledFailure = unhandledFailure ?? failure.error
                    }
                }
                if guarded, let failure = changes.failedRecordSaves.first {
                    // A retry must request a freshly guarded group. Do not
                    // let an SDK-cached individual record bypass its companion
                    // after any conditional or transient batch failure.
                    if failure.error.code == .serverRecordChanged || failure.error.code == .batchRequestFailed {
                        throw ICloudEngineError.temporarilyUnavailable
                    }
                    throw failure.error
                }
                if let error = unhandledFailure {
                    sendFailure = error
                    await automaticCallback?(.failed(error))
                } else {
                    try queuePending(on: syncEngine)
                }
                await automaticCallback?(.changed)
            case .didFetchRecordZoneChanges(let result):
                let epoch = try boundGeneration(on: syncEngine)
                let known = try ICloudGenerationZone.currentZone(result.zoneID, generation: epoch)
                guard result.zoneID == ICloudCloudRootCodec.zoneID || known != nil else { break }
                if let error = result.error {
                    fetchFailure = error
                    await automaticCallback?(.failed(error))
                }
            case .didFetchChanges:
                if fetchFailure == nil {
                    let epoch = try await verifyRoot(on: syncEngine)
                    needsInitialFetch = false
                    syncEngine.state.add(pendingDatabaseChanges: try repository.missingZones().map {
                        .saveZone(CKRecordZone(zoneID: try ICloudGenerationZone.id($0, generation: epoch)))
                    })
                    try queuePending(on: syncEngine)
                    await automaticCallback?(.completed)
                }
            case .didSendChanges:
                if sendFailure == nil { await automaticCallback?(.completed) }
            case .sentDatabaseChanges(let result):
                let epoch = try boundGeneration(on: syncEngine)
                if let failure = try result.failedZoneSaves.first(where: {
                    try ICloudGenerationZone.currentZone($0.zone.zoneID, generation: epoch) != nil
                }) {
                    sendFailure = failure.error
                    await automaticCallback?(.failed(failure.error))
                }
                for zone in result.savedZones {
                    if let known = try ICloudGenerationZone.currentZone(zone.zoneID, generation: epoch) {
                        try repository.markZoneInitialized(known)
                    }
                }
            default: break
            }
        } catch {
            guard engine === syncEngine else { return }
            // No raw CKRecord / URL / credentials are written to diagnostics.
            eventFailure = error
            if let root = error as? ICloudRootError, root == .malformedRoot || root == .unsupportedVersion {
                try? repository.pause(reason: "invalidCloudRoot")
            }
            // Do not await cancellation from inside the delegate event that
            // the SDK itself is awaiting. Detach cancellation and retain leases
            // until the owning engine is stopped.
            Task { await syncEngine.cancelOperations() }
            await automaticCallback?(.failed(error))
        }
    }

    func nextFetchChangesOptions(_ context: CKSyncEngine.FetchChangesContext,
                                syncEngine: CKSyncEngine) async -> CKSyncEngine.FetchChangesOptions {
        do {
            guard engine === syncEngine, eventFailure == nil else {
                return .init(scope: .zoneIDs([]))
            }
            return try ICloudGenerationZone.fetchOptions(context.options, generation: boundGeneration(on: syncEngine))
        } catch {
            guard engine === syncEngine else { return .init(scope: .zoneIDs([])) }
            eventFailure = error
            if let root = error as? ICloudRootError, root == .malformedRoot || root == .unsupportedVersion {
                try? repository.pause(reason: "invalidCloudRoot")
            }
            Task { await syncEngine.cancelOperations() }
            await automaticCallback?(.failed(error))
            return .init(scope: .zoneIDs([]))
        }
    }

    func nextRecordZoneChangeBatch(_ context: CKSyncEngine.SendChangesContext, syncEngine: CKSyncEngine) async -> CKSyncEngine.RecordZoneChangeBatch? {
        guard engine === syncEngine, eventFailure == nil, !needsInitialFetch else { return nil }
        do {
            let epoch = try await verifyRoot(on: syncEngine)
            let names = Set(try syncEngine.state.pendingRecordZoneChanges.compactMap { change -> String? in
                guard context.options.scope.contains(change), case .saveRecord(let id) = change else { return nil }
                guard try ICloudGenerationZone.currentZone(id.zoneID, generation: epoch) != nil else { return nil }
                guard case .current(let name) = try ICloudGenerationIdentity.classify(id.recordName, generation: epoch) else { return nil }
                return name
            })
            let groups = try repository.outgoingRecordGroups(recordNames: names)
            let guarded = try repository.usesRetentionProtocol()
            let batch = try ICloudSaveBatchPlanner.select(groups, generation: epoch, requiresArticleGuards: guarded,
                scope: context.options.scope, unavailable: guarded ? Set(inFlight.keys) : [])
            try removeInactiveSaves(on: syncEngine, scope: context.options.scope)
            var records: [CKRecord] = []
            for value in batch.records {
                let lease = try value.bodyData.flatMap { data in
                    data.count > ICloudArticleContentCodec.inlineBytes ? try ICloudAssetLease(data: data) : nil
                }
                let record = try ICloudRecordCodec.encode(value.envelope, systemFields: value.systemFields,
                                                         bodyData: value.bodyData, assetURL: lease?.fileURL, generation: epoch)
                records.append(record)
                inFlight[record.recordID] = value
                if let lease { inFlightAssets[record.recordID, default: []].append(lease) }
            }
            guard !records.isEmpty else {
                if groups.isEmpty { syncEngine.state.hasPendingUntrackedChanges = false }
                return nil
            }
            return CKSyncEngine.RecordZoneChangeBatch(recordsToSave: records, recordIDsToDelete: [], atomicByZone: batch.atomicByZone)
        } catch {
            guard engine === syncEngine else { return nil }
            eventFailure = error
            if let root = error as? ICloudRootError, root == .malformedRoot || root == .unsupportedVersion {
                try? repository.pause(reason: "invalidCloudRoot")
            }
            Task { await syncEngine.cancelOperations() }
            await automaticCallback?(.failed(error))
            return nil
        }
    }
}
