import Foundation
import XCTest
@testable import PaperRssDesktop

final class AgentMCPInstallTargetsTests: XCTestCase {
    let path = "/Applications/Paper Rss's.app/Contents/MacOS/paperrss-agent"

    func assertServer(_ server: [String: Any], label: String, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(server["command"] as? String, path, file: file, line: line)
        XCTAssertEqual(server["args"] as? [String], ["serve", "--stdio", "--client", label], file: file, line: line)
        XCTAssertEqual(server["env"] as? [String: String], ["PAPERRSS_AGENT_ENABLED": "1"], file: file, line: line)
    }
    func object(_ string: String) throws -> [String: Any] {
        try XCTUnwrap(JSONSerialization.jsonObject(with: Data(string.utf8)) as? [String: Any])
    }
    func testCursorLink() throws {
        let raw = try XCTUnwrap(AgentMCPInstallTarget.cursor.url(path: path)?.absoluteString)
        XCTAssertTrue(raw.hasPrefix("cursor://anysphere.cursor-deeplink/mcp/install?name=paperrss&config="))
        let encoded = try XCTUnwrap(raw.components(separatedBy: "config=").last)
        XCTAssertFalse(encoded.contains("+")); XCTAssertFalse(encoded.contains("/")); XCTAssertFalse(encoded.contains("="))
        let base64 = try XCTUnwrap(encoded.removingPercentEncoding)
        let data = try XCTUnwrap(Data(base64Encoded: base64))
        assertServer(try object(String(decoding: data, as: UTF8.self)), label: "cursor")
    }
    func testVSCodeLinks() throws {
        for target in [AgentMCPInstallTarget.vscode, .vscodeInsiders] {
            let raw = try XCTUnwrap(target.url(path: path)?.absoluteString)
            let scheme = target == .vscode ? "vscode" : "vscode-insiders"
            XCTAssertTrue(raw.hasPrefix("\(scheme):mcp/install?"))
            XCTAssertFalse(raw.hasPrefix("\(scheme)://"))
            let query = try XCTUnwrap(raw.components(separatedBy: "?").last?.removingPercentEncoding)
            let value = try object(query)
            XCTAssertEqual(value["name"] as? String, "paperrss")
            XCTAssertEqual(value["type"] as? String, "stdio")
            assertServer(value, label: target.label)
            XCTAssertTrue(raw.contains("'"))
        }
    }
    func testCommands() {
        let quoted = "'/Applications/Paper Rss'\\''s.app/Contents/MacOS/paperrss-agent'"
        XCTAssertEqual(AgentMCPInstallTarget.claudeCode.command(path: path), "claude mcp add --scope user --env PAPERRSS_AGENT_ENABLED=1 --transport stdio paperrss -- \(quoted) serve --stdio --client claude-code")
        XCTAssertEqual(AgentMCPInstallTarget.codex.command(path: path), "codex mcp add paperrss --env PAPERRSS_AGENT_ENABLED=1 -- \(quoted) serve --stdio --client codex")
    }
    func testPiCommandPassesLiteralHelperPathToUserScopedCLI() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let cli = root.appendingPathComponent("pi")
        try "#!/bin/sh\nprintf '%s\\0' \"$@\"\n".write(to: cli, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: cli.path)
        let helperPath = path + " $(printf injected);\n"
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", try XCTUnwrap(AgentMCPInstallTarget.pi.command(path: helperPath))]
        process.environment = ["PATH": root.path]
        let output = Pipe()
        process.standardOutput = output
        try process.run()
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        XCTAssertEqual(process.terminationStatus, 0)
        XCTAssertEqual(String(decoding: data, as: UTF8.self).split(separator: "\0").map(String.init),
                       ["mcp", "add", "paperrss", "--env", "PAPERRSS_AGENT_ENABLED=1", "--",
                        helperPath, "serve", "--stdio", "--client", "pi"])
    }

    func testDSHCommandWritesYAMLAndIsIdempotent() throws {
        // Execute the actual copied command, with both home locations isolated from user configuration.
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("build/reports/dsh-command-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        for useOverride in [false, true] {
            for initial in [nil, "[]", "  [ ] # empty layer\n# comment\n", " \n\t", "- id: other\n  name: other-plugin"] as [String?] {
                let home = root.appendingPathComponent(UUID().uuidString)
                let directory = home.appendingPathComponent(useOverride ? "custom dsh's home" : ".dsh")
                let file = directory.appendingPathComponent("cordis.patch.yml")
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
                if let initial { try initial.write(to: file, atomically: true, encoding: .utf8) }
                let command = try XCTUnwrap(AgentMCPInstallTarget.dsh.command(path: path))
                for _ in 0..<2 {
                    let process = Process()
                    process.executableURL = URL(fileURLWithPath: "/bin/sh")
                    process.arguments = ["-c", command]
                    process.environment = ["HOME": home.path, "DSH_HOME": useOverride ? directory.path : "", "PATH": "/usr/bin:/bin"]
                    try process.run()
                    process.waitUntilExit()
                    XCTAssertEqual(process.terminationStatus, 0)
                }
                let yaml = try String(contentsOf: file, encoding: .utf8)
                let expected = """

                - insert:
                    - id: mcp-paperrss
                      name: '@deepseek-ai/dsh-mcp-client'
                      config:
                        serverName: paperrss
                        transport: stdio
                        command: '/Applications/Paper Rss''s.app/Contents/MacOS/paperrss-agent'
                        args: [serve, --stdio, --client, dsh]
                        env:
                          PAPERRSS_AGENT_ENABLED: '1'

                """
                XCTAssertEqual(yaml, (initial?.hasPrefix("- id: other") == true ? initial! : "") + expected)
                // Decode the YAML single-quoted scalar and verify no shell quoting leaked into its value.
                let scalar = try XCTUnwrap(yaml.components(separatedBy: "        command: '").last?.components(separatedBy: "'\n").first)
                XCTAssertEqual(scalar.replacingOccurrences(of: "''", with: "'"), path)
                XCTAssertEqual(yaml.components(separatedBy: "id: mcp-paperrss").count - 1, 1)
            }
        }
    }

    func testTargetsAndMetadata() {
        XCTAssertEqual(AgentMCPInstallTarget.dsh.name, "DeepSeek dsh")
        XCTAssertEqual(AgentMCPInstallTarget.dsh.kind, .command)
        XCTAssertNil(AgentMCPInstallTarget.dsh.url(path: path))
        XCTAssertEqual(AgentMCPInstallTarget.pi.name, "Pi")
        XCTAssertEqual(AgentMCPInstallTarget.pi.kind, .command)
        XCTAssertNil(AgentMCPInstallTarget.pi.url(path: path))
        XCTAssertEqual(AgentMCPInstallTarget.allCases, [.codex, .claudeCode, .dsh, .pi, .cursor, .vscode, .vscodeInsiders])
        XCTAssertEqual(AgentMCPInstallTarget.allCases.map(\.label), ["codex", "claude-code", "dsh", "pi", "cursor", "vscode", "vscode-insiders"])
        XCTAssertEqual(AgentMCPInstallTarget.allCases.map(\.bundleIdentifier), [nil, nil, nil, nil, "com.todesktop.230313mzl4w4u92", "com.microsoft.VSCode", "com.microsoft.VSCodeInsiders"])
        XCTAssertEqual(AgentMCPInstallTarget.allCases.map(\.iconAssetName), ["AgentMCPCodex", "AgentMCPClaude", "AgentMCPDeepSeek", "AgentMCPPi", "AgentMCPCursor", "AgentMCPVSCode", "AgentMCPVSCode"])
    }
}
