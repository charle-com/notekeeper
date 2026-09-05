import Foundation

/// Piste audio d'origine d'un segment : le micro (moi) ou l'audio système (les autres).
public enum Track: String, Codable, Hashable, Sendable {
    case mic
    case system
}

public enum MeetingStatus: String, Codable, Hashable, Sendable {
    case recording      // capture en cours
    case processing     // capture terminée, post-traitement (diarisation, noms, résumé) en cours
    case ready          // tout est là
    case failed         // post-traitement en échec, transcript brut disponible
}

/// Une réunion. `summaryMarkdown` et `notes` sont du markdown ; `participants` vient du calendrier
/// ou de l'utilisateur et sert d'indice au nommage des locuteurs.
public struct Meeting: Identifiable, Codable, Hashable, Sendable {
    public var id: UUID
    public var title: String
    public var startedAt: Date
    public var endedAt: Date?
    /// Application détectée pendant la capture ("Zoom", "Google Meet", "FaceTime", "Micro seul"…).
    public var source: String
    public var participants: [String]
    public var calendarEventID: String?
    public var status: MeetingStatus
    public var language: String
    public var summaryMarkdown: String?
    public var notes: String
    /// Chemins des WAV par piste, nil une fois l'audio purgé.
    public var micAudioPath: String?
    public var systemAudioPath: String?
    public var createdAt: Date
    public var updatedAt: Date

    public init(id: UUID = UUID(), title: String, startedAt: Date = Date(), endedAt: Date? = nil,
                source: String = "Micro", participants: [String] = [], calendarEventID: String? = nil,
                status: MeetingStatus = .recording, language: String = "fr", summaryMarkdown: String? = nil,
                notes: String = "", micAudioPath: String? = nil, systemAudioPath: String? = nil,
                createdAt: Date = Date(), updatedAt: Date = Date()) {
        self.id = id; self.title = title; self.startedAt = startedAt; self.endedAt = endedAt
        self.source = source; self.participants = participants; self.calendarEventID = calendarEventID
        self.status = status; self.language = language; self.summaryMarkdown = summaryMarkdown
        self.notes = notes; self.micAudioPath = micAudioPath; self.systemAudioPath = systemAudioPath
        self.createdAt = createdAt; self.updatedAt = updatedAt
    }

    public var duration: TimeInterval { (endedAt ?? Date()).timeIntervalSince(startedAt) }
}

/// Un locuteur d'une réunion. `label` est l'étiquette technique stable ("Moi", "Locuteur 2"),
/// `name` le nom affiché une fois identifié. Renommer un locuteur renomme tous ses segments,
/// puisque les segments pointent sur son id.
public struct Speaker: Identifiable, Codable, Hashable, Sendable {
    public var id: UUID
    public var meetingID: UUID
    public var label: String
    public var name: String?
    public var isMe: Bool
    /// Identifiant de cluster rendu par le diarizer (pour recoller un second passage).
    public var clusterKey: String?

    public init(id: UUID = UUID(), meetingID: UUID, label: String, name: String? = nil,
                isMe: Bool = false, clusterKey: String? = nil) {
        self.id = id; self.meetingID = meetingID; self.label = label; self.name = name
        self.isMe = isMe; self.clusterKey = clusterKey
    }

    public var displayName: String { name ?? label }
}

/// Un tour de parole. `start`/`end` en secondes depuis le début de la réunion.
/// `isFinal == false` : hypothèse live, remplacée par le passage final.
public struct TranscriptSegment: Identifiable, Codable, Hashable, Sendable {
    public var id: UUID
    public var meetingID: UUID
    public var track: Track
    public var start: TimeInterval
    public var end: TimeInterval
    public var text: String
    public var speakerID: UUID?
    public var isFinal: Bool

    public init(id: UUID = UUID(), meetingID: UUID, track: Track, start: TimeInterval, end: TimeInterval,
                text: String, speakerID: UUID? = nil, isFinal: Bool = true) {
        self.id = id; self.meetingID = meetingID; self.track = track; self.start = start; self.end = end
        self.text = text; self.speakerID = speakerID; self.isFinal = isFinal
    }
}

/// Résultat d'une recherche plein texte.
public struct SearchHit: Identifiable, Hashable, Sendable {
    public var id: UUID { segmentID }
    public var meetingID: UUID
    public var meetingTitle: String
    public var meetingDate: Date
    public var segmentID: UUID
    public var start: TimeInterval
    public var snippet: String
    public var speakerName: String?

    public init(meetingID: UUID, meetingTitle: String, meetingDate: Date, segmentID: UUID,
                start: TimeInterval, snippet: String, speakerName: String?) {
        self.meetingID = meetingID; self.meetingTitle = meetingTitle; self.meetingDate = meetingDate
        self.segmentID = segmentID; self.start = start; self.snippet = snippet; self.speakerName = speakerName
    }
}

/// Réponse du « Ask anything » : texte markdown + sources cliquables.
public struct Citation: Hashable, Codable, Sendable {
    public var meetingID: UUID
    public var meetingTitle: String
    public var start: TimeInterval
    public var quote: String
    public init(meetingID: UUID, meetingTitle: String, start: TimeInterval, quote: String) {
        self.meetingID = meetingID; self.meetingTitle = meetingTitle; self.start = start; self.quote = quote
    }
}

public struct AskAnswer: Hashable, Codable, Sendable {
    public var markdown: String
    public var citations: [Citation]
    public init(markdown: String, citations: [Citation]) { self.markdown = markdown; self.citations = citations }
}

/// Une question/réponse conservée dans une réunion (historique du chat).
public struct ChatMessage: Identifiable, Codable, Hashable, Sendable {
    public enum Role: String, Codable, Sendable { case user, assistant }
    public var id: UUID
    public var meetingID: UUID?   // nil = question transverse (toutes les réunions)
    public var role: Role
    public var markdown: String
    public var citations: [Citation]
    public var createdAt: Date
    public init(id: UUID = UUID(), meetingID: UUID?, role: Role, markdown: String,
                citations: [Citation] = [], createdAt: Date = Date()) {
        self.id = id; self.meetingID = meetingID; self.role = role; self.markdown = markdown
        self.citations = citations; self.createdAt = createdAt
    }
}

public enum TimeFormat {
    /// "1:02:07" ou "12:07".
    public static func clock(_ t: TimeInterval) -> String {
        let s = max(0, Int(t.rounded()))
        let h = s / 3600, m = (s % 3600) / 60, sec = s % 60
        return h > 0 ? String(format: "%d:%02d:%02d", h, m, sec) : String(format: "%d:%02d", m, sec)
    }
}
