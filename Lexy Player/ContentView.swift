import SwiftUI
import UniformTypeIdentifiers
import AppKit

// MARK: - Hex colour helper

extension Color {
    init(hex: String) {
        let h = hex.hasPrefix("#") ? String(hex.dropFirst()) : hex
        let v = UInt64(h, radix: 16) ?? 0
        self.init(
            red:   Double((v >> 16) & 0xFF) / 255,
            green: Double((v >> 8)  & 0xFF) / 255,
            blue:  Double(v         & 0xFF) / 255
        )
    }

    /// Returns a color that automatically adapts to light / dark mode
    /// using macOS's native dynamic NSColor provider.
    init(light lightHex: String, dark darkHex: String) {
        func nsColor(_ hex: String) -> NSColor {
            let h = hex.hasPrefix("#") ? String(hex.dropFirst()) : hex
            let v = UInt64(h, radix: 16) ?? 0
            return NSColor(
                red:   CGFloat((v >> 16) & 0xFF) / 255,
                green: CGFloat((v >>  8) & 0xFF) / 255,
                blue:  CGFloat( v        & 0xFF) / 255,
                alpha: 1
            )
        }
        self.init(NSColor(name: nil) { appearance in
            appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
                ? nsColor(darkHex) : nsColor(lightHex)
        })
    }
}

// MARK: - CGFloat clamp (local)

private extension CGFloat {
    func clamped01() -> CGFloat { Swift.min(Swift.max(self, 0), 1) }
}

// MARK: - Pill button style

private struct PillButtonStyle: ButtonStyle {
    var width:            CGFloat = 27
    var isActive:         Bool    = false
    var activeBackground: Color   = Color(light: "d4d4d3", dark: "505050")

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .frame(width: width, height: 24)
            .background(
                RoundedRectangle(cornerRadius: 5)
                    .fill(isActive ? activeBackground : Color(light: "f6f6f5", dark: "3c3c3c"))
                    .shadow(color: .black.opacity(0.25), radius: 0.5, x: 0, y: 0)
            )
            .opacity(configuration.isPressed ? 0.75 : 1.0)
    }
}

// MARK: - Pill slider  (timeline)

private struct PillSlider: View {
    @Binding var value: Double
    let total: Double
    var onEditingChanged: (Bool) -> Void = { _ in }

    private let kThumb: CGFloat = 17
    private let kTrack: CGFloat = 20

    var body: some View {
        GeometryReader { geo in
            let travel = max(geo.size.width - kThumb, 1)
            let ratio  = CGFloat(total > 0 ? value / total : 0).clamped01()

            ZStack(alignment: .leading) {
                Capsule()
                    .fill(LinearGradient(
                        stops: [
                            .init(color: Color(light: "B7B7B7", dark: "383838"), location: 0),
                            .init(color: Color(light: "CECECE", dark: "424242"), location: 0.505),
                            .init(color: Color(light: "DCDCDC", dark: "4a4a4a"), location: 1)
                        ],
                        startPoint: .top, endPoint: .bottom
                    ))
                    .overlay(Capsule().strokeBorder(Color(light: "B8B8B8", dark: "2a2a2a"), lineWidth: 0.5))
                    .frame(height: kTrack)

                Circle()
                    .fill(.white)
                    .frame(width: kThumb, height: kThumb)
                    .offset(x: ratio * travel)
                    .allowsHitTesting(false)
            }
            .frame(height: kTrack)
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { g in
                        let x  = max(0, min(g.location.x - kThumb / 2, travel))
                        value  = Double(x / travel) * total
                        onEditingChanged(true)
                    }
                    .onEnded { _ in onEditingChanged(false) }
            )
        }
        .frame(height: kTrack)
    }
}

// MARK: - BPM toggle switch
// Binary pill switch: knob sits 1 pt from left edge (OFF) or right edge (ON).

private struct BPMToggle: View {
    @Binding var isOn: Bool
    var disabled: Bool = false

    private let kWidth:  CGFloat = 36
    private let kHeight: CGFloat = 20
    private var kKnob:   CGFloat { kHeight - 2 }   // 1 pt padding top+bottom

