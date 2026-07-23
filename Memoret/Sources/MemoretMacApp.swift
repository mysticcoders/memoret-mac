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
 The Dock icon is shown by default (activation policy .regular) and can be
 turned off from the UI, falling back to menu-bar-only (.accessory).
 Note: on notched MacBooks macOS silently hides status items that do not
 fit right of the notch — the Dock icon and its window remain reachable
 even when the menu bar icon is hidden.
 */
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private let model = ReceiverModel()
    private var statusItem: NSStatusItem?
    private let popover = NSPopover()
    private var window: NSWindow?

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(model.showDockIcon ? .regular : .accessory)
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

        if model.showDockIcon {
            showWindow()
        }
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows: Bool) -> Bool {
        if !hasVisibleWindows {
            showWindow()
        }
        return true
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

    /**
     Shows the main receiver window, creating it lazily. The window hosts
     the same view as the popover and is the entry point from the Dock.
     */
    private func showWindow() {
        if window == nil {
            let hosting = NSHostingController(rootView: MenuView(model: model))
            let w = NSWindow(contentViewController: hosting)
            w.title = "Memoret"
            w.styleMask = [.titled, .closable, .miniaturizable]
            w.isReleasedWhenClosed = false
            window = w
        }
        window?.makeKeyAndOrderFront(nil)
        positionWindowOnScreen()
        NSApp.activate(ignoringOtherApps: true)
    }

    /**
     Moves the window into the visible frame of the main screen if layout
     left it positioned off-screen.
     */
    private func positionWindowOnScreen() {
        guard let w = window, let screen = NSScreen.main else { return }
        if !screen.visibleFrame.intersects(w.frame) {
            let v = screen.visibleFrame
            w.setFrameOrigin(NSPoint(
                x: v.midX - w.frame.width / 2,
                y: v.midY - w.frame.height / 2
            ))
        }
    }
}
