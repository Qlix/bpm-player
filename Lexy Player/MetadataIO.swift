import AVFoundation
import AppKit

// MARK: - Track metadata model

struct TrackMetadata {
    var title:       String   = ""
    var artist:      String   = ""
    var album:       String   = ""
    var genre:       String   = ""
    var year:        String   = ""
    var trackNumber: String   = ""
    var bpm:         String   = ""
    var comment:     String   = ""
    var artwork:     NSImage? = nil
    var fileName:    String   = ""   // without extension (Expert Mode rename)

    nonisolated init() {}
}

// MARK: - Metadata I/O
//
// Read: direct binary parsers per format — no AVFoundation quirks.
//   • MP3 / AIFF  — ID3v2 header  +  ID3v1 128-byte tail
//   • FLAC        — Vorbis Comment block  +  PICTURE block
//   • WAV         — RIFF INFO sub-chunks  +  embedded "id3 " chunk
//   • M4A / AAC   — AVFoundation (MP4 atoms are reliably parsed there)
//
// Write: updates every metadata version present in the file.
//   • MP3  → rewrites ID3v2 header, updates/appends ID3v1 tail
//   • FLAC → rewrites Vorbis Comment block (full-file rewrite as needed)

enum MetadataIO {

    // MARK: - Read
    //
    // We never load the whole audio file — only the first 4 MB (enough for any reasonable
    // ID3v2 / Vorbis / RIFF metadata block including embedded artwork) plus the last 128 bytes
    // (ID3v1 tail). This avoids a 50-300 MB allocation that would compete with the audio
    // engine's PCM prefetch and cause audio dropouts on first open.

    nonisolated static func read(from url: URL) -> TrackMetadata {
        var meta = TrackMetadata()
        meta.fileName = url.deletingPathExtension().lastPathComponent

        let ext = url.pathExtension.lowercased()

        // M4A / AAC: AVFoundation parses MP4 atoms correctly and quickly.
        guard ["mp3", "aif", "aiff", "flac", "wav"].contains(ext) else {
            parseWithAVFoundation(url: url, into: &meta)
            return meta
        }

        // Read only the head and the ID3v1 tail — never the whole file.
        guard let (head, tail) = readHeadAndTail(url: url, headBytes: 4 * 1024 * 1024) else { return meta }

        switch ext {
        case "mp3":
            parseID3v2(head, into: &meta)
            parseID3v1Tail(tail, into: &meta)
        case "aif", "aiff":
            parseAIFF(head, into: &meta)
        case "flac":
            parseFLAC(head, into: &meta)
        case "wav":
            parseWAV(head, into: &meta)
        default:
            break
        }
        return meta
    }

    /// Read the first `headBytes` bytes and the last 128 bytes of a file without
    /// loading the whole file. Uses FileHandle (explicit reads, not mmap).
    nonisolated private static func readHeadAndTail(url: URL, headBytes: Int) -> (head: Data, tail: Data)? {
        guard let fh = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { fh.closeFile() }
        let head     = fh.readData(ofLength: headBytes)
        let fileSize = Int(fh.seekToEndOfFile())
        var tail     = Data()
        if fileSize >= 128 {
            fh.seek(toFileOffset: UInt64(fileSize - 128))
            tail = fh.readData(ofLength: 128)
        }
        return (head: head, tail: tail)
    }

    // MARK: ID3v2 parser  (MP3 — header at byte 0)

    nonisolated private static func parseID3v2(_ fileData: Data, into meta: inout TrackMetadata) {
        guard fileData.count >= 10,
              fileData[0] == 0x49, fileData[1] == 0x44, fileData[2] == 0x33  // "ID3"
        else { return }

        let version = Int(fileData[3])   // 2, 3, or 4
        let flags   = fileData[5]
        let tagSize = desynchsafe4(fileData, at: 6)
        var offset  = 10

        // Optional extended header (ID3v2.3 flag bit 6)
        if flags & 0x40 != 0 && fileData.count >= offset + 4 {
            let extSize = version == 4
                ? desynchsafe4(fileData, at: offset)
                : Int(beu32(fileData, at: offset)) + 4   // v2.3: plain BE + 4-byte size field itself
            offset += extSize
        }

        let tagEnd = min(10 + tagSize, fileData.count)
        guard offset < tagEnd else { return }

        // Slice out the frame region as a fresh 0-based Data so all sub-parsers use simple offsets
        let frames = Data(fileData[offset..<tagEnd])
        if version == 2 { parseV22Frames(frames, into: &meta) }
        else             { parseV23Frames(frames, synchsafe: version == 4, into: &meta) }
    }

