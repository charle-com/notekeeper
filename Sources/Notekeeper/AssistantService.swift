import Foundation
import NotekeeperCore

/// Ce que l'UI attend de l'assistant IA. `Assistant` (NotekeeperCore/LLM) s'y conforme ; les mocks aussi.
protocol AssistantService: AnyObject {
    func nameSpeakers(meeting: Meeting) async throws -> [Speaker]
    func summarize(meeting: Meeting) async throws -> String
    func catchUp(segments: [TranscriptSegment], speakers: [Speaker]) async throws -> String
    func ask(question: String, meetingID: UUID?) async throws -> AskAnswer
    func suggestTitle(meeting: Meeting) async throws -> String
}
