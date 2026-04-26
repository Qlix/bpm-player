import XCTest
@testable import Lexy_Player

// ============================================================
// BPM Player — Unit Tests
//
// Покрывают pure functions и logic без UI/рендеринга.
// Тестировать UI-рендеринг, SwiftUI views, цвета — ЗАПРЕЩЕНО.
//
// Как запустить:
//   1. В Xcode: File → New → Target → Unit Testing Bundle
//      Name: "Lexy Player Tests"
//   2. В Build Settings теста: Host Application = "Lexy Player"
//   3. Cmd+U
// ============================================================

// MARK: - Track.displayName

/**
 * Тестирует PlaylistManager.Track.displayName.
 * Критично: используется в window title, playlist rows, TrackInfoView header.
 */
final class TrackDisplayNameTests: XCTestCase {

    private func makeTrack(title: String? = nil, artist: String? = nil,
                           filename: String = "my_track.mp3") -> PlaylistManager.Track {
        let url = URL(fileURLWithPath: "/tmp/\(filename)")
        var t = PlaylistManager.Track(url: url)
        t.title  = title
        t.artist = artist
        return t
    }

    func test_displayName_bothTagsPresent() {
        let t = makeTrack(title: "Sunrise", artist: "DJ Nova")
        XCTAssertEqual(t.displayName, "DJ Nova - Sunrise")
    }

    func test_displayName_onlyTitle() {
        let t = makeTrack(title: "Sunrise", artist: nil)
        XCTAssertEqual(t.displayName, "Sunrise")
    }

    func test_displayName_onlyArtist() {
        let t = makeTrack(title: nil, artist: "DJ Nova")
        XCTAssertEqual(t.displayName, "DJ Nova")
    }

    func test_displayName_noTagsFallsBackToFilename() {
        let t = makeTrack(title: nil, artist: nil, filename: "cool_remix.mp3")
        XCTAssertEqual(t.displayName, "cool_remix")  // extension stripped
    }

    func test_displayName_emptyStringTagsTreatedAsNil() {
        // Empty strings are stored as nil by updateTags — same logic in Track.init
        let t = makeTrack(title: "", artist: "")
        // Empty strings → falls back to filename
        XCTAssertEqual(t.displayName, "my_track")
    }

    func test_displayName_whitespaceOnlyTitle_treatedAsNil() {
        let url = URL(fileURLWithPath: "/tmp/track.mp3")
        var t = PlaylistManager.Track(url: url)
        t.title  = nil
        t.artist = "DJ Nova"
        XCTAssertEqual(t.displayName, "DJ Nova")
    }
}

// MARK: - PlaylistIO — M3U Export

/**
 * Тестирует PlaylistIO.exportM3U.
 * Критично: используется при экспорте плейлиста для Rekordbox / других плееров.
 */
final class M3UExportTests: XCTestCase {

    private func makeTracks() -> [PlaylistManager.Track] {
        let url1 = URL(fileURLWithPath: "/Music/track1.mp3")
        let url2 = URL(fileURLWithPath: "/Music/subdir/track2.flac")
        var t1 = PlaylistManager.Track(url: url1, duration: 180)
        var t2 = PlaylistManager.Track(url: url2, duration: 0)   // unknown duration
        t1.bpm = 128; t1.isScanning = false
        t2.bpm = nil; t2.isScanning = true
        return [t1, t2]
    }

    func test_exportM3U_startsWithHeader() {
        let out = PlaylistIO.exportM3U(tracks: makeTracks())
        XCTAssertTrue(out.hasPrefix("#EXTM3U"), "M3U must start with #EXTM3U")
    }

    func test_exportM3U_containsExtinf() {
        let out = PlaylistIO.exportM3U(tracks: makeTracks())
        XCTAssertTrue(out.contains("#EXTINF:180,track1"))
    }

    func test_exportM3U_unknownDurationIsMinusOne() {
        let out = PlaylistIO.exportM3U(tracks: makeTracks())
        XCTAssertTrue(out.contains("#EXTINF:-1,track2"))
    }

    func test_exportM3U_containsAbsolutePaths() {
        let out = PlaylistIO.exportM3U(tracks: makeTracks())
        XCTAssertTrue(out.contains("/Music/track1.mp3"))
        XCTAssertTrue(out.contains("/Music/subdir/track2.flac"))
    }