    // ID3v2.2 — 3-byte IDs, 3-byte big-endian sizes
    nonisolated private static func parseV22Frames(_ data: Data, into meta: inout TrackMetadata) {
        var i = 0
        while i + 6 <= data.count {
            guard let id = ascii(data, at: i, len: 3), id != "\0\0\0" else { break }
            let size = (Int(data[i+3]) << 16) | (Int(data[i+4]) << 8) | Int(data[i+5])
            i += 6
            guard size > 0, i + size <= data.count else { break }
            let p = data[i..<i+size]; i += size
            switch id {
            case "TT2": setIfEmpty(&meta.title,       text: p)
            case "TP1": setIfEmpty(&meta.artist,      text: p)
            case "TAL": setIfEmpty(&meta.album,       text: p)
            case "TCO": setIfEmpty(&meta.genre,       text: p, transform: cleanGenre)
            case "TYE": setIfEmpty(&meta.year,        text: p)
            case "TRK": setIfEmpty(&meta.trackNumber, text: p)
            case "TBP": setIfEmpty(&meta.bpm,         text: p)
            case "COM": if meta.comment.isEmpty { meta.comment = id3Comment(p) ?? "" }
            case "PIC": if meta.artwork  == nil  { meta.artwork  = v22Picture(p) }
            default: break
            }
        }
    }

    // ID3v2.3 / v2.4 — 4-byte IDs, 4-byte sizes
    nonisolated private static func parseV23Frames(_ data: Data, synchsafe: Bool, into meta: inout TrackMetadata) {
        var i = 0
        while i + 10 <= data.count {
            guard let id = ascii(data, at: i, len: 4), id != "\0\0\0\0" else { break }
            let size = synchsafe
                ? desynchsafe4(data, at: i+4)
                : Int(beu32(data, at: i+4))
            i += 10           // skip ID (4) + size (4) + flags (2)
            guard size > 0, i + size <= data.count else { break }
            let p = data[i..<i+size]; i += size
            switch id {
            case "TIT2":         setIfEmpty(&meta.title,       text: p)
            case "TPE1":         setIfEmpty(&meta.artist,      text: p)
            case "TALB":         setIfEmpty(&meta.album,       text: p)
            case "TCON":         setIfEmpty(&meta.genre,       text: p, transform: cleanGenre)
            case "TYER","TDRC":  setIfEmpty(&meta.year,        text: p)
            case "TRCK":         setIfEmpty(&meta.trackNumber, text: p)
            case "TBPM":         setIfEmpty(&meta.bpm,         text: p)
            case "COMM": if meta.comment.isEmpty { meta.comment = id3Comment(p) ?? "" }
            case "APIC": if meta.artwork  == nil  { meta.artwork  = apicImage(p) }
            default: break
            }
        }
    }

    // MARK: ID3v1

    /// Parse ID3v1 from an exactly-128-byte tail (read via FileHandle — index 0 = first byte).
    nonisolated private static func parseID3v1Tail(_ data: Data, into meta: inout TrackMetadata) {
        guard data.count >= 128,
              data[0] == 0x54, data[1] == 0x41, data[2] == 0x47 else { return }  // "TAG"
        parseID3v1Bytes(data, base: 0, into: &meta)
    }

    /// Parse ID3v1 from the last 128 bytes of an arbitrary-length Data block
    /// (used by AIFF / WAV embedded ID3 chunk parsers).
    nonisolated private static func parseID3v1(_ data: Data, into meta: inout TrackMetadata) {
        guard data.count >= 128 else { return }
        let base = data.count - 128
        guard data[base] == 0x54, data[base+1] == 0x41, data[base+2] == 0x47 else { return }
        parseID3v1Bytes(data, base: base, into: &meta)
    }

    nonisolated private static func parseID3v1Bytes(_ data: Data, base: Int, into meta: inout TrackMetadata) {
        func str(_ off: Int, _ len: Int) -> String {
            let slice = data[(base+off)..<(base+off+len)].prefix { $0 != 0 }
            return (String(bytes: slice, encoding: .isoLatin1) ?? "").trimmingCharacters(in: .whitespaces)
        }
        if meta.title.isEmpty  { meta.title  = str(3,  30) }
        if meta.artist.isEmpty { meta.artist = str(33, 30) }
        if meta.album.isEmpty  { meta.album  = str(63, 30) }
        if meta.year.isEmpty   { meta.year   = str(93,  4) }
        if meta.comment.isEmpty {
            if data[base+125] == 0 && data[base+126] != 0 {
                if meta.trackNumber.isEmpty { meta.trackNumber = "\(data[base+126])" }
                meta.comment = str(97, 28)
            } else {
                meta.comment = str(97, 30)
            }
        }
        if meta.genre.isEmpty { meta.genre = id3v1Genre(data[base+127]) }
    }

    // MARK: AIFF parser  (IFF container, big-endian chunk sizes)

