import SwiftUI
import MediaPlayer
import Sparkle

// MARK: - Notification names

extension Notification.Name {
    /// Posted by AppDelegate when the OS asks the app to open an audio file.
    static let openAudioFile = Notification.Name("com.bpmapp.openAudioFile")

    // Media-key notifications (posted by MPRemoteCommandCenter handlers)
    static let mediaKeyTogglePlay = Notification.Name("com.bpmapp.mediaKey.togglePlay")
    static let mediaKeyNext       = Notification.Name("com.bpmapp.mediaKey.next")
    static let mediaKeyPrevious   = Notification.Name("com.bpmapp.mediaKey.previous")
}

// MARK: - App delegate

class AppDelegate: NSObject, NSApplicationDelegate {

    /// Sparkle updater — must be retained for the lifetime of the app.
    private var updaterController: SPUStandardUpdaterController!

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Start Sparkle — checks for updates automatically on launch
        // (frequency controlled by SUScheduledCheckInterval in Info.plist)
        updaterController = SPUStandardUpdaterController(
            startingUpdater: true,
            updaterDelegate: nil,
            userDriverDelegate: nil
        )
        setupRemoteCommandCenter()
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }

    func application(_ sender: NSApplication, openFile filename: String) -> Bool {
        let url = URL(fileURLWithPath: filename)
        NotificationCenter.default.post(name: .openAudioFile, object: url)
        return true
    }

    func application(_ sender: NSApplication, openFiles filenames: [String]) {
        for filename in filenames {
            NotificationCenter.default.post(name: .openAudioFile,
                                            object: URL(fileURLWithPath: filename))
        }
    }

    // MARK: Media keys (⏮ ⏯ ⏭ on keyboard / Touch Bar)

    private func setupRemoteCommandCenter() {
        let nc = NotificationCenter.default
        let c  = MPRemoteCommandCenter.shared()

        c.togglePlayPauseCommand.isEnabled = true
        c.togglePlayPauseCommand.addTarget { _ in
            nc.post(name: .mediaKeyTogglePlay, object: nil); return .success
        }
        c.playCommand.isEnabled = true
        c.playCommand.addTarget { _ in
            nc.post(name: .mediaKeyTogglePlay, object: nil); return .success
        }
        c.pauseCommand.isEnabled = true
        c.pauseCommand.addTarget { _ in
            nc.post(name: .mediaKeyTogglePlay, object: nil); return .success
        }
        c.nextTrackCommand.isEnabled = true
        c.nextTrackCommand.addTarget { _ in
            nc.post(name: .mediaKeyNext, object: nil); return .success
        }
        c.previousTrackCommand.isEnabled = true
        c.previousTrackCommand.addTarget { _ in
            nc.post(name: .mediaKeyPrevious, object: nil); return .success
        }
    }
}

// MARK: - Root view  (player bar + collapsible playlist)

struct RootView: View {

    @EnvironmentObject private var engine:   AudioEngine
    @EnvironmentObject private var playlist: PlaylistManager

    @State private var playlistVisible = false

    // Heights
    private let playerH: CGFloat  = 32
    private let playlistMinH: CGFloat = 200
    private let playlistIdealH: CGFloat = 440

    var body: some View {
        VStack(spacing: 0) {
            // ── Fixed player bar ─────────────────────────────────────────
            ContentView(playlistVisible: $playlistVisible)
                .frame(height: playerH)

            // ── Expandable playlist ──────────────────────────────────────
            if playlistVisible {
                PlaylistView()
            }
        }
        // No animation — playlist appears/disappears instantly
        // Width: always the same. Height: locked at playerH when collapsed,
        // free to resize (within min) when expanded.
        .frame(
            minWidth:   580,
            idealWidth: 800,
            maxWidth:   .infinity,
            minHeight:  playlistVisible ? playerH + playlistMinH  : playerH,
            idealHeight: playlistVisible ? playerH + playlistIdealH : playerH,
            maxHeight:  playlistVisible ? .infinity : playerH
        )
    }
}

// MARK: - App entry point

@main
struct BPMApp: App {

    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate

    @StateObject private var engine   = AudioEngine()
    @StateObject private var playlist = PlaylistManager()

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(engine)
                .environmentObject(playlist)
        }
        .defaultSize(width: 800, height: 32)
        .windowResizability(.contentSize)
        .commands {
            CommandGroup(replacing: .newItem) {}
        }
    }
}
