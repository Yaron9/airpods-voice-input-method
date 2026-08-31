import AppKit
import Foundation

private final class SpaceReceiverView: NSView {
    private let markerPath: String

    init(markerPath: String) {
        self.markerPath = markerPath
        super.init(frame: NSRect(x: 0, y: 0, width: 240, height: 80))
    }

    required init?(coder: NSCoder) { nil }
    override var acceptsFirstResponder: Bool { true }

    override func keyDown(with event: NSEvent) {
        guard event.keyCode == 49 else { return }
        let result = event.modifierFlags.contains(.function) ? "fn-space\n" : "plain-space\n"
        try? Data(result.utf8).write(to: URL(fileURLWithPath: markerPath))
        NSApp.terminate(nil)
    }
}

@MainActor
private final class AppDelegate: NSObject, NSApplicationDelegate {
    private var window: NSWindow?

    func applicationDidFinishLaunching(_ notification: Notification) {
        guard CommandLine.arguments.count == 3 else {
            NSApp.terminate(nil)
            return
        }
        let view = SpaceReceiverView(markerPath: CommandLine.arguments[1])
        let window = NSWindow(
            contentRect: view.frame, styleMask: [.titled], backing: .buffered, defer: false)
        window.contentView = view
        window.makeFirstResponder(view)
        window.makeKeyAndOrderFront(nil)
        self.window = window
        NSApp.activate(ignoringOtherApps: true)
        let readyPath = CommandLine.arguments[2]
        func markReadyWhenFrontmost(attemptsRemaining: Int) {
            if NSWorkspace.shared.frontmostApplication?.processIdentifier
                == ProcessInfo.processInfo.processIdentifier {
                FileManager.default.createFile(atPath: readyPath, contents: Data())
                return
            }
            guard attemptsRemaining > 0 else {
                NSApp.terminate(nil)
                return
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
                markReadyWhenFrontmost(attemptsRemaining: attemptsRemaining - 1)
            }
        }
        markReadyWhenFrontmost(attemptsRemaining: 40)
    }
}

MainActor.assumeIsolated {
    let app = NSApplication.shared
    app.setActivationPolicy(.regular)
    let delegate = AppDelegate()
    app.delegate = delegate
    app.run()
}