    nonisolated private static func parseAIFF(_ data: Data, into meta: inout TrackMetadata) {
        guard data.count >= 12,
              data[0]==0x46, data[1]==0x4F, data[2]==0x52, data[3]==0x4D,  // "FORM"
              data[8]==0x41, data[9]==0x49                                   // "AI…"
        else {
            // Non-standard — just try ID3v2 at the start anyway
            parseID3v2(data, into: &meta); return
        }
        var pos = 12
        while pos + 8 <= data.count {
            guard let id = ascii(data, at: pos, len: 4) else { break }
            let size = Int(beu32(data, at: pos+4))
            pos += 8
            let end = min(pos + size, data.count)
            if id == "ID3 " || id == "id3 " {
                let chunk = Data(data[pos..<end])
                parseID3v2(chunk, into: &meta)
                parseID3v1(chunk, into: &meta)
            }
            pos = end + (size & 1)   // IFF chunks are word-aligned
        }
    }

    // MARK: FLAC / Vorbis Comments

    nonisolated private static func parseFLAC(_ data: Data, into meta: inout TrackMetadata) {
        guard data.count >= 4,
              data[0]==0x66, data[1]==0x4C, data[2]==0x61, data[3]==0x43  // "fLaC"
        else { return }
        var pos = 4
        while pos + 4 <= data.count {
            let header    = data[pos]
            let isLast    = header & 0x80 != 0
            let blockType = header & 0x7F
            let length    = (Int(data[pos+1]) << 16) | (Int(data[pos+2]) << 8) | Int(data[pos+3])
            pos += 4
            guard pos + length <= data.count else { break }
            let block = Data(data[pos..<pos+length])   // fresh 0-based slice
            pos += length
            switch blockType {
            case 4: parseVorbisComments(block, into: &meta)
            case 6: if meta.artwork == nil { meta.artwork = flacPicture(block) }
            default: break
            }
            if isLast { break }
        }
    }

    nonisolated private static func parseVorbisComments(_ data: Data, into meta: inout TrackMetadata) {
        var pos = 0
        guard pos + 4 <= data.count else { return }
        let vendorLen = Int(leu32(data, at: pos)); pos += 4 + vendorLen
        guard pos + 4 <= data.count else { return }
        let count = Int(leu32(data, at: pos)); pos += 4
        for _ in 0..<count {
            guard pos + 4 <= data.count else { break }
            let len = Int(leu32(data, at: pos)); pos += 4
            guard pos + len <= data.count else { break }
            if let kv = String(bytes: data[pos..<pos+len], encoding: .utf8) {
                applyVorbis(kv, to: &meta)
            }
            pos += len
        }
    }

    nonisolated private static func applyVorbis(_ kv: String, to meta: inout TrackMetadata) {
        guard let eq = kv.firstIndex(of: "=") else { return }
        let key   = kv[..<eq].uppercased()
        let value = String(kv[kv.index(after: eq)...])
        guard !value.isEmpty else { return }
        switch key {
        case "TITLE":                if meta.title.isEmpty       { meta.title       = value }
        case "ARTIST":               if meta.artist.isEmpty      { meta.artist      = value }
        case "ALBUM":                if meta.album.isEmpty       { meta.album       = value }
        case "GENRE":                if meta.genre.isEmpty       { meta.genre       = value }
        case "DATE","YEAR":          if meta.year.isEmpty        { meta.year        = String(value.prefix(4)) }
        case "TRACKNUMBER","TRACK":  if meta.trackNumber.isEmpty { meta.trackNumber = value }
        case "BPM","TEMPO":          if meta.bpm.isEmpty         { meta.bpm         = value }
        case "COMMENT":              if meta.comment.isEmpty     { meta.comment     = value }
        default: break
        }
    }

    nonisolated private static func flacPicture(_ data: Data) -> NSImage? {
        guard data.count >= 32 else { return nil }
        var pos = 4                                         // skip picture type (4)
        let mimeLen = Int(beu32(data, at: pos)); pos += 4 + mimeLen
        guard pos + 4 <= data.count else { return nil }
        let descLen = Int(beu32(data, at: pos)); pos += 4 + descLen
        pos += 16                                           // width+height+depth+colors (4×4)
        guard pos + 4 <= data.count else { return nil }
        let picLen = Int(beu32(data, at: pos)); pos += 4
        guard pos + picLen <= data.count else { return nil }
        return NSImage(data: data[pos..<pos+picLen])
    }

    // MARK: WAV / RIFF parser

