import SwiftUI
import NotekeeperCore

struct SidebarView: View {
    @EnvironmentObject var model: AppModel

    private var grouped: [(day: String, items: [Meeting])] {
        let df = DateFormatter(); df.locale = Locale(identifier: "fr_FR"); df.dateFormat = "EEEE d MMMM yyyy"
        var out: [(String, [Meeting])] = []
        for m in model.meetings {
            let key = df.string(from: m.startedAt).capitalized
            if let i = out.firstIndex(where: { $0.0 == key }) { out[i].1.append(m) } else { out.append((key, [m])) }
        }
        return out.map { (day: $0.0, items: $0.1) }
    }

    var body: some View {
        VStack(spacing: 0) {
            if model.searchText.trimmingCharacters(in: .whitespaces).count >= 2 {
                SearchResults()
            } else {
                List(selection: $model.selectedMeetingID) {
                    ForEach(grouped, id: \.day) { g in
                        Section(g.day) {
                            ForEach(g.items) { m in
                                MeetingRow(meeting: m).tag(m.id)
                                    .contextMenu {
                                        Button("Exporter en markdown") { model.export(m) }
                                        Button("Régénérer le résumé") { model.regenerate(meeting: m) }
                                        Divider()
                                        Button("Supprimer", role: .destructive) { model.delete(meeting: m) }
                                    }
                            }
                        }
                    }
                }
                .listStyle(.sidebar)
            }
        }
        .searchable(text: $model.searchText, placement: .sidebar, prompt: "Rechercher dans les réunions")
        .safeAreaInset(edge: .bottom) {
            HStack(spacing: 6) {
                Circle().fill(model.engineReady ? NK.ok : NK.warn).frame(width: 6, height: 6)
                Text(model.engineStatus).font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1)
                Spacer()
            }
            .padding(.horizontal, 12).padding(.vertical, 8)
            .background(.bar)
        }
    }
}

struct MeetingRow: View {
    @EnvironmentObject var model: AppModel
    let meeting: Meeting
    var body: some View {
        HStack(spacing: 8) {
            VStack(alignment: .leading, spacing: 2) {
                Text(meeting.title).font(.system(size: 13, weight: .medium)).lineLimit(1)
                HStack(spacing: 6) {
                    Text(meeting.startedAt, style: .time)
                    Text("·")
                    Text(meeting.status == .recording ? "en cours" : TimeFormat.clock(meeting.duration))
                    if meeting.source != "Micro" { Text("·"); Text(meeting.source).lineLimit(1) }
                }
                .font(.system(size: 11)).foregroundStyle(.secondary)
            }
            Spacer()
            if meeting.status == .recording { Circle().fill(NK.live).frame(width: 8, height: 8) }
            else if model.processing[meeting.id] != nil || meeting.status == .processing { ProgressView().controlSize(.mini) }
            else if meeting.status == .failed { Image(systemName: "exclamationmark.circle").foregroundStyle(NK.warn) }
        }
        .padding(.vertical, 2)
    }
}

struct SearchResults: View {
    @EnvironmentObject var model: AppModel
    var body: some View {
        List {
            if model.searchHits.isEmpty {
                Text("Aucun résultat").foregroundStyle(.secondary)
            }
            ForEach(model.searchHits) { hit in
                Button {
                    model.selectedMeetingID = hit.meetingID
                    NotificationCenter.default.post(name: .scrollToSegment, object: hit.segmentID)
                } label: {
                    VStack(alignment: .leading, spacing: 3) {
                        HStack {
                            Text(hit.meetingTitle).font(.system(size: 12, weight: .medium)).lineLimit(1)
                            Spacer()
                            Text(hit.meetingDate, style: .date).font(.system(size: 10)).foregroundStyle(.secondary)
                        }
                        HStack(alignment: .firstTextBaseline, spacing: 4) {
                            Text(TimeFormat.clock(hit.start)).font(NK.mono(10)).foregroundStyle(.secondary)
                            if let s = hit.speakerName { Text(s).font(.system(size: 11, weight: .medium)) }
                        }
                        Text(hit.snippet).font(.system(size: 12)).foregroundStyle(.primary).lineLimit(3)
                    }
                }
                .buttonStyle(.plain)
            }
        }
        .listStyle(.sidebar)
    }
}

extension Notification.Name {
    static let scrollToSegment = Notification.Name("nk.scrollToSegment")
}
