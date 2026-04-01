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

    // MARK: Mutations

    /// Add URLs and start BPM scan + tag read for each new track.
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

    private func scan(id: UUID, url: URL) {
        Task.detached(priority: .userInitiated) {
            // ── Phase 1: tags (fast) ──────────────────────────────────────
            // Read ID3 / Vorbis / etc. tags first so the UI shows the proper
            // artist – title name as soon as possible, before BPM (slow).
            let meta   = MetadataIO.read(from: url)
            let title  = meta.title.isEmpty  ? nil : meta.title
            let artist = meta.artist.isEmpty ? nil : meta.artist

            await MainActor.run { [weak self] in
                guard let self,
                      let idx = self.tracks.firstIndex(where: { $0.id == id })
                else { return }
                self.tracks[idx].title  = title
                self.tracks[idx].artist = artist
                // isScanning stays true until BPM phase completes
            }

            // ── Phase 2: BPM (slow) ───────────────────────────────────────
            let bpm: Double
            if let file = try? AVAudioFile(forReading: url) {
                bpm = BPMDetector.detect(file: file)
            } else {
                bpm = 0
            }

            await MainActor.run { [weak self] in
                guard let self,
                      let idx = self.tracks.firstIndex(where: { $0.id == id })
                else { return }
                self.tracks[idx].bpm        = bpm
                self.tracks[idx].isScanning = false
                self.saveToPersistence()
            }
        }
    }

    // MARK: Persistence (UserDefaults, JSON)

    private struct SavedTrack: Codable {
        let urlAbsoluteString: String
        let bpm:      Double?
        let duration: Double
        let title:    String?
        let artist:   String?
    }

    func saveToPersistence() {
        let saved = tracks.map { t in
            SavedTrack(
                urlAbsoluteString: t.url.absoluteString,
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
            guard let url = URL(string: s.urlAbsoluteString),
                  FileManager.default.fileExists(atPath: url.path)
            else { continue }

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

    // MARK: Helpers

    private static func readDuration(url: URL) -> Double {
        guard let file = try? AVAudioFile(forReading: url) else { return 0 }
        return Double(file.length) / file.processingFormat.sampleRate
    }
}