    nonisolated private static func parseWAV(_ data: Data, into meta: inout TrackMetadata) {
        guard data.count >= 12,
              data[0]==0x52, data[1]==0x49, data[2]==0x46, data[3]==0x46,  // "RIFF"
              data[8]==0x57, data[9]==0x41, data[10]==0x56, data[11]==0x45  // "WAVE"
        else { return }
        var pos = 12
        while pos + 8 <= data.count {
            guard let id = ascii(data, at: pos, len: 4) else { break }
            let size = Int(leu32(data, at: pos+4)); pos += 8
            let end  = min(pos + size, data.count)
            switch id {
            case "id3 ", "ID3 ", "id3\0":
                let chunk = Data(data[pos..<end])
                parseID3v2(chunk, into: &meta)
                parseID3v1(chunk, into: &meta)
            case "LIST":
                if size >= 4, let type = ascii(data, at: pos, len: 4), type == "INFO" {
                    parseRIFFInfo(data, start: pos+4, end: end, into: &meta)
                }
            default: break
            }
            pos = end + (size & 1)   // RIFF chunks word-aligned
        }
    }

    nonisolated private static func parseRIFFInfo(_ data: Data, start: Int, end: Int, into meta: inout TrackMetadata) {
        var pos = start
        while pos + 8 <= end {
            guard let id = ascii(data, at: pos, len: 4) else { break }
            let size = Int(leu32(data, at: pos+4)); pos += 8
            guard pos + size <= end else { break }
            let raw = data[pos..<pos+size].prefix { $0 != 0 }
            let str = (String(bytes: raw, encoding: .utf8) ??
                       String(bytes: raw, encoding: .isoLatin1) ?? "")
                        .trimmingCharacters(in: .whitespaces)
            pos += size + (size & 1)
            switch id {
            case "INAM": if meta.title.isEmpty       { meta.title       = str }
            case "IART": if meta.artist.isEmpty      { meta.artist      = str }
            case "IPRD": if meta.album.isEmpty       { meta.album       = str }
            case "IGNR": if meta.genre.isEmpty       { meta.genre       = str }
            case "ICRD": if meta.year.isEmpty        { meta.year        = String(str.prefix(4)) }
            case "ITRK": if meta.trackNumber.isEmpty { meta.trackNumber = str }
            case "ICMT": if meta.comment.isEmpty     { meta.comment     = str }
            default: break
            }
        }
    }

    // MARK: AVFoundation fallback  (M4A, AAC, CAF, …)

    nonisolated private static func parseWithAVFoundation(url: URL, into meta: inout TrackMetadata) {
        let asset = AVURLAsset(url: url, options: [AVURLAssetPreferPreciseDurationAndTimingKey: false])
        let sem = DispatchSemaphore(value: 0)
        asset.loadValuesAsynchronously(forKeys: ["commonMetadata", "availableMetadataFormats"]) { sem.signal() }
        sem.wait()

        for item in asset.commonMetadata {
            guard let v = item.value else { continue }
            switch item.commonKey {
            case .commonKeyTitle:     if meta.title.isEmpty  { meta.title  = (v as? String) ?? "" }
            case .commonKeyArtist:    if meta.artist.isEmpty { meta.artist = (v as? String) ?? "" }
            case .commonKeyAlbumName: if meta.album.isEmpty  { meta.album  = (v as? String) ?? "" }
            case .commonKeyArtwork:
                if meta.artwork == nil {
                    if let d = v as? Data        { meta.artwork = NSImage(data: d) }
                    else if let i = v as? NSImage { meta.artwork = i }
                }
            default: break
            }
        }
        for format in asset.availableMetadataFormats {
            for item in asset.metadata(forFormat: format) {
                guard let v = item.value else { continue }
                let k = (item.key as? String) ?? ""
                switch k {
                case "©gen","gnre": if meta.genre.isEmpty       { meta.genre       = (v as? String) ?? "" }
                case "©day":        if meta.year.isEmpty        { meta.year        = (v as? String) ?? "" }
                case "trkn":        if meta.trackNumber.isEmpty { meta.trackNumber = (v as? String) ?? "" }
                case "©cmt":        if meta.comment.isEmpty     { meta.comment     = (v as? String) ?? "" }
                case "tmpo":
                    if meta.bpm.isEmpty {
                        if let s = v as? String       { meta.bpm = s }
                        else if let n = v as? NSNumber { meta.bpm = "\(n.intValue)" }
                    }
                default: break
                }
            }
        }
    }

    // MARK: - Write

    enum WriteError: LocalizedError {
        case unsupportedFormat(String)
        case writeFailure(String)
        var errorDescription: String? {
            switch self {
            case .unsupportedFormat(let e):
                return "Tag editing is not supported for .\(e) files (only .mp3 and .flac)."
            case .writeFailure(let m): return m
            }
        }
    }

    nonisolated static func canWrite(ext: String) -> Bool {
        ["mp3", "flac"].contains(ext.lowercased())
    }

