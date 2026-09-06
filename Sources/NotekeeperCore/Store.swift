import Foundation
import SQLite3

private let SQLITE_TRANSIENT = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

public enum StoreError: Error, LocalizedError {
    case open(String)
    case sql(String)
    public var errorDescription: String? {
        switch self {
        case .open(let m): return "Ouverture de la base impossible : \(m)"
        case .sql(let m): return "SQLite : \(m)"
        }
    }
}

/// Base locale SQLite (+ FTS5 pour la recherche). Une seule connexion, sérialisée par une file :
/// toutes les méthodes sont synchrones et thread-safe, appelables depuis n'importe où.
public final class Store: @unchecked Sendable {

    public static let schemaVersion = 1

    private var db: OpaquePointer?
    private let queue = DispatchQueue(label: "fr.charlesneveu.notekeeper.store")
    public let url: URL

    /// Dossier de données par défaut : ~/Library/Application Support/Notekeeper/
    public static func defaultDirectory() -> URL {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        return support.appendingPathComponent("Notekeeper", isDirectory: true)
    }

    public static func defaultURL() -> URL {
        defaultDirectory().appendingPathComponent("notekeeper.sqlite")
    }

    public init(url: URL) throws {
        self.url = url
        // « :memory: » doit être passé tel quel à SQLite : `url.path` en ferait un fichier réel dans le dossier courant.
        let inMemory = url.lastPathComponent == ":memory:"
        if !inMemory {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        }
        var handle: OpaquePointer?
        let flags = SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX
        guard sqlite3_open_v2(inMemory ? ":memory:" : url.path, &handle, flags, nil) == SQLITE_OK, let handle else {
            let msg = handle.map { String(cString: sqlite3_errmsg($0)) } ?? "?"
            throw StoreError.open(msg)
        }
        db = handle
        try exec("PRAGMA journal_mode=WAL")
        try exec("PRAGMA foreign_keys=ON")
        try migrate()
    }

    /// Base en mémoire, pour les tests.
    public static func inMemory() throws -> Store {
        try Store(url: URL(fileURLWithPath: ":memory:"))
    }

    deinit { if let db { sqlite3_close(db) } }

    // MARK: - Schéma

    private func migrate() throws {
        try exec("""
        CREATE TABLE IF NOT EXISTS meetings (
            id TEXT PRIMARY KEY,
            title TEXT NOT NULL,
            started_at REAL NOT NULL,
            ended_at REAL,
            source TEXT NOT NULL DEFAULT 'Micro',
            participants TEXT NOT NULL DEFAULT '[]',
            calendar_event_id TEXT,
            status TEXT NOT NULL,
            language TEXT NOT NULL DEFAULT 'fr',
            summary_md TEXT,
            notes TEXT NOT NULL DEFAULT '',
            mic_audio_path TEXT,
            system_audio_path TEXT,
            created_at REAL NOT NULL,
            updated_at REAL NOT NULL
        );
        CREATE TABLE IF NOT EXISTS speakers (
            id TEXT PRIMARY KEY,
            meeting_id TEXT NOT NULL REFERENCES meetings(id) ON DELETE CASCADE,
            label TEXT NOT NULL,
            name TEXT,
            is_me INTEGER NOT NULL DEFAULT 0,
            cluster_key TEXT
        );
        CREATE INDEX IF NOT EXISTS speakers_meeting ON speakers(meeting_id);
        CREATE TABLE IF NOT EXISTS segments (
            id TEXT PRIMARY KEY,
            meeting_id TEXT NOT NULL REFERENCES meetings(id) ON DELETE CASCADE,
            track TEXT NOT NULL,
            start REAL NOT NULL,
            end REAL NOT NULL,
            text TEXT NOT NULL,
            speaker_id TEXT REFERENCES speakers(id) ON DELETE SET NULL,
            is_final INTEGER NOT NULL DEFAULT 1
        );
        CREATE INDEX IF NOT EXISTS segments_meeting ON segments(meeting_id, start);
        CREATE VIRTUAL TABLE IF NOT EXISTS segments_fts USING fts5(
            text, meeting_id UNINDEXED, segment_id UNINDEXED, tokenize='unicode61 remove_diacritics 2'
        );
        CREATE TABLE IF NOT EXISTS chat (
            id TEXT PRIMARY KEY,
            meeting_id TEXT REFERENCES meetings(id) ON DELETE CASCADE,
            role TEXT NOT NULL,
            markdown TEXT NOT NULL,
            citations TEXT NOT NULL DEFAULT '[]',
            created_at REAL NOT NULL
        );
        CREATE TABLE IF NOT EXISTS dictionary (
            term TEXT PRIMARY KEY,
            note TEXT
        );
        CREATE TABLE IF NOT EXISTS meta (key TEXT PRIMARY KEY, value TEXT);
        """)
        try exec("INSERT OR IGNORE INTO meta(key, value) VALUES ('schema', '\(Self.schemaVersion)')")
    }

