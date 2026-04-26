import AVFoundation
import Combine
import SwiftUI

// MARK: - Playlist Manager

@MainActor
final class PlaylistManager: ObservableObject {

    // MARK: Track model

    struct Track: Identifiable, Equatable {
        let id:         UUID
        var url:        URL
        var name:       String      // raw filename (always set)
        var title:      String?     // ID3 title tag
        var artist:     String?     // ID3 artist tag
        var bpm:        Double?     // nil = still scanning; 0 = could not detect
        var isScanning: Bool
        var duration:   Double      // seconds; 0 if unknown

        /// Display-friendly name: "Artist – Title" when tags are available,
        /// otherwise the filename without its extension (e.g. "My Track" not "My Track.mp3").
        var displayName: String {
            let t = title?.isEmpty  == false ? title  : nil
            let a = artist?.isEmpty == false ? artist : nil
            switch (a, t) {
            case let (a?, t?): return "\(a) - \(t)"
            case let (nil, t?): return t
            case let (a?, nil): return a
            default:            return url.deletingPathExtension().lastPathComponent
            }
        }

        init(url: URL, bpm: Double? = nil, isScanning: Bool = true, duration: Double = 0,
             title: String? = nil, artist: String? = nil) {
            id              = UUID()
            self.url        = url
            name            = url.lastPathComponent
            self.bpm        = bpm
            self.isScanning = isScanning
            self.duration   = duration
            self.title      = title
            self.artist     = artist
        }

        static func == (lhs: Track, rhs: Track) -> Bool {
            lhs.id         == rhs.id         &&
            lhs.bpm        == rhs.bpm        &&
            lhs.isScanning == rhs.isScanning &&
            lhs.title      == rhs.title      &&
            lhs.artist     == rhs.artist
        }
    }

    // MARK: Published state

    @Published var tracks:         [Track] = []
    @Published var currentTrackID: UUID?   = nil
    @Published var isShuffled:     Bool    = false
    @Published var isLooping:      Bool    = true   // repeat playlist by default

    // MARK: Computed

    /// The detected BPM of the currently selected track (0 if not yet available).
    var currentTrackBPM: Double {
        guard let id    = currentTrackID,
              let track = tracks.first(where: { $0.id == id }),
              !track.isScanning,
              let bpm   = track.bpm, bpm > 0
        else { return 0 }
        return bpm
    }

    /// Sum of all track durations (for display in the playlist footer).
    var totalDuration: Double {
        tracks.reduce(0) { $0 + $1.duration }
    }

    // MARK: Persistence keys

    private let tracksKey     = "BPMApp.playlist.tracks"
    private let currentURLKey = "BPMApp.playlist.currentURL"

    // MARK: Security-scoped bookmark tracking
    //
    // We call startAccessingSecurityScopedResource() when resolving a stored
    // bookmark so that sandbox access is maintained across launches. Access is
    // stopped when a track is removed, or when the app exits (OS cleans up too).

    private var activeScopes: [URL: Bool] = [:]   // URL → whether we called startAccessing

    // MARK: Serial BPM scan queue
    //
    // Tracks are scanned one at a time, top-to-bottom, in the order they were
    // added.  This keeps CPU / memory pressure low while still delivering BPM
    // values progressively — the track at the top of the list (likely playing)
    // is always scanned first.

    private var bpmScanQueue:     [(id: UUID, url: URL)] = []
    private var isRunningBPMScan: Bool                   = false

    // MARK: Combine

    private var cancellables = Set<AnyCancellable>()

    // MARK: Init — restore saved playlist

    init() {
        restoreFromPersistence()
        $currentTrackID
            .dropFirst()
            .sink { [weak self] _ in self?.saveToPersistence() }
            .store(in: &cancellables)
    }

    deinit {
        // Stop all active security scopes when the manager is deallocated.
        for url in activeScopes.keys { url.stopAccessingSecurityScopedResource() }
    }

    // MARK: Mutations

    /// Add URLs and start BPM scan + tag read for each new track.
    /// Creates a security-scoped bookmark for each URL immediately so access
    /// persists after the next launch.
    /// - Parameter skipDuplicates: when true (default) silently skips URLs already in the playlist.
    func addURLs(_ urls: [URL], skipDuplicates: Bool = true) {
        for url in urls {
            if skipDuplicates, tracks.contains(where: { $0.url == url }) { continue }
            let duration = Self.readDuration(url: url)
            let track    = Track(url: url, duration: duration)
            tracks.append(track)
            scan(id: track.id, url: url)
        }
        saveToPersistence()
    }

