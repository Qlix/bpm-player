import SwiftUI
import AppKit
import UniformTypeIdentifiers

// MARK: - Track info editor sheet
//
// Presents ID3 tag fields for the track at `initialIndex` in the playlist.
// Album art shows change/delete buttons on hover.
// Navigation arrows flank the Save button; Expert Mode toggle is on the far left.
// Labels sit above their text fields for a cleaner vertical layout.

struct TrackInfoView: View {

    @EnvironmentObject private var playlist: PlaylistManager
    @EnvironmentObject private var engine:   AudioEngine
    @Environment(\.dismiss) private var dismiss

    let initialIndex: Int

    // MARK: State

    @State private var meta          = TrackMetadata()
    @State private var currentIndex  = 0
    @State private var isLoading     = false
    @State private var isDirty       = false
    @State private var isHoveringArt = false
    @State private var expertMode    = false
    @State private var writeError: String? = nil
    @State private var showError      = false
    @State private var showTipPopover = false
    @State private var titleCopied    = false   // brief ✓ feedback on header tap
    @State private var artPasteFlash  = false   // brief green border on Cmd+V paste

    // MARK: Body

    var body: some View {
        VStack(spacing: 0) {
            headerBar
            Divider()

            // Artwork left | all fields right — single HStack
            HStack(alignment: .top, spacing: 16) {
                artworkPanel
                    .frame(width: 156, height: 156)
                mainFieldsColumn
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .disabled(isLoading)

            if expertMode { expertPanel.padding(.horizontal, 14).padding(.bottom, 6) }

            Divider()
            footerBar
        }
        .frame(width: 520, height: expertMode ? 440 : 360)
        .background(Color(NSColor.windowBackgroundColor))
        .onAppear {
            currentIndex = initialIndex
            loadMetadata()
        }
        .alert("Could not save tags", isPresented: $showError) {
            Button("OK") { }
        } message: {
            Text(writeError ?? "Unknown error.")
        }
        // Cmd+V — paste image from clipboard as new artwork.
        // Fires when no text field holds focus (text fields handle their own paste natively).
        .background(
            Button("") { pasteArtworkFromClipboard() }
                .keyboardShortcut("v", modifiers: .command)
                .opacity(0)
                .allowsHitTesting(false)
        )
    }

    // MARK: Header

    private var headerBar: some View {
        HStack {
            // Tap to copy track name to clipboard.
            // Colour flips to accentColor for 1.5 s as confirmation.
            HStack(spacing: 4) {
                Text(playlist.tracks[safe: currentIndex]?.displayName ?? "Track Info")
                    .font(.system(size: 13, weight: .semibold))
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .foregroundStyle(titleCopied ? Color.accentColor : Color.primary)

                if titleCopied {
                    Image(systemName: "doc.on.doc")
                        .font(.system(size: 10, weight: .bold))
                        .foregroundStyle(Color.accentColor)
                        .transition(.opacity.combined(with: .scale))
                }
            }
            .animation(.easeInOut(duration: 0.15), value: titleCopied)
            .contentShape(Rectangle())
            .onTapGesture { copyTitleToClipboard() }
            .help("Click to copy")

            Spacer()
            Button { dismiss() } label: {
                Image(systemName: "xmark.circle.fill")
                    .font(.system(size: 16))
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
    }

    // MARK: Artwork

    private var artworkPanel: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 8)
                .fill(Color(light: "D0D0D0", dark: "404040"))

            if let img = meta.artwork {
                Image(nsImage: img)
                    .resizable()
                    .scaledToFill()
                    .clipped()
            } else {
                Image(systemName: "music.note")
                    .font(.system(size: 36))
                    .foregroundStyle(.secondary)
            }

            if isHoveringArt {
                RoundedRectangle(cornerRadius: 8)
                    .fill(Color.black.opacity(0.48))
                VStack(spacing: 10) {
                    Button("Change…") { chooseArtwork() }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                    if meta.artwork != nil {
                        Button("Remove") {
                            meta.artwork = nil
                            isDirty = true
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                        .foregroundStyle(.red)
                    }
                }
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 8))
        // Flash green border for 0.8 s after a successful Cmd+V paste
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .strokeBorder(Color.green, lineWidth: 2)
                .opacity(artPasteFlash ? 1 : 0)
                .animation(.easeOut(duration: 0.15), value: artPasteFlash)
        )
        .onHover { isHoveringArt = $0 }
        .animation(.easeInOut(duration: 0.12), value: isHoveringArt)
        .help(meta.artwork == nil
              ? "Change… or ⌘V to paste from clipboard"
              : "Change… / Remove on hover · ⌘V to paste")
    }

