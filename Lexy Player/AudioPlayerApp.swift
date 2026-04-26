import SwiftUI
import Combine
import MediaPlayer

// MARK: - Notification names (media keys only — file open now uses FileOpenRouter)

extension Notification.Name {
    static let mediaKeyTogglePlay = Notification.Name("com.bpmapp.mediaKey.togglePlay")
    static let mediaKeyNext       = Notification.Name("com.bpmapp.mediaKey.next")
    static let mediaKeyPrevious   = Notification.Name("com.bpmapp.mediaKey.previous")
}

// MARK: - File open router
//
// Singleton @Published bridge between AppDelegate and SwiftUI.
// AppDelegate writes pendingURL; ContentView reacts via .onChange which fires
// on the next SwiftUI update — guaranteed after the engine is initialised,
// regardless of whether the app was already running or just launched.
//
// With LSMultipleInstancesProhibited = YES in Info.plist the OS prevents a
// second instance from launching and routes file-open events directly to the
// running instance via application(_:open:). The programmatic guard below is
// kept as a belt-and-suspenders fallback only.

final class FileOpenRouter: ObservableObject {
    static let shared = FileOpenRouter()
    @Published var pendingURL: URL?
    private init() {}
}

// MARK: - App delegate

class AppDelegate: NSObject, NSApplicationDelegate {

    // Injected by BPMApp once the StateObjects are ready.
    // Direct references let us bypass SwiftUI lifecycle entirely.
    var audioEngine:     AudioEngine?
    var playlistManager: PlaylistManager?

    // MARK: Lifecycle

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Belt-and-suspenders single-instance guard (LSMultipleInstancesProhibited
        // in Info.plist is the primary guard; this handles any edge cases).
        let bundleID = Bundle.main.bundleIdentifier ?? ""
        let others   = NSRunningApplication
            .runningApplications(withBundleIdentifier: bundleID)
            .filter { $0 != .current }

        if !others.isEmpty {
            // Another instance is running — activate it and exit.
            // The file-open event will be retried by the OS since
            // LSMultipleInstancesProhibited routes it to the existing instance.
            others.first?.activate(options: .activateIgnoringOtherApps)
            NSApp.terminate(nil)
            return
        }

        setupRemoteCommandCenter()
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }

    // MARK: File open (Finder double-click / file association)

    // Modern Swift API — preferred by macOS 10.13+. This is the one the OS actually calls.
    func application(_ application: NSApplication, open urls: [URL]) {
        print("🎵 [AppDelegate] application(_:open:[URL]) — \(urls.map(\.path))")
        guard let first = urls.first else { return }
        routeFileOpen(first)
    }

    // Legacy ObjC-style fallbacks (kept for safety on older systems)
    func application(_ sender: NSApplication, openFile filename: String) -> Bool {
        print("🎵 [AppDelegate] application(_:openFile:) — \(filename)")
        routeFileOpen(URL(fileURLWithPath: filename)); return true
    }

    func application(_ sender: NSApplication, openFiles filenames: [String]) {
        print("🎵 [AppDelegate] application(_:openFiles:) — \(filenames)")
        guard let first = filenames.first else { return }
        routeFileOpen(URL(fileURLWithPath: first))
    }

    private func routeFileOpen(_ url: URL) {
        print("🎵 [routeFileOpen] url=\(url.path)  engine=\(audioEngine != nil ? "SET" : "NIL")  playlist=\(playlistManager != nil ? "SET" : "NIL")")
        NSApp.activate(ignoringOtherApps: true)
        NSApp.windows.first?.makeKeyAndOrderFront(nil)

        if let engine = audioEngine, let playlist = playlistManager {
            // Hot start: both objects ready — call directly, zero SwiftUI dependency.
            print("🎵 [routeFileOpen] hot path — direct call")
            Task { @MainActor in
                playlist.currentTrackID = nil  // deselect playlist — track is external
                engine.loadExternalURL(url)    // play ASAP + scan BPM in background
                // Drop focus from BPM field
                NSApp.keyWindow?.makeFirstResponder(nil)
            }
        } else {
            // Cold start: objects not yet ready — store for onAppear to handle.
            print("🎵 [routeFileOpen] cold path — pendingURL")
            FileOpenRouter.shared.pendingURL = url
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

    private let playerH: CGFloat       = 32
    private let playlistMinH: CGFloat  = 200
    private let playlistIdealH: CGFloat = 440

    var body: some View {
        VStack(spacing: 0) {
            ContentView(playlistVisible: $playlistVisible)
                .frame(height: playerH)

            if playlistVisible {
                PlaylistView()
            }
        }
        .frame(
            minWidth:    580,
            idealWidth:  800,
            maxWidth:    .infinity,
            minHeight:   playlistVisible ? playerH + playlistMinH   : playerH,
            idealHeight: playlistVisible ? playerH + playlistIdealH : playerH,
            maxHeight:   playlistVisible ? .infinity                : playerH
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
        // Window = exactly one window, never spawns extras on file-open events.
        Window("BPM Player", id: "main") {
            RootView()
                .environmentObject(engine)
                .environmentObject(playlist)
                .onAppear {
                    appDelegate.audioEngine     = engine
                    appDelegate.playlistManager = playlist
                }
        }
        .defaultSize(width: 800, height: 32)
        .windowResizability(.contentSize)
        .commands {
            CommandGroup(replacing: .newItem) {}
        }
    }
}
