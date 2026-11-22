import SwiftUI

@main
struct TiCiApp: App {
    var body: some Scene {
        WindowGroup {
            MiniPrompterView()
                .preferredColorScheme(.dark)
        }
    }
}