    var body: some View {
        ZStack(alignment: .leading) {
            Capsule()
                .fill(isOn
                      ? AnyShapeStyle(Color.accentColor)
                      : AnyShapeStyle(LinearGradient(
                            stops: [
                                .init(color: Color(light: "B7B7B7", dark: "383838"), location: 0),
                                .init(color: Color(light: "CECECE", dark: "424242"), location: 0.505),
                                .init(color: Color(light: "DCDCDC", dark: "4a4a4a"), location: 1)
                            ],
                            startPoint: .top, endPoint: .bottom
                        ))
                )
                .overlay(Capsule().strokeBorder(
                    isOn ? Color.accentColor.opacity(0.7) : Color(light: "B8B8B8", dark: "2a2a2a"),
                    lineWidth: 0.5
                ))
                .animation(.spring(duration: 0.18, bounce: 0.25), value: isOn)

            Circle()
                .fill(.white)
                .frame(width: kKnob, height: kKnob)
                // OFF → 1 pt from left;  ON → 1 pt from right
                .offset(x: isOn ? (kWidth - 1 - kKnob) : 1)
                .animation(.spring(duration: 0.18, bounce: 0.25), value: isOn)
                .allowsHitTesting(false)
        }
        .frame(width: kWidth, height: kHeight)
        .contentShape(Rectangle())
        .onTapGesture { guard !disabled else { return }; isOn.toggle() }
        .opacity(disabled ? 0.45 : 1.0)
    }
}

// MARK: - Volume slider
// Thin rect track, tick mark at 80 % (= 0 dB / 1.0×), snaps near tick,
// allows boost above 1.0 (up to kMaxVol = 1.55).

private struct VolumeSlider: View {
    @Binding var value: Double   // maps directly to engine.volume  (0 … 1.25)

    private let kThumb:    CGFloat = 16.5
    private let kTrack:    CGFloat = 4
    private let kHeight:   CGFloat = 17
    private let kMaxVol:   Double  = 1.55   // 0 dB at 64.5 % of travel
    private let kTickFrac: CGFloat = 0.645  // position of 0 dB tick in [0, 1] of travel
    private let kSnapPx:   CGFloat = 7      // magnetic snap radius (pts)

    var body: some View {
        GeometryReader { geo in
            let travel  = max(geo.size.width - kThumb, 1)
            let tickX   = kTickFrac * travel
            let ratio   = CGFloat(value / kMaxVol).clamped01()
            let thumbX  = ratio * travel

            ZStack(alignment: .leading) {
                // grey track
                RoundedRectangle(cornerRadius: 2)
                    .fill(Color(light: "AEAFAF", dark: "555555"))
                    .frame(height: kTrack)
                    .padding(.horizontal, kThumb / 2)

                // 0 dB tick
                Rectangle()
                    .fill(Color.primary)
                    .frame(width: 1, height: kHeight + 2)
                    .offset(x: tickX + kThumb / 2 - 0.5)

                // knob
                Circle()
                    .fill(.white)
                    .overlay(Circle().strokeBorder(Color(light: "C6C6C6", dark: "555555"), lineWidth: 0.5))
                    .frame(width: kThumb, height: kThumb)
                    .offset(x: thumbX)
                    .allowsHitTesting(false)
            }
            .frame(height: kHeight)
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { g in
                        let rawX    = max(0, min(g.location.x - kThumb / 2, travel))
                        // snap to 0 dB tick when within kSnapPx
                        let finalX  = abs(rawX - tickX) < kSnapPx ? tickX : rawX
                        value = Double(finalX / travel) * kMaxVol
                    }
            )
        }
        .frame(height: kHeight)
    }
}

// MARK: - Main player view

struct ContentView: View {

    @EnvironmentObject private var engine:   AudioEngine
    @EnvironmentObject private var playlist: PlaylistManager

    /// Bound to RootView — toggling this expands/collapses the playlist panel.
    @Binding var playlistVisible: Bool

