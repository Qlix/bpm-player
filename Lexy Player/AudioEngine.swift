import AVFoundation
import Combine

// MARK: - Render state (shared between main thread and render callback)

private final class RenderState {
    var isPlaying:   Bool = false
    var pendingSeek: Int? = nil
    var bypass:      Bool = false
    var readHead:    Int  = 0
    var totalFrames: Int  = 0
    var naturalEnd:  Bool = false
}

// MARK: - Audio Engine  (RubberBand + async loading)
//
// Audio graph:  AVAudioSourceNode → mainMixer
//
// Loading flow (optimistic UI):
//   loadURL() immediately updates fileName / hasFile / currentTime so the UI
//   responds instantly, then decodes PCM on a background thread via Task.detached.
//   Once decoded, rebuildSourceNode() + resumePlayback() run back on MainActor.
//   If the user loads a second track before the first finishes decoding, the
//   previous Task is cancelled and the state is never written.
//
// Bypass path: when playRate ≈ 1.0 AND pitchSemitones = 0, raw PCM is copied
//   directly to the output buffer — RubberBand is not invoked.

@MainActor
final class AudioEngine: ObservableObject {

    // MARK: Published state

    @Published var isPlaying      = false
    @Published var currentTime    = 0.0
    @Published var duration       = 0.0
    @Published var volume: Float  = 1.0 { didSet { engine.mainMixerNode.outputVolume = volume } }
    @Published var detectedBPM    = 0.0
    @Published var masterTempo    = false { didSet { applyRBParameters() } }
    @Published var fileName       = ""
    @Published var hasFile        = false
    @Published var pitchSemitones = 0.0   { didSet { applyRBParameters() } }

    let trackFinishedPublisher = PassthroughSubject<Void, Never>()

    // MARK: Playback rate

    private(set) var playRate: Float = 1.0
    var activeRate: Float { playRate }

    // MARK: Audio graph

    private let engine    = AVAudioEngine()
    private var sourceNode: AVAudioSourceNode?

    // MARK: RubberBand + render state

    private var rb: RBProcessor?
    private var renderState = RenderState()

    // MARK: In-memory PCM (replaced on each file load)

    private var pcmLeft:  [Float] = []
    private var pcmRight: [Float] = []
    private var fileSampleRate: Double = 44100

    // MARK: Load task (cancel on new load)

    private var loadTask: Task<Void, Never>?

    // MARK: Playback tracking

    private var seekBase  = 0.0
    private var wallBase: Date?
    private var timerSub: AnyCancellable?
    private var scheduleGen = 0

    // MARK: Init

    init() {
        engine.mainMixerNode.outputVolume = volume
        try? engine.start()
    }

    // MARK: File loading  (optimistic UI + async decode)

    func loadURL(_ url: URL) {
        // Cancel any in-flight decode from a previous call
        loadTask?.cancel()

        // ── Immediate UI update ───────────────────────────────────────────
        stopPlayback()
        fileName    = url.deletingPathExtension().lastPathComponent
        hasFile     = true          // enable controls right away
        currentTime = 0
        duration    = 0
        seekBase    = 0

        // ── Background PCM decode ─────────────────────────────────────────
        loadTask = Task {
            do {
                let pcm = try await Self.decodePCM(url)
                guard !Task.isCancelled else { return }

                // Back on MainActor (AudioEngine is @MainActor, Task inherits it)
                self.pcmLeft        = pcm.left
                self.pcmRight       = pcm.right
                self.fileSampleRate = pcm.sampleRate
                self.duration       = pcm.duration
                self.rebuildSourceNode()
                self.resumePlayback()
            } catch {
                guard !Task.isCancelled else { return }
                self.fileName = url.lastPathComponent + " — Error reading file"
                self.hasFile  = false
            }
        }
    }

    // Decode runs on a global background thread (Task.detached has no actor)
    private struct PCMResult {
        let left: [Float]; let right: [Float]
        let sampleRate: Double; let duration: Double
    }

    private static func decodePCM(_ url: URL) async throws -> PCMResult {
        try await Task.detached(priority: .userInitiated) {
            let f   = try AVAudioFile(forReading: url)
            let fmt = f.processingFormat
            let n   = Int(f.length)
            guard n > 0 else { throw CocoaError(.fileReadUnknown) }

            guard let buf = AVAudioPCMBuffer(pcmFormat: fmt,
                                             frameCapacity: AVAudioFrameCount(n)) else {
                throw CocoaError(.fileReadCorruptFile)
            }
            try f.read(into: buf)
            buf.frameLength = AVAudioFrameCount(n)

            let ch = Int(fmt.channelCount)
            let L: [Float]
            let R: [Float]
            if let d = buf.floatChannelData {
                L = Array(UnsafeBufferPointer(start: d[0], count: n))
                R = ch >= 2 ? Array(UnsafeBufferPointer(start: d[1], count: n)) : L
            } else {
                L = [Float](repeating: 0, count: n)
                R = L
            }
            return PCMResult(left: L, right: R,
                             sampleRate: fmt.sampleRate,
                             duration: Double(n) / fmt.sampleRate)
        }.value
    }