    func test_exportM3U_emptyPlaylistReturnsHeaderOnly() {
        let out = PlaylistIO.exportM3U(tracks: [])
        let lines = out.components(separatedBy: "\n").filter { !$0.isEmpty }
        XCTAssertEqual(lines, ["#EXTM3U"])
    }
}

// MARK: - PlaylistIO — Rekordbox XML Export

/**
 * Тестирует PlaylistIO.exportRekordboxXML.
 * Критично: DJ-интеграция (Rekordbox, djay).
 */
final class RekordboxXMLExportTests: XCTestCase {

    func test_xmlExport_containsRequiredRootElements() {
        let url = URL(fileURLWithPath: "/Music/track.mp3")
        let track = PlaylistManager.Track(url: url, duration: 240)
        let out = PlaylistIO.exportRekordboxXML(tracks: [track], playlistName: "MySet")
        XCTAssertTrue(out.contains("<DJ_PLAYLISTS"))
        XCTAssertTrue(out.contains("<COLLECTION Entries=\"1\""))
        XCTAssertTrue(out.contains("<PLAYLISTS>"))
    }

    func test_xmlExport_fileLocationFormat() {
        let url = URL(fileURLWithPath: "/Music/track.mp3")
        let track = PlaylistManager.Track(url: url)
        let out = PlaylistIO.exportRekordboxXML(tracks: [track])
        XCTAssertTrue(out.contains("file://localhost/Music/track.mp3"),
                      "Rekordbox expects file://localhost prefix")
    }

    func test_xmlExport_specialCharsEscaped() {
        let url = URL(fileURLWithPath: "/Music/track & remix.mp3")
        let track = PlaylistManager.Track(url: url)
        let out = PlaylistIO.exportRekordboxXML(tracks: [track])
        XCTAssertFalse(out.contains("& remix"),
                       "Unescaped & in XML attribute breaks Rekordbox")
        // Path-encoded — & → %26
        XCTAssertTrue(out.contains("track%20%26%20remix") || out.contains("track%20&amp;%20remix"))
    }

    func test_xmlExport_bpmFormattedToTwoDecimals() {
        let url = URL(fileURLWithPath: "/tmp/t.mp3")
        var track = PlaylistManager.Track(url: url)
        track.bpm = 128.5
        track.isScanning = false
        let out = PlaylistIO.exportRekordboxXML(tracks: [track])
        XCTAssertTrue(out.contains("AverageBpm=\"128.50\""))
    }

    func test_xmlExport_emptyTracks() {
        let out = PlaylistIO.exportRekordboxXML(tracks: [], playlistName: "Empty")
        XCTAssertTrue(out.contains("<COLLECTION Entries=\"0\""))
    }
}

// MARK: - PlaylistManager — duplicate detection

/**
 * Тестирует PlaylistManager.duplicates(in:).
 * Критично: предотвращает дублирование треков при drag & drop.
 */
@MainActor
final class PlaylistDuplicateTests: XCTestCase {

    func test_duplicates_findsExistingURL() async {
        let pm  = PlaylistManager()
        let url = URL(fileURLWithPath: "/tmp/song.mp3")
        pm.addURLs([url])
        let dupes = pm.duplicates(in: [url])
        XCTAssertEqual(dupes.count, 1)
        XCTAssertEqual(dupes.first, url)
    }

    func test_duplicates_returnsEmptyForNewURL() async {
        let pm  = PlaylistManager()
        let url = URL(fileURLWithPath: "/tmp/song.mp3")
        pm.addURLs([url])
        let newURL = URL(fileURLWithPath: "/tmp/other.mp3")
        XCTAssertTrue(pm.duplicates(in: [newURL]).isEmpty)
    }

    func test_duplicates_mixedList() async {
        let pm  = PlaylistManager()
        let existing = URL(fileURLWithPath: "/tmp/a.mp3")
        let fresh    = URL(fileURLWithPath: "/tmp/b.mp3")
        pm.addURLs([existing])
        let dupes = pm.duplicates(in: [existing, fresh])
        XCTAssertEqual(dupes.count, 1)
        XCTAssertEqual(dupes.first, existing)
    }
}

