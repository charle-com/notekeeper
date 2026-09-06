import Foundation
import NotekeeperCore

/// Journal sur stderr uniquement : stdout est réservé au protocole.
enum Log {
    static func info(_ message: String) {
        FileHandle.standardError.write(Data("[notekeeper-mcp] \(message)\n".utf8))
    }
}

/// Erreur JSON-RPC 2.0.
struct RPCError: Error {
    let code: Int
    let message: String
    static func methodNotFound(_ m: String) -> RPCError { RPCError(code: -32601, message: "Méthode inconnue : \(m)") }
    static func invalidParams(_ m: String) -> RPCError { RPCError(code: -32602, message: "Paramètres invalides : \(m)") }
    static func internalError(_ m: String) -> RPCError { RPCError(code: -32603, message: "Erreur interne : \(m)") }
    static let parseError = RPCError(code: -32700, message: "JSON illisible")
}

/// Serveur MCP sur stdio : une ligne JSON par message, réponses sur stdout, journal sur stderr.
final class MCPServer {

    static let version = "0.1.0"
    static let defaultProtocolVersion = "2025-06-18"

    let store: Store
    let tools: MeetingTools
    private let output = FileHandle.standardOutput

    init(store: Store) {
        self.store = store
        self.tools = MeetingTools(store: store)
    }

    /// Boucle principale : lit stdin jusqu'à EOF. Ne lève jamais : toute erreur devient une réponse JSON-RPC.
    func run() {
        Log.info("prêt, base : \(store.url.path)")
        while let line = readLine(strippingNewline: true) {
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { continue }
            guard let data = trimmed.data(using: .utf8),
                  let json = try? JSONSerialization.jsonObject(with: data) else {
                send(errorResponse(id: NSNull(), error: .parseError))
                continue
            }
            if let batch = json as? [[String: Any]] {
                let responses = batch.compactMap { handle($0) }
                if !responses.isEmpty { send(responses) }
            } else if let message = json as? [String: Any] {
                if let response = handle(message) { send(response) }
            } else {
                send(errorResponse(id: NSNull(), error: RPCError(code: -32600, message: "Requête invalide")))
            }
        }
        Log.info("stdin fermé, arrêt")
    }

    /// Traite un message ; nil pour une notification (pas d'id) ou une réponse entrante.
    func handle(_ message: [String: Any]) -> [String: Any]? {
        let id = message["id"]
        guard let method = message["method"] as? String else {
            // Réponse à une requête que nous n'avons pas envoyée : on l'ignore.
            if id == nil || message["result"] != nil || message["error"] != nil { return nil }
            return errorResponse(id: id ?? NSNull(), error: RPCError(code: -32600, message: "Requête sans méthode"))
        }
        let params = message["params"] as? [String: Any] ?? [:]
        let isNotification = id == nil || method.hasPrefix("notifications/")
        do {
            let result = try dispatch(method: method, params: params)
            if isNotification { return nil }
            return ["jsonrpc": "2.0", "id": id ?? NSNull(), "result": result]
        } catch let e as RPCError {
            if isNotification { Log.info("notification \(method) : \(e.message)"); return nil }
            return errorResponse(id: id ?? NSNull(), error: e)
        } catch {
            if isNotification { return nil }
            return errorResponse(id: id ?? NSNull(), error: .internalError(error.localizedDescription))
        }
    }

    private func dispatch(method: String, params: [String: Any]) throws -> Any {
        switch method {
        case "initialize":
            let requested = params["protocolVersion"] as? String ?? Self.defaultProtocolVersion
            return [
                "protocolVersion": requested,
                "capabilities": ["tools": [String: Any]()],
                "serverInfo": ["name": "notekeeper", "version": Self.version],
                "instructions": "Notes de réunion locales de l'utilisateur : réunions, transcripts horodatés, recherche plein texte.",
            ] as [String: Any]
        case "notifications/initialized", "notifications/cancelled", "notifications/progress", "notifications/roots/list_changed":
            return [:] as [String: Any]
        case "ping":
            return [:] as [String: Any]
        case "tools/list":
            return ["tools": tools.definitions] as [String: Any]
        case "tools/call":
            guard let name = params["name"] as? String else { throw RPCError.invalidParams("name manquant") }
            let arguments = params["arguments"] as? [String: Any] ?? [:]
            do {
                let text = try tools.call(name: name, arguments: arguments)
                return ["content": [["type": "text", "text": text]], "isError": false] as [String: Any]
            } catch let e as RPCError where e.code == -32602 {
                throw e
            } catch let e as ToolError {
                // Erreur d'exécution d'un outil : résultat marqué isError, pas une erreur de protocole.
                return ["content": [["type": "text", "text": e.message]], "isError": true] as [String: Any]
            }
        case "resources/list":
            return ["resources": [Any]()] as [String: Any]
        case "prompts/list":
            return ["prompts": [Any]()] as [String: Any]
        default:
            throw RPCError.methodNotFound(method)
        }
    }