    /// Write the detected BPM as an integer tag only if the file has no BPM value already.
    ///
    /// - Skips silently for unsupported formats (only .mp3 and .flac are writable).
    /// - Skips silently if the existing tag already has a BPM value (respects user data).
    /// - Safe to call from any thread (`nonisolated`).
    nonisolated static func writeBPMIfEmpty(_ bpm: Int, to url: URL) {
        let ext = url.pathExtension.lowercased()
        guard canWrite(ext: ext) else { return }
        var meta = read(from: url)
        guard meta.bpm.trimmingCharacters(in: .whitespaces).isEmpty else { return }
        meta.bpm = String(bpm)
        try? write(meta, to: url)
    }

    nonisolated static func write(_ meta: TrackMetadata, to url: URL) throws {
        switch url.pathExtension.lowercased() {
        case "mp3":  try writeMP3(meta, to: url)
        case "flac": try writeFLAC(meta, to: url)
        default:     throw WriteError.unsupportedFormat(url.pathExtension)
        }
    }

    // MARK: MP3 writer — ID3v2.3 header + ID3v1 tail

    nonisolated private static func writeMP3(_ meta: TrackMetadata, to url: URL) throws {
        let file = try Data(contentsOf: url)

        // Skip existing ID3v2 block
        var audioStart = 0
        if file.count >= 10, file[0]==0x49, file[1]==0x44, file[2]==0x33 {
            let flags = file[5]
            audioStart = 10 + desynchsafe4(file, at: 6)
            if flags & 0x10 != 0 { audioStart += 10 }  // ID3v2.4 footer
        }
        guard audioStart <= file.count else {
            throw WriteError.writeFailure("Corrupted ID3 header.")
        }

        // Remove old ID3v1 tail if present
        var audioEnd = file.count
        if audioEnd >= 128,
           file[audioEnd-128]==0x54, file[audioEnd-127]==0x41, file[audioEnd-126]==0x47 {
            audioEnd -= 128
        }

        // Build ID3v2.3 frames
        var frames = Data()
        func tf(_ id: String, _ v: String) {   // text frame
            let s = v.trimmingCharacters(in: .whitespaces); guard !s.isEmpty else { return }
            var d = Data([0x03]); d += s.data(using: .utf8) ?? Data()   // enc = UTF-8
            frames.appendID3Frame(id: id, payload: d)
        }
        tf("TIT2", meta.title);  tf("TPE1", meta.artist);  tf("TALB", meta.album)
        tf("TCON", meta.genre);  tf("TYER", meta.year);    tf("TRCK", meta.trackNumber)
        tf("TBPM", meta.bpm)

        let cmt = meta.comment.trimmingCharacters(in: .whitespaces)
        if !cmt.isEmpty {
            var d = Data([0x03])                   // encoding = UTF-8
            d += "eng".data(using: .ascii)!        // language
            d.append(0x00)                         // empty short-description NUL
            d += cmt.data(using: .utf8) ?? Data()
            frames.appendID3Frame(id: "COMM", payload: d)
        }
        if let art = meta.artwork, let jpg = art.jpegRepresentation {
            var d = Data([0x03])
            d += "image/jpeg".data(using: .ascii)!; d.append(0x00)  // MIME + NUL
            d.append(0x03); d.append(0x00)                           // type=cover, desc NUL
            d += jpg
            frames.appendID3Frame(id: "APIC", payload: d)
        }

        // ID3v2.3 header
        var hdr = Data("ID3".utf8); hdr += Data([0x03, 0x00, 0x00])
        hdr.appendSynchsafe32(UInt32(frames.count))

        // ID3v1 tail (always written — syncs metadata to the v1 format as well)
        let v1 = buildID3v1(meta)

        do {
            try (hdr + frames + file[audioStart..<audioEnd] + v1).write(to: url, options: .atomic)
        } catch {
            throw WriteError.writeFailure("Could not write file: \(error.localizedDescription)")
        }
    }

    nonisolated private static func buildID3v1(_ meta: TrackMetadata) -> Data {
        var tag = Data(count: 128)
        tag[0] = 0x54; tag[1] = 0x41; tag[2] = 0x47   // "TAG"
        func wr(_ s: String, at start: Int, maxLen: Int) {
            let enc = s.data(using: .isoLatin1) ?? s.data(using: .utf8) ?? Data()
            for (i, b) in enc.prefix(maxLen).enumerated() { tag[start+i] = b }
        }
        wr(meta.title,  at: 3,  maxLen: 30)
        wr(meta.artist, at: 33, maxLen: 30)
        wr(meta.album,  at: 63, maxLen: 30)
        wr(meta.year,   at: 93, maxLen: 4)
        if let tn = Int(meta.trackNumber), tn > 0 {
            wr(meta.comment, at: 97, maxLen: 28)
            tag[125] = 0; tag[126] = UInt8(min(tn, 255))
        } else {
            wr(meta.comment, at: 97, maxLen: 30)
        }
        let gi = id3v1Genres.firstIndex { $0.lowercased() == meta.genre.lowercased() } ?? 255
        tag[127] = UInt8(gi)
        return tag
    }

