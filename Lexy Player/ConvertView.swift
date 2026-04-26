import SwiftUI
import Combine
import AppKit

// Passed via sheet(item:) so track IDs are guaranteed fresh when sheet opens
struct ConvertSheetData: Identifiable {
    let id      = UUID()
    let trackIDs: Set<UUID>
}

// MARK: - Conversion Job (progress tracking)

@MainActor
final class ConversionJob: ObservableObject {
    @Published var completedCount      = 0
    @Published var totalCount          = 0
    @Published var isRunning           = false
    @Published var isDone              = false
    @Published var errorMessage: String? = nil
    @Published var convertedURLs: [URL]  = []
    /// 0…1 progress within the file currently being encoded (updated by chunked MP3).
    @Published var currentFileProgress: Double = 0

    /// Smooth combined progress across all files including within-file progress.
    var combinedProgress: Double {
        guard totalCount > 0 else { return 0 }
        return min(1.0, (Double(completedCount) + currentFileProgress) / Double(totalCount))
    }

    func start(tracks: [PlaylistManager.Track],
               format: ConvertFormat,
               destination: URL,
               deleteOriginals: Bool) {
        let urls      = tracks.map { $0.url }
        totalCount          = urls.count
        completedCount      = 0
        currentFileProgress = 0
        isRunning           = true
        isDone              = false
        errorMessage        = nil
        convertedURLs       = []

        Task.detached(priority: .userInitiated) { [weak self] in
            guard let self else { return }

            for sourceURL in urls {
                // Capture format.fileExtension on the background thread — nonisolated now.
                let ext    = format.fileExtension
                let destURL = destination
                    .appendingPathComponent(sourceURL.deletingPathExtension().lastPathComponent)
                    .appendingPathExtension(ext)

                do {
                    try AudioConverter.convert(
                        source: sourceURL,
                        to: destURL,
                        format: format
                    ) { progress in
                        // Called from background thread — hop to MainActor for @Published
                        Task { @MainActor [weak self] in
                            self?.currentFileProgress = progress
                        }
                    }
                    // Append directly to @Published array — no local captured var needed.
                    await MainActor.run { self.convertedURLs.append(destURL) }
                    if deleteOriginals {
                        try? FileManager.default.removeItem(at: sourceURL)
                    }
                } catch {
                    let msg = "\(sourceURL.lastPathComponent): \(error.localizedDescription)"
                    await MainActor.run { self.errorMessage = msg }
                }

                await MainActor.run {
                    self.currentFileProgress = 0   // reset before incrementing count
                    self.completedCount += 1
                }
            }

            await MainActor.run {
                self.isRunning = false
                self.isDone    = true
            }
        }
    }
}

// MARK: - Convert View

struct ConvertView: View {

    @EnvironmentObject private var playlist: PlaylistManager
    @Environment(\.dismiss) private var dismiss

    /// Track IDs that were selected when "Convert…" was chosen.
    let initialTrackIDs: Set<UUID>

    @StateObject private var job = ConversionJob()

    @State private var convertAll      = false
    @State private var selectedFormat  = ConvertFormat.flacStandard
    @State private var destinationURL: URL? = nil
    @State private var addToPlaylist   = true
    @State private var deleteOriginals = false

    /// Persists the last chosen destination folder path (display only).
    @AppStorage("lastConvertDestination") private var lastDestinationPath: String = ""
    /// Security-scoped bookmark for the destination folder (sandbox-safe persistence).
    @AppStorage("lastConvertDestinationBookmark") private var lastDestinationBookmark: Data = Data()

    private var tracksToConvert: [PlaylistManager.Track] {
        convertAll
            ? playlist.tracks
            : playlist.tracks.filter { initialTrackIDs.contains($0.id) }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {

            // ── Header ────────────────────────────────────────────────────
            HStack {
                Text("Convert Tracks")
                    .font(.system(size: 13, weight: .semibold))
                Spacer()
                Button { dismiss() } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 16))
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .disabled(job.isRunning)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)

            Divider()

