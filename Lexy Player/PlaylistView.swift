import SwiftUI
import UniformTypeIdentifiers
import AppKit

// MARK: - Playlist window

struct PlaylistView: View {

    @EnvironmentObject private var engine:   AudioEngine
    @EnvironmentObject private var playlist: PlaylistManager

    /// User-selected track IDs for batch operations (delete, etc.).
    /// Managed manually so double-click-to-play is not broken by List(selection:).
    @State private var selection: Set<UUID> = []
    /// Last single-tapped ID — needed for Shift+click range selection.
    @State private var anchorID: UUID? = nil

    @State private var isDragTarget    = false
    @State private var draggingTrackID: UUID? = nil

    // Duplicate drop alert state
    @State private var duplicateDropURLs:  [URL] = []   // dupes waiting for user decision
    @State private var freshDropURLs:      [URL] = []   // non-dupes ready to add
    @State private var showDuplicateAlert  = false

    // Import / export state
    @State private var pendingImportURLs:     [URL] = []
    @State private var showImportSheet        = false
    @State private var importIgnoreDuplicates = true
    @State private var importMode             = ImportMode.append
    @State private var showExportFormatPicker = false

    // Track info state
    @State private var showTrackInfo  = false
    @State private var infoTrackIndex = 0

    var body: some View {
        VStack(spacing: 0) {
            content
            Divider()
            bottomBar
        }
        .frame(minWidth: 300)
        .onDrop(of: [.fileURL], isTargeted: $isDragTarget, perform: handleFileDrop)
        .overlay(
            isDragTarget
                ? RoundedRectangle(cornerRadius: 4)
                    .stroke(Color.accentColor, lineWidth: 2).padding(1)
                : nil
        )
        // Import options sheet (shows when playlist is non-empty)
        .sheet(isPresented: $showImportSheet) {
            ImportOptionsSheet(
                mode:             $importMode,
                ignoreDuplicates: $importIgnoreDuplicates,
                onImport: {
                    doImport(mode: importMode, ignoreDuplicates: importIgnoreDuplicates)
                    showImportSheet = false
                },
                onCancel: {
                    pendingImportURLs = []
                    showImportSheet   = false
                }
            )
        }
        // Track info sheet
        .sheet(isPresented: $showTrackInfo) {
            TrackInfoView(initialIndex: infoTrackIndex)
                .environmentObject(playlist)
                .environmentObject(engine)
        }
        // Duplicate tracks alert (shown when dropped files are already in the playlist)
        .alert("Duplicate Tracks", isPresented: $showDuplicateAlert) {
            Button("Add Anyway") {
                playlist.addURLs(freshDropURLs + duplicateDropURLs, skipDuplicates: false)
                freshDropURLs = []; duplicateDropURLs = []
            }
            Button("Skip Duplicates") {
                playlist.addURLs(freshDropURLs)
                freshDropURLs = []; duplicateDropURLs = []
            }
            Button("Cancel", role: .cancel) {
                freshDropURLs = []; duplicateDropURLs = []
            }
        } message: {
            let n = duplicateDropURLs.count
            Text("\(n) \(n == 1 ? "track is" : "tracks are") already in the playlist. Add \(n == 1 ? "it" : "them") anyway?")
        }

        // Export: choose format
        .confirmationDialog("Export playlist as",
                            isPresented: $showExportFormatPicker,
                            titleVisibility: .visible) {
            Button("M3U Playlist")      { exportAs(.m3u) }
            Button("Rekordbox XML")     { exportAs(.rekordbox) }
            Button("Serato Crate")      { exportAs(.serato) }
            Button("Cancel", role: .cancel) {}
        }
    }

    // MARK: Content

    @ViewBuilder
    private var content: some View {
        if playlist.tracks.isEmpty { emptyState } else { trackList }
    }

