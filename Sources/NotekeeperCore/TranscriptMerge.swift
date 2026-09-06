import Foundation

/// Fusion des pistes et attribution des locuteurs. Logique pure, testée.
public enum TranscriptMerge {

    /// Attribue à chaque segment de la piste système le cluster de diarisation qui le recouvre le plus.
    /// Les segments micro reçoivent `meSpeakerID`. Renvoie les segments mis à jour et la table
    /// cluster -> Speaker (créée à la volée, étiquettes « Locuteur 2 », « Locuteur 3 »… dans l'ordre
    /// d'apparition, « Moi » étant le locuteur 1).
    public static func assignSpeakers(segments: [TranscriptSegment], spans: [DiarizedSpan],
                                      meetingID: UUID, meSpeakerID: UUID,
                                      existing: [Speaker] = []) -> (segments: [TranscriptSegment], speakers: [Speaker]) {
        var byCluster: [String: Speaker] = [:]
        for s in existing { if let k = s.clusterKey { byCluster[k] = s } }
        var out: [TranscriptSegment] = []
        var order = existing.filter { !$0.isMe }.count
        let sorted = spans.sorted { $0.start < $1.start }
        for var seg in segments.sorted(by: { $0.start < $1.start }) {
            if seg.track == .mic {
                seg.speakerID = meSpeakerID
            } else {
                var overlap: [String: TimeInterval] = [:]
                for sp in sorted {
                    if sp.end <= seg.start { continue }
                    if sp.start >= seg.end { break }
                    let o = min(sp.end, seg.end) - max(sp.start, seg.start)
                    if o > 0 { overlap[sp.clusterKey, default: 0] += o }
                }
                if let best = overlap.max(by: { $0.value < $1.value })?.key {
                    if byCluster[best] == nil {
                        order += 1
                        byCluster[best] = Speaker(meetingID: meetingID, label: "Locuteur \(order + 1)", clusterKey: best)
                    }
                    seg.speakerID = byCluster[best]!.id
                } else if seg.speakerID == nil {
                    // Aucun cluster : on garde le dernier locuteur système connu, sinon nil.
                    seg.speakerID = out.last(where: { $0.track == .system })?.speakerID
                }
            }
            out.append(seg)
        }
        let speakers = Array(byCluster.values).sorted { $0.label < $1.label }
        return (out, speakers)
    }

    /// Regroupe les segments consécutifs du même locuteur séparés de moins de `gap` secondes,
    /// pour un transcript lisible (un paragraphe par tour de parole).
    public static func coalesce(_ segments: [TranscriptSegment], gap: TimeInterval = 1.5, maxLength: Int = 700) -> [TranscriptSegment] {
        var out: [TranscriptSegment] = []
        for seg in segments.sorted(by: { $0.start < $1.start }) {
            if var last = out.last, last.speakerID == seg.speakerID, last.track == seg.track,
               seg.start - last.end <= gap, last.text.count + seg.text.count < maxLength {
                last.end = max(last.end, seg.end)
                last.text = joinText(last.text, seg.text)
                out[out.count - 1] = last
            } else {
                out.append(seg)
            }
        }
        return out
    }

    static func joinText(_ a: String, _ b: String) -> String {
        let a = a.trimmingCharacters(in: .whitespaces), b = b.trimmingCharacters(in: .whitespaces)
        if a.isEmpty { return b }
        if b.isEmpty { return a }
        return a + " " + b
    }

    /// Transcript en texte brut horodaté, tel qu'on l'envoie au LLM et qu'on l'exporte.
    public static func render(_ segments: [TranscriptSegment], speakers: [Speaker], withTimes: Bool = true) -> String {
        let names = Dictionary(uniqueKeysWithValues: speakers.map { ($0.id, $0.displayName) })
        var lines: [String] = []
        for s in segments where !s.text.trimmingCharacters(in: .whitespaces).isEmpty {
            let who = s.speakerID.flatMap { names[$0] } ?? (s.track == .mic ? "Moi" : "?")
            let t = withTimes ? "[\(TimeFormat.clock(s.start))] " : ""
            lines.append("\(t)\(who) : \(s.text.trimmingCharacters(in: .whitespacesAndNewlines))")
        }
        return lines.joined(separator: "\n")
    }

    /// Les segments des `seconds` dernières secondes avant `now` (pour « Qu'est-ce que j'ai raté ? »).
    public static func recent(_ segments: [TranscriptSegment], now: TimeInterval, seconds: TimeInterval) -> [TranscriptSegment] {
        segments.filter { $0.end >= now - seconds }.sorted { $0.start < $1.start }
    }
}

// MARK: - Écho acoustique

extension TranscriptMerge {

    /// Mots normalisés (minuscules, sans accents ni ponctuation) pour comparer deux textes.
    static func words(_ s: String) -> [String] {
        s.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: Locale(identifier: "fr"))
            .lowercased()
            .split(whereSeparator: { !$0.isLetter && !$0.isNumber })
            .map(String.init)
            .filter { $0.count > 1 }
    }

    /// Part des mots de `mic` que l'on retrouve dans `others` (0…1).
    static func overlapRatio(mic: String, others: String) -> Double {
        let m = words(mic)
        guard m.count >= 3 else { return 0 }
        let o = Set(words(others))
        let shared = m.filter { o.contains($0) }.count
        return Double(shared) / Double(m.count)
    }

    /// Vrai si le segment micro est l'écho acoustique de la piste système (le micro a entendu les
    /// haut-parleurs) : même fenêtre de temps et texte quasi identique.
    public static func isEcho(_ mic: TranscriptSegment, against system: [TranscriptSegment],
                              tolerance: TimeInterval = 2.0, threshold: Double = 0.6) -> Bool {
        guard mic.track == .mic else { return false }
        let near = system.filter { $0.track == .system && $0.end >= mic.start - tolerance && $0.start <= mic.end + tolerance }
        guard !near.isEmpty else { return false }
        let others = near.map(\.text).joined(separator: " ")
        return overlapRatio(mic: mic.text, others: others) >= threshold
    }

    /// Retire les segments micro qui ne sont que l'écho de la piste système.
    public static func removeEcho(_ segments: [TranscriptSegment], tolerance: TimeInterval = 2.0,
                                  threshold: Double = 0.6) -> [TranscriptSegment] {
        let system = segments.filter { $0.track == .system }
        return segments.filter { !isEcho($0, against: system, tolerance: tolerance, threshold: threshold) }
    }

    /// Nettoyage d'un texte de segment : espaces, tirets de dialogue en tête laissés par Whisper.
    public static func cleanText(_ s: String) -> String {
        var t = s.trimmingCharacters(in: .whitespacesAndNewlines)
        while t.hasPrefix("- ") || t.hasPrefix("– ") { t = String(t.dropFirst(2)).trimmingCharacters(in: .whitespaces) }
        return t
    }
}
