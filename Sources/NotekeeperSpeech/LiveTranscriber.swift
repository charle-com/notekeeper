import Foundation
import NotekeeperCore

/// Transcription live par piste : tampon 16 kHz, VAD énergétique à seuil adaptatif, énoncés fermés
/// après 600 ms de silence ou à 12 s, inférences sérialisées (une à la fois, toutes pistes).
/// Les temps émis sont ABSOLUS (temps de session fourni par `feed`).
final class LiveTranscriber: @unchecked Sendable {

    struct Utterance {
        let track: Track
        var samples: [Float]
        let start: TimeInterval
        var end: TimeInterval
    }

    private final class TrackState {
        var pending: [Float] = []          // reste inter-appels, découpé en trames de 20 ms
        var pendingStart: TimeInterval = 0
        var inUtterance = false
        var buffer: [Float] = []
        var bufferStart: TimeInterval = 0
        var voiceSamples = 0
        var trailingSilence = 0
        var preRoll: [Float] = []
        var noiseFloor: Float = 0.002      // RMS du bruit de fond, estimé sur les trames de silence
    }

    private static let sampleRate = 16_000
    private static let frame = 320                          // 20 ms
    private static let silenceClose = 16_000 * 6 / 10       // 600 ms
    private static let maxUtterance = 16_000 * 12           // 12 s : au-delà, on affiche même sans pause
    private static let minVoice = 16_000 * 4 / 10           // 400 ms
    private static let preRollMax = 16_000 * 3 / 10         // 300 ms
    private static let mergeGap = 16_000 / 5                // 200 ms de silence entre énoncés fusionnés

    private let engine: WhisperEngine
    private let meetingID: UUID
    private let language: String
    private let dictionary: [String]
    private let onEvent: (TranscriptEvent) -> Void

    private let lock = NSLock()
    private var states: [Track: TrackState] = [.mic: TrackState(), .system: TrackState()]
    private var queue: [Utterance] = []
    private var kicks: AsyncStream<Void>.Continuation?
    private var worker: Task<Void, Never>?
    private var stopped = false

    init(engine: WhisperEngine, meetingID: UUID, language: String, dictionary: [String],
         onEvent: @escaping (TranscriptEvent) -> Void) {
        self.engine = engine
        self.meetingID = meetingID
        self.language = language
        self.dictionary = dictionary
        self.onEvent = onEvent
        let (stream, continuation) = AsyncStream<Void>.makeStream()
        kicks = continuation
        worker = Task.detached(priority: .userInitiated) { [weak self] in
            for await _ in stream {
                guard let self else { return }
                await self.drain()
            }
        }
    }

    // MARK: - Entrée audio

    /// Appelé depuis le thread audio : léger (verrou + RMS par trame de 20 ms).
    func feed(track: Track, samples: [Float], at time: TimeInterval) {
        lock.lock()
        defer { lock.unlock() }
        guard !stopped, let st = states[track] else { return }
        if st.pending.isEmpty { st.pendingStart = time }
        st.pending.append(contentsOf: samples)
        var offset = 0
        while st.pending.count - offset >= Self.frame {
            let frame = Array(st.pending[offset..<(offset + Self.frame)])
            let frameTime = st.pendingStart + Double(offset) / Double(Self.sampleRate)
            process(frame: frame, at: frameTime, state: st, track: track)
            offset += Self.frame
        }
        st.pending.removeFirst(offset)
        st.pendingStart += Double(offset) / Double(Self.sampleRate)
    }

    private func process(frame: [Float], at time: TimeInterval, state st: TrackState, track: Track) {
        var energy: Float = 0
        for s in frame { energy += s * s }
        let rms = (energy / Float(frame.count)).squareRoot()
        // Seuil adaptatif : 3 fois le plancher de bruit, jamais sous 0,003 (silence numérique).
        let threshold = max(0.003, st.noiseFloor * 3)
        let isVoice = rms > threshold
        if !isVoice {
            st.noiseFloor = max(0.0005, st.noiseFloor * 0.95 + rms * 0.05)
        }

        if !st.inUtterance {
            if isVoice {
                st.inUtterance = true
                st.buffer = st.preRoll + frame
                st.bufferStart = time - Double(st.preRoll.count) / Double(Self.sampleRate)
                st.preRoll = []
                st.voiceSamples = frame.count
                st.trailingSilence = 0
            } else {
                st.preRoll.append(contentsOf: frame)
                if st.preRoll.count > Self.preRollMax { st.preRoll.removeFirst(st.preRoll.count - Self.preRollMax) }
            }
            return
        }

        st.buffer.append(contentsOf: frame)
        if isVoice {
            st.voiceSamples += frame.count
            st.trailingSilence = 0
        } else {
            st.trailingSilence += frame.count
        }
        if st.trailingSilence >= Self.silenceClose || st.buffer.count >= Self.maxUtterance {
            closeUtterance(state: st, track: track)
        }
    }