    // MARK: Transport

    func togglePlay() { isPlaying ? pausePlayback() : resumePlayback() }

    func resumePlayback() {
        guard hasFile else { return }
        if !engine.isRunning { try? engine.start() }

        rb?.reset()
        applyRBParameters()

        renderState.naturalEnd  = false
        renderState.pendingSeek = Int(seekBase * fileSampleRate)
        renderState.isPlaying   = true

        isPlaying = true
        wallBase  = Date()
        startTimer()
    }

    private func pausePlayback() {
        seekBase = currentTime
        renderState.isPlaying = false
        isPlaying = false
        stopTimer()
    }

    func stopPlayback() {
        renderState.isPlaying   = false
        renderState.pendingSeek = 0
        isPlaying         = false
        seekBase          = 0
        currentTime       = 0
        stopTimer()
    }

    func seek(to time: Double) {
        let t = max(0, min(time, duration))
        seekBase    = t
        currentTime = t
        rb?.reset()
        renderState.pendingSeek = Int(t * fileSampleRate)
        if isPlaying { wallBase = Date() }
    }

    // MARK: BPM / Tempo

    func applyTargetBPM(_ target: Double) {
        guard detectedBPM > 0, target > 0 else { return }
        let ratio = Float(target / detectedBPM).clamped(to: 0.25...4.0)
        setRate(ratio)
    }

    func resetRate() { setRate(1.0) }
    func applyRate(_ rate: Float) { setRate(rate.clamped(to: 0.25...4.0)) }
    func toggleMasterTempo() { masterTempo.toggle() }

    private func setRate(_ rate: Float) {
        playRate = rate
        applyRBParameters()
    }

    private func applyRBParameters() {
        guard let rb else { return }
        let rate      = Double(playRate)
        let semiScale = pow(2.0, pitchSemitones / 12.0)

        rb.timeRatio  = 1.0 / rate
        rb.pitchScale = masterTempo ? semiScale : (rate * semiScale)

        // Bypass when speed AND pitch are both at unity — this covers:
        //   • BPM OFF + KEY LOCK OFF  →  bypass (trivially true)
        //   • BPM OFF + KEY LOCK ON   →  bypass (masterTempo adds no shift at rate=1.0)
        //   • BPM ON  + KEY LOCK ON   →  NOT bypassed (pitch must be preserved)
        //   • BPM ON  + KEY LOCK OFF  →  NOT bypassed (speed changed)
        let isBypass = (abs(rate - 1.0) < 0.001) && (abs(pitchSemitones) < 0.001)
        if !isBypass && renderState.bypass {
            rb.reset()
            renderState.pendingSeek = renderState.readHead
        }
        renderState.bypass = isBypass
    }

    // MARK: Source node

