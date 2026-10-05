import AppKit
import SwiftUI

/// Settings tab for the MCP server: the switch, its privacy warning, ready-to-paste client
/// configuration and the in-memory call journal.
struct MCPSettingsView: View {
    @ObservedObject private var server = MCPServerService.shared
    @EnvironmentObject private var localization: LocalizationService
    @State private var copiedSnippet: Snippet?

    enum Snippet: String, CaseIterable, Identifiable {
        case claudeCode, claudeDesktop, vsCode
        var id: String { rawValue }
    }

    var body: some View {
        Form {
            Section {
                Toggle(localization.tr("mcp.enabled"), isOn: $server.isEnabled)
                Text(localization.tr("mcp.description"))
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                Label {
                    Text(localization.tr("mcp.privacy.warning"))
                        .font(.system(size: 11))
                } icon: {
                    Image(systemName: "exclamationmark.shield")
                        .foregroundStyle(.orange)
                }
                LabeledContent(localization.tr("mcp.status"), value: statusText)
            }

            Section(localization.tr("mcp.connect.section")) {
                if server.isBridgeInstalled {
                    ForEach(Snippet.allCases) { snippet in
                        snippetRow(snippet)
                    }
                    Text(localization.tr("mcp.connect.hint"))
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                } else {
                    Text(localization.tr("mcp.connect.bridgeMissing"))
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }
            }

            Section(localization.tr("mcp.journal.section")) {
                if server.journal.isEmpty {
                    Text(localization.tr("mcp.journal.empty"))
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(server.journal.prefix(15)) { entry in
                        HStack(spacing: 6) {
                            Image(systemName: entry.isError ? "xmark.circle" : "checkmark.circle")
                                .foregroundStyle(entry.isError ? .orange : .secondary)
                            Text(entry.tool)
                                .font(.system(size: 11, design: .monospaced))
                            if let client = entry.client, !client.isEmpty {
                                Text(client)
                                    .font(.system(size: 11))
                                    .foregroundStyle(.secondary)
                            }
                            Spacer()
                            Text(entry.date, style: .time)
                                .font(.system(size: 11))
                                .foregroundStyle(.secondary)
                        }
                    }
                    Text(localization.tr("mcp.journal.hint"))
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }
            }
        }
        .formStyle(.grouped)
        .frame(minWidth: 320, minHeight: 420)
    }

    private var statusText: String {
        switch server.status {
        case .stopped:
            return localization.tr("mcp.status.stopped")
        case .unavailable(let reason):
            return localization.tr("mcp.status.unavailable", reason)
        case .listening:
            guard server.isEnabled else { return localization.tr("mcp.status.disabled") }
            let connected = server.clients.count
            return connected == 0
                ? localization.tr("mcp.status.ready")
                : localization.tr("mcp.status.connected", connected)
        }
    }

    private func snippetRow(_ snippet: Snippet) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(title(snippet))
                    .font(.system(size: 12, weight: .medium))
                Spacer()
                Button(copiedSnippet == snippet ? localization.tr("mcp.connect.copied") : localization.tr("mcp.connect.copy")) {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(text(snippet), forType: .string)
                    copiedSnippet = snippet
                }
                .controlSize(.small)
            }
            Text(text(snippet))
                .font(.system(size: 10, design: .monospaced))
                .foregroundStyle(.secondary)
                .textSelection(.enabled)
                .lineLimit(nil)
        }
    }

    private func title(_ snippet: Snippet) -> String {
        switch snippet {
        case .claudeCode: localization.tr("mcp.connect.claudeCode")
        case .claudeDesktop: localization.tr("mcp.connect.claudeDesktop")
        case .vsCode: localization.tr("mcp.connect.vsCode")
        }
    }

    private func text(_ snippet: Snippet) -> String {
        let path = server.bridgePath
        switch snippet {
        case .claudeCode:
            return "claude mcp add owa-widget -- \"\(path)\""
        case .claudeDesktop:
            return Self.json(["mcpServers": ["owa-widget": ["command": path]]])
        case .vsCode:
            return Self.json(["servers": ["owa-widget": ["type": "stdio", "command": path]]])
        }
    }

    private static func json(_ object: [String: Any]) -> String {
        guard let data = try? JSONSerialization.data(
            withJSONObject: object,
            options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        ) else { return "" }
        return String(data: data, encoding: .utf8) ?? ""
    }
}