    // MARK: - Meetings

    public func insert(_ m: Meeting) throws {
        try queue.sync {
            try run("""
            INSERT INTO meetings (id,title,started_at,ended_at,source,participants,calendar_event_id,status,language,
                summary_md,notes,mic_audio_path,system_audio_path,created_at,updated_at)
            VALUES (?,?,?,?,?,?,?,?,?,?,?,?,?,?,?)
            """, [m.id.uuidString, m.title, m.startedAt.timeIntervalSince1970, m.endedAt?.timeIntervalSince1970,
                  m.source, Self.json(m.participants), m.calendarEventID, m.status.rawValue, m.language,
                  m.summaryMarkdown, m.notes, m.micAudioPath, m.systemAudioPath,
                  m.createdAt.timeIntervalSince1970, Date().timeIntervalSince1970])
        }
    }

    public func update(_ m: Meeting) throws {
        try queue.sync {
            try run("""
            UPDATE meetings SET title=?, started_at=?, ended_at=?, source=?, participants=?, calendar_event_id=?,
                status=?, language=?, summary_md=?, notes=?, mic_audio_path=?, system_audio_path=?, updated_at=?
            WHERE id=?
            """, [m.title, m.startedAt.timeIntervalSince1970, m.endedAt?.timeIntervalSince1970, m.source,
                  Self.json(m.participants), m.calendarEventID, m.status.rawValue, m.language, m.summaryMarkdown,
                  m.notes, m.micAudioPath, m.systemAudioPath, Date().timeIntervalSince1970, m.id.uuidString])
        }
    }

    public func delete(meetingID: UUID) throws {
        try queue.sync {
            try run("DELETE FROM segments_fts WHERE meeting_id=?", [meetingID.uuidString])
            try run("DELETE FROM meetings WHERE id=?", [meetingID.uuidString])
        }
    }

    public func meeting(_ id: UUID) throws -> Meeting? {
        try queue.sync {
            try query("SELECT * FROM meetings WHERE id=?", [id.uuidString], Self.meeting(from:)).first
        }
    }

    /// Toutes les réunions, les plus récentes d'abord.
    public func meetings(limit: Int = 1000) throws -> [Meeting] {
        try queue.sync {
            try query("SELECT * FROM meetings ORDER BY started_at DESC LIMIT ?", [limit], Self.meeting(from:))
        }
    }

    // MARK: - Speakers

    public func upsert(_ s: Speaker) throws {
        try queue.sync {
            try run("""
            INSERT INTO speakers (id,meeting_id,label,name,is_me,cluster_key) VALUES (?,?,?,?,?,?)
            ON CONFLICT(id) DO UPDATE SET label=excluded.label, name=excluded.name, is_me=excluded.is_me,
                cluster_key=excluded.cluster_key
            """, [s.id.uuidString, s.meetingID.uuidString, s.label, s.name, s.isMe ? 1 : 0, s.clusterKey])
        }
    }

    public func speakers(meetingID: UUID) throws -> [Speaker] {
        try queue.sync {
            try query("SELECT * FROM speakers WHERE meeting_id=? ORDER BY is_me DESC, label", [meetingID.uuidString]) { st in
                Speaker(id: UUID(uuidString: Self.text(st, 0))!, meetingID: UUID(uuidString: Self.text(st, 1))!,
                        label: Self.text(st, 2), name: Self.optText(st, 3), isMe: sqlite3_column_int(st, 4) == 1,
                        clusterKey: Self.optText(st, 5))
            }
        }
    }