    private func errorResponse(id: Any, error: RPCError) -> [String: Any] {
        ["jsonrpc": "2.0", "id": id, "error": ["code": error.code, "message": error.message]]
    }

    private func send(_ payload: Any) {
        guard var data = try? JSONSerialization.data(withJSONObject: payload, options: [.withoutEscapingSlashes]) else {
            Log.info("réponse non sérialisable")
            return
        }
        data.append(0x0A)
        output.write(data)
    }
}

/// Erreur d'exécution d'un outil (réunion introuvable, base illisible…), renvoyée dans le résultat.
struct ToolError: Error {
    let message: String
}

/// Les outils exposés : définitions (JSON Schema) et exécution sur le `Store`.
struct MeetingTools {

    let store: Store

    var definitions: [[String: Any]] {
        [
            tool("list_meetings", "List meetings, most recent first. Optional ISO 8601 date range.",
                 properties: [
                    "limit": ["type": "integer", "description": "Max meetings to return (default 20).", "minimum": 1, "maximum": 500],
                    "from": ["type": "string", "description": "Only meetings started at or after this ISO 8601 date."],
                    "to": ["type": "string", "description": "Only meetings started before this ISO 8601 date."],
                 ], required: []),
            tool("get_meeting", "Get a meeting: metadata, participants, speakers, summary and notes.",
                 properties: ["id": ["type": "string", "description": "Meeting id (UUID)."]], required: ["id"]),
            tool("get_transcript", "Get the timestamped transcript of a meeting, optionally limited to a time window in seconds.",
                 properties: [
                    "id": ["type": "string", "description": "Meeting id (UUID)."],
                    "from_seconds": ["type": "number", "description": "Start of the window, seconds from meeting start."],
                    "to_seconds": ["type": "number", "description": "End of the window, seconds from meeting start."],
                 ], required: ["id"]),
            tool("search_meetings", "Full-text search across all transcripts (prefix match, accents ignored). Returns snippets with meeting id and timestamp.",
                 properties: [
                    "query": ["type": "string", "description": "Words to search for."],
                    "limit": ["type": "integer", "description": "Max hits (default 20).", "minimum": 1, "maximum": 200],
                 ], required: ["query"]),
            tool("add_note", "Append a markdown note to a meeting.",
                 properties: [
                    "id": ["type": "string", "description": "Meeting id (UUID)."],
                    "text": ["type": "string", "description": "Note to append."],
                 ], required: ["id", "text"]),
            tool("rename_speaker", "Set the display name of a speaker in a meeting; all their turns follow.",
                 properties: [
                    "meeting_id": ["type": "string", "description": "Meeting id (UUID)."],
                    "speaker_id": ["type": "string", "description": "Speaker id (UUID), or the current label such as \"Locuteur 2\"."],
                    "name": ["type": "string", "description": "New name. Empty string clears the name."],
                 ], required: ["meeting_id", "speaker_id", "name"]),
        ]
    }

    private func tool(_ name: String, _ description: String, properties: [String: Any], required: [String]) -> [String: Any] {
        ["name": name, "description": description,
         "inputSchema": ["type": "object", "properties": properties, "required": required, "additionalProperties": false]]
    }

    func call(name: String, arguments: [String: Any]) throws -> String {
        switch name {
        case "list_meetings": return try listMeetings(arguments)
        case "get_meeting": return try getMeeting(arguments)
        case "get_transcript": return try getTranscript(arguments)
        case "search_meetings": return try searchMeetings(arguments)
        case "add_note": return try addNote(arguments)
        case "rename_speaker": return try renameSpeaker(arguments)
        default: throw RPCError.invalidParams("outil inconnu : \(name)")
        }
    }

    // MARK: - Outils

