import Foundation
import AVFoundation
import NotekeeperCore

/// Session de capture à deux pistes : micro (moi) et audio système (les autres).
///
/// Horloge commune : les deux pistes sont datées en secondes depuis `start()`. Chaque piste est
/// ancrée sur le temps hôte de son premier callback (les WAV reçoivent du silence jusque-là), puis
/// avance au compte d'échantillons. Le temps d'un bloc est donc sa position dans le WAV : les WAV,
/// les blocs livrés et les événements de transcription partagent le même axe. Si une source se
/// recrée en vol (changement de sortie ou de micro), son premier bloc porte `discontinuity` et la
/// piste est recalée sur l'horloge par du silence, sans jamais perdre l'origine.
///
/// Files : les blocs sont livrés via `onSamples` sur une file série interne (jamais le thread IO),
/// les WAV y sont écrits ; les niveaux RMS lissés partent sur le main thread à 20 Hz.
///
/// Si le tap système échoue (autorisation refusée), la session continue avec le micro seul et
/// expose l'erreur dans `lastWarning`.
public final class CaptureSession: CaptureEngine, @unchecked Sendable {

    public var onLevels: ((_ mic: Float, _ system: Float) -> Void)? {
        get { lock.withLock { _onLevels } }
        set { lock.withLock { _onLevels = newValue } }
    }
    public var micDeviceName: String { mic.deviceName }
    public var systemOutputName: String {
        if #available(macOS 14.2, *), let t = tap as? SystemAudioTap { return t.outputDeviceName }
        return "Sortie"
    }
    /// Dernier avertissement non bloquant (tap refusé, device basculé…). `nil` si tout va bien.
    public private(set) var lastWarning: String? {
        get { lock.withLock { _lastWarning } }
        set { lock.withLock { _lastWarning = newValue } }
    }
    /// Vrai si la piste système est effectivement capturée.
    public var isSystemAudioActive: Bool {
        if #available(macOS 14.2, *), let t = tap as? SystemAudioTap { return t.isRunning }
        return false
    }
    public var isRunning: Bool { lock.withLock { running } }

    /// `tapOptions` : montage du tap système (défauts validés sur le terrain).
    public init(tapOptions: SystemTapOptions = SystemTapOptions()) {
        self.tapOptions = tapOptions
    }
    private let tapOptions: SystemTapOptions

    deinit {
        // Une session détruite en capture est arrêtée sans attendre (deinit synchrone).
        if isRunning { stopSync() }
    }

    // MARK: CaptureEngine

