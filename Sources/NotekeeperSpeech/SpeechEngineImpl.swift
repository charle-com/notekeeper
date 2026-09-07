import Foundation
import NotekeeperCore

/// Implémentation de `SpeechEngine` : Whisper (WhisperKit) pour le texte, FluidAudio pour les locuteurs.
public final class WhisperSpeechEngine: SpeechEngine, @unchecked Sendable {

    public let whisper = WhisperEngine()
    public let diarizer = DiarizerService()

    private let lock = NSLock()
    private var ready = false
    private var live: LiveTranscriber?

    public init() {}

    public var isReady: Bool {
        lock.lock(); defer { lock.unlock() }
        return ready
    }

    /// Libellé du profil de calcul Whisper retenu ("tout Neural Engine"…), pour l'UI et les rapports.
    public func activeProfileLabel() async -> String? {
        await whisper.activeProfile?.label
    }

    public func prepare(progress: @escaping (String) -> Void) async throws {
        try await whisper.prepare(progress: progress)
        // La diarisation n'est pas bloquante : sans elle, le transcript reste disponible.
        await diarizer.prepare(progress: progress)
        lock.withLock { ready = true }
    }

    public func startLive(meetingID: UUID, language: String, dictionary: [String],
                          onEvent: @escaping (TranscriptEvent) -> Void) {
        let transcriber = LiveTranscriber(engine: whisper, meetingID: meetingID, language: language,
                                          dictionary: dictionary, onEvent: onEvent)
        lock.lock()
        let previous = live
        live = transcriber
        lock.unlock()
        if let previous { Task { await previous.stop() } }
        onEvent(.status("Transcription live démarrée"))
    }

    public func feed(track: Track, samples: [Float], at time: TimeInterval) {
        lock.lock(); let l = live; lock.unlock()
        l?.feed(track: track, samples: samples, at: time)
    }

    public func stopLive() async {
        let l = lock.withLock { () -> LiveTranscriber? in let l = live; live = nil; return l }
        await l?.stop()
    }

    public func finalPass(meetingID: UUID, language: String, dictionary: [String], micWAV: URL?, systemWAV: URL?,
                          progress: @escaping (String) -> Void) async throws -> (segments: [TranscriptSegment], spans: [DiarizedSpan]) {
        // Sans transcription live, les moteurs ne sont pas chargés pendant l'appel : on le fait ici (idempotent).
        if await !whisper.isLoaded { progress("Chargement de Whisper") }
        try await whisper.prepare(progress: progress)
        await diarizer.prepare(progress: progress)
        lock.withLock { ready = true }

        var segments: [TranscriptSegment] = []
        var systemSamples: [Float]?

        for (track, url) in [(Track.mic, micWAV), (Track.system, systemWAV)] {
            guard let url, FileManager.default.fileExists(atPath: url.path) else { continue }
            let label = track == .mic ? "micro" : "système"
            progress("Lecture de la piste \(label)")
            let samples = try AudioFileLoader.loadMono16k(url: url)
            if track == .system { systemSamples = samples }
            guard samples.count >= 1600 else { continue }
            progress(String(format: "Transcription de la piste %@ (%.0f s)", label, Double(samples.count) / 16_000))
            let t0 = Date()
            let found = try await whisper.transcribe(samples: samples, language: language,
                                                     promptTerms: dictionary, timestamps: true)
            SpeechLog.log(String(format: "passage final %@ : %d segments en %.1f s", label, found.count, Date().timeIntervalSince(t0)))
            for s in found {
                segments.append(TranscriptSegment(meetingID: meetingID, track: track, start: s.start, end: s.end,
                                                  text: s.text, speakerID: nil, isFinal: true))
            }
        }

        var spans: [DiarizedSpan] = []
        if let systemSamples {
            progress("Diarisation de la piste système")
            spans = await diarizer.diarize(samples: systemSamples, progress: progress)
        }
        progress("Transcription finale terminée")
        return (segments.sorted { $0.start < $1.start }, spans)
    }

    public func release() async {
        await stopLive()
        await whisper.unload()
        diarizer.unload()
        lock.withLock { ready = false }
    }
}