    /// Renomme un locuteur : tous ses segments suivent, puisqu'ils référencent son id.
    public func rename(speakerID: UUID, name: String?) throws {
        try queue.sync {
            try run("UPDATE speakers SET name=? WHERE id=?", [name?.isEmpty == true ? nil : name, speakerID.uuidString])
        }
    }

    /// Fusionne `source` dans `target` (même personne détectée deux fois).
    public func merge(speakerID source: UUID, into target: UUID) throws {
        try queue.sync {
            try run("UPDATE segments SET speaker_id=? WHERE speaker_id=?", [target.uuidString, source.uuidString])
            try run("DELETE FROM speakers WHERE id=?", [source.uuidString])
        }
    }

    public func delete(speakerID: UUID) throws {
        try queue.sync { try run("DELETE FROM speakers WHERE id=?", [speakerID.uuidString]) }
    }

    // MARK: - Segments

    public func insert(_ segs: [TranscriptSegment]) throws {
        guard !segs.isEmpty else { return }
        try queue.sync {
            try exec("BEGIN")
            do {
                for s in segs { try insertUnsafe(s) }
                try exec("COMMIT")
            } catch { try? exec("ROLLBACK"); throw error }
        }
    }

    private func insertUnsafe(_ s: TranscriptSegment) throws {
        try run("INSERT INTO segments (id,meeting_id,track,start,end,text,speaker_id,is_final) VALUES (?,?,?,?,?,?,?,?)",
                [s.id.uuidString, s.meetingID.uuidString, s.track.rawValue, s.start, s.end, s.text,
                 s.speakerID?.uuidString, s.isFinal ? 1 : 0])
        if s.isFinal {
            try run("INSERT INTO segments_fts (text, meeting_id, segment_id) VALUES (?,?,?)",
                    [s.text, s.meetingID.uuidString, s.id.uuidString])
        }
    }

    public func update(_ s: TranscriptSegment) throws {
        try queue.sync {
            try run("UPDATE segments SET track=?, start=?, end=?, text=?, speaker_id=?, is_final=? WHERE id=?",
                    [s.track.rawValue, s.start, s.end, s.text, s.speakerID?.uuidString, s.isFinal ? 1 : 0, s.id.uuidString])
            try run("DELETE FROM segments_fts WHERE segment_id=?", [s.id.uuidString])
            if s.isFinal {
                try run("INSERT INTO segments_fts (text, meeting_id, segment_id) VALUES (?,?,?)",
                        [s.text, s.meetingID.uuidString, s.id.uuidString])
            }
        }
    }

    public func delete(segmentID: UUID) throws {
        try queue.sync {
            try run("DELETE FROM segments_fts WHERE segment_id=?", [segmentID.uuidString])
            try run("DELETE FROM segments WHERE id=?", [segmentID.uuidString])
        }
    }

    /// Remplace TOUS les segments d'une réunion (passage final après le live).
    public func replaceSegments(meetingID: UUID, with segs: [TranscriptSegment]) throws {
        try queue.sync {
            try exec("BEGIN")
            do {
                try run("DELETE FROM segments_fts WHERE meeting_id=?", [meetingID.uuidString])
                try run("DELETE FROM segments WHERE meeting_id=?", [meetingID.uuidString])
                for s in segs { try insertUnsafe(s) }
                try exec("COMMIT")
            } catch { try? exec("ROLLBACK"); throw error }
        }
    }

    public func segments(meetingID: UUID, finalOnly: Bool = false) throws -> [TranscriptSegment] {
        try queue.sync {
            let sql = "SELECT * FROM segments WHERE meeting_id=? \(finalOnly ? "AND is_final=1" : "") ORDER BY start, track"
            return try query(sql, [meetingID.uuidString], Self.segment(from:))
        }
    }

    // MARK: - Recherche