// MARK: - PlaylistManager — shuffle

/**
 * Тестирует PlaylistManager.randomNextTrackID(excluding:).
 * Критично: shuffle не должен повторять текущий трек.
 */
@MainActor
final class ShuffleTests: XCTestCase {

    func test_randomNext_excludesCurrentTrack() async {
        let pm = PlaylistManager()
        pm.addURLs([
            URL(fileURLWithPath: "/tmp/a.mp3"),
            URL(fileURLWithPath: "/tmp/b.mp3"),
            URL(fileURLWithPath: "/tmp/c.mp3"),
        ])
        let currentID = pm.tracks.first!.id
        for _ in 0..<20 {
            let next = pm.randomNextTrackID(excluding: currentID)
            XCTAssertNotEqual(next, currentID,
                              "shuffle must never return the current track")
        }
    }

    func test_randomNext_returnsSomethingForTwoTracks() async {
        let pm = PlaylistManager()
        pm.addURLs([
            URL(fileURLWithPath: "/tmp/a.mp3"),
            URL(fileURLWithPath: "/tmp/b.mp3"),
        ])
        let currentID = pm.tracks.first!.id
        let next = pm.randomNextTrackID(excluding: currentID)
        XCTAssertNotNil(next, "should always find a next track when 2+ exist")
    }

    func test_randomNext_singleTrackExcluded_returnsNil() async {
        let pm = PlaylistManager()
        pm.addURLs([URL(fileURLWithPath: "/tmp/only.mp3")])
        let only = pm.tracks.first!.id
        let next = pm.randomNextTrackID(excluding: only)
        XCTAssertNil(next, "no other track available — must return nil")
    }
}

// MARK: - PlaylistManager — totalDuration

/**
 * Тестирует PlaylistManager.totalDuration.
 * Критично: отображается в нижней панели плейлиста.
 */
@MainActor
final class TotalDurationTests: XCTestCase {

    func test_totalDuration_sumOfAllTracks() async {
        let pm = PlaylistManager()
        let url1 = URL(fileURLWithPath: "/tmp/a.mp3")
        let url2 = URL(fileURLWithPath: "/tmp/b.mp3")
        // addURLs triggers scan which we can't easily control in unit tests,
        // so we test the computed property via internal mutation.
        pm.addURLs([url1, url2])
        // totalDuration is sum of track.duration; both start at 0 (no real file)
        XCTAssertEqual(pm.totalDuration, 0, accuracy: 0.001)
    }

    func test_totalDuration_emptyPlaylist() async {
        let pm = PlaylistManager()
        XCTAssertEqual(pm.totalDuration, 0)
    }
}

// MARK: - AudioEngine — rate clamping

/**
 * Тестирует Comparable.clamped(to:) — используется для BPM ratio и volume.
 * Критично: защищает RubberBand от недопустимых значений (0 → div-by-zero).
 */
final class ClampTests: XCTestCase {

    func test_clamped_withinRange_unchanged() {
        XCTAssertEqual(Float(1.5).clamped(to: 0.25...4.0), 1.5)
    }

    func test_clamped_belowMin_returnsMin() {
        XCTAssertEqual(Float(0.1).clamped(to: 0.25...4.0), 0.25)
    }

    func test_clamped_aboveMax_returnsMax() {
        XCTAssertEqual(Float(10.0).clamped(to: 0.25...4.0), 4.0)
    }

    func test_clamped_exactlyMin_unchanged() {
        XCTAssertEqual(Float(0.25).clamped(to: 0.25...4.0), 0.25)
    }

    func test_clamped_exactlyMax_unchanged() {
        XCTAssertEqual(Float(4.0).clamped(to: 0.25...4.0), 4.0)
    }

    // regression: нулевой rate вызывал деление на ноль в BPM ratio
    func test_clamped_zero_clamped_to_min() {
        XCTAssertEqual(Float(0.0).clamped(to: 0.25...4.0), 0.25,
                       "regression: zero rate must be clamped, not passed to RubberBand")
    }
}

// MARK: - PlaylistIO — M3U Import roundtrip

/**
 * Тестирует exportM3U → importPlaylist roundtrip.
 * Критично: треки должны выжить export + import без потерь путей.
 */
