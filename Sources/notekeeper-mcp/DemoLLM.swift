import Foundation
import NotekeeperCore

/// `notekeeper-mcp --demo-llm <db> [question]` : enchaîne les cinq fonctions de l'assistant sur la
/// première réunion seedée, avec le vrai fournisseur configuré (Gemini par défaut, clé via trousseau
/// ou `GEMINI_API_KEY`). Affiche les résultats sur stdout, pour juger la qualité des prompts.
enum DemoLLM {

    static func run(store: Store, question: String?) async -> Int32 {
        let config = LLMConfig.load()
        let llm = config.makeClient()
        let userName = config.userName == LLMConfig.defaultUserName ? "Charles" : config.userName
        let assistant = Assistant(llm: llm, store: store, userName: userName)
        print("Fournisseur : \(llm.name), utilisateur : \(userName)")

        guard let meeting = (try? store.meetings())?.min(by: { $0.startedAt < $1.startedAt }) else {
            print("Aucune réunion dans la base : lance d'abord --seed-demo.")
            return 1
        }
        print("Réunion : « \(meeting.title) » (\(meeting.id.uuidString))\n")

        func step(_ name: String, _ body: () async throws -> String) async -> Bool {
            let t0 = Date()
            do {
                let out = try await body()
                print("=== \(name) (\(String(format: "%.1f", Date().timeIntervalSince(t0))) s) ===\n\(out)\n")
                return true
            } catch {
                print("=== \(name) : ÉCHEC ===\n\(error.localizedDescription)\n")
                return false
            }
        }

        var ok = true
        ok = await step("nameSpeakers") {
            let speakers = try await assistant.nameSpeakers(meeting: meeting)
            return speakers.map { "\($0.label) -> \($0.name ?? "(sans nom)")\($0.isMe ? " [moi]" : "")" }.joined(separator: "\n")
        } && ok
        ok = await step("summarize") { try await assistant.summarize(meeting: meeting) } && ok
        ok = await step("suggestTitle") { try await assistant.suggestTitle(meeting: meeting) } && ok
        ok = await step("catchUp (2 dernières minutes)") {
            let segments = try store.segments(meetingID: meeting.id, finalOnly: true)
            let speakers = try store.speakers(meetingID: meeting.id)
            let now = segments.map(\.end).max() ?? 0
            return try await assistant.catchUp(segments: TranscriptMerge.recent(segments, now: now, seconds: 120), speakers: speakers)
        } && ok

        let q1 = question ?? "Quelle est la date de mise en ligne prévue pour le site et quel budget a été validé ?"
        ok = await step("ask (réunion) : \(q1)") {
            let a = try await assistant.ask(question: q1, meetingID: meeting.id)
            return a.markdown + "\n" + render(a.citations)
        } && ok

        let q2 = "Combien coûte le petit porteur pour les palettes tampon ?"
        ok = await step("ask (toutes réunions) : \(q2)") {
            let a = try await assistant.ask(question: q2, meetingID: nil)
            return a.markdown + "\n" + render(a.citations)
        } && ok

        return ok ? 0 : 1
    }

    private static func render(_ citations: [Citation]) -> String {
        guard !citations.isEmpty else { return "(aucune citation)" }
        return "Citations :\n" + citations.map {
            "- [\($0.meetingTitle)] [\(TimeFormat.clock($0.start))] « \($0.quote) »"
        }.joined(separator: "\n")
    }
}
