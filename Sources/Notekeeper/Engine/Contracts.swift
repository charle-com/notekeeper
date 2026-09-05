import Foundation
import NotekeeperCore

/// Contrats entre les modules de l'app. Chaque module en implémente un, l'UI ne connaît que ceux-ci.
/// Temps : toutes les positions sont en secondes depuis le début de la capture (`start()`),
/// identiques sur les deux pistes.

/// Capture audio des deux pistes (micro = moi, audio système = les autres).
protocol CaptureEngine: AnyObject {
    /// Démarre la capture. `onSamples` reçoit des blocs 16 kHz mono Float32 avec le temps du premier
    /// échantillon du bloc. Les WAV (16 kHz mono PCM 16 bits) sont écrits au fil de l'eau.
    /// Lève une erreur si une autorisation manque (micro, enregistrement audio système).
    func start(micWAV: URL, systemWAV: URL, onSamples: @escaping (Track, [Float], TimeInterval) -> Void) async throws
    func stop() async
    /// Niveaux RMS lissés 0…1, publiés sur le main thread pour les vumètres.
    var onLevels: ((_ mic: Float, _ system: Float) -> Void)? { get set }
    /// Nom du périphérique micro en cours ("MacBook Pro Microphone").
    var micDeviceName: String { get }
}

/// Détection d'un appel en cours : quelle application utilise le micro (Zoom, Google Meet via Chrome,
/// Teams, FaceTime, WhatsApp, Slack, Discord…). `nil` = aucun appel.
protocol CallDetector: AnyObject {
    var onChange: ((String?) -> Void)? { get set }
    var currentApp: String? { get }
    func start()
    func stop()
}

/// Transcription (Whisper on-device) et diarisation (FluidAudio).
protocol SpeechEngine: AnyObject {
    /// Charge les modèles (téléchargement si absents). `progress` reçoit des messages courts pour l'UI.
    func prepare(progress: @escaping (String) -> Void) async throws
    var isReady: Bool { get }
    /// Démarre la transcription live. `onEvent` est appelé sur un thread quelconque.
    func startLive(meetingID: UUID, language: String, dictionary: [String], onEvent: @escaping (TranscriptEvent) -> Void)
    /// Blocs 16 kHz mono, temps du premier échantillon.
    func feed(track: Track, samples: [Float], at time: TimeInterval)
    /// Vide les tampons et émet les derniers segments, puis s'arrête.
    func stopLive() async
    /// Passage final après la réunion : retranscription complète des WAV (contexte entier) et
    /// diarisation de la piste système. Les segments rendus ont `speakerID == nil` ; c'est
    /// `TranscriptMerge.assignSpeakers` qui les attribue.
    func finalPass(meetingID: UUID, language: String, dictionary: [String], micWAV: URL?, systemWAV: URL?,
                   progress: @escaping (String) -> Void) async throws -> (segments: [TranscriptSegment], spans: [DiarizedSpan])
}
