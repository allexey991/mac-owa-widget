import AppKit
import SwiftUI

/// Settings tab for the Calendar.app subscription: the switch, the subscription address and the
/// manual steps. The subscription itself cannot be automated: Calendar rejects `webcal://` to
/// 127.0.0.1 (it insists on TLS) and `file://` outright, so the user pastes an `http://` address.
struct ICSFeedSettingsView: View {
    @ObservedObject private var feed = ICSFeedService.shared
    @EnvironmentObject private var localization: LocalizationService
    @State private var copied = false
    @State private var portText = ""
    @State private var confirmingNewAddress = false

    var body: some View {
        Form {
            Section {
                Toggle(localization.tr("icsFeed.enabled"), isOn: $feed.isEnabled)
                Text(localization.tr("icsFeed.description"))
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                Label {
                    Text(localization.tr("icsFeed.privacy.warning"))
                        .font(.system(size: 11))
                } icon: {
                    Image(systemName: "exclamationmark.shield")
                        .foregroundStyle(.orange)
                }
                LabeledContent(localization.tr("icsFeed.status")) {
                    HStack(spacing: 6) {
                        Text(statusText)
                        if canRetry {
                            Button(localization.tr("icsFeed.retry")) { feed.retry() }
                                .controlSize(.small)
                        }
                    }
                }
            }

            if feed.isEnabled, let url = feed.feedURL {
                Section(localization.tr("icsFeed.subscribe.section")) {
                    HStack {
                        Text(url.absoluteString)
                            .font(.system(size: 11, design: .monospaced))
                            .textSelection(.enabled)
                            .lineLimit(1)
                            .truncationMode(.middle)
                        Spacer()
                        Button(copied ? localization.tr("icsFeed.copied") : localization.tr("icsFeed.copy")) {
                            copy(url)
                        }
                        .controlSize(.small)
                    }
                    VStack(alignment: .leading, spacing: 4) {
                        ForEach(1...4, id: \.self) { step in
                            Text(localization.tr("icsFeed.subscribe.step\(step)"))
                                .font(.system(size: 11))
                        }
                    }
                    Button(localization.tr("icsFeed.openCalendar")) {
                        copy(url)
                        openCalendar()
                    }
                    Text(localization.tr("icsFeed.subscribe.hint"))
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }

                Section(localization.tr("icsFeed.advanced.section")) {
                    HStack {
                        Text(localization.tr("icsFeed.port"))
                        TextField("", text: $portText)
                            .frame(width: 70)
                            .onSubmit(applyPort)
                        Button(localization.tr("icsFeed.port.apply"), action: applyPort)
                            .controlSize(.small)
                            .disabled(UInt16(portText) == nil || UInt16(portText) == feed.port || UInt16(portText) == 0)
                    }
                    Button(localization.tr("icsFeed.newAddress")) { confirmingNewAddress = true }
                    Text(localization.tr("icsFeed.advanced.hint"))
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }
            }

            Section {
                Text(localization.tr("icsFeed.unsubscribe.hint"))
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .frame(minWidth: 320, minHeight: 420)
        .onAppear { portText = String(feed.port) }
        .onChange(of: feed.port) { portText = String($0) }
        .alert(localization.tr("icsFeed.newAddress.confirm.title"), isPresented: $confirmingNewAddress) {
            Button(localization.tr("icsFeed.newAddress.confirm.action"), role: .destructive) {
                feed.regenerateAddress()
                copied = false
            }
            Button(localization.tr("icsFeed.cancel"), role: .cancel) {}
        } message: {
            Text(localization.tr("icsFeed.newAddress.confirm.message"))
        }
    }

    private var statusText: String {
        switch feed.status {
        case .stopped:
            return localization.tr("icsFeed.status.stopped")
        case .starting:
            return localization.tr("icsFeed.status.starting")
        case .listening:
            guard let last = feed.lastRequest else { return localization.tr("icsFeed.status.waiting") }
            let time = last.date.formatted(date: .omitted, time: .shortened)
            return localization.tr("icsFeed.status.served", time, last.status)
        case .portInUse(let port):
            return localization.tr("icsFeed.status.portInUse", Int(port))
        case .failed(let reason):
            return localization.tr("icsFeed.status.failed", reason)
        }
    }

    private var canRetry: Bool {
        switch feed.status {
        case .portInUse, .failed: true
        default: false
        }
    }

    private func applyPort() {
        guard let port = UInt16(portText), port > 0 else { return }
        feed.setPort(port)
        copied = false
    }

    private func copy(_ url: URL) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(url.absoluteString, forType: .string)
        copied = true
    }

    private func openCalendar() {
        guard let app = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.apple.iCal") else { return }
        NSWorkspace.shared.openApplication(at: app, configuration: NSWorkspace.OpenConfiguration())
    }
}