    // Observe the singleton so SwiftUI re-renders when pendingURL changes.
    @ObservedObject private var fileRouter = FileOpenRouter.shared

    @State private var sliderValue      = 0.0
    @State private var isSeeking        = false
    @State private var isDragTarget     = false
    @State private var showRemainingTime = false
    @State private var isPinned         = false

    @State private var userTargetBPM: Double = 120
    @State private var fieldText             = "120"
    @State private var bpmEnabled            = false
    @FocusState private var bpmFocused: Bool

    // MARK: Computed

    /// Navigation title: ID3 artist – title when available, else filename, else app name.
    private var currentTrackTitle: String {
        if let id    = playlist.currentTrackID,
           let track = playlist.tracks.first(where: { $0.id == id }) {
            return track.displayName
        }
        // fileName already strips the extension (set in AudioEngine.loadURL)
        let name = engine.fileName
        return name.isEmpty ? "BPM Player" : name
    }

    // MARK: Body

    var body: some View {
        HStack(spacing: 0) {

            // ── Left: prev · play · next · playlist ──────────────────────
            HStack(spacing: 2) {
                Button { playPrevious() } label: {
                    Image(systemName: "backward.end.fill")
                        .font(.system(size: 10))
                        .foregroundStyle(.primary)
                }
                .buttonStyle(PillButtonStyle(width: 27))
                .disabled(!engine.hasFile)
                .help("Previous track  ⌘←")

                Button { handlePlayButton() } label: {
                    Image(systemName: engine.isPlaying ? "pause.fill" : "play.fill")
                        .font(.system(size: 11))
                        .foregroundStyle(.primary)
                }
                .buttonStyle(PillButtonStyle(width: 27))
                .disabled(!engine.hasFile && playlist.tracks.isEmpty)
                .help(engine.isPlaying ? "Pause  Space" : "Play  Space")

                Button { playNext() } label: {
                    Image(systemName: "forward.end.fill")
                        .font(.system(size: 10))
                        .foregroundStyle(.primary)
                }
                .buttonStyle(PillButtonStyle(width: 27))
                .disabled(!engine.hasFile)
                .help("Next track  ⌘→")

                Button { togglePlaylist() } label: {
                    VStack(spacing: 3) {
                        ForEach(0..<3, id: \.self) { _ in
                            Rectangle().fill(Color.primary).frame(width: 13, height: 1)
                        }
                    }
                }
                .buttonStyle(PillButtonStyle(width: 27))
                .help("Toggle Playlist  ⌘O")
                .keyboardShortcut("o", modifiers: .command)
            }
            .padding(.trailing, 10)

            // ── Centre: timeline + time ───────────────────────────────────
            HStack(spacing: 8) {
                PillSlider(
                    value: Binding(get: { sliderValue }, set: { sliderValue = $0 }),
                    total: max(engine.duration, 1),
                    onEditingChanged: { editing in
                        isSeeking = editing
                        if !editing { engine.seek(to: sliderValue) }
                    }
                )
                .frame(minWidth: 80)
                .disabled(!engine.hasFile)

                // ① time — tap to toggle elapsed ↔ remaining
                Text(timeText)
                    .font(.system(size: 12, weight: .bold))
                    .foregroundStyle(.primary)
                    .frame(width: 44, alignment: .center)
                    .contentShape(Rectangle())
                    .onTapGesture { if engine.hasFile { showRemainingTime.toggle() } }
            }

            Spacer(minLength: 12)

            // ── Right: BPM · KEY LOCK · volume ───────────────────────────
            HStack(spacing: 16) {

                // BPM field + ② BPM toggle switch
                HStack(spacing: 6) {
                    TextField(
                        engine.detectedBPM > 0
                            ? String(Int(engine.detectedBPM)) : "BPM",
                        text: $fieldText
                    )
                    .font(.system(size: 12, weight: .bold))
                    .multilineTextAlignment(.center)
                    .textFieldStyle(.plain)
                    .frame(width: 50, height: 24)
                    .background(
                        RoundedRectangle(cornerRadius: 5)
                            .fill(Color(light: "f6f6f5", dark: "3c3c3c"))
                            .shadow(color: .black.opacity(0.25), radius: 0.5)
                    )
                    .focused($bpmFocused)
                    .onSubmit { handleBPMSubmit() }
                    .onChange(of: bpmFocused) { handleBPMFocus($0) }

                    // ② Binary BPM toggle (pill switch)
                    BPMToggle(
                        isOn: Binding(
                            get: { bpmEnabled },
                            set: { newVal in
                                bpmEnabled = newVal
                                if newVal {
                                    if engine.detectedBPM > 0, userTargetBPM > 0 {
                                        engine.applyTargetBPM(userTargetBPM)
                                    }
                                    fieldText = String(Int(userTargetBPM))
                                } else {
                                    engine.resetRate()
                                    fieldText = engine.detectedBPM > 0
                                        ? String(Int(engine.detectedBPM))
                                        : String(Int(userTargetBPM))
                                }
                            }
                        ),
                        disabled: !engine.hasFile
                    )
                    .help(bpmEnabled
                          ? "BPM match ON — tap to restore original speed"
                          : "BPM match OFF — tap to play at \(Int(userTargetBPM)) BPM")
                }

                // ③ KEY LOCK
                Button { engine.toggleMasterTempo() } label: {
                    Text("KEY LOCK")
                        .font(.system(size: 9, weight: .bold))
                        .foregroundStyle(engine.masterTempo ? Color.accentColor : .primary)
                }
                .buttonStyle(PillButtonStyle(width: 65, isActive: engine.masterTempo,
                                             activeBackground: Color(light: "EBF1FE", dark: "1e3260")))
                .help(engine.masterTempo
                      ? "Master Tempo ON — pitch stays constant"
                      : "Master Tempo OFF — pitch shifts with speed")

                // ④ Volume slider (tick at 64.5 % = 0 dB, snaps, boosts up to 1.55 ×)
                VolumeSlider(
                    value: Binding(
                        get: { Double(engine.volume) },
                        set: { engine.volume = Float($0) }
                    )
                )
                .frame(width: 68)
                .help(String(format: "Volume: %.0f%%", Double(engine.volume) / 1.55 * 100))

                // ⑤ Pin — lives in the player bar (not the toolbar) so it
                //   never shifts when the window re-lays out its toolbar.
                Button { isPinned.toggle() } label: {
                    Image(systemName: isPinned ? "pin.fill" : "pin")
                        .font(.system(size: 12))
                        .foregroundStyle(isPinned ? Color.accentColor : Color.secondary)
                        .frame(width: 18, height: 18)   // fixed size — both variants
                }
                .buttonStyle(.plain)
                .help(isPinned ? "Unpin window" : "Keep window above all others")
            }
        }
        .padding(.horizontal, 10)
        .frame(height: 32)
        .background(Color(light: "e7e7e7", dark: "2c2c2c"))
        .overlay(alignment: .top) {
            Rectangle().fill(Color(light: "c6c6c6", dark: "1c1c1c")).frame(height: 0.5)
        }
        .background(WindowPinHelper(isPinned: isPinned, title: currentTrackTitle))
        .onDrop(of: [.fileURL], isTargeted: $isDragTarget, perform: handleDrop)
        .overlay(
            isDragTarget
                ? RoundedRectangle(cornerRadius: 4)
                    .stroke(Color.accentColor, lineWidth: 2).padding(1)
                : nil
        )
        .onChange(of: engine.currentTime) { t in
            if !isSeeking { sliderValue = t }
        }
        .onChange(of: playlist.currentTrackBPM) { bpm in
            guard bpm > 0 else { return }
            engine.detectedBPM = bpm
            if bpmEnabled, userTargetBPM > 0 {
                engine.applyTargetBPM(userTargetBPM)
                fieldText = String(Int(userTargetBPM))
            } else {
                fieldText = String(Int(bpm))
            }
        }
        // BPM arrived from background scan of an external (Finder-opened) file.
        // Only act when there is no current playlist track — that's the external state.
        .onChange(of: engine.detectedBPM) { bpm in
            guard playlist.currentTrackID == nil, bpm > 0 else { return }
            if bpmEnabled, userTargetBPM > 0 {
                engine.applyTargetBPM(userTargetBPM)
                fieldText = String(Int(userTargetBPM))
            } else {
                fieldText = String(Int(bpm))
            }
        }
        .onReceive(engine.trackFinishedPublisher) { _ in playNext() }
        // React to files opened from Finder (via AppDelegate → FileOpenRouter).
        // fileRouter is @ObservedObject so ContentView re-renders when pendingURL changes,
        // which makes onChange fire reliably.
        .onChange(of: fileRouter.pendingURL) { url in
            print("🎵 [ContentView.onChange] pendingURL=\(url?.path ?? "nil")")
            guard let url else { return }
            fileRouter.pendingURL = nil
            openExternalFile(url)
        }
        .onAppear {
            print("🎵 [ContentView.onAppear] pendingURL=\(fileRouter.pendingURL?.path ?? "nil")")
            if let url = fileRouter.pendingURL {
                fileRouter.pendingURL = nil
                openExternalFile(url)
            }
        }
        // Media keys (keyboard ⏮ ⏯ ⏭)
        .onReceive(NotificationCenter.default.publisher(for: .mediaKeyTogglePlay)) { _ in
            engine.togglePlay()
        }
        .onReceive(NotificationCenter.default.publisher(for: .mediaKeyNext)) { _ in
            playNext()
        }
        .onReceive(NotificationCenter.default.publisher(for: .mediaKeyPrevious)) { _ in
            playPrevious()
        }
        // ⑤ Spacebar = play / pause (disabled when BPM text field has focus)
        .background(
            Group {
                Button("") { engine.togglePlay() }
                    .keyboardShortcut(.space, modifiers: [])
                    .disabled(bpmFocused || !engine.hasFile)
                    .opacity(0)
                Button("") { playPrevious() }
                    .keyboardShortcut(.leftArrow, modifiers: .command)
                    .opacity(0)
                Button("") { playNext() }
                    .keyboardShortcut(.rightArrow, modifiers: .command)
                    .opacity(0)
            }
        )
    }

