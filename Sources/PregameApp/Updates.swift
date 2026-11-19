import Combine
import Sparkle
import SwiftUI

/// In-app updates through Sparkle (docs/updates.md). The appcast URL, the
/// update key and the default for automatic checks live in Info.plist; this
/// starts the updater and exposes what the menu and Settings show.
final class Updates: ObservableObject {
    static let shared = Updates()

    private let controller = SPUStandardUpdaterController(startingUpdater: false,
                                                          updaterDelegate: nil, userDriverDelegate: nil)
    private var updater: SPUUpdater { controller.updater }

    @Published private(set) var canCheck = false
    @Published private(set) var lastChecked: Date?

    /// Only a built app (scripts/build-app.sh) carries the appcast URL. A bare
    /// `swift run` has none, and Sparkle would only report that it can't start.
    let isAvailable = Bundle.main.object(forInfoDictionaryKey: "SUFeedURL") != nil

    private init() {
        guard isAvailable else { return }
        controller.startUpdater()
        updater.publisher(for: \.canCheckForUpdates).receive(on: RunLoop.main).assign(to: &$canCheck)
        updater.publisher(for: \.lastUpdateCheckDate).receive(on: RunLoop.main).assign(to: &$lastChecked)
    }

    func checkForUpdates() { controller.checkForUpdates(nil) }

    var checksAutomatically: Bool {
        get { updater.automaticallyChecksForUpdates }
        set { objectWillChange.send(); updater.automaticallyChecksForUpdates = newValue }
    }

    var installsAutomatically: Bool {
        get { updater.automaticallyDownloadsUpdates }
        set { objectWillChange.send(); updater.automaticallyDownloadsUpdates = newValue }
    }
}

/// Pregame › Check for Updates…
struct CheckForUpdatesButton: View {
    @ObservedObject private var updates = Updates.shared

    var body: some View {
        Button("Check for Updates…") { updates.checkForUpdates() }
            .disabled(!updates.canCheck)
    }
}

/// Settings › Updates.
struct UpdateSettings: View {
    @ObservedObject private var updates = Updates.shared

    var body: some View {
        Form {
            Section {
                Toggle("Check for updates automatically", isOn: $updates.checksAutomatically)
                Toggle("Download and install updates automatically", isOn: $updates.installsAutomatically)
                    .disabled(!updates.checksAutomatically)
            } footer: {
                Text("Pregame checks GitHub about once a day. Updates are signed, and installing one keeps your Mixes, settings and folder access.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section {
                HStack {
                    Text(lastCheckedText).foregroundStyle(.secondary)
                    Spacer()
                    Button("Check Now") { updates.checkForUpdates() }
                        .disabled(!updates.canCheck)
                }
            }
        }
        .formStyle(.grouped)
        .disabled(!updates.isAvailable)
    }

    private var lastCheckedText: String {
        guard updates.isAvailable else { return "Updates work only in the built app (scripts/build-app.sh)." }
        guard let date = updates.lastChecked else { return "Not checked yet" }
        return "Last checked \(date.formatted(.relative(presentation: .named)))"
    }
}
