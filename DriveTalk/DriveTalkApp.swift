import SwiftUI

@main
struct DriveTalkApp: App {
    @StateObject private var settings = SettingsStore()
    @StateObject private var engine = ConversationEngine()
    @StateObject private var router = AppRouter()

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(settings)
                .environmentObject(engine)
                .environmentObject(router)
                .tint(Theme.accent)   // follows the iPhone light / dark setting
        }
    }
}

@MainActor
final class AppRouter: ObservableObject {
    enum Tab: Hashable { case practice, lookup, news, vocab, stats }
    @Published var tab: Tab = .practice
}

struct RootView: View {
    @EnvironmentObject var router: AppRouter
    @Environment(\.scenePhase) private var scenePhase
    /// When the user started looking at a study tab (查詢／新聞／生字本) — counted as study time.
    @State private var studyStart: Date?

    var body: some View {
        TabView(selection: $router.tab) {
            DriveView()
                .tabItem { Label("練習", systemImage: "car.fill") }
                .tag(AppRouter.Tab.practice)
            LookupView()
                .tabItem { Label("查詢", systemImage: "character.book.closed") }
                .tag(AppRouter.Tab.lookup)
            NewsView()
                .tabItem { Label("新聞", systemImage: "newspaper") }
                .tag(AppRouter.Tab.news)
            VocabView()
                .tabItem { Label("生字本", systemImage: "bookmark") }
                .tag(AppRouter.Tab.vocab)
            StatsView()
                .tabItem { Label("統計", systemImage: "chart.bar.fill") }
                .tag(AppRouter.Tab.stats)
        }
        .onChange(of: router.tab) { _, _ in updateStudyClock() }
        .onChange(of: scenePhase) { _, _ in updateStudyClock() }
        .onAppear { updateStudyClock() }
    }

    private var isStudying: Bool {
        scenePhase == .active && [.lookup, .news, .vocab].contains(router.tab)
    }

    private func updateStudyClock() {
        if let start = studyStart {
            // Cap one stretch at 30 minutes in case the phone was left on a study screen.
            ProgressStore.shared.addStudy(seconds: min(Date().timeIntervalSince(start), 1800))
            studyStart = nil
        }
        if isStudying { studyStart = Date() }
    }
}
