import AppKit
import SwiftUI

@main
struct MemoretMacApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var delegate

    var body: some Scene {
        Settings {
            EmptyView()
        }
    }
}

/**
 Owns the status bar item directly via AppKit rather than MenuBarExtra so
 launch, activation policy, and popover behavior are fully deterministic.
 Note: on notched MacBooks macOS silently hides status items that do not
 fit right of the notch — a crowded menu bar hides this icon entirely.
 */
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private let model = ReceiverModel()
    private var statusItem: NSStatusItem?
    private let popover = NSPopover()

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        model.start()

        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        item.button?.image = NSImage(
            systemSymbolName: "waveform",
            accessibilityDescription: "Memoret"
        )
        item.button?.target = self
        item.button?.action = #selector(togglePopover)
        statusItem = item

        popover.contentViewController = NSHostingController(rootView: MenuView(model: model))
        popover.behavior = .transient
    }

    /**
     Shows or hides the receiver popover anchored to the status item.
     */
    @objc private func togglePopover() {
        guard let button = statusItem?.button else { return }
        if popover.isShown {
            popover.performClose(nil)
        } else {
            popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
            popover.contentViewController?.view.window?.makeKey()
            NSApp.activate(ignoringOtherApps: true)
        }
    }
}
