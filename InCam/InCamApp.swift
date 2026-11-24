import SwiftUI

// FILE GUIDE: App entry point. It creates one shared instance of each long-
// lived store and injects them into CameraScreen. Creating these objects is
// lightweight; opening the physical camera begins from CameraScreen.onAppear.

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