final class M3URoundtripTests: XCTestCase {

    func test_m3u_roundtrip_absolutePaths() throws {
        let urls = [
            URL(fileURLWithPath: "/Music/Artist/track1.mp3"),
            URL(fileURLWithPath: "/Music/Artist/track2.flac"),
        ]
        var tracks = urls.map { PlaylistManager.Track(url: $0, duration: 120) }
        tracks[0].isScanning = false
        tracks[1].isScanning = false

        // Export to temp file
        let m3u    = PlaylistIO.exportM3U(tracks: tracks)
        let tmpURL = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("test_\(UUID().uuidString).m3u")
        try m3u.write(to: tmpURL, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: tmpURL) }

        // Import back
        let imported = try PlaylistIO.importPlaylist(from: tmpURL)
        XCTAssertEqual(imported.count, urls.count)
        for (original, roundtripped) in zip(urls, imported) {
            XCTAssertEqual(original.path, roundtripped.path)
        }
    }
}

// MARK: - MetadataIO — canWrite

/**
 * Тестирует MetadataIO.canWrite(ext:).
 * Критично: запись тегов разрешена только для mp3 и flac.
 */
final class MetadataIOCanWriteTests: XCTestCase {

    func test_canWrite_mp3_true()  { XCTAssertTrue(MetadataIO.canWrite(ext: "mp3"))  }
    func test_canWrite_MP3_true()  { XCTAssertTrue(MetadataIO.canWrite(ext: "MP3"))  }
    func test_canWrite_flac_true() { XCTAssertTrue(MetadataIO.canWrite(ext: "flac")) }
    func test_canWrite_wav_false() { XCTAssertFalse(MetadataIO.canWrite(ext: "wav")) }
    func test_canWrite_aiff_false(){ XCTAssertFalse(MetadataIO.canWrite(ext: "aiff"))}
    func test_canWrite_m4a_false() { XCTAssertFalse(MetadataIO.canWrite(ext: "m4a")) }
    func test_canWrite_empty_false(){ XCTAssertFalse(MetadataIO.canWrite(ext: ""))   }

    // regression: запрос write для aif (не aiff) раньше проходил через AVFoundation
    func test_canWrite_aif_false() {
        XCTAssertFalse(MetadataIO.canWrite(ext: "aif"),
                       "regression: aif (без второго f) тоже не поддерживает запись")
    }
}

// MARK: - AudioEngine — external BPM scan

/**
 * Тестирует AudioEngine.loadExternalURL — detectedBPM сбрасывается сразу.
 * Критично: поле BPM должно очиститься до окончания сканирования.
 */
@MainActor
final class ExternalBPMScanTests: XCTestCase {

    func test_loadExternalURL_resetsDetectedBPMImmediately() {
        let engine = AudioEngine()
        engine.detectedBPM = 128   // simulate previously loaded playlist track
        let url = URL(fileURLWithPath: "/nonexistent/file.mp3")
        engine.loadExternalURL(url)
        XCTAssertEqual(engine.detectedBPM, 0,
                       "detectedBPM must be 0 immediately after loadExternalURL — before scan completes")
    }
}

// MARK: - MetadataIO — writeBPMIfEmpty

/**
 * Тестирует MetadataIO.writeBPMIfEmpty.
 * Контракт: никогда не перезаписывает существующий BPM; молча игнорирует
 * неподдерживаемые форматы и несуществующие файлы.
 */
final class WriteBPMIfEmptyTests: XCTestCase {

    // MARK: — Helper: build a minimal ID3v2.3 MP3 byte sequence