    // MARK: External file open (Finder double-click / file association)

    /// Loads and immediately plays a file opened from outside the app.
    /// Does not touch the playlist — leaves it intact.
    private func openExternalFile(_ url: URL) {
        print("🎵 [openExternalFile] \(url.path)")
        bpmFocused = false                          // drop focus from BPM field
        playlist.currentTrackID = nil              // deselect playlist — track is external
        fieldText = String(Int(userTargetBPM))     // clear old BPM display immediately
        engine.loadExternalURL(url)                // play ASAP + BPM scan in background
    }

    // MARK: Time display

    private var timeText: String {
        if showRemainingTime, engine.duration > 0 {
            let remaining = max(0, engine.duration - engine.currentTime)
            return "-" + formatTime(remaining)
        }
        return formatTime(engine.currentTime)
    }

    // MARK: BPM field helpers

    private func handleBPMSubmit() {
        if let bpm = Double(fieldText), bpm > 0 {
            userTargetBPM = bpm
            bpmEnabled    = true
            if engine.detectedBPM > 0 { engine.applyTargetBPM(bpm) }
            fieldText = String(Int(bpm))
        } else {
            fieldText = bpmDisplayText
        }
        bpmFocused = false
    }

    private func handleBPMFocus(_ focused: Bool) {
        if focused, !bpmEnabled, engine.detectedBPM > 0 {
            fieldText = String(Int(engine.detectedBPM))
        } else if !focused {
            fieldText = bpmDisplayText
        }
    }