    // MARK: FLAC writer — rewrites Vorbis Comment + PICTURE block

    nonisolated private static func writeFLAC(_ meta: TrackMetadata, to url: URL) throws {
        let file = try Data(contentsOf: url)
        guard file.count >= 4,
              file[0]==0x66, file[1]==0x4C, file[2]==0x61, file[3]==0x43
        else { throw WriteError.writeFailure("Not a valid FLAC file.") }

        struct Block { var type: UInt8; var data: Data }
        var blocks = [Block](); var audioStart = file.count
        var pos = 4
        while pos + 4 <= file.count {
            let hdr   = file[pos]; let isLast = hdr & 0x80 != 0; let btype = hdr & 0x7F
            let len   = (Int(file[pos+1]) << 16) | (Int(file[pos+2]) << 8) | Int(file[pos+3])
            pos += 4
            guard pos + len <= file.count else { break }
            blocks.append(Block(type: btype, data: Data(file[pos..<pos+len])))
            pos += len
            if isLast { audioStart = pos; break }
        }

        // Replace or insert Vorbis Comment block (type 4)
        let vcData = buildVorbisComment(meta)
        if let i = blocks.firstIndex(where: { $0.type == 4 }) {
            blocks[i].data = vcData
        } else {
            let ins = (blocks.firstIndex(where: { $0.type == 0 }) ?? -1) + 1
            blocks.insert(Block(type: 4, data: vcData), at: ins)
        }

        // Replace or insert PICTURE block (type 6) if artwork is present
        if let art = meta.artwork, let picData = buildFLACPicture(art) {
            if let i = blocks.firstIndex(where: { $0.type == 6 }) {
                blocks[i].data = picData
            } else {
                blocks.append(Block(type: 6, data: picData))
            }
        }

        // Serialize
        var out = Data("fLaC".utf8)
        for (idx, block) in blocks.enumerated() {
            let lastFlag: UInt8 = idx == blocks.count-1 ? 0x80 : 0x00
            out.append(lastFlag | block.type)
            let l = block.data.count
            out.append(UInt8((l >> 16) & 0xFF))
            out.append(UInt8((l >>  8) & 0xFF))
            out.append(UInt8( l        & 0xFF))
            out += block.data
        }
        out += file[audioStart...]
        do {
            try out.write(to: url, options: .atomic)
        } catch {
            throw WriteError.writeFailure("Could not write FLAC file: \(error.localizedDescription)")
        }
    }

    nonisolated private static func buildVorbisComment(_ meta: TrackMetadata) -> Data {
        var pairs = [String]()
        if !meta.title.isEmpty       { pairs.append("TITLE=\(meta.title)") }
        if !meta.artist.isEmpty      { pairs.append("ARTIST=\(meta.artist)") }
        if !meta.album.isEmpty       { pairs.append("ALBUM=\(meta.album)") }
        if !meta.genre.isEmpty       { pairs.append("GENRE=\(meta.genre)") }
        if !meta.year.isEmpty        { pairs.append("DATE=\(meta.year)") }
        if !meta.trackNumber.isEmpty { pairs.append("TRACKNUMBER=\(meta.trackNumber)") }
        if !meta.bpm.isEmpty         { pairs.append("BPM=\(meta.bpm)") }
        if !meta.comment.isEmpty     { pairs.append("COMMENT=\(meta.comment)") }
        let vendor = "Lexy Player".data(using: .utf8)!
        var d = Data(); d.appendLE32(UInt32(vendor.count)); d += vendor
        d.appendLE32(UInt32(pairs.count))
        for p in pairs { let b = p.data(using: .utf8)!; d.appendLE32(UInt32(b.count)); d += b }
        return d
    }

    nonisolated private static func buildFLACPicture(_ image: NSImage) -> Data? {
        guard let jpg = image.jpegRepresentation else { return nil }
        let mime = "image/jpeg".data(using: .ascii)!
        var d = Data()
        d.appendBE32(3)                            // picture type: cover (front)
        d.appendBE32(UInt32(mime.count)); d += mime
        d.appendBE32(0)                            // no description
        d.appendBE32(0); d.appendBE32(0)           // width, height (unspecified)
        d.appendBE32(0); d.appendBE32(0)           // colorDepth, colorCount
        d.appendBE32(UInt32(jpg.count)); d += jpg
        return d
    }

    // MARK: - ID3 frame decoders

    /// Decode a text frame payload (encoding byte + text bytes)
    nonisolated private static func id3Text(_ data: Data.SubSequence) -> String? {
        guard !data.isEmpty else { return nil }
        let enc  = data[data.startIndex]
        let body = Data(data[(data.startIndex+1)...])
        return id3String(body, enc: enc)
    }

