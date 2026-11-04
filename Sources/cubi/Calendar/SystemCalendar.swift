import EventKit
import Observation
import CubiKit

/// The macOS calendar (synced on by the system to Google etc.), written on plugins' behalf.
/// Needs full access: write-only access cannot list calendars nor find what was already written.
@MainActor
@Observable
final class SystemCalendar {
    static let calendarKey = "calendarID"

    struct Entry: Identifiable, Hashable {
        var id: String
        var name: String
    }

    struct Outcome: Equatable {
        var created = 0
        var extended = 0
        var skipped = 0
    }

    enum CalendarError: LocalizedError {
        case notAuthorized, notConfigured, missing(String)

        var errorDescription: String? {
            switch self {
            case .notAuthorized: return "沒有行事曆存取權限（設定 → 行事曆）"
            case .notConfigured: return "還沒選要寫入的行事曆，或那個行事曆已不存在（設定 → 行事曆）"
            case .missing(let id): return "要延長的事件不見了：\(id)"
            }
        }
    }

    private let store = EKEventStore()
    private(set) var status = EKEventStore.authorizationStatus(for: .event)
    private(set) var calendars: [Entry] = []
    var calendarID: String? {
        didSet { UserDefaults.standard.set(calendarID, forKey: Self.calendarKey) }
    }

    init() {
        calendarID = UserDefaults.standard.string(forKey: Self.calendarKey)
    }

    var authorized: Bool { status == .fullAccess }
    var isReady: Bool { authorized && calendarID.flatMap { store.calendar(withIdentifier: $0) } != nil }

    func refresh() {
        status = EKEventStore.authorizationStatus(for: .event)
        calendars = authorized
            ? store.calendars(for: .event).filter(\.allowsContentModifications)
                .map { Entry(id: $0.calendarIdentifier, name: "\($0.title)（\($0.source.title)）") }
                .sorted { $0.name < $1.name }
            : []
    }

    func requestAccess() async {
        let granted = (try? await store.requestFullAccessToEvents()) ?? false
        CubiLog.write("calendar access \(granted ? "granted" : "denied")")
        refresh()
    }

    /// Carries out `CalendarMerge.plan` for each entry against the events around it.
    func write(_ entries: [PluginIO.CalendarEntry]) throws -> Outcome {
        guard authorized else { throw CalendarError.notAuthorized }
        guard let id = calendarID, let calendar = store.calendar(withIdentifier: id) else { throw CalendarError.notConfigured }
        var outcome = Outcome()
        for e in entries {
            let events = store.events(matching: store.predicateForEvents(
                withStart: Date(timeIntervalSince1970: e.start - CalendarMerge.gap),
                end: Date(timeIntervalSince1970: e.end + CalendarMerge.gap), calendars: [calendar]))
            let nearby = events.map {
                CalendarMerge.Existing(id: $0.eventIdentifier, title: $0.title ?? "", start: $0.startDate.timeIntervalSince1970,
                                       end: $0.endDate.timeIntervalSince1970, notes: $0.notes)
            }
            switch CalendarMerge.plan(e, nearby: nearby) {
            case .skip:
                outcome.skipped += 1
            case .create(let title, let start, let end, let notes):
                let event = EKEvent(eventStore: store)
                event.calendar = calendar
                fill(event, title: title, start: start, end: end, notes: notes)
                try store.save(event, span: .thisEvent, commit: false)
                outcome.created += 1
            case .extend(let eventID, let start, let end, let notes, let remove):
                guard let event = events.first(where: { $0.eventIdentifier == eventID }) else { throw CalendarError.missing(eventID) }
                fill(event, title: event.title, start: start, end: end, notes: notes)
                try store.save(event, span: .thisEvent, commit: false)
                for extra in events where remove.contains(extra.eventIdentifier) { try store.remove(extra, span: .thisEvent, commit: false) }
                outcome.extended += 1
            }
        }
        try store.commit()
        return outcome
    }

    private func fill(_ event: EKEvent, title: String, start: Double, end: Double, notes: String) {
        event.title = title
        event.startDate = Date(timeIntervalSince1970: start)
        event.endDate = Date(timeIntervalSince1970: end)
        event.notes = notes
        // Marked free so it never blocks a meeting invite; EventKit has no "private" to set.
        event.availability = .free
    }
}