    private var bpmDisplayText: String {
        if bpmEnabled, userTargetBPM > 0 { return String(Int(userTargetBPM)) }
        if engine.detectedBPM > 0        { return String(Int(engine.detectedBPM)) }
        return String(Int(userTargetBPM))
    }

    // MARK: Playlist toggle

    private func togglePlaylist() {
        playlistVisible.toggle()
    }

    // MARK: Formatting

    private func formatTime(_ s: Double) -> String {
        let t = max(0, Int(s))
        return String(format: "%d:%02d", t / 60, t % 60)
    }

    // MARK: Navigation

    private func playPrevious() {
        let tracks = playlist.tracks
        guard !tracks.isEmpty,
              let id  = playlist.currentTrackID,
              let idx = tracks.firstIndex(where: { $0.id == id }),
              idx > 0 else { return }
        playTrackAtIndex(idx - 1)
    }

    private func handlePlayButton() {
        if engine.hasFile {
            engine.togglePlay()
        } else if !playlist.tracks.isEmpty {
            // Nothing loaded yet — start from playlist
            if playlist.isShuffled,
               let nextID = playlist.randomNextTrackID(excluding: nil),
               let track  = playlist.tracks.first(where: { $0.id == nextID }) {
                playlist.currentTrackID = nextID
                if let bpm = track.bpm, bpm > 0, !track.isScanning { engine.detectedBPM = bpm }
                engine.loadURL(track.url)
            } else {
                playTrackAtIndex(0)
            }
        }
    }

