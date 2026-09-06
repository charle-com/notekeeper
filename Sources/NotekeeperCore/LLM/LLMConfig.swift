import Foundation

/// Réglages du module IA, persistés dans `UserDefaults.standard` sous des clés préfixées `llm.`.
/// `makeClient()` fabrique le client correspondant au fournisseur choisi.
public struct LLMConfig: Equatable, Sendable {

    public enum Provider: String, CaseIterable, Sendable {
        case gemini
        case ollama
        public var displayName: String {
            switch self {
            case .gemini: return "Gemini (cloud)"
            case .ollama: return "Ollama (local)"
            }
        }
    }

    public enum Keys {
        public static let provider = "llm.provider"
        public static let geminiModel = "llm.geminiModel"
        public static let ollamaModel = "llm.ollamaModel"
        public static let ollamaURL = "llm.ollamaURL"
        public static let userName = "llm.userName"
    }

    public static let defaultGeminiModel = "gemini-3.1-pro-preview"
    public static let defaultOllamaModel = "qwen3:8b"
    public static let defaultOllamaURL = "http://127.0.0.1:11434"
    public static let defaultUserName = "Moi"

    public var provider: Provider
    public var geminiModel: String
    public var ollamaModel: String
    public var ollamaURL: String
    /// Prénom de l'utilisateur, utilisé pour désigner « Moi » dans les prompts.
    public var userName: String

    public init(provider: Provider = .gemini, geminiModel: String = LLMConfig.defaultGeminiModel,
                ollamaModel: String = LLMConfig.defaultOllamaModel, ollamaURL: String = LLMConfig.defaultOllamaURL,
                userName: String = LLMConfig.defaultUserName) {
        self.provider = provider
        self.geminiModel = geminiModel
        self.ollamaModel = ollamaModel
        self.ollamaURL = ollamaURL
        self.userName = userName
    }

    // MARK: - Persistance

    /// Charge les réglages ; toute clé absente ou vide prend sa valeur par défaut.
    public static func load(from defaults: UserDefaults = .standard) -> LLMConfig {
        func str(_ key: String, _ fallback: String) -> String {
            let v = defaults.string(forKey: key)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            return v.isEmpty ? fallback : v
        }
        return LLMConfig(
            provider: Provider(rawValue: str(Keys.provider, Provider.gemini.rawValue)) ?? .gemini,
            geminiModel: str(Keys.geminiModel, defaultGeminiModel),
            ollamaModel: str(Keys.ollamaModel, defaultOllamaModel),
            ollamaURL: str(Keys.ollamaURL, defaultOllamaURL),
            userName: str(Keys.userName, defaultUserName)
        )
    }

    public func save(to defaults: UserDefaults = .standard) {
        defaults.set(provider.rawValue, forKey: Keys.provider)
        defaults.set(geminiModel, forKey: Keys.geminiModel)
        defaults.set(ollamaModel, forKey: Keys.ollamaModel)
        defaults.set(ollamaURL, forKey: Keys.ollamaURL)
        defaults.set(userName, forKey: Keys.userName)
    }

    // MARK: - Fabrique

    /// Le client LLM correspondant aux réglages. La clé Gemini est lue au moment de l'appel
    /// (trousseau, puis variable d'environnement `GEMINI_API_KEY`), jamais figée ici.
    public func makeClient() -> LLMClient {
        switch provider {
        case .gemini:
            return GeminiClient(model: geminiModel)
        case .ollama:
            let url = URL(string: ollamaURL) ?? URL(string: LLMConfig.defaultOllamaURL)!
            return OllamaClient(model: ollamaModel, baseURL: url)
        }
    }

    /// Raccourci : client fabriqué depuis les réglages courants.
    public static func makeClient() -> LLMClient {
        load().makeClient()
    }
}
