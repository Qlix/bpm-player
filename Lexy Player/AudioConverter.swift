import Foundation
import AVFoundation
import AudioToolbox

// AudioFileTypeID raw values (not always bridged to Swift by name)
nonisolated(unsafe) private let kFlacFileType: AudioFileTypeID = 0x666C6163  // 'flac'
// kAudioFileAIFFType = 0x41494646  ('AIFF') — available directly in AudioToolbox

// MARK: - Format

enum ConvertFormat: String, CaseIterable, Identifiable {
    case flacHighRes  = "FLAC High Res (24-bit / 96 kHz)"
    case flacStandard = "FLAC (24-bit / 48 kHz)"
    case aiffHighRes  = "AIFF High Res (24-bit / 96 kHz)"
    case aiffStandard = "AIFF (24-bit / 48 kHz)"
    case mp3_320      = "MP3 320 kbps"

    var id: String { rawValue }

    nonisolated var fileExtension: String {
        switch self {
        case .flacHighRes, .flacStandard: return "flac"
        case .aiffHighRes, .aiffStandard: return "aiff"
        case .mp3_320:                    return "mp3"
        }
    }

    nonisolated var sampleRate: Double {
        switch self {
        case .flacHighRes, .aiffHighRes:   return 96_000
        case .flacStandard, .aiffStandard: return 48_000
        case .mp3_320:                     return 44_100
        }
    }

    nonisolated var bitDepth: UInt32 {
        switch self {
        case .mp3_320: return 16
        default:       return 24
        }
    }
}

// MARK: - Errors

enum AudioConvertError: LocalizedError {
    case bufferAllocationFailed
    case extAudioFileFailed(OSStatus)
    case mp3InitFailed
    case mp3EncodeFailed(Int32)

    var errorDescription: String? {
        switch self {
        case .bufferAllocationFailed:     return "Could not allocate audio buffer"
        case .extAudioFileFailed(let s):  return "ExtAudioFile error \(s)"
        case .mp3InitFailed:              return "LAME MP3 encoder failed to initialise"
        case .mp3EncodeFailed(let code):  return "LAME encode error \(code)"
        }
    }
}

// MARK: - Converter

enum AudioConverter {

    /// Convert a single audio file synchronously (call from a background thread).
    /// `onProgress` receives values 0…1 as encoding proceeds (used for UI progress bar).
    nonisolated static func convert(source: URL,
                                    to destination: URL,
                                    format: ConvertFormat,
                                    onProgress: ((Double) -> Void)? = nil) throws {

        // ── Read source into PCM buffer ───────────────────────────────────
        let srcFile    = try AVAudioFile(forReading: source)
        let srcFormat  = srcFile.processingFormat          // non-interleaved float32
        let frameCount = AVAudioFrameCount(srcFile.length)

        guard let buffer = AVAudioPCMBuffer(pcmFormat: srcFormat, frameCapacity: frameCount) else {
            throw AudioConvertError.bufferAllocationFailed
        }
        try srcFile.read(into: buffer)

        // ── Write to destination ──────────────────────────────────────────
        switch format {
        case .aiffHighRes, .aiffStandard:
            try writeAIFF(buffer: buffer, to: destination, format: format)
            onProgress?(1.0)
        case .flacHighRes, .flacStandard:
            try writeFLAC(buffer: buffer, to: destination, format: format)
            onProgress?(1.0)
        case .mp3_320:
            // MP3 uses chunked encoding so onProgress fires incrementally
            try writeMP3(buffer: buffer, to: destination, onProgress: onProgress)
        }
    }

    // MARK: AIFF
    //
    // Uses ExtAudioFile (same pattern as FLAC).
    // macOS's internal AudioConverter handles resampling and
    // non-interleaved float32 → interleaved int24 big-endian automatically.

    nonisolated private static func writeAIFF(buffer: AVAudioPCMBuffer,
                                              to url: URL,
                                              format: ConvertFormat) throws {
        let bps = format.bitDepth / 8          // bytes per sample
        var outputASBD = AudioStreamBasicDescription(
            mSampleRate:       format.sampleRate,
            mFormatID:         kAudioFormatLinearPCM,
            // AIFF = big-endian, signed integer, packed
            mFormatFlags:      kAudioFormatFlagIsBigEndian
                             | kAudioFormatFlagIsSignedInteger
                             | kAudioFormatFlagIsPacked,
            mBytesPerPacket:   bps * 2,
            mFramesPerPacket:  1,
            mBytesPerFrame:    bps * 2,
            mChannelsPerFrame: 2,
            mBitsPerChannel:   format.bitDepth,
            mReserved:         0
        )

        var extFile: ExtAudioFileRef?
        let status = ExtAudioFileCreateWithURL(
            url as CFURL,
            kAudioFileAIFFType,        // 'AIFF' — defined in AudioToolbox
            &outputASBD,
            nil,
            AudioFileFlags.eraseFile.rawValue,
            &extFile
        )
        guard status == noErr, let ef = extFile else {
            throw AudioConvertError.extAudioFileFailed(status)
        }
        defer { ExtAudioFileDispose(ef) }

        // Tell ExtAudioFile what PCM format we'll supply (float32 non-interleaved)
        var clientASBD = buffer.format.streamDescription.pointee
        let setStatus = ExtAudioFileSetProperty(
            ef,
            kExtAudioFileProperty_ClientDataFormat,
            UInt32(MemoryLayout<AudioStreamBasicDescription>.size),
            &clientASBD
        )
        guard setStatus == noErr else {
            throw AudioConvertError.extAudioFileFailed(setStatus)
        }

        let writeStatus = ExtAudioFileWrite(ef, buffer.frameLength, buffer.audioBufferList)
        guard writeStatus == noErr else {
            throw AudioConvertError.extAudioFileFailed(writeStatus)
        }
    }

