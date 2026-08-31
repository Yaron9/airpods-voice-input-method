import AppKit
import Foundation

private final class SpaceReceiverView: NSView {
    let markerPath: String

    init(markerPath: String) {
        self.markerPath = markerPath
        super.init(frame: NSRect(x: 0, y: 0, width: 320, height: 120))
    }

    required init?(coder: NSCoder) { nil }
    override var acceptsFirstResponder: Bool { true }

    override func keyDown(with event: NSEvent) {
        guard event.keyCode == 49 else {
            super.keyDown(with: event)
            return
        }
        let result = event.modifierFlags.contains(.function) ? "fn-space\n" : "plain-space\n"
        try? Data(result.utf8).write(to: URL(fileURLWithPath: markerPath))
        NSApp.terminate(nil)
    }
}

@MainActor
private final class AppDelegate: NSObject, NSApplicationDelegate {
    private var window: NSWindow?
    private var activationTimer: Timer?

    func applicationDidFinishLaunching(_ notification: Notification) {
        guard CommandLine.arguments.count == 3 else {
            NSApp.terminate(nil)
            return
        }
        let view = SpaceReceiverView(markerPath: CommandLine.arguments[1])
        let window = NSWindow(
            contentRect: view.frame, styleMask: [.titled], backing: .buffered, defer: false)
        window.title = "Keyboard safety receiver"
        window.contentView = view
        window.makeFirstResponder(view)
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        self.window = window
        waitUntilFrontmost(readyPath: CommandLine.arguments[2], attemptsRemaining: 30)
    }

    private func waitUntilFrontmost(readyPath: String, attemptsRemaining: Int) {
        if NSWorkspace.shared.frontmostApplication?.processIdentifier
            == ProcessInfo.processInfo.processIdentifier {
            FileManager.default.createFile(atPath: readyPath, contents: Data())
            activationTimer = Timer.scheduledTimer(withTimeInterval: 0.05, repeats: true) {
                [weak self] _ in
                Task { @MainActor in
                    self?.window?.makeKeyAndOrderFront(nil)
                    NSApp.activate(ignoringOtherApps: true)
                }
            }
            return
        }
        guard attemptsRemaining > 0 else {
            fputs("Receiver could not become frontmost\n", stderr)
            NSApp.terminate(nil)
            return
        }
        NSApp.activate(ignoringOtherApps: true)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { [weak self] in
            self?.waitUntilFrontmost(
                readyPath: readyPath, attemptsRemaining: attemptsRemaining - 1)
        }
    }
}

MainActor.assumeIsolated {
    let app = NSApplication.shared
    app.setActivationPolicy(.regular)
    let delegate = AppDelegate()
    app.delegate = delegate
    app.run()
}