    // MARK: Main fields column (Title / Artist / Album / Genre)

    private var mainFieldsColumn: some View {
        VStack(alignment: .leading, spacing: 6) {
            stackedField("Title",  tracked($meta.title))
            stackedField("Artist", tracked($meta.artist))
            stackedField("Album",  tracked($meta.album))
            stackedField("Genre",  tracked($meta.genre))

            // Year / Track / BPM inline
            HStack(spacing: 10) {
                stackedField("Year",   tracked($meta.year),        width: 58)
                stackedField("Track",  tracked($meta.trackNumber), width: 46)
                stackedField("BPM",    tracked($meta.bpm),         width: 46)
                Spacer(minLength: 0)
            }

            // Comment
            VStack(alignment: .leading, spacing: 2) {
                Text("Comment")
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
                TextField("", text: tracked($meta.comment))
                    .textFieldStyle(.roundedBorder)
                    .font(.system(size: 12))
            }
        }
        .frame(maxWidth: .infinity)
    }

    // MARK: Field builder — label above input

    @ViewBuilder
    private func stackedField(_ label: String, _ binding: Binding<String>,
                               width: CGFloat? = nil) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label)
                .font(.system(size: 10))
                .foregroundStyle(.secondary)
            TextField("", text: binding)
                .textFieldStyle(.roundedBorder)
                .font(.system(size: 12))
                .frame(width: width)
        }
    }

    // MARK: Expert panel

    private var expertPanel: some View {
        VStack(alignment: .leading, spacing: 4) {
            Divider()
            VStack(alignment: .leading, spacing: 6) {
                Text("Filename")
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
                HStack(spacing: 4) {
                    TextField("", text: tracked($meta.fileName))
                        .textFieldStyle(.roundedBorder)
                        .font(.system(size: 12))
                    if let ext = playlist.tracks[safe: currentIndex]?.url.pathExtension,
                       !ext.isEmpty {
                        Text(".\(ext)")
                            .font(.system(size: 12))
                            .foregroundStyle(.secondary)
                    }
                }
                // Warning
                Text("⚠ Renaming may break references in other apps and playlists.")
                    .font(.system(size: 10))
                    .foregroundStyle(.orange)
            }
            .padding(.top, 4)
        }
    }

    // MARK: Footer  [Expert Mode]  [Spacer]  [←  Save  →]

    private var footerBar: some View {
        HStack(spacing: 0) {
            // Expert mode toggle (far left)
            Button {
                withAnimation(.easeInOut(duration: 0.15)) { expertMode.toggle() }
            } label: {
                Text("Expert Mode")
                    .font(.system(size: 11))
                    .foregroundStyle(expertMode ? Color.accentColor : Color.secondary)
            }
            .buttonStyle(.plain)
            .help("Rename the audio file on disk")

            Spacer()

            // ← [Save/spinner] →
            HStack(spacing: 4) {
                Button {
                    navigateTo(currentIndex - 1)
                } label: {
                    Image(systemName: "chevron.left")
                        .font(.system(size: 12, weight: .semibold))
                        .frame(width: 26, height: 26)
                }
                .buttonStyle(.plain)
                .disabled(currentIndex <= 0)

                if isLoading {
                    ProgressView().scaleEffect(0.7).frame(width: 64, height: 26)
                } else {
                    Button("Save") { trySaveAndClose() }
                        .buttonStyle(.borderedProminent)
                        .disabled(!isDirty)
                        .keyboardShortcut(.return, modifiers: .command)
                }

                Button {
                    navigateTo(currentIndex + 1)
                } label: {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 12, weight: .semibold))
                        .frame(width: 26, height: 26)
                }
                .buttonStyle(.plain)
                .disabled(currentIndex >= playlist.tracks.count - 1)
            }

            // ☕ Tip jar — right of navigation arrows
            Button { showTipPopover.toggle() } label: {
                Image(systemName: "mug.fill")
                    .font(.system(size: 13))
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .help("Buy me a coffee")
            .padding(.leading, 10)
            .popover(isPresented: $showTipPopover, arrowEdge: .top) {
                VStack(spacing: 10) {
                    Text("Buy me a coffee ☕")
                        .font(.system(size: 13, weight: .semibold))
                    Link("paypal.me/oleinikovs",
                         destination: URL(string: "https://paypal.me/oleinikovs")!)
                        .font(.system(size: 12))
                    Text("v\(Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "—")")
                        .font(.system(size: 10))
                        .foregroundStyle(.tertiary)
                }
                .padding(16)
                .frame(minWidth: 180)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
    }

    // MARK: Binding wrapper — marks dirty on user edit

    private func tracked(_ binding: Binding<String>) -> Binding<String> {
        Binding(
            get: { binding.wrappedValue },
            set: { newValue in
                binding.wrappedValue = newValue
                isDirty = true
            }
        )
    }

    // MARK: Load

    private func loadMetadata() {
        guard let url = playlist.tracks[safe: currentIndex]?.url else { return }
        isLoading = true
        Task.detached(priority: .userInitiated) {
            let loaded = MetadataIO.read(from: url)
            await MainActor.run {
                meta      = loaded
                isLoading = false
                isDirty   = false
            }
        }
    }

    // MARK: Navigation (auto-saves if dirty)

    private func navigateTo(_ index: Int) {
        guard playlist.tracks.indices.contains(index) else { return }
        if isDirty { _ = trySave(silent: true) }
        currentIndex = index
        loadMetadata()
    }

    // MARK: Save

    @discardableResult
    private func trySave(silent: Bool = false) -> Bool {
        guard let track = playlist.tracks[safe: currentIndex] else { return false }
        var targetURL = track.url

        if expertMode {
            let newName = meta.fileName.trimmingCharacters(in: .whitespaces)
            let oldName = targetURL.deletingPathExtension().lastPathComponent
            if !newName.isEmpty, newName != oldName {
                let ext      = targetURL.pathExtension
                let newURL   = targetURL.deletingLastPathComponent()
                    .appendingPathComponent(newName)
                    .appendingPathExtension(ext)

                // If this track is currently loaded in the audio engine, stop it
                // first so the engine releases its file handle before the rename.
                let isCurrentTrack = (track.id == playlist.currentTrackID)
                let wasPlaying     = engine.isPlaying
                if isCurrentTrack {
                    engine.stopPlayback()
                }

                do {
                    try FileManager.default.moveItem(at: targetURL, to: newURL)
                    targetURL = newURL
                    // Keep the playlist reference in sync so nothing tries the old path.
                    playlist.updateURL(for: track.id, url: newURL)
                    // Reload the engine from the new path.
                    if isCurrentTrack {
                        engine.loadURL(newURL)
                        // Restore playing state if the user hadn't paused.
                        if wasPlaying { engine.togglePlay() }
                    }
                } catch {
                    if !silent {
                        writeError = "Could not rename: \(error.localizedDescription)"
                        showError  = true
                    }
                    return false
                }
            }
        }

        guard MetadataIO.canWrite(ext: targetURL.pathExtension) else {
            isDirty = false
            return true
        }
        do {
            try MetadataIO.write(meta, to: targetURL)
            isDirty = false
            // Sync the in-memory playlist so the row updates immediately
            playlist.updateTags(
                for:    track.id,
                title:  meta.title.isEmpty  ? nil : meta.title,
                artist: meta.artist.isEmpty ? nil : meta.artist
            )
            return true
        } catch {
            if !silent {
                writeError = error.localizedDescription
                showError  = true
            }
            return false
        }
    }

    private func trySaveAndClose() {
        if trySave() { dismiss() }
    }

    // MARK: Title copy

    private func copyTitleToClipboard() {
        let name = playlist.tracks[safe: currentIndex]?.displayName ?? ""
        guard !name.isEmpty else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(name, forType: .string)
        titleCopied = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { titleCopied = false }
    }

    // MARK: Artwork paste (Cmd+V)

    private func pasteArtworkFromClipboard() {
        guard let raw = NSImage(pasteboard: NSPasteboard.general) else { return }
        // Resize to ≤800×800 and compress to JPEG q=0.75 before storing.
        meta.artwork = raw.jpegThumbnail(maxSide: 800, quality: 0.75) ?? raw
        isDirty = true
        // Brief green flash to confirm
        artPasteFlash = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) { artPasteFlash = false }
    }

    // MARK: Artwork picker

    private func chooseArtwork() {
        let panel = NSOpenPanel()
        panel.title = "Choose Artwork"
        panel.allowedContentTypes = [.jpeg, .png, .tiff, .heic]
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK,
              let url = panel.url,
              let img = NSImage(contentsOf: url) else { return }
        meta.artwork = img
        isDirty = true
    }
}