    /// Recherche plein texte FTS5 (préfixes acceptés, accents ignorés).
    public func search(_ raw: String, limit: Int = 50) throws -> [SearchHit] {
        let terms = raw.split(whereSeparator: { !$0.isLetter && !$0.isNumber })
            .map { "\"\($0)\"*" }
        guard !terms.isEmpty else { return [] }
        let match = terms.joined(separator: " ")
        return try queue.sync {
            try query("""
            SELECT m.id, m.title, m.started_at, s.id, s.start, snippet(segments_fts, 0, '«', '»', '…', 14), sp.name, sp.label
            FROM segments_fts f
            JOIN segments s ON s.id = f.segment_id
            JOIN meetings m ON m.id = s.meeting_id
            LEFT JOIN speakers sp ON sp.id = s.speaker_id
            WHERE segments_fts MATCH ?
            ORDER BY bm25(segments_fts), m.started_at DESC
            LIMIT ?
            """, [match, limit]) { st in
                SearchHit(meetingID: UUID(uuidString: Self.text(st, 0))!, meetingTitle: Self.text(st, 1),
                          meetingDate: Date(timeIntervalSince1970: sqlite3_column_double(st, 2)),
                          segmentID: UUID(uuidString: Self.text(st, 3))!, start: sqlite3_column_double(st, 4),
                          snippet: Self.text(st, 5), speakerName: Self.optText(st, 6) ?? Self.optText(st, 7))
            }
        }
    }

    // MARK: - Chat

    public func insert(_ c: ChatMessage) throws {
        try queue.sync {
            try run("INSERT INTO chat (id,meeting_id,role,markdown,citations,created_at) VALUES (?,?,?,?,?,?)",
                    [c.id.uuidString, c.meetingID?.uuidString, c.role.rawValue, c.markdown,
                     Self.json(c.citations), c.createdAt.timeIntervalSince1970])
        }
    }

    /// Historique : `meetingID == nil` renvoie le fil transverse.
    public func chat(meetingID: UUID?) throws -> [ChatMessage] {
        try queue.sync {
            let sql = meetingID == nil
                ? "SELECT * FROM chat WHERE meeting_id IS NULL ORDER BY created_at"
                : "SELECT * FROM chat WHERE meeting_id=? ORDER BY created_at"
            return try query(sql, meetingID.map { [$0.uuidString] } ?? []) { st in
                ChatMessage(id: UUID(uuidString: Self.text(st, 0))!,
                            meetingID: Self.optText(st, 1).flatMap(UUID.init(uuidString:)),
                            role: ChatMessage.Role(rawValue: Self.text(st, 2)) ?? .assistant,
                            markdown: Self.text(st, 3),
                            citations: Self.decode([Citation].self, Self.text(st, 4)) ?? [],
                            createdAt: Date(timeIntervalSince1970: sqlite3_column_double(st, 5)))
            }
        }
    }

    public func clearChat(meetingID: UUID?) throws {
        try queue.sync {
            if let meetingID { try run("DELETE FROM chat WHERE meeting_id=?", [meetingID.uuidString]) }
            else { try run("DELETE FROM chat WHERE meeting_id IS NULL", []) }
        }
    }

    // MARK: - Dictionnaire personnel (noms propres, jargon, pour Whisper et le LLM)

    public func dictionary() throws -> [(term: String, note: String?)] {
        try queue.sync {
            try query("SELECT term, note FROM dictionary ORDER BY term COLLATE NOCASE", []) { st in
                (term: Self.text(st, 0), note: Self.optText(st, 1))
            }
        }
    }

    public func addDictionary(term: String, note: String? = nil) throws {
        try queue.sync {
            try run("INSERT INTO dictionary (term, note) VALUES (?,?) ON CONFLICT(term) DO UPDATE SET note=excluded.note",
                    [term, note])
        }
    }

    public func removeDictionary(term: String) throws {
        try queue.sync { try run("DELETE FROM dictionary WHERE term=?", [term]) }
    }

    // MARK: - Meta

    public func meta(_ key: String) throws -> String? {
        try queue.sync { try query("SELECT value FROM meta WHERE key=?", [key]) { Self.text($0, 0) }.first }
    }

    public func setMeta(_ key: String, _ value: String) throws {
        try queue.sync {
            try run("INSERT INTO meta (key,value) VALUES (?,?) ON CONFLICT(key) DO UPDATE SET value=excluded.value", [key, value])
        }
    }

    // MARK: - Plomberie SQLite

    private func exec(_ sql: String) throws {
        var err: UnsafeMutablePointer<CChar>?
        guard sqlite3_exec(db, sql, nil, nil, &err) == SQLITE_OK else {
            let msg = err.map { String(cString: $0) } ?? "?"
            sqlite3_free(err)
            throw StoreError.sql(msg)
        }
    }

