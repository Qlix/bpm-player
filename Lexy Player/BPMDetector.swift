import AVFoundation
import Accelerate

// MARK: - BPM Detector
//
// Algorithm:
//   1. Read up to 60 s of audio, mix to mono.
//   2. Compute a half-wave rectified first-difference onset envelope
//      (energy frames with 10 ms hop).
//   3. Compute the normalised autocorrelation of the onset envelope.
//   4. Find the lag with the highest score in the range [55, 200] BPM.
//   5. Apply octave correction (halve/double) to land in [70, 170] BPM.

struct BPMDetector {

    nonisolated static func detect(file: AVAudioFile) -> Double {

        let format      = file.processingFormat
        let sampleRate  = Float(format.sampleRate)
        let channels    = Int(format.channelCount)

        // -- Read audio ---------------------------------------------------
        let maxFrames    = Int(sampleRate * 60)
        let framesToRead = min(Int(file.length), maxFrames)

        guard let buffer = AVAudioPCMBuffer(
            pcmFormat:      format,
            frameCapacity:  AVAudioFrameCount(framesToRead)
        ) else { return 120 }

        file.framePosition = 0
        guard (try? file.read(into: buffer, frameCount: AVAudioFrameCount(framesToRead))) != nil,
              let channelData = buffer.floatChannelData
        else { return 120 }

        let actualFrames = Int(buffer.frameLength)

        // -- Mix to mono --------------------------------------------------
        var mono = [Float](repeating: 0, count: actualFrames)
        for ch in 0..<channels {
            vDSP_vadd(mono, 1, channelData[ch], 1, &mono, 1, vDSP_Length(actualFrames))
        }
        var invCh = 1.0 / Float(channels)
        vDSP_vsmul(mono, 1, &invCh, &mono, 1, vDSP_Length(actualFrames))

        // -- Energy envelope (RMS per hop) --------------------------------
        let hopSize  = max(1, Int(sampleRate * 0.010))  // ~10 ms
        let winSize  = hopSize * 4

        var energy = [Float]()
        energy.reserveCapacity(actualFrames / hopSize + 1)

        var offset = 0
        while offset + winSize <= actualFrames {
            var rms: Float = 0
            vDSP_rmsqv(mono.withUnsafeBufferPointer { $0.baseAddress! + offset },
                       1, &rms, vDSP_Length(winSize))
            energy.append(rms)
            offset += hopSize
        }

        // -- Half-wave rectified first difference (onset function) --------
        let N = energy.count
        guard N > 10 else { return 120 }

        var onset = [Float](repeating: 0, count: N)
        for i in 1..<N {
            onset[i] = max(0, energy[i] - energy[i - 1])
        }

        // -- Autocorrelation in BPM range [55, 200] -----------------------
        let hopsPerSec = sampleRate / Float(hopSize)
        let minLag     = max(1, Int(hopsPerSec * 60 / 200))   // lag for 200 BPM
        let maxLag     = min(N - 1, Int(hopsPerSec * 60 / 55)) // lag for 55 BPM

        guard minLag < maxLag else { return 120 }

        // Normalisation factor for unbiased autocorrelation at lag 0
        var energy0: Float = 0
        vDSP_dotpr(onset, 1, onset, 1, &energy0, vDSP_Length(N))
        guard energy0 > 0 else { return 120 }

        var bestBPM:   Float = 120
        var bestScore: Float = -1

        for lag in minLag...maxLag {
            let len = N - lag
            guard len > 0 else { break }

            var corr: Float = 0
            // dot(onset[0..<len], onset[lag..<lag+len])
            onset.withUnsafeBufferPointer { ptr in
                vDSP_dotpr(ptr.baseAddress!, 1,
                           ptr.baseAddress! + lag, 1,
                           &corr, vDSP_Length(len))
            }

            let bpm    = hopsPerSec * 60.0 / Float(lag)
            // Slight preference for typical music BPM range
            let weight: Float = (bpm >= 80 && bpm <= 160) ? 1.05 : 1.0
            let score  = (corr / energy0) * weight

            if score > bestScore {
                bestScore = score
                bestBPM   = bpm
            }
        }

        // -- Octave correction: keep result in [70, 170] BPM --------------
        while bestBPM < 70  { bestBPM *= 2 }
        while bestBPM > 170 { bestBPM /= 2 }

        // Round to nearest 0.5 BPM
        return Double((bestBPM * 2).rounded() / 2)
    }
}
