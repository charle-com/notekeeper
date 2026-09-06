import Foundation
import NotekeeperCore

/// Contrats du module de capture audio. L'UI ne connaît que ceux-ci.
/// Temps : toutes les positions sont en secondes depuis le début de la capture (`start()`),
/// identiques sur les deux pistes.

/// Capture audio des deux pistes (micro = moi, audio système = les autres).
public protocol CaptureEngine: AnyObject {
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
public protocol CallDetector: AnyObject {
    var onChange: ((String?) -> Void)? { get set }
    var currentApp: String? { get }
    func start()
    func stop()
}