// MARK: - Safe array subscript

extension Array {
    subscript(safe index: Int) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}

// MARK: - NSImage JPEG thumbnail helper

private extension NSImage {

    /// Returns a new 800×800 JPEG NSImage using cover-fill:
    /// the image is scaled so the shorter side = 800 px, then center-cropped
    /// to a perfect square.  No letterboxing, no distortion.
    /// Quality 0…1 maps to JPEG compressionFactor.
    func jpegThumbnail(maxSide: CGFloat, quality: CGFloat) -> NSImage? {
        let src = size
        guard src.width > 0, src.height > 0 else { return nil }

        // Scale so the SHORTER side fills the square (cover semantics)
        let scale   = maxSide / min(src.width, src.height)
        let scaled  = NSSize(width:  src.width  * scale,
                             height: src.height * scale)

        // Center-crop offset: how far outside the 800×800 canvas the scaled image starts
        let dx = (scaled.width  - maxSide) / 2
        let dy = (scaled.height - maxSide) / 2

        // 800×800 RGB bitmap (no alpha — JPEG doesn't support it)
        guard let bmp = NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide:       Int(maxSide),
            pixelsHigh:       Int(maxSide),
            bitsPerSample:    8,
            samplesPerPixel:  3,
            hasAlpha:         false,
            isPlanar:         false,
            colorSpaceName:   .deviceRGB,
            bytesPerRow:      0,
            bitsPerPixel:     0
        ) else { return nil }

        NSGraphicsContext.saveGraphicsState()
        defer { NSGraphicsContext.restoreGraphicsState() }
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: bmp)

        // Draw scaled image shifted left/up so only the center square is captured
        draw(in:        NSRect(x: -dx, y: -dy, width: scaled.width, height: scaled.height),
             from:      NSRect(origin: .zero, size: src),
             operation: .copy,
             fraction:  1.0)

        guard let jpegData = bmp.representation(using: .jpeg,
                                                 properties: [.compressionFactor: quality]),
              let result    = NSImage(data: jpegData)
        else { return nil }

        return result
    }
}
