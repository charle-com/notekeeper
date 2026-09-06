import Foundation

/// Client Ollama local (`POST /api/chat`, sans streaming).
public struct OllamaClient: LLMClient {

    public let name: String
    public let model: String
    public let baseURL: URL
    public let temperature: Double
    public let timeout: TimeInterval

    private let session: URLSession

    public init(model: String, baseURL: URL, timeout: TimeInterval = 300, temperature: Double = 0.2) {
        self.name = "Ollama \(model)"
        self.model = model
        self.baseURL = baseURL
        self.timeout = timeout
        self.temperature = temperature
        let cfg = URLSessionConfiguration.ephemeral
        cfg.timeoutIntervalForRequest = timeout
        cfg.timeoutIntervalForResource = timeout + 30
        self.session = URLSession(configuration: cfg)
    }

    public func complete(system: String, user: String, jsonMode: Bool) async throws -> String {
        var body: [String: Any] = [
            "model": model,
            "stream": false,
            "messages": [
                ["role": "system", "content": system],
                ["role": "user", "content": user],
            ],
            "options": ["temperature": temperature],
        ]
        if jsonMode { body["format"] = "json" }

        var req = URLRequest(url: baseURL.appendingPathComponent("api/chat"))
        req.httpMethod = "POST"
        req.timeoutInterval = timeout
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try JSONSerialization.data(withJSONObject: body)

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: req)
        } catch let e as URLError {
            switch e.code {
            case .cannotConnectToHost, .cannotFindHost, .networkConnectionLost, .notConnectedToInternet, .dnsLookupFailed:
                throw LLMError.unavailable(
                    "Ollama ne répond pas sur \(baseURL.absoluteString). Lance « ollama serve » puis « ollama pull \(model) ».")
            case .timedOut:
                throw LLMError.unavailable("Ollama n'a pas répondu en \(Int(timeout)) s (modèle \(model)).")
            default:
                throw LLMError.unavailable("Ollama : \(e.localizedDescription)")
            }
        }

        let code = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(code) else {
            let message = Self.errorMessage(from: data)
            if code == 404 || message.lowercased().contains("not found") {
                throw LLMError.unavailable("Modèle « \(model) » absent d'Ollama : lance « ollama pull \(model) ».")
            }
            throw LLMError.http(code, message)
        }
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw LLMError.badResponse(String(data: data, encoding: .utf8) ?? "corps illisible")
        }
        if let error = root["error"] as? String { throw LLMError.badResponse("Ollama : \(error)") }
        guard let message = root["message"] as? [String: Any], let content = message["content"] as? String else {
            throw LLMError.badResponse(String(data: data, encoding: .utf8) ?? "réponse sans message")
        }
        let cleaned = Self.stripThinking(content)
        guard !cleaned.isEmpty else { throw LLMError.badResponse("Ollama a renvoyé une réponse vide") }
        return cleaned
    }

    /// Certains modèles (qwen3) renvoient leur raisonnement entre balises `<think>` ; on l'enlève.
    static func stripThinking(_ text: String) -> String {
        var out = text
        while let open = out.range(of: "<think>"), let close = out.range(of: "</think>", range: open.upperBound..<out.endIndex) {
            out.removeSubrange(open.lowerBound..<close.upperBound)
        }
        return out.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func errorMessage(from data: Data) -> String {
        if let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let error = root["error"] as? String {
            return error
        }
        return String(data: data, encoding: .utf8) ?? ""
    }
}
