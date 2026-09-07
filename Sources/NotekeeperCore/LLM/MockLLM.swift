import Foundation

/// LLM scriptable, sans réseau : pour les tests et le mode démo de l'interface.
/// Ordre de résolution d'une réponse : `handler` s'il est posé, puis la file (`enqueue`),
/// puis la première règle dont le mot-clé apparaît dans le prompt (système + utilisateur),
/// puis `defaultResponse`. Chaque appel est mémorisé dans `calls`.
public final class MockLLM: LLMClient, @unchecked Sendable {

    public struct Call: Sendable {
        public let system: String
        public let user: String
        public let jsonMode: Bool
    }

    public let name = "Mock"
    private let lock = NSLock()
    private var queue: [String]
    private var rules: [(keyword: String, response: String)]
    private var recorded: [Call] = []
    private var handler: (@Sendable (String, String, Bool) throws -> String)?
    public var defaultResponse: String
    /// Erreur à lancer au prochain appel (consommée une fois).
    public var nextError: Error?
    /// Latence simulée, pour donner un rendu réaliste en démo.
    public var latency: TimeInterval = 0

    public init(responses: [String] = [], rules: [(String, String)] = [], defaultResponse: String = "") {
        self.queue = responses
        self.rules = rules.map { (keyword: $0.0, response: $0.1) }
        self.defaultResponse = defaultResponse
    }

    public var calls: [Call] { lock.withLock { recorded } }
    public var lastCall: Call? { calls.last }

    public func enqueue(_ response: String) { lock.withLock { queue.append(response) } }
    public func on(_ keyword: String, respond response: String) { lock.withLock { rules.append((keyword, response)) } }
    public func setHandler(_ h: (@Sendable (String, String, Bool) throws -> String)?) { lock.withLock { handler = h } }
    public func reset() { lock.withLock { queue = []; rules = []; recorded = []; handler = nil; nextError = nil } }

    public func complete(system: String, user: String, jsonMode: Bool) async throws -> String {
        if latency > 0 { try await Task.sleep(nanoseconds: UInt64(latency * 1_000_000_000)) }
        return try lock.withLock {
            recorded.append(Call(system: system, user: user, jsonMode: jsonMode))
            if let e = nextError { nextError = nil; throw e }
            if let handler { return try handler(system, user, jsonMode) }
            if !queue.isEmpty { return queue.removeFirst() }
            let haystack = system + "\n" + user
            if let rule = rules.first(where: { haystack.contains($0.keyword) }) { return rule.response }
            return defaultResponse
        }
    }

    // MARK: - Mode démo

    /// Un mock qui répond de façon plausible à chaque prompt de `Prompts`, pour montrer l'UI sans clé.
    public static func demo(latency: TimeInterval = 0.6) -> MockLLM {
        let m = MockLLM(rules: [
            (Prompts.Marker.identifySpeakers,
             #"{"speakers":[{"label":"Locuteur 2","name":"Priya","confidence":0.92,"evidence":"[00:14] Moi : merci Priya"},{"label":"Locuteur 3","name":"Paul","confidence":0.9,"evidence":"[00:31] Moi : Paul, ta reco ?"}]}"#),
            (Prompts.Marker.summarize, """
            ## En bref
            Cadrage de la refonte du site : périmètre, planning et budget validés, un point bloquant sur le nom de domaine.

            ## Qui a dit quoi
            ### Toi
            - Tu valides le thème sur mesure sans slider et le budget de 10 000 EUR.
            ### Priya
            - Trois demandes de devis perdues le mois dernier ; elle présente la comparaison au client cette semaine.
            ### Paul
            - LCP de 4,5 s sur mobile ; il chiffre 18 jours, démarrage le 22 septembre.

            ## Décisions
            - Thème sur mesure sans slider, hébergement conservé.
            - Formulaire de devis avec double notification et suivi dans un Google Sheet.
            - Mise en ligne cible le 31 octobre, budget 10 000 EUR plus option catalogue à 1 700 EUR.

            ## Par thème
            ### Performance
            - Paul mesure un LCP de 4,5 s sur mobile, causé par les images et le slider.
            ### Devis
            - Trois demandes perdues le mois dernier, dont une cuisine complète.

            ## Prochaines étapes
            - Priya : présenter la comparaison de performance au client, cette semaine.
            - Paul : démarrer l'intégration, le 22 septembre.

            ## Questions ouvertes
            - Le nom de domaine est encore au nom de l'ancien prestataire.
            """),
            (Prompts.Marker.catchUp, """
            - Paul a chiffré le projet à 18 jours, démarrage le 22 septembre.
            - Mise en ligne cible fixée au 31 octobre.
            - Priya présente le budget découpé au client cette semaine.
            """),
            (Prompts.Marker.ask, """
            La mise en ligne est prévue le 31 octobre, avec un budget de 10 000 EUR hors taxes pour le socle et une option catalogue à 1 700 EUR.

            ```json
            {"citations":[]}
            ```
            """),
            (Prompts.Marker.suggestTitle, "Cadrage refonte site Atelier Morin"),
        ], defaultResponse: "Réponse de démonstration.")
        m.latency = latency
        return m
    }
}
