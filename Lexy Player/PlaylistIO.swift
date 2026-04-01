import Foundation

// MARK: - Playlist I/O
//
// Supports three playlist formats:
//
//   M3U / M3U8  — plain-text, one path per line (with optional #EXTINF header)
//
//   Rekordbox XML — DJ_PLAYLISTS/COLLECTION/TRACK elements;
//                   Location is encoded as "file://localhost/URL-encoded-path"
//
//   Serato .crate — binary TLV, UTF-16 BE strings.
//                   Structure:
//                     vrsn  → "1.0/Serato ScratchLive Crate"
//                     ovct* → column defs (tvcn = name, tvcw = width)
//                     otrk* → track entries  (ptrk = path, no leading "/")

enum PlaylistIO {

    // MARK: - Export

    static func exportM3U(tracks: [PlaylistManager.Track]) -> String {
        var lines = ["#EXTM3U", ""]
        for track in tracks {
            let dur  = track.duration > 0 ? Int(track.duration) : -1
            let name = track.url.deletingPathExtension().lastPathComponent
            lines.append("#EXTINF:\(dur),\(name)")
            lines.append(track.url.path)
        }
        return lines.joined(separator: "\n") + "\n"
    }

    static func exportRekordboxXML(tracks: [PlaylistManager.Track],
                                   playlistName: String = "Lexy Player") -> String {
        var out = [String]()
        out.append("<?xml version=\"1.0\" encoding=\"UTF-8\" ?>")
        out.append("<DJ_PLAYLISTS Version=\"1.0.0\">")
        out.append("  <PRODUCT Name=\"Lexy Player\" Version=\"1.0\" Company=\"\"/>")
        out.append("  <COLLECTION Entries=\"\(tracks.count)\">")

        for (i, track) in tracks.enumerated() {
            let id   = i + 1
            // file://localhost + URL-percent-encoded absolute path
            let loc  = "file://localhost" + track.url.path.xmlPathEncoded
            let name = track.url.deletingPathExtension().lastPathComponent.xmlEscaped
            let dur  = track.duration > 0 ? Int(track.duration) : 0
            let bpm  = (track.bpm ?? 0) > 0
                         ? String(format: "%.2f", track.bpm!)
                         : "0.00"
            out.append(
                "    <TRACK TrackID=\"\(id)\" Name=\"\(name)\" Artist=\"\" Album=\"\" " +
                "Genre=\"\" Kind=\"\" Size=\"0\" TotalTime=\"\(dur)\" " +
                "DiscNumber=\"0\" TrackNumber=\"0\" Year=\"0\" AverageBpm=\"\(bpm)\" " +
                "DateModified=\"\" DateAdded=\"\" BitRate=\"0\" SampleRate=\"0\" " +
                "Comments=\"\" PlayCount=\"0\" Rating=\"0\" Location=\"\(loc)\" " +
                "Remixer=\"\" Tonality=\"\" Label=\"\" Mix=\"\"/>"
            )
        }

        out.append("  </COLLECTION>")
        out.append("  <PLAYLISTS>")
        out.append("    <NODE Type=\"0\" Name=\"ROOT\" Count=\"1\">")
        out.append("      <NODE Type=\"1\" Name=\"\(playlistName.xmlEscaped)\" " +
                   "KeyType=\"0\" Entries=\"\(tracks.count)\" Count=\"\(tracks.count)\">")
        for (i, _) in tracks.enumerated() {
            out.append("        <TRACK Key=\"\(i + 1)\"/>")
        }
        out.append("      </NODE>")
        out.append("    </NODE>")
        out.append("  </PLAYLISTS>")
        out.append("</DJ_PLAYLISTS>")
        return out.joined(separator: "\n") + "\n"
    }

    static func exportSeratoCrate(tracks: [PlaylistManager.Track]) -> Data {
        var data = Data()

        // Version header
        data.appendTLV(tag: "vrsn", utf16BE: "1.0/Serato ScratchLive Crate")

        // Column definitions
        let columns: [(String, String)] = [
            ("song", "250"), ("artist", "250"), ("bpm", "30"),
            ("key", "30"),   ("album", "250"),  ("length", "250"),
            ("comment", "250"),
        ]
        for (colName, colWidth) in columns {
            var inner = Data()
            inner.appendTLV(tag: "tvcn", utf16BE: colName)
            inner.appendTLV(tag: "tvcw", utf16BE: colWidth)
            data.appendTLV(tag: "ovct", payload: inner)
        }

        // Track entries — path without leading "/"
        for track in tracks {
            let path = track.url.path.hasPrefix("/")
                ? String(track.url.path.dropFirst())
                : track.url.path
            var inner = Data()
            inner.appendTLV(tag: "ptrk", utf16BE: path)
            data.appendTLV(tag: "otrk", payload: inner)
        }

        return data
    }

    // MARK: - Import

    /// Dispatch to the appropriate importer based on file extension.
    static func importPlaylist(from url: URL) throws -> [URL] {
        switch url.pathExtension.lowercased() {
        case "m3u", "m3u8":    return try importM3U(from: url)
        case "xml":            return try importRekordboxXML(from: url)
        case "crate":          return try importSeratoCrate(from: url)
        default:               throw PlaylistIOError.unsupportedFormat
        }
    }

