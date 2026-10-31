import SwiftUI

@main
struct InCamApp: App {
    @UIApplicationDelegateAdaptor(InCamAppDelegate.self) private var appDelegate
    @StateObject private var camera = CameraController()
    @StateObject private var recipes = CameraColorStore()
    @StateObject private var shortcuts = ShortcutStore()
    @StateObject private var screenPreferences = CameraScreenPreferences()

    var body: some Scene {
        WindowGroup {
            CameraScreen()
                .environmentObject(camera)
                .environmentObject(recipes)
                .environmentObject(shortcuts)
                .environmentObject(screenPreferences)
                .preferredColorScheme(.dark)
        }
    }
}