            VStack(alignment: .leading, spacing: 14) {

                // ── Track selection toggle + file preview ─────────────────
                let allCount = playlist.tracks.count
                let selCount = initialTrackIDs.count
                VStack(alignment: .leading, spacing: 4) {
                    Toggle(
                        convertAll
                            ? "Convert all tracks in playlist (\(allCount))"
                            : "Convert all tracks in playlist — \(selCount) selected",
                        isOn: $convertAll
                    )
                    .font(.system(size: 12))
                    .toggleStyle(.checkbox)
                    .disabled(job.isRunning)

                    // File name preview: up to 3 names, then "+N more"
                    let preview = tracksToConvert
                    if !preview.isEmpty {
                        VStack(alignment: .leading, spacing: 1) {
                            ForEach(preview.prefix(3)) { track in
                                Text(track.displayName)
                                    .font(.system(size: 10))
                                    .foregroundStyle(.secondary)
                                    .lineLimit(1)
                                    .truncationMode(.middle)
                            }
                            if preview.count > 3 {
                                Text("+\(preview.count - 3) more")
                                    .font(.system(size: 10))
                                    .foregroundStyle(.tertiary)
                            }
                        }
                        .padding(.leading, 20)
                    }
                }

                // ── Format picker ─────────────────────────────────────────
                VStack(alignment: .leading, spacing: 4) {
                    Text("Format")
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                    Picker("", selection: $selectedFormat) {
                        ForEach(ConvertFormat.allCases) { f in
                            Text(f.rawValue).tag(f)
                        }
                    }
                    .labelsHidden()
                    .frame(maxWidth: .infinity)
                    .disabled(job.isRunning)
                }

                // ── Destination folder — entire row is clickable ──────────
                VStack(alignment: .leading, spacing: 4) {
                    Text("Destination folder")
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                    Button(action: chooseDestination) {
                        HStack(spacing: 8) {
                            Text(destinationURL.map { $0.abbreviatingWithTildeInPath }
                                 ?? "Click to choose folder…")
                                .font(.system(size: 11))
                                .foregroundStyle(destinationURL == nil ? .secondary : .primary)
                                .lineLimit(1)
                                .truncationMode(.middle)
                            Spacer(minLength: 4)
                            Image(systemName: "folder")
                                .font(.system(size: 11))
                                .foregroundStyle(.secondary)
                        }
                        .padding(.horizontal, 8)
                        .padding(.vertical, 5)
                        .frame(maxWidth: .infinity)
                        .background(Color(NSColor.controlBackgroundColor))
                        .clipShape(RoundedRectangle(cornerRadius: 5))
                        .overlay(
                            RoundedRectangle(cornerRadius: 5)
                                .stroke(Color(NSColor.separatorColor), lineWidth: 0.5)
                        )
                    }
                    .buttonStyle(.plain)
                    .disabled(job.isRunning)
                }

                Divider()

                // ── Options ───────────────────────────────────────────────
                VStack(alignment: .leading, spacing: 8) {
                    Toggle("Add converted tracks to playlist", isOn: $addToPlaylist)
                        .font(.system(size: 12))
                        .toggleStyle(.checkbox)
                        .disabled(job.isRunning)
                    Toggle("Delete originals after conversion", isOn: $deleteOriginals)
                        .font(.system(size: 12))
                        .toggleStyle(.checkbox)
                        .disabled(job.isRunning)
                }

                // ── Progress ──────────────────────────────────────────────
                if job.isRunning || job.isDone {
                    Divider()
                    VStack(alignment: .leading, spacing: 6) {
                        HStack {
                            Text(job.isDone ? "Done" : "Converting…")
                                .font(.system(size: 11))
                                .foregroundStyle(.secondary)
                            Spacer()
                            Text("\(job.completedCount) of \(job.totalCount)")
                                .font(.system(size: 11, design: .monospaced))
                                .foregroundStyle(.secondary)
                        }
                        ProgressView(value: job.combinedProgress)
                            .progressViewStyle(.linear)
                            .tint(job.isDone ? .green : Color.accentColor)
                            .animation(.linear(duration: 0.1), value: job.combinedProgress)

                        if let err = job.errorMessage {
                            Text(err)
                                .font(.system(size: 10))
                                .foregroundStyle(.red)
                                .lineLimit(2)
                        }
                    }
                }
            }
            .padding(16)

