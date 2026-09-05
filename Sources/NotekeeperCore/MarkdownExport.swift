import Foundation

/// Export d'une réunion en markdown (lisible dans Obsidian, un fichier par réunion).
public enum MarkdownExport {

    public static func fileName(for m: Meeting) -> String {
        let df = DateFormatter(); df.dateFormat = "yyyy-MM-dd HH'h'mm"
        let safe = m.title.replacingOccurrences(of: "[/:\\\\]", with: "-", options: .regularExpression)
            .trimmingCharacters(in: .whitespaces)
        return "\(df.string(from: m.startedAt)) \(safe.isEmpty ? "Réunion" : safe).md"
    }

    public static func render(meeting m: Meeting, segments: [TranscriptSegment], speakers: [Speaker]) -> String {
        let df = DateFormatter(); df.locale = Locale(identifier: "fr_FR"); df.dateStyle = .full; df.timeStyle = .short
        var out = "# \(m.title)\n\n"
        out += "- Date : \(df.string(from: m.startedAt))\n"
        out += "- Durée : \(TimeFormat.clock(m.duration))\n"
        out += "- Source : \(m.source)\n"
        let names = speakers.map(\.displayName)
        if !names.isEmpty { out += "- Participants : \(names.joined(separator: ", "))\n" }
        if !m.participants.isEmpty { out += "- Invités (calendrier) : \(m.participants.joined(separator: ", "))\n" }
        out += "\n"
        if let s = m.summaryMarkdown, !s.isEmpty { out += "## Résumé\n\n\(s)\n\n" }
        if !m.notes.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { out += "## Mes notes\n\n\(m.notes)\n\n" }
        out += "## Transcript\n\n"
        let coalesced = TranscriptMerge.coalesce(segments.filter(\.isFinal))
        let nameOf = Dictionary(uniqueKeysWithValues: speakers.map { ($0.id, $0.displayName) })
        for s in coalesced where !s.text.isEmpty {
            let who = s.speakerID.flatMap { nameOf[$0] } ?? (s.track == .mic ? "Moi" : "?")
            out += "**\(who)** `\(TimeFormat.clock(s.start))`  \n\(s.text)\n\n"
        }
        return out
    }
}