    /// Returns URLs from the given list that are already present in the playlist.
    func duplicates(in urls: [URL]) -> [URL] {
        urls.filter { url in tracks.contains(where: { $0.url == url }) }
    }

    func remove(at offsets: IndexSet) {
        // Stop security scope for removed tracks
        for idx in offsets {
            let url = tracks[idx].url
            if activeScopes[url] == true {
                url.stopAccessingSecurityScopedResource()
                activeScopes.removeValue(forKey: url)
            }
        }
        tracks.remove(atOffsets: offsets)
        saveToPersistence()
    }

    func move(from source: IndexSet, to destination: Int) {
        tracks.move(fromOffsets: source, toOffset: destination)
        saveToPersistence()
    }

    /// Mark the track matching this URL as current (used when loading from drop).
    func setCurrentURL(_ url: URL) {
        currentTrackID = tracks.first(where: { $0.url == url })?.id
    }

    /// Update the on-disk URL of a track after it has been renamed/moved.
    func updateURL(for id: UUID, url: URL) {
        guard let idx = tracks.firstIndex(where: { $0.id == id }) else { return }
        tracks[idx].url  = url
        tracks[idx].name = url.lastPathComponent
        saveToPersistence()
    }

    /// Update the in-memory title and artist after the user edits tags in TrackInfoView.
    func updateTags(for id: UUID, title: String?, artist: String?) {
        guard let idx = tracks.firstIndex(where: { $0.id == id }) else { return }
        tracks[idx].title  = title.flatMap  { $0.trimmingCharacters(in: .whitespaces).isEmpty ? nil : $0 }
        tracks[idx].artist = artist.flatMap { $0.trimmingCharacters(in: .whitespaces).isEmpty ? nil : $0 }
        saveToPersistence()
    }

    /// Manually override the BPM for a track.
    func updateBPM(for id: UUID, bpm: Double) {
        guard let idx = tracks.firstIndex(where: { $0.id == id }) else { return }
        tracks[idx].bpm        = bpm
        tracks[idx].isScanning = false
        saveToPersistence()
    }

    // MARK: Shuffle

    func randomNextTrackID(excluding currentID: UUID?) -> UUID? {
        let available = tracks.filter { $0.id != currentID }
        return available.randomElement()?.id
    }

    // MARK: BPM scanning + tag reading (background)

    /// Start metadata + BPM resolution for one track.
    ///
    /// Phase 1 (parallel, fast): reads ID3 / Vorbis / etc. tags.  If the BPM
    /// field is already set in the file, we use it directly — no scan needed.
    ///
    /// Phase 2 (serial, slow): if no BPM tag exists, the track is added to the
    /// FIFO `bpmScanQueue`.  The queue processes one track at a time so we never
    /// run N parallel BPM analyses, which would thrash the CPU and cause audio
    /// dropouts while the user is listening.
    private func scan(id: UUID, url: URL) {
        Task.detached(priority: .userInitiated) {
            // ── Phase 1: tags + ID3 BPM check (fast) ─────────────────────
            let meta   = MetadataIO.read(from: url)
            let title  = meta.title.isEmpty  ? nil : meta.title
            let artist = meta.artist.isEmpty ? nil : meta.artist
            let tagBPM = Double(meta.bpm.trimmingCharacters(in: .whitespaces))

            await MainActor.run { [weak self] in
                guard let self,
                      let idx = self.tracks.firstIndex(where: { $0.id == id })
                else { return }
                self.tracks[idx].title  = title
                self.tracks[idx].artist = artist

                if let bpm = tagBPM, bpm > 0 {
                    // ✅ ID3 tag already has BPM — use it, skip the slow scan.
                    self.tracks[idx].bpm        = bpm
                    self.tracks[idx].isScanning = false
                    self.saveToPersistence()
                } else {
                    // ⏳ No tag BPM — enqueue for serial scan.
                    self.enqueueBPMScan(id: id, url: url)
                }
            }
        }
    }

    private func enqueueBPMScan(id: UUID, url: URL) {
        bpmScanQueue.append((id: id, url: url))
        if !isRunningBPMScan { processBPMScanQueue() }
    }

