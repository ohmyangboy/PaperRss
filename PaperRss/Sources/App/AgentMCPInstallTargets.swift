#if os(macOS)
import Foundation

enum AgentMCPInstallTarget: String, CaseIterable, Identifiable {
    case codex, claudeCode, dsh, pi, cursor, vscode, vscodeInsiders
    enum Kind { case deeplink, command }
    var id: String { rawValue }
    var label: String {
        switch self {
        case .vscodeInsiders: return "vscode-insiders"
        case .claudeCode: return "claude-code"
        default: return rawValue
        }
    }
    var name: String {
        switch self {
        case .cursor: return "Cursor"
        case .vscode: return "VS Code"
        case .vscodeInsiders: return "VS Code Insiders"
        case .claudeCode: return "Claude Code"
        case .codex: return "Codex CLI"
        case .dsh: return "DeepSeek dsh"
        case .pi: return "Pi"
        }
    }
    var kind: Kind {
        switch self {
        case .cursor, .vscode, .vscodeInsiders: return .deeplink
        case .claudeCode, .codex, .dsh, .pi: return .command
        }
    }
    var bundleIdentifier: String? {
        switch self {
        case .cursor: return "com.todesktop.230313mzl4w4u92"
        case .vscode: return "com.microsoft.VSCode"
        case .vscodeInsiders: return "com.microsoft.VSCodeInsiders"
        case .claudeCode, .codex, .dsh, .pi: return nil
        }
    }
    var iconAssetName: String {
        switch self {
        case .cursor: return "AgentMCPCursor"
        case .vscode, .vscodeInsiders: return "AgentMCPVSCode"
        case .claudeCode: return "AgentMCPClaude"
        case .codex: return "AgentMCPCodex"
        case .dsh: return "AgentMCPDeepSeek"
        case .pi: return "AgentMCPPi"
        }
    }
    private func server(path: String) -> [String: Any] {
        ["command": path, "args": ["serve", "--stdio", "--client", label], "env": ["PAPERRSS_AGENT_ENABLED": "1"]]
    }
    private func json(_ object: Any) -> String {
        let data = try! JSONSerialization.data(withJSONObject: object, options: [.sortedKeys, .withoutEscapingSlashes])
        return String(decoding: data, as: UTF8.self)
    }
    private func encode(_ value: String, allowed: String) -> String {
        value.utf8.map { byte in
            if allowed.utf8.contains(byte) { return String(UnicodeScalar(byte)) }
            return String(format: "%%%02X", byte)
        }.joined()
    }
    private var uriAllowed: String { "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_.!~*'()" }
    func url(path: String) -> URL? {
        switch self {
        case .cursor:
            let base64 = Data(json(server(path: path)).utf8).base64EncodedString()
            return URL(string: "cursor://anysphere.cursor-deeplink/mcp/install?name=paperrss&config=\(encode(base64, allowed: uriAllowed))")
        case .vscode, .vscodeInsiders:
            var object = server(path: path)
            object["name"] = "paperrss"
            object["type"] = "stdio"
            let scheme = self == .vscode ? "vscode" : "vscode-insiders"
            return URL(string: "\(scheme):mcp/install?\(encode(json(object), allowed: uriAllowed))")
        default: return nil
        }
    }
    func command(path: String) -> String? {
        let quoted = "'" + path.replacingOccurrences(of: "'", with: "'\\''") + "'"
        switch self {
        case .claudeCode: return "claude mcp add --scope user --env PAPERRSS_AGENT_ENABLED=1 --transport stdio paperrss -- \(quoted) serve --stdio --client \(label)"
        case .codex: return "codex mcp add paperrss --env PAPERRSS_AGENT_ENABLED=1 -- \(quoted) serve --stdio --client \(label)"
        case .pi: return "pi mcp add paperrss --env PAPERRSS_AGENT_ENABLED=1 -- \(quoted) serve --stdio --client \(label)"
        case .dsh:
            // YAML and POSIX shell quoting are separate layers; never interpolate the path as shell code.
            let yamlPath = "'" + path.replacingOccurrences(of: "'", with: "''") + "'"
            // Patch layers only override existing ids; new entries must be wrapped in a top-level `insert:` patch.
            let lines = ["", "- insert:", "    - id: mcp-paperrss", "      name: '@deepseek-ai/dsh-mcp-client'", "      config:",
                         "        serverName: paperrss", "        transport: stdio", "        command: \(yamlPath)",
                         "        args: [serve, --stdio, --client, dsh]", "        env:", "          PAPERRSS_AGENT_ENABLED: '1'"]
            let payload = lines.map { "'" + $0.replacingOccurrences(of: "'", with: "'\\''") + "'" }.joined(separator: " ")
            // Empty flow arrays cannot be followed by block-array entries. Ignore comments when checking emptiness.
            return #"f="${DSH_HOME:-$HOME/.dsh}/cordis.patch.yml"; mkdir -p "$(dirname "$f")" && if ! grep -Eq '^[[:space:]]*(-[[:space:]]*)?id:[[:space:]]*mcp-paperrss([[:space:]]*(#.*)?)?$' "$f" 2>/dev/null; then if [ ! -e "$f" ] || awk '{sub(/#.*/, ""); gsub(/[[:space:]]/, ""); s=s $0} END {exit !(s == "" || s == "[]")}' "$f"; then : > "$f"; fi && printf '%s\n' "# + payload + #" >> "$f"; fi"#
        default: return nil
        }
    }
}
#endif
