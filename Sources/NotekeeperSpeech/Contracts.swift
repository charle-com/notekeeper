import Foundation
import NotekeeperCore

/// Transcription (Whisper on-device) et diarisation (FluidAudio).
/// Temps : toutes les positions sont en secondes depuis le début de la capture (`start()`),
/// identiques sur les deux pistes.
public protocol SpeechEngine: AnyObject {
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
    /// Décharge les modèles (Whisper, diarisation) pour rendre la mémoire. `prepare` ou `finalPass` les rechargent.
    func release() async
}