            Divider()

            // ── Footer ────────────────────────────────────────────────────
            HStack {
                Spacer()
                if job.isDone {
                    Button("Close") { dismiss() }
                        .buttonStyle(.borderedProminent)
                        .keyboardShortcut(.return, modifiers: .command)
                } else {
                    Button("Convert") { startConversion() }
                        .buttonStyle(.borderedProminent)
                        .keyboardShortcut(.return, modifiers: .command)
                        .disabled(destinationURL == nil || job.isRunning || tracksToConvert.isEmpty)
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
        }
        .frame(width: 370)
        .background(Color(NSColor.windowBackgroundColor))
        // Restore last destination on first open (prefer security-scoped bookmark)
        .onAppear {
            if destinationURL == nil {
                destinationURL = resolveDestinationBookmark()
            }
        }
        // Success sound + add to playlist
        .onChange(of: job.isDone) { done in
            guard done else { return }
            NSSound(named: NSSound.Name("Glass"))?.play()
            if addToPlaylist { playlist.addURLs(job.convertedURLs) }
        }
        // Reset to "Convert" when user changes settings after a run
        .onChange(of: selectedFormat)  { _ in resetIfDone() }
        .onChange(of: convertAll)      { _ in resetIfDone() }
        .onChange(of: deleteOriginals) { _ in resetIfDone() }
        .onChange(of: addToPlaylist)   { _ in resetIfDone() }
    }

    // MARK: Actions

    private func chooseDestination() {
        let panel = NSOpenPanel()
        panel.title                   = "Choose Destination Folder"
        panel.canChooseFiles          = false
        panel.canChooseDirectories    = true
        panel.canCreateDirectories    = true
        panel.allowsMultipleSelection = false
        // Pre-navigate to last used folder if it still exists
        if !lastDestinationPath.isEmpty {
            panel.directoryURL = URL(fileURLWithPath: lastDestinationPath)
        }
        guard panel.runModal() == .OK, let url = panel.url else { return }
        destinationURL      = url
        lastDestinationPath = url.path   // for display
        // Create a security-scoped bookmark so access persists across launches
        if let bookmark = try? url.bookmarkData(options: [.withSecurityScope]) {
            lastDestinationBookmark = bookmark
        }
    }

    /// Resolve the stored security-scoped bookmark for the destination folder.
    private func resolveDestinationBookmark() -> URL? {
        guard !lastDestinationBookmark.isEmpty else {
            // No bookmark yet — fall back to plain path (pre-sandbox builds)
            if !lastDestinationPath.isEmpty {
                let url = URL(fileURLWithPath: lastDestinationPath)
                return (try? url.checkResourceIsReachable()) == true ? url : nil
            }
            return nil
        }
        var isStale = false
        guard let url = try? URL(
            resolvingBookmarkData: lastDestinationBookmark,
            options: [.withSecurityScope],
            relativeTo: nil,
            bookmarkDataIsStale: &isStale
        ) else { return nil }
        _ = url.startAccessingSecurityScopedResource()
        return url
    }

    private func resetIfDone() {
        guard job.isDone else { return }
        job.isDone              = false
        job.completedCount      = 0
        job.totalCount          = 0
        job.currentFileProgress = 0
        job.errorMessage        = nil
        job.convertedURLs       = []
    }

    // MARK: Helpers

    private func startConversion() {
        guard let dest = destinationURL else { return }
        job.start(
            tracks:         tracksToConvert,
            format:         selectedFormat,
            destination:    dest,
            deleteOriginals: deleteOriginals
        )
    }
}

// MARK: - URL helper

private extension URL {
    /// Replaces the user's home directory prefix with ~ for compact display.
    var abbreviatingWithTildeInPath: String {
        (path as NSString).abbreviatingWithTildeInPath
    }
}
