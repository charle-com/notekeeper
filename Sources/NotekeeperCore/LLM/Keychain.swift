import Foundation
import Security

/// Secrets dans le trousseau macOS (`kSecClassGenericPassword`), service `fr.charlesneveu.notekeeper`.
/// La clé Gemini est stockée sous le compte `gemini` ; en lecture, la variable d'environnement
/// `GEMINI_API_KEY` sert de repli (pratique pour le serveur MCP et les scripts).
public enum Keychain {

    public static let service = "fr.charlesneveu.notekeeper"
    public static let geminiAccount = "gemini"
    public static let geminiEnvironmentVariable = "GEMINI_API_KEY"

    public enum KeychainError: Error, LocalizedError {
        case status(OSStatus)
        public var errorDescription: String? {
            switch self {
            case .status(let s):
                let msg = SecCopyErrorMessageString(s, nil) as String? ?? "code \(s)"
                return "Trousseau : \(msg)"
            }
        }
    }

    // MARK: - Générique

    private static func baseQuery(account: String) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: service,
         kSecAttrAccount as String: account]
    }

    /// Lit un secret ; `nil` s'il n'existe pas ou si le trousseau refuse l'accès.
    public static func read(account: String) -> String? {
        var query = baseQuery(account: account)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        guard status == errSecSuccess, let data = item as? Data else { return nil }
        let value = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return value.isEmpty ? nil : value
    }

    /// Écrit (ou remplace) un secret. Une valeur vide supprime l'entrée.
    public static func write(_ secret: String, account: String) throws {
        let value = secret.trimmingCharacters(in: .whitespacesAndNewlines)
        if value.isEmpty { try delete(account: account); return }
        let data = Data(value.utf8)
        let query = baseQuery(account: account)
        let update: [String: Any] = [kSecValueData as String: data]
        let status = SecItemUpdate(query as CFDictionary, update as CFDictionary)
        if status == errSecSuccess { return }
        guard status == errSecItemNotFound else { throw KeychainError.status(status) }
        var insert = query
        insert[kSecValueData as String] = data
        insert[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
        let added = SecItemAdd(insert as CFDictionary, nil)
        guard added == errSecSuccess else { throw KeychainError.status(added) }
    }

    /// Supprime un secret ; ne fait rien s'il n'existe pas.
    public static func delete(account: String) throws {
        let status = SecItemDelete(baseQuery(account: account) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else { throw KeychainError.status(status) }
    }

    // MARK: - Gemini

    /// Clé API Gemini : trousseau d'abord, puis `GEMINI_API_KEY`. `nil` si aucune des deux.
    public static func geminiAPIKey() -> String? {
        if let k = read(account: geminiAccount) { return k }
        let env = ProcessInfo.processInfo.environment[geminiEnvironmentVariable]?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return env.isEmpty ? nil : env
    }

    public static func setGeminiAPIKey(_ key: String) throws {
        try write(key, account: geminiAccount)
    }

    public static func deleteGeminiAPIKey() throws {
        try delete(account: geminiAccount)
    }

    /// Vrai si une clé est disponible, sans dire d'où elle vient.
    public static var hasGeminiAPIKey: Bool { geminiAPIKey() != nil }
}