    /// Decode a COMM frame payload → returns the actual comment text
    nonisolated private static func id3Comment(_ data: Data.SubSequence) -> String? {
        guard data.count >= 5 else { return nil }
        let enc  = data[data.startIndex]
        // skip encoding(1) + language(3) = 4 bytes, then find null-terminated short description
        var body = Data(data[(data.startIndex+4)...])
        let nl   = (enc == 1 || enc == 2) ? 2 : 1
        var i    = 0
        while i + nl <= body.count {
            let isNull = nl == 2 ? (body[i] == 0 && body[i+1] == 0) : body[i] == 0
            if isNull { body = Data(body[(i+nl)...]); break }
            i += nl
        }
        return id3String(body, enc: enc)
    }

    /// Encoding-aware string decode: 0=Latin-1, 1=UTF-16+BOM, 2=UTF-16BE, 3=UTF-8
    nonisolated private static func id3String(_ data: Data, enc: UInt8) -> String? {
        guard !data.isEmpty else { return nil }
        let bytes = Array(data)
        let raw: String?
        switch enc {
        case 0:  raw = String(bytes: bytes, encoding: .isoLatin1)
        case 1:
            if bytes.count >= 2 && bytes[0] == 0xFF && bytes[1] == 0xFE {
                raw = String(bytes: Array(bytes.dropFirst(2)), encoding: .utf16LittleEndian)
            } else if bytes.count >= 2 && bytes[0] == 0xFE && bytes[1] == 0xFF {
                raw = String(bytes: Array(bytes.dropFirst(2)), encoding: .utf16BigEndian)
            } else {
                raw = String(bytes: bytes, encoding: .utf16LittleEndian)
            }
        case 2:  raw = String(bytes: bytes, encoding: .utf16BigEndian)
        default: raw = String(bytes: bytes, encoding: .utf8)
                 ?? String(bytes: bytes, encoding: .isoLatin1)
        }
        return raw?.trimmingCharacters(in: CharacterSet.controlCharacters.union(.whitespaces)).nonEmpty
    }

    /// Decode APIC frame payload → NSImage
    nonisolated private static func apicImage(_ data: Data.SubSequence) -> NSImage? {
        guard !data.isEmpty else { return nil }
        let enc = data[data.startIndex]
        var i   = data.startIndex + 1
        while i < data.endIndex, data[i] != 0 { i += 1 }  // skip MIME (ASCII NUL-term)
        i += 2   // NUL + picture-type byte
        guard i <= data.endIndex else { return nil }
        // skip description (encoding-aware NUL)
        let nl = (enc == 1 || enc == 2) ? 2 : 1
        while i + nl <= data.endIndex {
            let isNull = nl == 2 ? (data[i] == 0 && i+1 < data.endIndex && data[i+1] == 0) : data[i] == 0
            if isNull { i += nl; break }; i += nl
        }
        guard i < data.endIndex else { return nil }
        return NSImage(data: Data(data[i...]))
    }

    /// Decode ID3v2.2 PIC frame (3-char format instead of MIME string)
    nonisolated private static func v22Picture(_ data: Data.SubSequence) -> NSImage? {
        guard data.count >= 5 else { return nil }
        let enc = data[data.startIndex]
        var i   = data.startIndex + 5   // encoding(1) + format(3) + picture-type(1)
        let nl  = (enc == 1 || enc == 2) ? 2 : 1
        while i + nl <= data.endIndex {
            let isNull = nl == 2 ? (data[i] == 0 && i+1 < data.endIndex && data[i+1] == 0) : data[i] == 0
            if isNull { i += nl; break }; i += nl
        }
        guard i < data.endIndex else { return nil }
        return NSImage(data: Data(data[i...]))
    }

    // Convenience: decode and set a metadata string only if the field is still empty
    nonisolated private static func setIfEmpty(_ field: inout String, text payload: Data.SubSequence,
                                               transform: ((String) -> String)? = nil) {
        guard field.isEmpty, let s = id3Text(payload) else { return }
        field = transform?(s) ?? s
    }

    // MARK: - Genre helpers

    // ID3 genre can be "(12)", "(12)Rock", or plain text. Decode the numeric prefix.
    nonisolated private static func cleanGenre(_ raw: String) -> String {
        let s = raw.trimmingCharacters(in: .whitespaces)
        if s.hasPrefix("("), let close = s.firstIndex(of: ")") {
            if let idx = Int(s[s.index(after: s.startIndex)..<close]) {
                let after = String(s[s.index(after: close)...]).trimmingCharacters(in: .whitespaces)
                return after.isEmpty ? id3v1Genre(UInt8(min(idx, 255))) : after
            }
        }
        return s
    }

