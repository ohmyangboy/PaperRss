import SwiftUI

@MainActor
final class AppNavigationModel: ObservableObject {
    enum Destination: Equatable {
        case unread
    }

    struct Request: Identifiable, Equatable {
        let id = UUID()
        let destination: Destination
    }

    @Published private(set) var request: Request?

    func openUnread() {
        request = Request(destination: .unread)
    }
}
