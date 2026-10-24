// The playground: `swift run RobotPlayground` opens the window of controls;
// `--measure <scenario>` runs one measurement and prints its JSON line
// (see docs/swift-port/PLAYGROUND.md).

import AppKit
import SwiftUI

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private let measure: MeasureOptions?
    private var window: NSWindow?
    private var model: PlaygroundModel?
    private var measurement: Measurement?

    init(measure: MeasureOptions?) {
        self.measure = measure
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.mainMenu = Self.makeMenu()
        if let measure {
            let m = Measurement(options: measure)
            measurement = m
            m.start()
        } else {
            let model = PlaygroundModel()
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1280, height: 820), styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView], backing: .buffered, defer: false)
            window.title = "RobotPlayground"
            window.titlebarAppearsTransparent = true
            window.contentViewController = NSHostingController(rootView: PlaygroundView(model: model))
            let room = NSScreen.main?.visibleFrame.height ?? 820
            window.setContentSize(NSSize(width: 1280, height: min(920, room - 40)))
            window.center()
            window.makeKeyAndOrderFront(nil)
            window.orderFrontRegardless()
            self.model = model
            self.window = window
        }
        // a SwiftPM executable starts in the background; bring it forward
        NSApp.activate()
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }

    /// The app menu, so ⌘Q and ⌘W work.
    private static func makeMenu() -> NSMenu {
        let menu = NSMenu()
        let app = NSMenuItem()
        app.submenu = NSMenu()
        app.submenu?.addItem(withTitle: "Quit RobotPlayground", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        menu.addItem(app)
        let window = NSMenuItem()
        window.submenu = NSMenu(title: "Window")
        window.submenu?.addItem(withTitle: "Close", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")
        window.submenu?.addItem(withTitle: "Minimize", action: #selector(NSWindow.performMiniaturize(_:)), keyEquivalent: "m")
        menu.addItem(window)
        return menu
    }
}

MainActor.assumeIsolated {
    let options: MeasureOptions?
    do {
        options = try MeasureOptions(arguments: Array(CommandLine.arguments.dropFirst()))
    } catch {
        FileHandle.standardError.write(Data((MeasureOptions.usage + "\n").utf8))
        exit(2)
    }
    let app = NSApplication.shared
    let delegate = AppDelegate(measure: options)
    app.delegate = delegate
    app.setActivationPolicy(.regular)
    app.run()
}