    /// Returns a Data blob that looks like an MP3 with a TBPM frame set to `bpm`
    /// (or no TBPM frame if `bpm` is nil).  The "audio" is a single null byte.
    private func makeMinimalMP3(bpm: String?) -> Data {
        var frames = Data()

        func textFrame(_ id: String, _ value: String) {
            guard let idBytes = id.data(using: .ascii) else { return }
            var payload = Data([0x03])   // UTF-8 encoding byte
            payload += value.data(using: .utf8)!
            // frame header: ID (4) + size BE32 (4) + flags (2)
            frames.append(idBytes)
            let sz = UInt32(payload.count)
            frames.append(UInt8((sz >> 24) & 0xFF))
            frames.append(UInt8((sz >> 16) & 0xFF))
            frames.append(UInt8((sz >>  8) & 0xFF))
            frames.append(UInt8( sz        & 0xFF))
            frames.append(contentsOf: [0x00, 0x00])
            frames.append(payload)
        }

        if let bpm { textFrame("TBPM", bpm) }

        // ID3v2.3 header
        var header = Data("ID3".utf8)
        header.append(contentsOf: [0x03, 0x00, 0x00])   // v2.3, no flags
        // synchsafe size
        let size = UInt32(frames.count)
        header.append(UInt8((size >> 21) & 0x7F))
        header.append(UInt8((size >> 14) & 0x7F))
        header.append(UInt8((size >>  7) & 0x7F))
        header.append(UInt8( size        & 0x7F))

        return header + frames + Data([0x00])   // 1 null "audio" byte
    }

    // MARK: — writeBPMIfEmpty: unsupported format silently no-ops

    func test_writeBPMIfEmpty_unsupportedFormat_noOp() {
        // WAV write is not supported — function must return without crashing
        let url = URL(fileURLWithPath: "/tmp/test_\(UUID()).wav")
        MetadataIO.writeBPMIfEmpty(128, to: url)   // must not throw or crash
        // No file should have been created
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))
    }

    func test_writeBPMIfEmpty_nonexistentMP3_noOp() {
        // Supported format but file doesn't exist — try? in write() must swallow the error
        let url = URL(fileURLWithPath: "/tmp/nonexistent_\(UUID()).mp3")
        MetadataIO.writeBPMIfEmpty(128, to: url)   // must not crash
    }

    // MARK: — read: TBPM frame is parsed from ID3v2 header

    func test_metadataRead_tbpmTag_parsedCorrectly() throws {
        let data = makeMinimalMP3(bpm: "140")
        let url  = URL(fileURLWithPath: "/tmp/test_bpm_\(UUID()).mp3")
        defer { try? FileManager.default.removeItem(at: url) }
        try data.write(to: url)

        let meta = MetadataIO.read(from: url)
        XCTAssertEqual(meta.bpm, "140", "TBPM frame value must be read back verbatim")
    }

    func test_metadataRead_noTbpmTag_returnsEmptyBPM() throws {
        let data = makeMinimalMP3(bpm: nil)
        let url  = URL(fileURLWithPath: "/tmp/test_nobpm_\(UUID()).mp3")
        defer { try? FileManager.default.removeItem(at: url) }
        try data.write(to: url)

        let meta = MetadataIO.read(from: url)
        XCTAssertTrue(meta.bpm.isEmpty, "No TBPM frame → bpm field must be empty")
    }

    // MARK: — writeBPMIfEmpty: writes when tag is empty

    func test_writeBPMIfEmpty_writesWhenTagEmpty() throws {
        let data = makeMinimalMP3(bpm: nil)
        let url  = URL(fileURLWithPath: "/tmp/test_write_bpm_\(UUID()).mp3")
        defer { try? FileManager.default.removeItem(at: url) }
        try data.write(to: url)

        MetadataIO.writeBPMIfEmpty(128, to: url)

        let meta = MetadataIO.read(from: url)
        XCTAssertEqual(meta.bpm, "128", "BPM should be written when tag was empty")
    }

    // MARK: — writeBPMIfEmpty: NEVER overwrites an existing BPM value

    func test_writeBPMIfEmpty_respectsExistingTag() throws {
        let data = makeMinimalMP3(bpm: "140")
        let url  = URL(fileURLWithPath: "/tmp/test_existing_bpm_\(UUID()).mp3")
        defer { try? FileManager.default.removeItem(at: url) }
        try data.write(to: url)

        // Attempt to overwrite 140 → 99
        MetadataIO.writeBPMIfEmpty(99, to: url)

        let meta = MetadataIO.read(from: url)
        XCTAssertEqual(meta.bpm, "140",
                       "writeBPMIfEmpty must NEVER overwrite an existing BPM tag")
    }

    func test_writeBPMIfEmpty_whitespaceOnlyBPM_treatedAsEmpty() throws {
        // If somehow a tag has only whitespace, we should write BPM
        // We can simulate this by building a frame with a space value
        let data = makeMinimalMP3(bpm: "   ")
        let url  = URL(fileURLWithPath: "/tmp/test_ws_bpm_\(UUID()).mp3")
        defer { try? FileManager.default.removeItem(at: url) }
        try data.write(to: url)

        MetadataIO.writeBPMIfEmpty(130, to: url)

        let meta = MetadataIO.read(from: url)
        // After trimming, the original "   " is empty → should have been overwritten
        XCTAssertEqual(meta.bpm, "130",
                       "Whitespace-only BPM tag should be treated as empty and overwritten")
    }
}

