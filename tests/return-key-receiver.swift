import AppKit
import Foundation

private final class ReturnKeyView: NSView {
    let markerPath: String
    private var returnCount = 0

    init(markerPath: String) {
        self.markerPath = markerPath
        super.init(frame: NSRect(x: 0, y: 0, width: 320, height: 120))
    }

    required init?(coder: NSCoder) { nil }
    override var acceptsFirstResponder: Bool { true }

    override func keyDown(with event: NSEvent) {
        guard event.keyCode == 36 else {
            super.keyDown(with: event)
            return
        }
        returnCount += 1
        guard returnCount == 2 else { return }
        FileManager.default.createFile(atPath: markerPath, contents: Data("return\n".utf8))
        NSApp.terminate(nil)
    }
}

@MainActor
private final class AppDelegate: NSObject, NSApplicationDelegate {
    private var window: NSWindow?
    private var readyPath = ""
    private var activationTimer: Timer?

    func applicationDidFinishLaunching(_ notification: Notification) {
        let markerPath = CommandLine.arguments[1]
        readyPath = CommandLine.arguments[2]
        let view = ReturnKeyView(markerPath: markerPath)
        let window = NSWindow(
            contentRect: view.frame,
            styleMask: [.titled],
            backing: .buffered,
            defer: false)
        window.title = "Return Key Regression Receiver"
        window.contentView = view
        window.makeFirstResponder(view)
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        self.window = window
        signalReadyWhenFrontmost(attemptsRemaining: 20)
    }

    private func signalReadyWhenFrontmost(attemptsRemaining: Int) {
        let ownPID = ProcessInfo.processInfo.processIdentifier
        if NSWorkspace.shared.frontmostApplication?.processIdentifier == ownPID {
            FileManager.default.createFile(atPath: readyPath, contents: Data())
            activationTimer = Timer.scheduledTimer(withTimeInterval: 0.05, repeats: true) { [weak self] _ in
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
            self?.signalReadyWhenFrontmost(attemptsRemaining: attemptsRemaining - 1)
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