    private func playNext() {
        let tracks = playlist.tracks
        guard !tracks.isEmpty else { return }
        if playlist.isShuffled {
            guard let nextID = playlist.randomNextTrackID(excluding: playlist.currentTrackID),
                  let track  = tracks.first(where: { $0.id == nextID }) else { return }
            playlist.currentTrackID = nextID
            if let bpm = track.bpm, bpm > 0, !track.isScanning { engine.detectedBPM = bpm }
            engine.loadURL(track.url)
        } else {
            guard let id  = playlist.currentTrackID,
                  let idx = tracks.firstIndex(where: { $0.id == id }) else { return }
            if idx < tracks.count - 1 {
                playTrackAtIndex(idx + 1)
            } else if playlist.isLooping {
                // End of playlist + loop ON → wrap to first track
                playTrackAtIndex(0)
            }
            // Loop OFF + last track → stop (do nothing)
        }
    }

    private func playTrackAtIndex(_ idx: Int) {
        let track = playlist.tracks[idx]
        playlist.currentTrackID = track.id
        if let bpm = track.bpm, bpm > 0, !track.isScanning { engine.detectedBPM = bpm }
        engine.loadURL(track.url)
    }

    // MARK: Window pin

    private struct WindowPinHelper: NSViewRepresentable {
        let isPinned: Bool
        let title:    String

        class HelperView: NSView {
            var isPinned = false
            var title    = ""

            override func viewDidMoveToWindow() {
                super.viewDidMoveToWindow()
                apply()
                // macOS auto-focuses the first text field in the window.
                // Clear first responder once, after the window is ready.
                DispatchQueue.main.async { [weak self] in
                    self?.window?.makeFirstResponder(nil)
                }
            }

            func apply() {
                guard let win = window else { return }
                // Use the native window title — macOS centres it automatically
                // and never changes the title-bar height.
                win.title = title.isEmpty ? "BPM Player" : title
                win.level = isPinned ? .floating : .normal
            }
        }

        func makeNSView(context: Context) -> HelperView { HelperView() }

        func updateNSView(_ nsView: HelperView, context: Context) {
            nsView.isPinned = isPinned
            nsView.title    = title
            nsView.apply()
        }
    }

    // MARK: Drag & drop

    private func handleDrop(providers: [NSItemProvider]) -> Bool {
        let group = DispatchGroup()
        var urls: [URL] = []
        for provider in providers {
            group.enter()
            provider.loadItem(
                forTypeIdentifier: UTType.fileURL.identifier, options: nil
            ) { item, _ in
                if let data = item as? Data,
                   let url  = URL(dataRepresentation: data, relativeTo: nil) {
                    urls.append(url)
                }
                group.leave()
            }
        }
        group.notify(queue: .main) {
            guard !urls.isEmpty else { return }
            playlist.addURLs(urls)
            if let first = urls.first {
                playlist.setCurrentURL(first)
                engine.loadURL(first)
            }
        }
        return true
    }
}