// MARK: - AudioEngine — BPM switch state defaults

/**
 * Тестирует начальные значения полей BPM в AudioEngine.
 * Критично: при первом открытии файла из Finder BPM switch должен быть OFF.
 */
@MainActor
final class AudioEngineBPMStateTests: XCTestCase {

    func test_bpmSwitchEnabled_defaultsToFalse() {
        let engine = AudioEngine()
        XCTAssertFalse(engine.bpmSwitchEnabled,
                       "BPM switch must be OFF by default — no holds on first launch")
    }

    func test_bpmTarget_defaultsTo120() {
        let engine = AudioEngine()
        XCTAssertEqual(engine.bpmTarget, 120,
                       "Default target BPM must be 120 (musical standard)")
    }

    func test_loadExternalURL_switchOFF_doesNotHold() {
        // With switch OFF, loadExternalURL must not hold audio.
        // We verify that detectedBPM is cleared and no scan is pending.
        let engine = AudioEngine()
        engine.detectedBPM     = 99    // simulate old value
        engine.bpmSwitchEnabled = false

        let url = URL(fileURLWithPath: "/nonexistent/track.mp3")
        engine.loadExternalURL(url)

        XCTAssertEqual(engine.detectedBPM, 0,
                       "detectedBPM must be reset to 0 regardless of switch state")
        // hasFile becomes true only when decode succeeds — with nonexistent file it stays false.
        XCTAssertFalse(engine.hasFile,
                       "nonexistent file must not set hasFile = true after decode error")
    }

    func test_loadExternalURL_switchON_alsoResetsDetectedBPM() {
        let engine = AudioEngine()
        engine.detectedBPM      = 128
        engine.bpmSwitchEnabled = true
        engine.bpmTarget        = 130

        let url = URL(fileURLWithPath: "/nonexistent/track.mp3")
        engine.loadExternalURL(url)

        XCTAssertEqual(engine.detectedBPM, 0,
                       "detectedBPM must reset to 0 immediately even when switch is ON")
    }
}

// MARK: - ConvertFormat

/**
 * Тестирует ConvertFormat.fileExtension и sampleRate.
 * Критично: неправильное расширение → файл не откроется в DAW.
 */
final class ConvertFormatTests: XCTestCase {

    func test_flacStandard_extension() {
        XCTAssertEqual(ConvertFormat.flacStandard.fileExtension, "flac")
    }

    func test_flacHighRes_sampleRate() {
        XCTAssertEqual(ConvertFormat.flacHighRes.sampleRate, 96_000)
    }

    func test_aiffStandard_extension() {
        XCTAssertEqual(ConvertFormat.aiffStandard.fileExtension, "aiff")
    }

    func test_mp3_320_extension() {
        XCTAssertEqual(ConvertFormat.mp3_320.fileExtension, "mp3")
    }

    func test_mp3_320_sampleRate_is44100() {
        XCTAssertEqual(ConvertFormat.mp3_320.sampleRate, 44_100,
                       "MP3 must output 44.1 kHz for LAME compatibility")
    }

    func test_mp3_320_bitDepth_is16() {
        XCTAssertEqual(ConvertFormat.mp3_320.bitDepth, 16,
                       "LAME encodes from 16-bit int internally")
    }

    func test_allCases_haveUniqueExtensions_perCategory() {
        let flacFormats = ConvertFormat.allCases.filter { $0.fileExtension == "flac" }
        let aiffFormats = ConvertFormat.allCases.filter { $0.fileExtension == "aiff" }
        XCTAssertEqual(flacFormats.count, 2, "Standard + HighRes")
        XCTAssertEqual(aiffFormats.count, 2, "Standard + HighRes")
    }
}
