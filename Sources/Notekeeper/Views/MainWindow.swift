import SwiftUI
import NotekeeperCore

struct MainWindow: View {
    @EnvironmentObject var model: AppModel
    @State private var showGlobalAsk = false

    var body: some View {
        NavigationSplitView {
            SidebarView()
                .navigationSplitViewColumnWidth(min: 240, ideal: 280, max: 360)
        } detail: {
            ZStack(alignment: .top) {
                if model.isRecording, model.selectedMeetingID == model.recording?.meetingID {
                    MeetingView()
                } else if model.selectedMeeting != nil {
                    MeetingView()
                } else {
                    EmptyState()
                }
                if let b = model.banner { BannerView(banner: b) }
            }
        }
        .toolbar { toolbar }
        .sheet(isPresented: $model.showWelcome) { WelcomeView().environmentObject(model) }
        .sheet(isPresented: $showGlobalAsk) { AskSheet(allMeetings: true).environmentObject(model) }
    }

    @ToolbarContentBuilder
    private var toolbar: some ToolbarContent {
        ToolbarItemGroup(placement: .primaryAction) {
            if model.isRecording {
                Button { model.catchUp() } label: { Label("Qu'est-ce que j'ai raté ?", systemImage: "clock.arrow.circlepath") }
                    .help("Résumé des dernières minutes")
                Button { Task { await model.stopMeeting() } } label: { Label("Terminer", systemImage: "stop.circle.fill") }
                    .tint(NK.live)
            } else {
                Button { model.startMeeting() } label: { Label("Enregistrer", systemImage: "record.circle") }
                    .help("Démarrer une réunion (⇧⌘R)")
                    .disabled(!model.engineReady)
            }
            Button { model.loadGlobalChat(); showGlobalAsk = true } label: { Label("Demander", systemImage: "sparkles") }
                .help("Poser une question sur toutes les réunions")
        }
    }
}

struct EmptyState: View {
    @EnvironmentObject var model: AppModel
    var body: some View {
        VStack(spacing: 14) {
            Image(systemName: "text.bubble").font(.system(size: 42, weight: .light)).foregroundStyle(.secondary)
            Text("Aucune réunion sélectionnée").font(NK.title(18))
            Text(model.engineReady ? "Lance un enregistrement, ou attends qu'un appel soit détecté." : model.engineStatus)
                .foregroundStyle(.secondary)
            if model.engineReady {
                Button { model.startMeeting() } label: { Label("Enregistrer une réunion", systemImage: "record.circle") }
                    .keyboardShortcut("r", modifiers: [.command, .shift])
                    .controlSize(.large)
            } else {
                ProgressView().controlSize(.small)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

struct BannerView: View {
    @EnvironmentObject var model: AppModel
    let banner: AppModel.Banner

    var color: Color {
        switch banner.kind { case .info: return NK.accent; case .warning: return NK.warn; case .error: return NK.live }
    }

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: banner.kind == .info ? "phone.fill" : "exclamationmark.triangle.fill").foregroundStyle(color)
            Text(banner.text).font(NK.body()).lineLimit(3)
            Spacer()
            if let a = banner.action {
                Button(a) { banner.onAction?(); model.banner = nil }.buttonStyle(.borderedProminent).controlSize(.small)
            }
            Button { model.banner = nil } label: { Image(systemName: "xmark") }.buttonStyle(.plain).foregroundStyle(.secondary)
        }
        .padding(.horizontal, 14).padding(.vertical, 10)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(color.opacity(0.35)))
        .padding(12)
        .transition(.move(edge: .top).combined(with: .opacity))
        .onAppear {
            if banner.kind == .info {
                DispatchQueue.main.asyncAfter(deadline: .now() + 20) { if model.banner == banner { model.banner = nil } }
            }
        }
    }
}