    // MARK: FLAC

    nonisolated private static func writeFLAC(buffer: AVAudioPCMBuffer,
                                              to url: URL,
                                              format: ConvertFormat) throws {
        let flacFormatID: AudioFormatID = 0x666C6163  // 'flac'

        // Start with the fields we know
        var outputASBD = AudioStreamBasicDescription(
            mSampleRate:       format.sampleRate,
            mFormatID:         flacFormatID,
            mFormatFlags:      0,
            mBytesPerPacket:   0,
            mFramesPerPacket:  0,
            mBytesPerFrame:    0,
            mChannelsPerFrame: 2,
            mBitsPerChannel:   format.bitDepth,
            mReserved:         0
        )

        // Let the system fill in any remaining required fields
        var asdbSize = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
        AudioFormatGetProperty(kAudioFormatProperty_FormatInfo,
                               0, nil, &asdbSize, &outputASBD)

        // Create file + codec in one step
        var extFile: ExtAudioFileRef?
        let status = ExtAudioFileCreateWithURL(
            url as CFURL,
            kFlacFileType,
            &outputASBD,
            nil,
            AudioFileFlags.eraseFile.rawValue,
            &extFile
        )
        guard status == noErr, let ef = extFile else {
            throw AudioConvertError.extAudioFileFailed(status)
        }
        defer { ExtAudioFileDispose(ef) }

        // Tell ExtAudioFile what PCM format we'll supply
        var clientASBD = buffer.format.streamDescription.pointee
        let setPropStatus = ExtAudioFileSetProperty(
            ef,
            kExtAudioFileProperty_ClientDataFormat,
            UInt32(MemoryLayout<AudioStreamBasicDescription>.size),
            &clientASBD
        )
        guard setPropStatus == noErr else {
            throw AudioConvertError.extAudioFileFailed(setPropStatus)
        }

        // Write all frames
        let writeStatus = ExtAudioFileWrite(ef, buffer.frameLength, buffer.audioBufferList)
        guard writeStatus == noErr else {
            throw AudioConvertError.extAudioFileFailed(writeStatus)
        }
    }

    // MARK: MP3 via LAME
    //
    // Requires libmp3lame.a built by build_lame.sh and linked in Xcode.
    // Encodes in 4096-frame chunks so onProgress fires ~10× per second,
    // giving the UI a smooth, real progress bar instead of a long freeze.

    nonisolated private static func writeMP3(buffer: AVAudioPCMBuffer,
                                             to url: URL,
                                             onProgress: ((Double) -> Void)?) throws {

        // ── Init LAME ────────────────────────────────────────────────────
        guard let lame = lame_init() else { throw AudioConvertError.mp3InitFailed }
        defer { lame_close(lame) }

        let srcRate  = Int32(buffer.format.sampleRate)
        let channels = Int32(buffer.format.channelCount)

        lame_set_in_samplerate(lame, srcRate)
        lame_set_num_channels(lame, channels)
        lame_set_out_samplerate(lame, 44_100)
        lame_set_brate(lame, 320)
        lame_set_quality(lame, 2)               // 0 = best, 9 = worst

        guard lame_init_params(lame) >= 0 else { throw AudioConvertError.mp3InitFailed }

        // ── Channel pointers ──────────────────────────────────────────────
        guard let channelData = buffer.floatChannelData else {
            throw AudioConvertError.bufferAllocationFailed
        }
        let left        = channelData[0]
        let right       = channels > 1 ? channelData[1] : channelData[0]
        let totalFrames = Int(buffer.frameLength)

        // ── Prepare output file ───────────────────────────────────────────
        FileManager.default.createFile(atPath: url.path, contents: nil)
        guard let fh = FileHandle(forWritingAtPath: url.path) else {
            throw AudioConvertError.bufferAllocationFailed
        }
        defer { try? fh.close() }

        // ── Chunked encode ────────────────────────────────────────────────
        // 4096 frames ≈ 93 ms at 44.1 kHz — fine enough for smooth progress.
        let chunkFrames = 4096
        let mp3BufSize  = Int(1.25 * Double(chunkFrames) + 7200)
        var mp3Buf      = [UInt8](repeating: 0, count: mp3BufSize)
        var offset      = 0

        while offset < totalFrames {
            let thisChunk = min(chunkFrames, totalFrames - offset)

            let encoded = lame_encode_buffer_ieee_float(
                lame,
                left.advanced(by: offset),
                right.advanced(by: offset),
                Int32(thisChunk),
                &mp3Buf,
                Int32(mp3BufSize)
            )
            guard encoded >= 0 else { throw AudioConvertError.mp3EncodeFailed(encoded) }
            if encoded > 0 { fh.write(Data(mp3Buf.prefix(Int(encoded)))) }

            offset += thisChunk
            onProgress?(Double(offset) / Double(totalFrames))
        }

        // ── Flush ─────────────────────────────────────────────────────────
        var flushBuf = [UInt8](repeating: 0, count: 7200)
        let flushed  = lame_encode_flush(lame, &flushBuf, 7200)
        guard flushed >= 0 else { throw AudioConvertError.mp3EncodeFailed(flushed) }
        if flushed > 0 { fh.write(Data(flushBuf.prefix(Int(flushed)))) }
    }

}