    public func start(micWAV: URL, systemWAV: URL,
                      onSamples: @escaping (Track, [Float], TimeInterval) -> Void) async throws {
        guard !isRunning else { return }

        // Micro : autorisation bloquante. Demandée si jamais posée.
        switch AudioPermissions.microphoneStatus {
        case .authorized: break
        case .notDetermined:
            guard await AudioPermissions.requestMicrophone() else {
                throw AudioCaptureError(1, "Accès au micro refusé. À autoriser dans Réglages Système > Confidentialité > Microphone.")
            }
        default:
            throw AudioCaptureError(1, "Accès au micro refusé. À autoriser dans Réglages Système > Confidentialité > Microphone.")
        }

        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            deliveryQueue.async {
                do {
                    try self.startOnQueue(micWAV: micWAV, systemWAV: systemWAV, onSamples: onSamples)
                    cont.resume()
                } catch {
                    cont.resume(throwing: error)
                }
            }
        }
    }

    public func stop() async {
        await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
            DispatchQueue.global(qos: .userInitiated).async {
                self.stopSync()
                cont.resume()
            }
        }
    }

    // MARK: Interne

    private let lock = UnfairLock()
    private var _onLevels: ((Float, Float) -> Void)?
    private var _lastWarning: String?
    private var running = false

    /// File série de livraison : blocs, WAV, niveaux. Tout l'état des pistes vit ici.
    private let deliveryQueue = DispatchQueue(label: "fr.charlesneveu.notekeeper.capture.delivery", qos: .userInitiated)
    private let mic = MicCapture()
    private var tap: AnyObject?   // SystemAudioTap, typé faiblement pour la disponibilité macOS 14.2

    private var startHost: UInt64 = 0
    private var micState = TrackState()
    private var sysState = TrackState()
    private var onSamples: ((Track, [Float], TimeInterval) -> Void)?
    private var levelTimer: DispatchSourceTimer?

    /// Écart toléré entre l'horloge hôte et la position dans le WAV avant recalage hors
    /// discontinuité (dérive normale des horloges : quelques ms par heure).
    private static let resyncThreshold: Double = 0.15
    private static let levelInterval: Double = 0.05

    private struct TrackState {
        var writer: WAVWriter?
        var framesInWAV: Int64 = 0
        var anchored = false
        var sumSq: Double = 0
        var count: Int = 0
        var smoothed: Float = 0
        var writeErrorLogged = false
        var time: TimeInterval { Double(framesInWAV) / TargetFormat.sampleRate }
    }

    private func startOnQueue(micWAV: URL, systemWAV: URL,
                              onSamples: @escaping (Track, [Float], TimeInterval) -> Void) throws {
        lastWarning = nil
        micState = TrackState()
        sysState = TrackState()
        micState.writer = try WAVWriter(url: micWAV)
        do {
            sysState.writer = try WAVWriter(url: systemWAV)
        } catch {
            try? micState.writer?.close()
            micState.writer = nil
            throw error
        }
        self.onSamples = onSamples
        startHost = HostClock.now()

        mic.onChunk = { [weak self] chunk in
            self?.deliveryQueue.async { self?.handle(track: .mic, chunk: chunk) }
        }
        mic.onWarning = { [weak self] w in self?.lastWarning = w }
        do {
            try mic.start()
        } catch {
            closeWritersOnQueue()
            throw AudioCaptureError(2, "Micro indisponible : \(error.localizedDescription)")
        }

        if #available(macOS 14.2, *) {
            let t = SystemAudioTap(options: tapOptions)
            t.onChunk = { [weak self] chunk in
                self?.deliveryQueue.async { self?.handle(track: .system, chunk: chunk) }
            }
            t.onWarning = { [weak self] w in self?.lastWarning = w }
            do {
                try t.start()
                tap = t
            } catch {
                lastWarning = "Audio système non capturé : \(error.localizedDescription)"
                AudioLog.log("session : \(lastWarning ?? "")")
            }
        } else {
            lastWarning = "Audio système non capturé : macOS 14.2 minimum"
        }

        lock.withLock { running = true }
        startLevelTimer()
        AudioLog.log("session démarrée : micro \(mic.deviceName), système \(isSystemAudioActive ? "actif" : "inactif")")
    }

    private func stopSync() {
        guard lock.withLock({ running }) else { return }
        // Les sources posent leur propre barrière : au retour, plus aucun bloc n'est en route.
        mic.stop()
        if #available(macOS 14.2, *), let t = tap as? SystemAudioTap { t.stop() }
        deliveryQueue.sync {
            levelTimer?.cancel()
            levelTimer = nil
            closeWritersOnQueue()
            onSamples = nil
            tap = nil
        }
        lock.withLock { running = false }
        if let cb = onLevels { DispatchQueue.main.async { cb(0, 0) } }
        AudioLog.log(String(format: "session arrêtée : micro %.1f s, système %.1f s",
                            micState.time, sysState.time))
    }

    private func closeWritersOnQueue() {
        for keyPath in [\CaptureSession.micState, \CaptureSession.sysState] {
            do { try self[keyPath: keyPath].writer?.close() } catch { AudioLog.log("WAV : fermeture : \(error)") }
            self[keyPath: keyPath].writer = nil
        }
    }

    /// Sur deliveryQueue : recalage, WAV, livraison, accumulation du niveau.
    private func handle(track: Track, chunk: AudioChunk) {
        let keyPath: ReferenceWritableKeyPath<CaptureSession, TrackState> = track == .mic ? \.micState : \.sysState
        guard onSamples != nil, self[keyPath: keyPath].writer != nil else { return }

        // Position attendue sur l'horloge commune, position réelle dans le WAV.
        let elapsed = max(0, HostClock.seconds(from: startHost, to: chunk.hostTime))
        let expected = Int64(elapsed * TargetFormat.sampleRate)
        let gap = expected - self[keyPath: keyPath].framesInWAV
        if gap > 0, chunk.discontinuity || !self[keyPath: keyPath].anchored
            || Double(gap) / TargetFormat.sampleRate > Self.resyncThreshold {
            do {
                try self[keyPath: keyPath].writer?.appendSilence(frames: Int(gap))
                self[keyPath: keyPath].framesInWAV += gap
            } catch {
                logWriteError(keyPath, error)
            }
        }
        self[keyPath: keyPath].anchored = true

        let time = self[keyPath: keyPath].time
        do {
            try self[keyPath: keyPath].writer?.append(chunk.samples)
        } catch {
            logWriteError(keyPath, error)
        }
        self[keyPath: keyPath].framesInWAV += Int64(chunk.samples.count)
        onSamples?(track, chunk.samples, time)

        var sum: Float = 0
        for s in chunk.samples { sum += s * s }
        self[keyPath: keyPath].sumSq += Double(sum)
        self[keyPath: keyPath].count += chunk.samples.count
    }

    private func logWriteError(_ keyPath: ReferenceWritableKeyPath<CaptureSession, TrackState>, _ error: Error) {
        guard !self[keyPath: keyPath].writeErrorLogged else { return }
        self[keyPath: keyPath].writeErrorLogged = true
        AudioLog.log("WAV : écriture : \(error)")
        lastWarning = "Écriture du WAV en échec : \(error.localizedDescription)"
    }

    // MARK: Niveaux (20 Hz)

    private func startLevelTimer() {
        let timer = DispatchSource.makeTimerSource(queue: deliveryQueue)
        timer.schedule(deadline: .now() + Self.levelInterval, repeating: Self.levelInterval, leeway: .milliseconds(5))
        timer.setEventHandler { [weak self] in self?.publishLevels() }
        timer.resume()
        levelTimer = timer
    }

    private func publishLevels() {
        let m = Self.updateLevel(&micState)
        let s = Self.updateLevel(&sysState)
        guard let cb = onLevels else { return }
        DispatchQueue.main.async { cb(m, s) }
    }

    /// RMS de la fenêtre -> courbe dB sur 50 dB de dynamique -> lissage (attaque instantanée,
    /// relâchement progressif).
    private static func updateLevel(_ state: inout TrackState) -> Float {
        var level: Float = 0
        if state.count > 0 {
            let rms = Float((state.sumSq / Double(state.count)).squareRoot())
            let db = 20 * log10(max(rms, 1e-6))
            level = max(0, min(1, (db + 50) / 50))
        }
        state.sumSq = 0
        state.count = 0
        state.smoothed = level >= state.smoothed ? level : state.smoothed * 0.75 + level * 0.25
        if state.smoothed < 0.005 { state.smoothed = 0 }
        return state.smoothed
    }
}