    private func listMeetings(_ args: [String: Any]) throws -> String {
        let limit = try optionalInt(args, "limit") ?? 20
        let from = try optionalDate(args, "from")
        let to = try optionalDate(args, "to")
        var meetings = try wrap { try store.meetings(limit: 1000) }
        if let from { meetings = meetings.filter { $0.startedAt >= from } }
        if let to { meetings = meetings.filter { $0.startedAt < to } }
        meetings = Array(meetings.prefix(max(1, limit)))
        guard !meetings.isEmpty else { return "Aucune réunion." }
        var out = ["\(meetings.count) réunion(s) :", ""]
        for m in meetings {
            var line = "- \(Self.iso(m.startedAt)) | \(m.title) | \(TimeFormat.clock(m.duration)) | \(m.source) | \(m.status.rawValue)"
            if !m.participants.isEmpty { line += " | invités : \(m.participants.joined(separator: ", "))" }
            line += " | id: \(m.id.uuidString)"
            out.append(line)
        }
        return out.joined(separator: "\n")
    }

    private func getMeeting(_ args: [String: Any]) throws -> String {
        let m = try meeting(args, "id")
        let speakers = try wrap { try store.speakers(meetingID: m.id) }
        let segments = try wrap { try store.segments(meetingID: m.id, finalOnly: true) }
        var out = "# \(m.title)\n\n"
        out += "- id : \(m.id.uuidString)\n"
        out += "- Début : \(Self.iso(m.startedAt))\n"
        if let end = m.endedAt { out += "- Fin : \(Self.iso(end))\n" }
        out += "- Durée : \(TimeFormat.clock(m.duration))\n"
        out += "- Source : \(m.source)\n"
        out += "- Statut : \(m.status.rawValue)\n"
        out += "- Langue : \(m.language)\n"
        if !m.participants.isEmpty { out += "- Invités (calendrier) : \(m.participants.joined(separator: ", "))\n" }
        out += "- Tours de parole : \(segments.count)\n"
        if !speakers.isEmpty {
            out += "\n## Locuteurs\n"
            for s in speakers {
                out += "- \(s.displayName) (label : \(s.label), id : \(s.id.uuidString)\(s.isMe ? ", moi" : ""))\n"
            }
        }
        if let summary = m.summaryMarkdown, !summary.isEmpty { out += "\n## Résumé\n\n\(summary)\n" }
        if !m.notes.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { out += "\n## Notes\n\n\(m.notes)\n" }
        return out
    }

    private func getTranscript(_ args: [String: Any]) throws -> String {
        let m = try meeting(args, "id")
        let from = try optionalDouble(args, "from_seconds")
        let to = try optionalDouble(args, "to_seconds")
        if let from, let to, to < from { throw RPCError.invalidParams("to_seconds doit être supérieur à from_seconds") }
        let speakers = try wrap { try store.speakers(meetingID: m.id) }
        var segments = TranscriptMerge.coalesce(try wrap { try store.segments(meetingID: m.id, finalOnly: true) })
        if let from { segments = segments.filter { $0.end >= from } }
        if let to { segments = segments.filter { $0.start <= to } }
        guard !segments.isEmpty else { return "Aucun tour de parole dans cette fenêtre." }
        let header = "# \(m.title) (\(Self.iso(m.startedAt)), id: \(m.id.uuidString))\n\n"
        return header + TranscriptMerge.render(segments, speakers: speakers)
    }

    private func searchMeetings(_ args: [String: Any]) throws -> String {
        let query = try requiredString(args, "query")
        let limit = try optionalInt(args, "limit") ?? 20
        let hits = try wrap { try store.search(query, limit: max(1, limit)) }
        guard !hits.isEmpty else { return "Aucun résultat pour « \(query) »." }
        var out = ["\(hits.count) résultat(s) pour « \(query) » :", ""]
        for h in hits {
            let who = h.speakerName ?? "?"
            out.append("- [\(h.meetingTitle), \(Self.iso(h.meetingDate))] [\(TimeFormat.clock(h.start))] \(who) : \(h.snippet) (meeting_id: \(h.meetingID.uuidString), start_seconds: \(Int(h.start)))")
        }
        return out.joined(separator: "\n")
    }

    private func addNote(_ args: [String: Any]) throws -> String {
        var m = try meeting(args, "id")
        let text = try requiredString(args, "text").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { throw RPCError.invalidParams("text vide") }
        let existing = m.notes.trimmingCharacters(in: .whitespacesAndNewlines)
        m.notes = existing.isEmpty ? text : existing + "\n\n" + text
        try wrap { try store.update(m) }
        return "Note ajoutée à « \(m.title) » (\(m.notes.count) caractères de notes au total)."
    }

