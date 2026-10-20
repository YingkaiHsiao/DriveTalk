import SwiftUI

@main
struct DriveTalkApp: App {
    @StateObject private var settings = SettingsStore()
    @StateObject private var engine = ConversationEngine()

    var body: some Scene {
        WindowGroup {
            DriveView()
                .environmentObject(settings)
                .environmentObject(engine)
                .preferredColorScheme(.dark)   // easier on the eyes in the car
        }
    }
}