    private func rebuildSourceNode() {
        if let old = sourceNode { engine.detach(old); sourceNode = nil }

        guard let outFmt = AVAudioFormat(standardFormatWithSampleRate: fileSampleRate,
                                        channels: 2) else { return }

        let processor = RBProcessor(sampleRate: fileSampleRate, channels: 2)
        rb            = processor
        applyRBParameters()

        let st         = RenderState()
        st.totalFrames = pcmLeft.count
        st.bypass      = renderState.bypass
        renderState    = st

        let capturedL  = pcmLeft
        let capturedR  = pcmRight
        let capturedRB = processor
        let capturedSt = st

        let node = AVAudioSourceNode(format: outFmt) { [weak capturedSt, weak capturedRB]
            isSilence, _, frameCount, audioBufferList -> OSStatus in

            guard let st = capturedSt else { isSilence.pointee = true; return noErr }

            let nOut = Int(frameCount)
            let abl  = UnsafeMutableAudioBufferListPointer(audioBufferList)
            guard abl.count >= 2,
                  let outL = abl[0].mData?.assumingMemoryBound(to: Float.self),
                  let outR = abl[1].mData?.assumingMemoryBound(to: Float.self)
            else { isSilence.pointee = true; return noErr }

            outL.initialize(repeating: 0, count: nOut)
            outR.initialize(repeating: 0, count: nOut)

            if let target = st.pendingSeek {
                st.readHead    = max(0, min(target, st.totalFrames))
                st.pendingSeek = nil
                capturedRB?.reset()
            }

            guard st.isPlaying else { isSilence.pointee = true; return noErr }

            // ── BYPASS PATH ───────────────────────────────────────────────
            if st.bypass {
                let remain  = st.totalFrames - st.readHead
                let canCopy = min(nOut, remain)
                if canCopy > 0 {
                    capturedL.withUnsafeBufferPointer { lBuf in
                        capturedR.withUnsafeBufferPointer { rBuf in
                            outL.update(from: lBuf.baseAddress!.advanced(by: st.readHead), count: canCopy)
                            outR.update(from: rBuf.baseAddress!.advanced(by: st.readHead), count: canCopy)
                        }
                    }
                    st.readHead += canCopy
                }
                if st.readHead >= st.totalFrames && !st.naturalEnd {
                    st.isPlaying = false; st.naturalEnd = true
                    DispatchQueue.main.async {
                        NotificationCenter.default.post(name: .audioEngineTrackEnded, object: nil)
                    }
                }
                return noErr
            }

            // ── RUBBERBAND PATH ───────────────────────────────────────────
            guard let rb = capturedRB else { return noErr }
            var outCursor = 0; var flushed = false

            while outCursor < nOut {
                let avail = Int(rb.available)
                if avail > 0 {
                    let want = min(avail, nOut - outCursor)
                    let got  = Int(rb.retrieveLeft(outL.advanced(by: outCursor),
                                                   right: outR.advanced(by: outCursor),
                                                   maxFrames: want))
                    outCursor += got
                    if outCursor >= nOut { break }
                }
                if flushed { break }

                let needed  = max(Int(rb.samplesRequired), 128)
                let remain  = st.totalFrames - st.readHead
                let canFeed = min(needed, remain)
                let isFinal = (remain - canFeed) <= 0

                if canFeed > 0 {
                    capturedL.withUnsafeBufferPointer { lBuf in
                        capturedR.withUnsafeBufferPointer { rBuf in
                            rb.processLeft(lBuf.baseAddress!.advanced(by: st.readHead),
                                           right: rBuf.baseAddress!.advanced(by: st.readHead),
                                           frames: canFeed, isFinal: isFinal)
                        }
                    }
                    st.readHead += canFeed
                } else {
                    capturedL.withUnsafeBufferPointer { lBuf in
                        capturedR.withUnsafeBufferPointer { rBuf in
                            rb.processLeft(lBuf.baseAddress!, right: rBuf.baseAddress!,
                                           frames: 0, isFinal: true)
                        }
                    }
                    flushed = true
                }
            }

            if st.readHead >= st.totalFrames && Int(rb.available) == 0 && !st.naturalEnd {
                st.isPlaying = false; st.naturalEnd = true
                DispatchQueue.main.async {
                    NotificationCenter.default.post(name: .audioEngineTrackEnded, object: nil)
                }
            }
            return noErr
        }

        engine.attach(node)
        engine.connect(node, to: engine.mainMixerNode, format: outFmt)
        sourceNode = node

        scheduleGen += 1
        let myGen = scheduleGen
        NotificationCenter.default.addObserver(
            forName: .audioEngineTrackEnded, object: nil, queue: .main
        ) { [weak self] _ in
            guard let self, self.scheduleGen == myGen else { return }
            self.handleNaturalEnd()
        }
    }

    private func handleNaturalEnd() {
        isPlaying = false; seekBase = 0; currentTime = 0
        stopTimer()
        trackFinishedPublisher.send()
    }

    // MARK: Timer

    private func startTimer() {
        wallBase = Date()
        timerSub = Timer.publish(every: 0.05, on: .main, in: .common)
            .autoconnect()
            .sink { [weak self] _ in self?.tick() }
    }

    private func stopTimer() { timerSub = nil; wallBase = nil }

    private func tick() {
        guard isPlaying, let wb = wallBase else { return }
        currentTime = min(seekBase + Date().timeIntervalSince(wb) * Double(playRate), duration)
    }
}

// MARK: - Notification name

extension Notification.Name {
    static let audioEngineTrackEnded = Notification.Name("com.lexyplayer.trackEnded")
}

// MARK: - Clamping helper

extension Comparable {
    func clamped(to range: ClosedRange<Self>) -> Self {
        min(max(self, range.lowerBound), range.upperBound)
    }
}
