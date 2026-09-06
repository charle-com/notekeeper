import Foundation

/// Client Gemini (API REST `generateContent`). Un appel = un prompt système + un message utilisateur.
/// La clé n'est jamais journalisée : elle est retirée de tout message d'erreur qui pourrait la contenir.
public struct GeminiClient: LLMClient {

    public let name: String
    public let model: String
    public let maxOutputTokens: Int
    public let temperature: Double
    public let timeout: TimeInterval
    /// Nombre de réessais sur 429 / 5xx / erreur réseau transitoire.
    public let retries: Int

    private let explicitKey: String?
    private let session: URLSession
    private let endpoint: URL

    public static let defaultEndpoint = URL(string: "https://generativelanguage.googleapis.com/v1beta")!

    public init(model: String, apiKey: String? = nil, endpoint: URL = GeminiClient.defaultEndpoint,
                timeout: TimeInterval = 180, retries: Int = 2, temperature: Double = 0.2,
                maxOutputTokens: Int = 8192) {
        self.name = "Gemini \(model)"
        self.model = model
        self.explicitKey = apiKey
        self.endpoint = endpoint
        self.timeout = timeout
        self.retries = retries
        self.temperature = temperature
        self.maxOutputTokens = maxOutputTokens
        let cfg = URLSessionConfiguration.ephemeral
        cfg.timeoutIntervalForRequest = timeout
        cfg.timeoutIntervalForResource = timeout + 30
        cfg.waitsForConnectivity = false
        self.session = URLSession(configuration: cfg)
    }

    public func complete(system: String, user: String, jsonMode: Bool) async throws -> String {
        guard let key = explicitKey ?? Keychain.geminiAPIKey(), !key.isEmpty else {
            throw LLMError.noAPIKey("Gemini")
        }
        let request = try makeRequest(key: key, system: system, user: user, jsonMode: jsonMode)

        var attempt = 0
        while true {
            do {
                let (data, response) = try await session.data(for: request)
                let code = (response as? HTTPURLResponse)?.statusCode ?? 0
                if (code == 429 || code >= 500), attempt < retries {
                    attempt += 1
                    try await Task.sleep(nanoseconds: UInt64(backoff(attempt) * 1_000_000_000))
                    continue
                }
                guard (200..<300).contains(code) else {
                    throw LLMError.http(code, Self.scrub(Self.errorMessage(from: data), key: key))
                }
                return try Self.parse(data, key: key)
            } catch let e as URLError {
                let transient: Set<URLError.Code> = [.timedOut, .networkConnectionLost, .cannotConnectToHost,
                                                     .dnsLookupFailed, .notConnectedToInternet, .cannotFindHost]
                if transient.contains(e.code), attempt < retries {
                    attempt += 1
                    try await Task.sleep(nanoseconds: UInt64(backoff(attempt) * 1_000_000_000))
                    continue
                }
                throw LLMError.unavailable("Gemini injoignable : " + Self.scrub(e.localizedDescription, key: key))
            }
        }
    }

    // MARK: - Requête

    private func makeRequest(key: String, system: String, user: String, jsonMode: Bool) throws -> URLRequest {
        var components = URLComponents(url: endpoint.appendingPathComponent("models/\(model):generateContent"),
                                       resolvingAgainstBaseURL: false)!
        components.queryItems = [URLQueryItem(name: "key", value: key)]
        guard let url = components.url else { throw LLMError.badResponse("URL Gemini invalide") }

        var generation: [String: Any] = [
            "temperature": temperature,
            "maxOutputTokens": maxOutputTokens,
        ]
        if jsonMode { generation["responseMimeType"] = "application/json" }

        let body: [String: Any] = [
            "systemInstruction": ["parts": [["text": system]]],
            "contents": [["role": "user", "parts": [["text": user]]]],
            "generationConfig": generation,
        ]
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.timeoutInterval = timeout
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try JSONSerialization.data(withJSONObject: body)
        return req
    }

    private func backoff(_ attempt: Int) -> Double {
        attempt == 1 ? 2 : 5
    }

    // MARK: - Réponse

    /// Concatène les `parts.text` du premier candidat (les parties de raisonnement `thought` sont ignorées).
    static func parse(_ data: Data, key: String) throws -> String {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw LLMError.badResponse(scrub(String(data: data, encoding: .utf8) ?? "corps illisible", key: key))
        }
        if let candidates = root["candidates"] as? [[String: Any]], let first = candidates.first {
            let content = first["content"] as? [String: Any]
            let parts = content?["parts"] as? [[String: Any]] ?? []
            let text = parts
                .filter { ($0["thought"] as? Bool) != true }
                .compactMap { $0["text"] as? String }
                .joined()
            if !text.isEmpty { return text }
            let reason = first["finishReason"] as? String ?? "inconnue"
            throw LLMError.badResponse("Gemini a renvoyé une réponse vide (finishReason : \(reason))")
        }
        if let feedback = root["promptFeedback"] as? [String: Any], let reason = feedback["blockReason"] as? String {
            throw LLMError.badResponse("Gemini a bloqué la requête (\(reason))")
        }
        throw LLMError.badResponse(scrub(String(data: data, encoding: .utf8) ?? "réponse sans candidat", key: key))
    }

    static func errorMessage(from data: Data) -> String {
        if let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let error = root["error"] as? [String: Any] {
            let status = error["status"] as? String ?? ""
            let message = error["message"] as? String ?? ""
            return [status, message].filter { !$0.isEmpty }.joined(separator: " : ")
        }
        return String(data: data, encoding: .utf8) ?? ""
    }

    /// Retire la clé d'un texte destiné à un message d'erreur ou à un journal.
    static func scrub(_ text: String, key: String) -> String {
        guard !key.isEmpty else { return text }
        return text.replacingOccurrences(of: key, with: "***")
    }
}
