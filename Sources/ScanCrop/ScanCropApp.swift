import AppKit
import SwiftUI

@main
struct ScanCropApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @State private var store = ScanStore()

    var body: some Scene {
        Window("ScanCrop", id: "main") {
            ContentView()
                .environment(store)
                .frame(minWidth: 900, minHeight: 600)
        }
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("Add Scans…") { store.showOpenPanel() }
                    .keyboardShortcut("o")
                Button("Export Photos…") { store.showingExport = true }
                    .keyboardShortcut("e")
                    .disabled(store.photoCount == 0)
                Divider()
                Button("Remove All Scans") { store.removeAll() }
                    .disabled(store.items.isEmpty)
            }
            CommandMenu("Scan") {
                Button("Previous Scan") { store.select(offset: -1) }
                    .keyboardShortcut(.upArrow, modifiers: .command)
                Button("Next Scan") { store.select(offset: 1) }
                    .keyboardShortcut(.downArrow, modifiers: .command)
                Divider()
                Button("Detect Photos Again") {
                    if let item = store.selectedItem { store.redetect(item, force: true) }
                }
                .keyboardShortcut("r")
                .disabled(store.selectedItem == nil)
            }
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        // Needed when the app is started with `swift run` (without an .app bundle).
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
}