    private func run(_ sql: String, _ params: [Any?]) throws {
        let st = try prepare(sql, params)
        defer { sqlite3_finalize(st) }
        guard sqlite3_step(st) == SQLITE_DONE else { throw StoreError.sql(String(cString: sqlite3_errmsg(db))) }
    }

    private func query<T>(_ sql: String, _ params: [Any?], _ map: (OpaquePointer) throws -> T) throws -> [T] {
        let st = try prepare(sql, params)
        defer { sqlite3_finalize(st) }
        var out: [T] = []
        while true {
            let rc = sqlite3_step(st)
            if rc == SQLITE_ROW { out.append(try map(st!)) }
            else if rc == SQLITE_DONE { break }
            else { throw StoreError.sql(String(cString: sqlite3_errmsg(db))) }
        }
        return out
    }

    private func prepare(_ sql: String, _ params: [Any?]) throws -> OpaquePointer? {
        var st: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &st, nil) == SQLITE_OK else {
            throw StoreError.sql(String(cString: sqlite3_errmsg(db)) + " dans : " + sql)
        }
        for (i, p) in params.enumerated() {
            let idx = Int32(i + 1)
            switch p {
            case nil: sqlite3_bind_null(st, idx)
            case let v as String: sqlite3_bind_text(st, idx, v, -1, SQLITE_TRANSIENT)
            case let v as Int: sqlite3_bind_int64(st, idx, Int64(v))
            case let v as Int64: sqlite3_bind_int64(st, idx, v)
            case let v as Double: sqlite3_bind_double(st, idx, v)
            case let v as Bool: sqlite3_bind_int(st, idx, v ? 1 : 0)
            default: sqlite3_bind_text(st, idx, String(describing: p!), -1, SQLITE_TRANSIENT)
            }
        }
        return st
    }

    private static func text(_ st: OpaquePointer, _ i: Int32) -> String {
        guard let c = sqlite3_column_text(st, i) else { return "" }
        return String(cString: c)
    }
    private static func optText(_ st: OpaquePointer, _ i: Int32) -> String? {
        guard sqlite3_column_type(st, i) != SQLITE_NULL, let c = sqlite3_column_text(st, i) else { return nil }
        return String(cString: c)
    }
    private static func optDouble(_ st: OpaquePointer, _ i: Int32) -> Double? {
        sqlite3_column_type(st, i) == SQLITE_NULL ? nil : sqlite3_column_double(st, i)
    }

    private static func meeting(from st: OpaquePointer) -> Meeting {
        Meeting(id: UUID(uuidString: text(st, 0))!, title: text(st, 1),
                startedAt: Date(timeIntervalSince1970: sqlite3_column_double(st, 2)),
                endedAt: optDouble(st, 3).map(Date.init(timeIntervalSince1970:)),
                source: text(st, 4), participants: decode([String].self, text(st, 5)) ?? [],
                calendarEventID: optText(st, 6), status: MeetingStatus(rawValue: text(st, 7)) ?? .ready,
                language: text(st, 8), summaryMarkdown: optText(st, 9), notes: text(st, 10),
                micAudioPath: optText(st, 11), systemAudioPath: optText(st, 12),
                createdAt: Date(timeIntervalSince1970: sqlite3_column_double(st, 13)),
                updatedAt: Date(timeIntervalSince1970: sqlite3_column_double(st, 14)))
    }

    private static func segment(from st: OpaquePointer) -> TranscriptSegment {
        TranscriptSegment(id: UUID(uuidString: text(st, 0))!, meetingID: UUID(uuidString: text(st, 1))!,
                          track: Track(rawValue: text(st, 2)) ?? .mic, start: sqlite3_column_double(st, 3),
                          end: sqlite3_column_double(st, 4), text: text(st, 5),
                          speakerID: optText(st, 6).flatMap(UUID.init(uuidString:)),
                          isFinal: sqlite3_column_int(st, 7) == 1)
    }

    static func json<T: Encodable>(_ v: T) -> String {
        (try? String(data: JSONEncoder().encode(v), encoding: .utf8)) ?? "[]"
    }
    static func decode<T: Decodable>(_ t: T.Type, _ s: String) -> T? {
        try? JSONDecoder().decode(t, from: Data(s.utf8))
    }
}