    private func renameSpeaker(_ args: [String: Any]) throws -> String {
        let m = try meeting(args, "meeting_id")
        let ref = try requiredString(args, "speaker_id").trimmingCharacters(in: .whitespaces)
        let name = try requiredString(args, "name").trimmingCharacters(in: .whitespacesAndNewlines)
        let speakers = try wrap { try store.speakers(meetingID: m.id) }
        let target = speakers.first { $0.id.uuidString.caseInsensitiveCompare(ref) == .orderedSame }
            ?? speakers.first { $0.label.caseInsensitiveCompare(ref) == .orderedSame }
            ?? speakers.first { ($0.name ?? "").caseInsensitiveCompare(ref) == .orderedSame }
        guard let target else {
            throw ToolError(message: "Locuteur « \(ref) » introuvable dans « \(m.title) ». Locuteurs : "
                            + speakers.map { "\($0.displayName) (\($0.id.uuidString))" }.joined(separator: ", "))
        }
        try wrap { try store.rename(speakerID: target.id, name: name.isEmpty ? nil : name) }
        return name.isEmpty
            ? "Nom de \(target.label) effacé dans « \(m.title) »."
            : "\(target.label) s'appelle maintenant « \(name) » dans « \(m.title) »."
    }

    // MARK: - Paramètres

    private func meeting(_ args: [String: Any], _ key: String) throws -> Meeting {
        let raw = try requiredString(args, key)
        guard let id = UUID(uuidString: raw.trimmingCharacters(in: .whitespaces)) else {
            throw RPCError.invalidParams("\(key) n'est pas un UUID : \(raw)")
        }
        guard let m = try wrap({ try store.meeting(id) }) else { throw ToolError(message: "Réunion introuvable : \(id.uuidString)") }
        return m
    }

    private func requiredString(_ args: [String: Any], _ key: String) throws -> String {
        guard let v = args[key] else { throw RPCError.invalidParams("\(key) manquant") }
        guard let s = v as? String else { throw RPCError.invalidParams("\(key) doit être une chaîne") }
        return s
    }

    private func optionalInt(_ args: [String: Any], _ key: String) throws -> Int? {
        guard let v = args[key], !(v is NSNull) else { return nil }
        if let i = v as? Int { return i }
        if let d = v as? Double { return Int(d) }
        if let s = v as? String, let i = Int(s) { return i }
        throw RPCError.invalidParams("\(key) doit être un entier")
    }

    private func optionalDouble(_ args: [String: Any], _ key: String) throws -> Double? {
        guard let v = args[key], !(v is NSNull) else { return nil }
        if let d = v as? Double { return d }
        if let i = v as? Int { return Double(i) }
        if let s = v as? String, let d = Double(s) { return d }
        throw RPCError.invalidParams("\(key) doit être un nombre")
    }

    private func optionalDate(_ args: [String: Any], _ key: String) throws -> Date? {
        guard let v = args[key], !(v is NSNull) else { return nil }
        guard let s = v as? String else { throw RPCError.invalidParams("\(key) doit être une date ISO 8601") }
        guard let d = Self.parseISO(s) else { throw RPCError.invalidParams("\(key) : date ISO 8601 illisible : \(s)") }
        return d
    }

    /// Toute erreur du Store devient une erreur d'outil lisible, jamais un crash.
    private func wrap<T>(_ body: () throws -> T) throws -> T {
        do { return try body() } catch { throw ToolError(message: "Base de données : \(error.localizedDescription)") }
    }

    // MARK: - Dates

    static func iso(_ d: Date) -> String {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f.string(from: d)
    }

    static func parseISO(_ s: String) -> Date? {
        let trimmed = s.trimmingCharacters(in: .whitespaces)
        let full = ISO8601DateFormatter()
        full.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let d = full.date(from: trimmed) { return d }
        full.formatOptions = [.withInternetDateTime]
        if let d = full.date(from: trimmed) { return d }
        let dayOnly = DateFormatter()
        dayOnly.locale = Locale(identifier: "en_US_POSIX")
        dayOnly.timeZone = TimeZone.current
        for format in ["yyyy-MM-dd'T'HH:mm:ss", "yyyy-MM-dd'T'HH:mm", "yyyy-MM-dd"] {
            dayOnly.dateFormat = format
            if let d = dayOnly.date(from: trimmed) { return d }
        }
        return nil
    }
}