    // MARK: M3U

    private static func importM3U(from url: URL) throws -> [URL] {
        // Try UTF-8 first, fall back to Latin-1
        let text: String
        if let s = try? String(contentsOf: url, encoding: .utf8) {
            text = s
        } else {
            text = try String(contentsOf: url, encoding: .isoLatin1)
        }

        var urls = [URL]()
        for raw in text.components(separatedBy: .newlines) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            guard !line.isEmpty, !line.hasPrefix("#") else { continue }
            if line.hasPrefix("file://") {
                if let u = URL(string: line) { urls.append(u) }
            } else if line.hasPrefix("/") {
                urls.append(URL(fileURLWithPath: line))
            }
        }
        return urls
    }

    // MARK: Rekordbox XML

    private static func importRekordboxXML(from url: URL) throws -> [URL] {
        let data = try Data(contentsOf: url)
        let doc  = try XMLDocument(data: data)
        var urls = [URL]()

        for node in (try? doc.nodes(forXPath: "//TRACK[@Location]")) ?? [] {
            guard let el  = node as? XMLElement,
                  let loc = el.attribute(forName: "Location")?.stringValue
            else { continue }

            if let u = URL(string: loc) {
                // URL(string:) handles "file://localhost/..." correctly
                urls.append(u)
            } else {
                // Manual fallback: strip "file://localhost" prefix then percent-decode
                let stripped = loc
                    .replacingOccurrences(of: "file://localhost", with: "")
                    .replacingOccurrences(of: "file://", with: "")
                if let decoded = stripped.removingPercentEncoding {
                    urls.append(URL(fileURLWithPath: decoded))
                }
            }
        }
        return urls
    }

    // MARK: Serato .crate

    private static func importSeratoCrate(from url: URL) throws -> [URL] {
        let data = try Data(contentsOf: url)
        var urls = [URL]()
        var offset = 0

        while let (tag, payload, next) = parseTLV(data: data, at: offset) {
            offset = next
            guard tag == "otrk" else { continue }

            // Walk inner blocks looking for "ptrk"
            var inner = 0
            while let (iTag, iPayload, iNext) = parseTLV(data: payload, at: inner) {
                inner = iNext
                guard iTag == "ptrk" else { continue }
                if let path = String(data: iPayload, encoding: .utf16BigEndian) {
                    // Serato stores paths without the leading "/"
                    let full = path.hasPrefix("/") ? path : "/" + path
                    urls.append(URL(fileURLWithPath: full))
                }
            }
        }
        return urls
    }

    // MARK: TLV parser

    private static func parseTLV(data: Data, at offset: Int)
        -> (tag: String, payload: Data, next: Int)?
    {
        guard offset + 8 <= data.count else { return nil }
        let tagBytes = data[data.startIndex.advanced(by: offset) ..< data.startIndex.advanced(by: offset + 4)]
        guard let tag = String(bytes: tagBytes, encoding: .ascii) else { return nil }
        let lenSlice = data[data.startIndex.advanced(by: offset + 4) ..< data.startIndex.advanced(by: offset + 8)]
        let len = Int(lenSlice.withUnsafeBytes { $0.load(as: UInt32.self).bigEndian })
        guard offset + 8 + len <= data.count else { return nil }
        let payload = data[data.startIndex.advanced(by: offset + 8) ..< data.startIndex.advanced(by: offset + 8 + len)]
        return (tag, payload, offset + 8 + len)
    }
}

// MARK: - Error type

enum PlaylistIOError: LocalizedError {
    case unsupportedFormat
    case parseError(String)

    var errorDescription: String? {
        switch self {
        case .unsupportedFormat:   return "Unsupported playlist format."
        case .parseError(let msg): return "Could not parse playlist: \(msg)"
        }
    }
}

// MARK: - String helpers

private extension String {
    /// XML-escape the five predefined entities.
    var xmlEscaped: String {
        self
            .replacingOccurrences(of: "&",  with: "&amp;")
            .replacingOccurrences(of: "<",  with: "&lt;")
            .replacingOccurrences(of: ">",  with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
            .replacingOccurrences(of: "'",  with: "&apos;")
    }

    /// Percent-encode a file-system path for embedding in an XML URI attribute.
    var xmlPathEncoded: String {
        // Allow path characters; additionally escape XML-unsafe chars that
        // urlPathAllowed already excludes (&, <, >, ", ').
        var cs = CharacterSet.urlPathAllowed
        cs.remove(charactersIn: "&'\"<>")
        return addingPercentEncoding(withAllowedCharacters: cs) ?? self
    }
}

// MARK: - Data TLV builder

private extension Data {
    mutating func appendTLV(tag: String, utf16BE string: String) {
        let payload = string.data(using: .utf16BigEndian) ?? Data()
        appendTLV(tag: tag, payload: payload)
    }

    mutating func appendTLV(tag: String, payload: Data) {
        guard let tagBytes = tag.data(using: .ascii), tagBytes.count == 4 else { return }
        append(tagBytes)
        var bigLen = UInt32(payload.count).bigEndian
        append(Data(bytes: &bigLen, count: 4))
        append(payload)
    }
}
