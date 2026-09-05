import Foundation

/// Client LLM minimal : un prompt système + un prompt utilisateur, une réponse texte.
/// Implémentations : Gemini (REST), Ollama (local), plus un `MockLLM` pour les tests et l'UI.
public protocol LLMClient: Sendable {
    var name: String { get }
    /// `jsonMode` demande une sortie JSON stricte quand le backend le supporte.
    func complete(system: String, user: String, jsonMode: Bool) async throws -> String
}

public enum LLMError: Error, LocalizedError {
    case noAPIKey(String)
    case http(Int, String)
    case badResponse(String)
    case unavailable(String)
    public var errorDescription: String? {
        switch self {
        case .noAPIKey(let p): return "Aucune clé API pour \(p). Renseigne-la dans les Réglages."
        case .http(let code, let body): return "HTTP \(code) : \(body.prefix(300))"
        case .badResponse(let m): return "Réponse inattendue : \(m.prefix(300))"
        case .unavailable(let m): return m
        }
    }
}

/// Événement émis par le transcripteur live.
public enum TranscriptEvent: Sendable {
    /// Hypothèse en cours sur une piste (texte provisoire, remplace la précédente pour cette piste).
    case partial(track: Track, text: String)
    /// Segment terminé, à persister.
    case final(TranscriptSegment)
    case status(String)
    case error(String)
}

/// Résultat de diarisation : qui parle quand sur une piste (secondes depuis le début de la piste).
public struct DiarizedSpan: Hashable, Sendable {
    public var clusterKey: String
    public var start: TimeInterval
    public var end: TimeInterval
    public init(clusterKey: String, start: TimeInterval, end: TimeInterval) {
        self.clusterKey = clusterKey; self.start = start; self.end = end
    }
}
