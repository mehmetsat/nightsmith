import AppKit
import SwiftUI

/// The app, or its OCR helper when started with --ocr-worker.
@main
enum Launcher {
    static func main() {
        if CommandLine.arguments.contains("--ocr-worker") { OCRClient.runWorker() }
        ShotBoxApp.main()
    }
}

struct ShotBoxApp: App {
    @StateObject private var model = AppModel()

    var body: some Scene {
        Window("ShotBox", id: "main") {
            if #available(macOS 15, *) {
                MainView()
                    .environmentObject(model)
            }
        }
        .defaultSize(width: 960, height: 640)

        Window("Settings", id: "settings") {
            SettingsView()
                .environmentObject(model)
        }
        .windowResizability(.contentMinSize)

        MenuBarExtra {
            MenuContent()
                .environmentObject(model)
        } label: {
            MenuBarLabel()
                .environmentObject(model)
        }
    }
}

/// Always alive while the app runs, so it can keep the hotkey's way back to the window.
/// It also opens the main window once at launch, since a Window scene is not shown on its own here.
private struct MenuBarLabel: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Image(systemName: "camera.viewfinder")
            .accessibilityIdentifier("menubarItem")
            .onAppear {
                model.openMainWindow = { openWindow(id: "main") }
                model.showMainWindow()
            }
    }
}

private struct MenuContent: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Button("Open ShotBox") {
            model.showMainWindow()
        }
        .accessibilityIdentifier("menuOpen")

        Text(model.totalCount == 1 ? "1 capture" : "\(model.totalCount) captures")
            .accessibilityIdentifier("menuCount")

        Button(model.paused ? "Resume capturing" : "Pause capturing") {
            model.paused.toggle()
        }
        .accessibilityIdentifier("menuPause")

        Button("Settings…") {
            openWindow(id: "settings")
            NSApp.activate(ignoringOtherApps: true)
        }
        .accessibilityIdentifier("menuSettings")

        Divider()

        Button("Quit ShotBox") {
            NSApp.terminate(nil)
        }
        .keyboardShortcut("q")
        .accessibilityIdentifier("menuQuit")
    }
}