    nonisolated private static func id3v1Genre(_ index: UInt8) -> String {
        let i = Int(index); return i < id3v1Genres.count ? id3v1Genres[i] : ""
    }

    // Standard ID3v1 genre list (indices 0-79 per spec + common Winamp extensions)
    nonisolated private static let id3v1Genres: [String] = [
        "Blues","Classic Rock","Country","Dance","Disco","Funk","Grunge","Hip-Hop","Jazz",
        "Metal","New Age","Oldies","Other","Pop","R&B","Rap","Reggae","Rock","Techno",
        "Industrial","Alternative","Ska","Death Metal","Pranks","Soundtrack","Euro-Techno",
        "Ambient","Trip-Hop","Vocal","Jazz+Funk","Fusion","Trance","Classical","Instrumental",
        "Acid","House","Game","Sound Clip","Gospel","Noise","Alternative Rock","Bass","Soul",
        "Punk","Space","Meditative","Instrumental Pop","Instrumental Rock","Ethnic","Gothic",
        "Darkwave","Techno-Industrial","Electronic","Pop-Folk","Eurodance","Dream",
        "Southern Rock","Comedy","Cult","Gangsta","Top 40","Christian Rap","Pop/Funk",
        "Jungle","Native American","Cabaret","New Wave","Psychedelic","Rave","Showtunes",
        "Trailer","Lo-Fi","Tribal","Acid Punk","Acid Jazz","Polka","Retro","Musical",
        "Rock & Roll","Hard Rock"
    ]

    // MARK: - Binary read helpers  (absolute-index into a Data value)

    /// 4-byte synchsafe integer (ID3v2 header / ID3v2.4 frame sizes)
    nonisolated private static func desynchsafe4(_ d: Data, at p: Int) -> Int {
        (Int(d[p]   & 0x7F) << 21) | (Int(d[p+1] & 0x7F) << 14) |
        (Int(d[p+2] & 0x7F) <<  7) |  Int(d[p+3] & 0x7F)
    }
    /// 4-byte big-endian unsigned int
    nonisolated private static func beu32(_ d: Data, at p: Int) -> UInt32 {
        (UInt32(d[p]) << 24) | (UInt32(d[p+1]) << 16) | (UInt32(d[p+2]) << 8) | UInt32(d[p+3])
    }
    /// 4-byte little-endian unsigned int
    nonisolated private static func leu32(_ d: Data, at p: Int) -> UInt32 {
        UInt32(d[p]) | (UInt32(d[p+1]) << 8) | (UInt32(d[p+2]) << 16) | (UInt32(d[p+3]) << 24)
    }
    /// ASCII/Latin-1 string of given byte length
    nonisolated private static func ascii(_ d: Data, at p: Int, len: Int) -> String? {
        guard p + len <= d.count else { return nil }
        return String(bytes: d[p..<p+len], encoding: .isoLatin1)
    }
}

// MARK: - Data write helpers

private extension Data {

    /// Append a 4-byte big-endian unsigned int
    nonisolated mutating func appendBE32(_ v: UInt32) {
        append(UInt8((v >> 24) & 0xFF)); append(UInt8((v >> 16) & 0xFF))
        append(UInt8((v >>  8) & 0xFF)); append(UInt8( v        & 0xFF))
    }
    /// Append a 4-byte little-endian unsigned int
    nonisolated mutating func appendLE32(_ v: UInt32) {
        append(UInt8( v        & 0xFF)); append(UInt8((v >>  8) & 0xFF))
        append(UInt8((v >> 16) & 0xFF)); append(UInt8((v >> 24) & 0xFF))
    }
    /// Append an ID3v2.3 frame (4-char ID, plain big-endian size, 2 zero flags)
    nonisolated mutating func appendID3Frame(id: String, payload: Data) {
        guard let idBytes = id.data(using: .ascii), idBytes.count == 4 else { return }
        append(idBytes); appendBE32(UInt32(payload.count))
        append(contentsOf: [0x00, 0x00]); append(payload)
    }
    /// Append 4 bytes as a synchsafe integer (ID3v2 tag header size field)
    nonisolated mutating func appendSynchsafe32(_ v: UInt32) {
        append(UInt8((v >> 21) & 0x7F)); append(UInt8((v >> 14) & 0x7F))
        append(UInt8((v >>  7) & 0x7F)); append(UInt8( v        & 0x7F))
    }
}

// MARK: - NSImage → JPEG data

private extension NSImage {
    nonisolated var jpegRepresentation: Data? {
        guard let tiff = tiffRepresentation,
              let rep  = NSBitmapImageRep(data: tiff) else { return nil }
        return rep.representation(using: .jpeg, properties: [.compressionFactor: 0.9])
    }
}

// MARK: - String non-empty helper

private extension String {
    nonisolated var nonEmpty: String? { isEmpty ? nil : self }
}
