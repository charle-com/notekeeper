import Foundation
import EventKit

/// Lecture du calendrier pour titrer une réunion et lister les invités (indices pour les noms).
final class CalendarService: @unchecked Sendable {
    struct CurrentEvent { let id: String; let title: String; let attendees: [String] }

    private let store = EKEventStore()

    var authorized: Bool {
        if #available(macOS 14, *) { return EKEventStore.authorizationStatus(for: .event) == .fullAccess }
        return EKEventStore.authorizationStatus(for: .event) == .authorized
    }

    func requestAccess() async -> Bool {
        if #available(macOS 14, *) { return (try? await store.requestFullAccessToEvents()) ?? false }
        return (try? await store.requestAccess(to: .event)) ?? false
    }

    /// L'événement en cours (ou qui commence dans les 10 min, ou fini depuis moins de 10 min).
    func currentEvent(at date: Date = Date()) -> CurrentEvent? {
        guard authorized else { return nil }
        let pred = store.predicateForEvents(withStart: date.addingTimeInterval(-10 * 60),
                                            end: date.addingTimeInterval(10 * 60), calendars: nil)
        let events = store.events(matching: pred).filter { !$0.isAllDay }
            .sorted { abs($0.startDate.timeIntervalSince(date)) < abs($1.startDate.timeIntervalSince(date)) }
        guard let e = events.first else { return nil }
        let names = (e.attendees ?? []).compactMap { $0.name }.filter { !$0.contains("@") }
        return CurrentEvent(id: e.eventIdentifier, title: e.title ?? "Réunion", attendees: names)
    }
}