    /// Ferme l'énoncé courant (verrou tenu). Envoyé seulement s'il contient assez de voix.
    private func closeUtterance(state st: TrackState, track: Track) {
        guard st.inUtterance else { return }
        let duration = Double(st.buffer.count) / Double(Self.sampleRate)
        // Fin réelle : on rogne le silence de queue au-delà de 300 ms.
        let excess = max(0, st.trailingSilence - Self.preRollMax)
        let end = st.bufferStart + duration - Double(excess) / Double(Self.sampleRate)
        if st.voiceSamples >= Self.minVoice {
            let samples = excess > 0 ? Array(st.buffer.dropLast(excess)) : st.buffer
            queue.append(Utterance(track: track, samples: samples, start: st.bufferStart, end: end))
            kicks?.yield(())
        }
        st.preRoll = Array(st.buffer.suffix(Self.preRollMax))
        st.buffer = []
        st.inUtterance = false
        st.voiceSamples = 0
        st.trailingSilence = 0
    }

    // MARK: - Inférences sérialisées

    private func drain() async {
        while let u = nextUtterance() {
            await run(u)
        }
    }

    /// Prochain énoncé : le plus ancien toutes pistes confondues, fusionné avec ceux de la même
    /// piste encore en attente (quand l'inférence a pris du retard).
    private func nextUtterance() -> Utterance? {
        lock.lock()
        defer { lock.unlock() }
        guard !queue.isEmpty else { return nil }
        let idx = queue.indices.min(by: { queue[$0].start < queue[$1].start })!
        var u = queue.remove(at: idx)
        let sameTrack = queue.indices.filter { queue[$0].track == u.track }.sorted { queue[$0].start < queue[$1].start }
        if !sameTrack.isEmpty {
            for i in sameTrack {
                let next = queue[i]
                u.samples.append(contentsOf: [Float](repeating: 0, count: Self.mergeGap))
                u.samples.append(contentsOf: next.samples)
                u.end = max(u.end, next.end)
            }
            for i in sameTrack.reversed() { queue.remove(at: i) }
            SpeechLog.log("live \(u.track.rawValue) : \(sameTrack.count + 1) énoncés en retard fusionnés (\(String(format: "%.1f", u.end - u.start)) s)")
        }
        return u
    }

    private func run(_ u: Utterance) async {
        onEvent(.partial(track: u.track, text: "…"))
        do {
            let segments = try await engine.transcribe(samples: u.samples, language: language,
                                                       promptTerms: dictionary, timestamps: false)
            let text = segments.map(\.text).joined(separator: " ").trimmingCharacters(in: .whitespacesAndNewlines)
            if text.isEmpty {
                onEvent(.partial(track: u.track, text: ""))
            } else {
                onEvent(.final(TranscriptSegment(meetingID: meetingID, track: u.track, start: u.start, end: u.end,
                                                 text: text, speakerID: nil, isFinal: true)))
            }
        } catch {
            SpeechLog.log("live \(u.track.rawValue) : inférence en échec : \(error)")
            onEvent(.error("Transcription live : \(error.localizedDescription)"))
            onEvent(.partial(track: u.track, text: ""))
        }
    }

    /// Ferme les énoncés en cours, attend les dernières inférences, puis s'arrête.
    func stop() async {
        closeAll()
        await worker?.value
        worker = nil
    }

    /// Ferme de force les énoncés ouverts et clôt la file (le reste de moins de 20 ms est négligé).
    private func closeAll() {
        lock.withLock {
            stopped = true
            for (track, st) in states {
                closeUtterance(state: st, track: track)
                st.pending = []
            }
            kicks?.finish()
            kicks = nil
        }
    }
}