    /// Dequeue and process one BPM scan at a time (serial FIFO).
    ///
    /// Runs BPMDetector in a background-priority detached task, then updates
    /// the track and writes the BPM back to the file tag (only if the tag was
    /// empty — never overwrites a user-set value).
    private func processBPMScanQueue() {
        guard !bpmScanQueue.isEmpty else {
            isRunningBPMScan = false
            return
        }
        isRunningBPMScan = true
        let item = bpmScanQueue.removeFirst()
        let scanID  = item.id
        let scanURL = item.url

        Task { [weak self] in
            let bpm = await Task.detached(priority: .background) { () -> Double in
                guard let file = try? AVAudioFile(forReading: scanURL) else { return 0 }
                return BPMDetector.detect(file: file)
            }.value

            guard let self else { return }

            // Write BPM back to the file tag so the scan only runs once per track.
            if bpm > 0 {
                let rounded = Int(bpm.rounded())
                Task.detached(priority: .background) {
                    MetadataIO.writeBPMIfEmpty(rounded, to: scanURL)
                }
            }

            // Update the playlist on the main actor, then kick off the next scan.
            if let idx = self.tracks.firstIndex(where: { $0.id == scanID }) {
                self.tracks[idx].bpm        = bpm
                self.tracks[idx].isScanning = false
                self.saveToPersistence()
            }
            self.processBPMScanQueue()   // tail-call: process next item
        }
    }

    // MARK: Persistence (UserDefaults + security-scoped bookmarks)
    //
    // Each track is stored as a security-scoped bookmark (Data) rather than a
    // plain URL string. On restore the bookmark is resolved and
    // startAccessingSecurityScopedResource() is called so the sandbox allows
    // continued file access across app launches.

    private struct SavedTrack: Codable {
        // Preferred: security-scoped bookmark for sandbox persistence
        var bookmarkData: Data?
        // Fallback for tracks added before bookmarks were introduced
        var urlAbsoluteString: String?
        var bpm:      Double?
        var duration: Double
        var title:    String?
        var artist:   String?
    }

    func saveToPersistence() {
        let saved: [SavedTrack] = tracks.map { t in
            // Create a fresh security-scoped bookmark so it never goes stale.
            let bookmark = try? t.url.bookmarkData(
                options: [.withSecurityScope],
                includingResourceValuesForKeys: nil,
                relativeTo: nil
            )
            return SavedTrack(
                bookmarkData:      bookmark,
                urlAbsoluteString: bookmark == nil ? t.url.absoluteString : nil,
                bpm:      t.isScanning ? nil : t.bpm,
                duration: t.duration,
                title:    t.title,
                artist:   t.artist
            )
        }
        if let data = try? JSONEncoder().encode(saved) {
            UserDefaults.standard.set(data, forKey: tracksKey)
        }
        if let id = currentTrackID,
           let track = tracks.first(where: { $0.id == id }) {
            UserDefaults.standard.set(track.url.absoluteString, forKey: currentURLKey)
        } else {
            UserDefaults.standard.removeObject(forKey: currentURLKey)
        }
    }

    private func restoreFromPersistence() {
        guard let data  = UserDefaults.standard.data(forKey: tracksKey),
              let saved = try? JSONDecoder().decode([SavedTrack].self, from: data)
        else { return }

        for s in saved {
            guard let url = resolveURL(from: s) else { continue }
            guard FileManager.default.fileExists(atPath: url.path) else { continue }

            let known = s.bpm != nil
            let track = Track(url: url, bpm: s.bpm, isScanning: !known, duration: s.duration,
                              title: s.title, artist: s.artist)
            tracks.append(track)
            if !known { scan(id: track.id, url: url) }
        }

        let savedURL = UserDefaults.standard.string(forKey: currentURLKey)
        if let urlString = savedURL,
           let match = tracks.first(where: { $0.url.absoluteString == urlString }) {
            currentTrackID = match.id
        }
    }

    /// Resolve a URL from a saved track, starting security scope if a bookmark is available.
    private func resolveURL(from saved: SavedTrack) -> URL? {
        // Prefer bookmark (sandbox-safe, persistent)
        if let bookmarkData = saved.bookmarkData {
            var isStale = false
            if let url = try? URL(
                resolvingBookmarkData: bookmarkData,
                options: [.withSecurityScope],
                relativeTo: nil,
                bookmarkDataIsStale: &isStale
            ) {
                // Start accessing — this must be balanced with stopAccessing when removed.
                let started = url.startAccessingSecurityScopedResource()
                activeScopes[url] = started
                if isStale {
                    // Bookmark is stale (file moved/renamed) — try to refresh it
                    _ = try? url.bookmarkData(options: [.withSecurityScope])
                }
                return url
            }
        }

        // Fallback: plain URL string (works outside sandbox or for files in accessible locations)
        if let urlString = saved.urlAbsoluteString {
            return URL(string: urlString)
        }

        return nil
    }

    // MARK: Helpers

    private static func readDuration(url: URL) -> Double {
        guard let file = try? AVAudioFile(forReading: url) else { return 0 }
        return Double(file.length) / file.processingFormat.sampleRate
    }
}
