import Foundation
import FluidAudio
import NotekeeperCore

/// Diarisation offline (FluidAudio, pyannote community-1 : segmentation + WeSpeaker + PLDA/VBx).
/// Les modèles sont téléchargés depuis Hugging Face au premier usage dans
/// `~/Library/Application Support/Notekeeper/FluidAudio/Models/speaker-diarization-coreml/`.
/// Tout échec rend `[]` et un log : la diarisation n'empêche jamais un transcript.
public final class DiarizerService: @unchecked Sendable {

    public static func modelsDirectory() -> URL {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Application Support")
        return support.appendingPathComponent("Notekeeper", isDirectory: true)
            .appendingPathComponent("FluidAudio", isDirectory: true)
            .appendingPathComponent("Models", isDirectory: true)
    }

    private let lock = NSLock()
    private var manager: OfflineDiarizerManager?
    private var preparing: Task<Bool, Never>?

    public init() {}

    public var isReady: Bool { lock.withLock { manager != nil } }

    /// Charge (et télécharge si besoin) les modèles. Faux en cas d'échec, jamais d'erreur.
    @discardableResult
    public func prepare(progress: @escaping (String) -> Void) async -> Bool {
        enum State { case ready, inFlight(Task<Bool, Never>), start }
        let state: State = lock.withLock {
            if manager != nil { return .ready }
            if let preparing { return .inFlight(preparing) }
            return .start
        }
        switch state {
        case .ready: return true
        case .inFlight(let t): return await t.value
        case .start: break
        }
        let task = Task<Bool, Never> { [weak self] in
            guard let self else { return false }
            let t0 = Date()
            progress("Chargement des modèles de diarisation")
            let m = OfflineDiarizerManager(config: OfflineDiarizerConfig())
            do {
                try await m.prepareModels(directory: Self.modelsDirectory())
                self.lock.withLock { self.manager = m }
                SpeechLog.log(String(format: "diarizer prêt en %.1f s", Date().timeIntervalSince(t0)))
                progress("Diarisation prête")
                return true
            } catch {
                SpeechLog.log("diarizer indisponible : \(error)")
                progress("Diarisation indisponible")
                return false
            }
        }
        lock.withLock { preparing = task }
        let ok = await task.value
        lock.withLock { preparing = nil }
        return ok
    }

    /// Diarise un WAV (temps depuis le début du fichier). `[]` si les modèles manquent ou en cas d'erreur.
    public func diarize(wav: URL, progress: @escaping (String) -> Void) async -> [DiarizedSpan] {
        let samples: [Float]
        do { samples = try AudioFileLoader.loadMono16k(url: wav) } catch {
            SpeechLog.log("diarisation : \(error)")
            return []
        }
        return await diarize(samples: samples, progress: progress)
    }

    public func diarize(samples: [Float], progress: @escaping (String) -> Void) async -> [DiarizedSpan] {
        guard samples.count >= 16_000 else { return [] }
        guard await prepare(progress: progress) else { return [] }
        guard let m = lock.withLock({ manager }) else { return [] }
        let t0 = Date()
        let lastTenth = TenthBox()
        do {
            let result = try await m.process(audio: samples) { done, total in
                guard total > 0 else { return }
                let tenth = done * 10 / total
                if lastTenth.update(tenth) { progress("Diarisation : \(tenth * 10) %") }
            }
            let spans = result.segments
                .filter { $0.endTimeSeconds > $0.startTimeSeconds }
                .map { DiarizedSpan(clusterKey: $0.speakerId, start: TimeInterval($0.startTimeSeconds),
                                    end: TimeInterval($0.endTimeSeconds)) }
                .sorted { $0.start < $1.start }
            let clusters = Set(spans.map(\.clusterKey)).count
            SpeechLog.log(String(format: "diarisation de %.1f s en %.2f s : %d segments, %d locuteurs",
                                 Double(samples.count) / 16_000, Date().timeIntervalSince(t0), spans.count, clusters))
            return spans
        } catch {
            SpeechLog.log("diarisation en échec : \(error)")
            return []
        }
    }
}

private final class TenthBox: @unchecked Sendable {
    private let lock = NSLock()
    private var last = -1
    func update(_ v: Int) -> Bool {
        lock.lock(); defer { lock.unlock() }
        guard v != last else { return false }
        last = v
        return true
    }
}