    private var emptyState: some View {
        VStack(spacing: 10) {
            Image(systemName: "music.note.list")
                .font(.system(size: 36))
                .foregroundStyle(.tertiary)
            Text("Drop audio files here\nor press  +  to add")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: Track list
    //
    // We use a plain List WITHOUT `selection:` because List(selection:) on macOS
    // intercepts mouse events at the NSTableView level, which breaks onTapGesture(count:2)
    // inside rows. Selection is therefore handled entirely in SwiftUI with NSEvent modifier flags.
    //
    // Behaviour matches Finder:
    //   • single click           → select this row (deselect others)
    //   • Shift + click          → range-select from anchor to this row
    //   • ⌘ + click              → toggle this row in/out of selection
    //   • double click (name)    → play the track
    //   • Delete key             → delete selected tracks
    //   • right-click            → context menu

    private var trackList: some View {
        List {
            ForEach(playlist.tracks) { track in
                TrackRow(
                    track:       track,
                    isCurrent:   track.id == playlist.currentTrackID,
                    isSelected:  selection.contains(track.id),
                    onPlay:      { playTrack(track) },
                    onSingleTap: { handleRowTap(track) },
                    onInfo:      { showInfoPanel(for: track) },
                    onBPMChange: { newBPM in
                        playlist.updateBPM(for: track.id, bpm: newBPM)
                        if track.id == playlist.currentTrackID {
                            engine.detectedBPM = newBPM
                        }
                    }
                )
                .listRowInsets(EdgeInsets(top: 0, leading: 8, bottom: 0, trailing: 8))
                .listRowBackground(rowBackground(for: track))
                .contextMenu {
                    Button("View Info") { showInfoPanel(for: track) }
                    Divider()
                    let batch: Set<UUID> = selection.contains(track.id) ? selection : [track.id]
                    if batch.count > 1 {
                        Button("Remove \(batch.count) tracks", role: .destructive) {
                            deleteByIDs(batch)
                        }
                    } else {
                        Button("Remove", role: .destructive) {
                            deleteByIDs([track.id])
                        }
                    }
                }
                .onDrag {
                    draggingTrackID = track.id
                    return NSItemProvider(object: track.id.uuidString as NSString)
                }
                .onDrop(
                    of: [UTType.utf8PlainText, .fileURL],
                    delegate: TrackDropDelegate(
                        targetID:        track.id,
                        playlist:        playlist,
                        draggingTrackID: $draggingTrackID,
                        onFileDrop:      handleFileDrop
                    )
                )
            }
            .onDelete { playlist.remove(at: $0) }
        }
        .listStyle(.plain)
        // File drops directly over existing rows — row-level onDrop accepts
        // only utf8PlainText (reorder), so .fileURL bubbles up here instead.
        .onDrop(of: [.fileURL], isTargeted: .constant(false), perform: handleFileDrop)
        // Delete key removes selected tracks while the list has keyboard focus
        .onDeleteCommand {
            guard !selection.isEmpty else { return }
            deleteByIDs(selection)
        }
        // ⌘A — select all  |  ⌘⌫ — delete selected
        .background(
            Group {
                Button("") {
                    selection = Set(playlist.tracks.map { $0.id })
                    anchorID  = playlist.tracks.last?.id
                }
                .keyboardShortcut("a", modifiers: .command)

                Button("") {
                    guard !selection.isEmpty else { return }
                    deleteByIDs(selection)
                }
                .keyboardShortcut(.delete, modifiers: .command)
            }
            .opacity(0)
        )
    }

    // MARK: Row background helper

    @ViewBuilder
    private func rowBackground(for track: PlaylistManager.Track) -> some View {
        if selection.contains(track.id) {
            // Selected — use macOS-standard highlight colour
            RoundedRectangle(cornerRadius: 4)
                .fill(Color.accentColor.opacity(0.22))
        } else if track.id == playlist.currentTrackID {
            // Currently loaded track
            RoundedRectangle(cornerRadius: 4)
                .fill(Color.accentColor.opacity(0.10))
        } else {
            Color.clear
        }
    }

    // MARK: Selection logic (Finder-style)

    private func handleRowTap(_ track: PlaylistManager.Track) {
        let flags = NSApp.currentEvent?.modifierFlags ?? []

        if flags.contains(.shift) {
            // Range-select from anchor to this row
            guard let anchor = anchorID,
                  let anchorIdx = playlist.tracks.firstIndex(where: { $0.id == anchor }),
                  let thisIdx   = playlist.tracks.firstIndex(where: { $0.id == track.id })
            else {
                selection = [track.id]
                anchorID  = track.id
                return
            }
            let lo = min(anchorIdx, thisIdx)
            let hi = max(anchorIdx, thisIdx)
            selection = Set(playlist.tracks[lo...hi].map { $0.id })
            // Anchor stays at the original click point (not updated on shift-click)

        } else if flags.contains(.command) {
            // Toggle individual row
            if selection.contains(track.id) {
                selection.remove(track.id)
            } else {
                selection.insert(track.id)
            }
            anchorID = track.id

        } else {
            // Plain click — select only this row
            selection = [track.id]
            anchorID  = track.id
        }
    }

    // MARK: Bottom bar
    // Layout: [(count) duration] [↓import] [↑export]  ·spacer·  [shuffle] [loop] [+]

    private var bottomBar: some View {
        HStack(spacing: 6) {
            // Track count · 4px · total duration · import · export
            HStack(spacing: 4) {
                Text("(\(playlist.tracks.count))")
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(.secondary)
                Text(formatDuration(playlist.totalDuration))
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(.secondary)
            }
            .help("Track count and total duration")

            // Import
            Button { importPlaylist() } label: {
                Image(systemName: "square.and.arrow.down")
                    .font(.system(size: 13))
                    .frame(width: 22, height: 22)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("Import playlist (M3U / Rekordbox XML / Serato Crate)")

            // Export
            Button { showExportFormatPicker = true } label: {
                Image(systemName: "square.and.arrow.up")
                    .font(.system(size: 13))
                    .frame(width: 22, height: 22)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(playlist.tracks.isEmpty)
            .help("Export playlist")

            Spacer()

            // Shuffle
            Button { playlist.isShuffled.toggle() } label: {
                Image(systemName: "shuffle")
                    .font(.system(size: 14))
                    .foregroundStyle(playlist.isShuffled ? Color.accentColor : .secondary)
                    .frame(width: 22, height: 22)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(playlist.isShuffled ? "Shuffle: ON" : "Shuffle: OFF")

            // Loop / repeat playlist
            Button { playlist.isLooping.toggle() } label: {
                Image(systemName: "repeat")
                    .font(.system(size: 14))
                    .foregroundStyle(playlist.isLooping ? Color.accentColor : .secondary)
                    .frame(width: 22, height: 22)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(playlist.isLooping ? "Repeat: ON — click to disable"
                                     : "Repeat: OFF — click to enable")

            // Add files
            Button { addFiles() } label: {
                Image(systemName: "plus")
                    .font(.system(size: 14))
                    .frame(width: 22, height: 22)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("Add audio files")

        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    // MARK: Actions

    private func formatDuration(_ seconds: Double) -> String {
        guard seconds > 0 else { return "0:00" }
        let s = Int(seconds)
        let h = s / 3600; let m = (s % 3600) / 60; let sec = s % 60
        return h > 0
            ? String(format: "%d:%02d:%02d", h, m, sec)
            : String(format: "%d:%02d", m, sec)
    }

    private func playTrack(_ track: PlaylistManager.Track) {
        playlist.currentTrackID = track.id
        if let bpm = track.bpm, bpm > 0, !track.isScanning { engine.detectedBPM = bpm }
        engine.loadURL(track.url)
    }

    private func showInfoPanel(for track: PlaylistManager.Track) {
        guard let idx = playlist.tracks.firstIndex(where: { $0.id == track.id }) else { return }
        infoTrackIndex = idx
        showTrackInfo  = true
    }

    private func deleteByIDs(_ ids: Set<UUID>) {
        let indices = IndexSet(
            playlist.tracks.indices.filter { ids.contains(playlist.tracks[$0].id) }
        )
        playlist.remove(at: indices)
        selection.subtract(ids)
    }

    private func addFiles() {
        let panel = NSOpenPanel()
        panel.title = "Add audio files"
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        panel.allowedContentTypes = [
            .audio, .mp3, .wav, .aiff,
            UTType(filenameExtension: "flac") ?? .audio,
            UTType(filenameExtension: "aif")  ?? .aiff,
            UTType(filenameExtension: "m4a")  ?? .audio,
            UTType(filenameExtension: "alac") ?? .audio,
            UTType(filenameExtension: "aac")  ?? .audio,
            UTType(filenameExtension: "caf")  ?? .audio,
        ]
        if panel.runModal() == .OK { playlist.addURLs(panel.urls) }
    }

    // MARK: Import

    enum ImportMode { case replace, append }
    private enum ExportFormat { case m3u, rekordbox, serato }

    private func importPlaylist() {
        let panel = NSOpenPanel()
        panel.title = "Import Playlist"
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.allowedContentTypes = [
            UTType(filenameExtension: "m3u")   ?? .plainText,
            UTType(filenameExtension: "m3u8")  ?? .plainText,
            UTType(filenameExtension: "xml")   ?? .xml,
            UTType(filenameExtension: "crate") ?? .data,
        ]
        guard panel.runModal() == .OK, let url = panel.url else { return }

        do {
            let urls = try PlaylistIO.importPlaylist(from: url)
            guard !urls.isEmpty else { return }
            pendingImportURLs = urls
            if playlist.tracks.isEmpty {
                // Playlist is empty — import directly with default ignore-duplicates
                doImport(mode: .append, ignoreDuplicates: true)
            } else {
                importMode = .append
                showImportSheet = true
            }
        } catch {
            // Silent failure — bad file format
        }
    }

    private func doImport(mode: ImportMode, ignoreDuplicates: Bool) {
        if mode == .replace {
            playlist.remove(at: IndexSet(0..<playlist.tracks.count))
        }
        var urls = pendingImportURLs
        if ignoreDuplicates {
            let existing = Set(playlist.tracks.map { $0.url })
            urls = urls.filter { !existing.contains($0) }
        }
        playlist.addURLs(urls)
        pendingImportURLs = []
    }

    // MARK: Export

    private func exportAs(_ format: ExportFormat) {
        let panel = NSSavePanel()
        panel.canCreateDirectories = true

        switch format {
        case .m3u:
            panel.title = "Export M3U"
            panel.nameFieldStringValue = "playlist.m3u"
            panel.allowedContentTypes = [UTType(filenameExtension: "m3u") ?? .plainText]
            guard panel.runModal() == .OK, let url = panel.url else { return }
            let content = PlaylistIO.exportM3U(tracks: playlist.tracks)
            try? content.write(to: url, atomically: true, encoding: .utf8)

        case .rekordbox:
            panel.title = "Export Rekordbox XML"
            panel.nameFieldStringValue = "playlist.xml"
            panel.allowedContentTypes = [.xml]
            guard panel.runModal() == .OK, let url = panel.url else { return }
            let content = PlaylistIO.exportRekordboxXML(tracks: playlist.tracks,
                                                        playlistName: url.deletingPathExtension().lastPathComponent)
            try? content.write(to: url, atomically: true, encoding: .utf8)

        case .serato:
            panel.title = "Export Serato Crate"
            panel.nameFieldStringValue = "playlist.crate"
            panel.allowedContentTypes = [UTType(filenameExtension: "crate") ?? .data]
            panel.message = "Save to ~/Music/_Serato_/Subcrates so Serato picks it up automatically."
            // Pre-navigate to the user's Serato Subcrates folder if it exists
            let subcrates = FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent("Music/_Serato_/Subcrates")
            if FileManager.default.fileExists(atPath: subcrates.path) {
                panel.directoryURL = subcrates
            }
            guard panel.runModal() == .OK, let url = panel.url else { return }
            let crateData = PlaylistIO.exportSeratoCrate(tracks: playlist.tracks)
            try? crateData.write(to: url)
            // If saved outside Subcrates, remind the user where to put it
            if url.deletingLastPathComponent().path != subcrates.path {
                let alert = NSAlert()
                alert.messageText = "Serato Crate Saved"
                alert.informativeText =
                    "For Serato to recognise this crate automatically, place the file in:\n\(subcrates.path)"
                alert.addButton(withTitle: "OK")
                alert.addButton(withTitle: "Show in Finder")
                if alert.runModal() == .alertSecondButtonReturn {
                    NSWorkspace.shared.activateFileViewerSelecting([url])
                }
            }
        }
    }

    private func handleFileDrop(providers: [NSItemProvider]) -> Bool {
        let group = DispatchGroup(); var urls: [URL] = []
        for p in providers {
            group.enter()
            p.loadItem(forTypeIdentifier: UTType.fileURL.identifier, options: nil) { item, _ in
                if let d = item as? Data, let u = URL(dataRepresentation: d, relativeTo: nil) { urls.append(u) }
                group.leave()
            }
        }
        group.notify(queue: .main) {
            let dupes = playlist.duplicates(in: urls)
            let fresh = urls.filter { url in !dupes.contains(url) }
            if dupes.isEmpty {
                // No duplicates — add immediately
                playlist.addURLs(fresh)
            } else {
                // Some duplicates — ask the user
                freshDropURLs     = fresh
                duplicateDropURLs = dupes
                showDuplicateAlert = true
            }
        }
        return true
    }
}

// MARK: - Drag-to-reorder delegate

private struct TrackDropDelegate: DropDelegate {
    let targetID:   UUID
    let playlist:   PlaylistManager
    @Binding var draggingTrackID: UUID?
    /// Forward external file drops back to PlaylistView.handleFileDrop
    let onFileDrop: ([NSItemProvider]) -> Bool

    func dropEntered(info: DropInfo) {
        // Only reorder when this is an internal drag (uuid string)
        guard info.hasItemsConforming(to: [UTType.utf8PlainText]) else { return }
        guard let fromID = draggingTrackID, fromID != targetID else { return }
        let tracks = playlist.tracks
        guard let fi = tracks.firstIndex(where: { $0.id == fromID }),
              let ti = tracks.firstIndex(where: { $0.id == targetID }), fi != ti
        else { return }
        withAnimation(.default) {
            playlist.move(from: IndexSet(integer: fi), to: ti > fi ? ti + 1 : ti)
        }
    }
    func dropUpdated(info: DropInfo) -> DropProposal? {
        info.hasItemsConforming(to: [.fileURL])
            ? DropProposal(operation: .copy)
            : DropProposal(operation: .move)
    }
    func performDrop(info: DropInfo) -> Bool {
        // External file drop — hand off to playlist handler
        if info.hasItemsConforming(to: [.fileURL]) {
            return onFileDrop(info.itemProviders(for: [.fileURL]))
        }
        // Internal reorder — drag already applied in dropEntered
        draggingTrackID = nil
        return true
    }
}

// MARK: - Track row
//
// single click  → onSingleTap (selection logic in PlaylistView)
// double click  → onPlay      (load + play immediately)
// BPM badge tap → edit BPM inline
// drag          → reorder via .onDrag / .onDrop at the List level

private struct TrackRow: View {

    @EnvironmentObject private var engine: AudioEngine

    let track:       PlaylistManager.Track
    let isCurrent:   Bool
    let isSelected:  Bool
    let onPlay:      () -> Void
    let onSingleTap: () -> Void
    let onInfo:      () -> Void
    let onBPMChange: (Double) -> Void

    @State private var isEditingBPM = false
    @State private var bpmInput     = ""
    @FocusState private var bpmFocused: Bool

    var body: some View {
        HStack(spacing: 5) {
            // ℹ Info button (unobtrusive, left of track name)
            Button { onInfo() } label: {
                Image(systemName: "info.circle")
                    .font(.system(size: 11))
                    .foregroundStyle(.tertiary)
                    .frame(width: 16, height: 16)
            }
            .buttonStyle(.plain)
            .help("Track info & tag editor")
            // Prevent ℹ double-click from triggering row play
            .onTapGesture(count: 2) { }

            // Track name (ID3 title/artist if available, else filename)
            Text(track.displayName)
                .font(.system(size: 12))
                .lineLimit(1)
                .truncationMode(.middle)
                .frame(maxWidth: .infinity, alignment: .leading)
                .foregroundStyle(isCurrent ? Color.accentColor : .primary)

            // BPM badge — block double-tap from bubbling up to the row's play action
            bpmBadge
                .onTapGesture(count: 2) { /* consume — don't play on double-tap of BPM */ }
        }
        .contentShape(Rectangle())
        // Both gestures run simultaneously so single-tap highlights instantly
        // (no ~300 ms wait for double-tap disambiguation). Double-tap fires
        // onPlay(); single-tap fires onSingleTap() on every tap — including
        // both taps of a double-click, which is fine (selection is idempotent).
        .simultaneousGesture(TapGesture(count: 2).onEnded { onPlay() })
        .simultaneousGesture(TapGesture(count: 1).onEnded { onSingleTap() })
        .padding(.vertical, 5)
    }

    @ViewBuilder
    private var bpmBadge: some View {
        if track.isScanning {
            ProgressView().scaleEffect(0.5).frame(width: 40, height: 14)
        } else if isEditingBPM {
            TextField("", text: $bpmInput)
                .font(.system(size: 11, design: .monospaced))
                .multilineTextAlignment(.trailing)
                .frame(width: 44)
                .textFieldStyle(.roundedBorder)
                .focused($bpmFocused)
                .onSubmit { commitBPM() }
                .onChange(of: bpmFocused) { if !$0 { cancelBPM() } }
        } else {
            let label = track.bpm.flatMap { $0 > 0 ? String(Int($0)) : nil } ?? "—"
            Text(label)
                .font(.system(size: 11, design: .monospaced))
                .foregroundStyle(track.bpm != nil && track.bpm! > 0 ? .secondary : .tertiary)
                .frame(width: 40, alignment: .trailing)
                .help("Click to edit BPM")
                .onTapGesture {
                    bpmInput = track.bpm.flatMap { $0 > 0 ? String(Int($0)) : nil } ?? ""
                    isEditingBPM = true
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { bpmFocused = true }
                }
        }
    }

    private func commitBPM() {
        if let bpm = Double(bpmInput), bpm > 0 { onBPMChange(bpm) }
        isEditingBPM = false; bpmFocused = false
    }

    /// Exit BPM editing without saving — triggered on focus loss.
    private func cancelBPM() {
        isEditingBPM = false
        // bpmFocused becomes false automatically; original BPM value is unchanged
    }
}

// MARK: - Import options sheet
//
// Presented when the user imports a playlist and the existing playlist is non-empty.
// Offers: Replace / Add to End  +  Ignore Duplicates toggle.

private struct ImportOptionsSheet: View {

    @Binding var mode:             PlaylistView.ImportMode
    @Binding var ignoreDuplicates: Bool
    let onImport: () -> Void
    let onCancel: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Import Playlist")
                .font(.headline)

            Text("Your playlist already has tracks. How would you like to import?")
                .foregroundStyle(.secondary)
                .font(.system(size: 12))
                .fixedSize(horizontal: false, vertical: true)

            Picker("", selection: $mode) {
                Text("Replace Playlist").tag(PlaylistView.ImportMode.replace)
                Text("Add to End").tag(PlaylistView.ImportMode.append)
            }
            .pickerStyle(.radioGroup)
            .labelsHidden()

            Divider()

            Toggle("Ignore duplicates", isOn: $ignoreDuplicates)
                .font(.system(size: 12))

            HStack {
                Button("Cancel", action: onCancel)
                Spacer()
                Button("Import", action: onImport)
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.return, modifiers: .command)
            }
        }
        .padding(20)
        .frame(width: 310)
    }
}
