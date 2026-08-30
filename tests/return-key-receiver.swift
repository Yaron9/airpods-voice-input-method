import AppKit
import Foundation

private final class ReturnKeyView: NSView {
    private let markerPath: String
    private let expectedCycles: Int
    private var returnCount = 0
    private var completedCycles = 0

    init(markerPath: String, expectedCycles: Int) {
        self.markerPath = markerPath
        self.expectedCycles = expectedCycles
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
        returnCount = 0
        completedCycles += 1
        if !FileManager.default.fileExists(atPath: markerPath) {
            FileManager.default.createFile(atPath: markerPath, contents: Data())
        }
        if let handle = try? FileHandle(forWritingTo: URL(fileURLWithPath: markerPath)) {
            _ = try? handle.seekToEnd()
            try? handle.write(contentsOf: Data("cycle \(completedCycles)\n".utf8))
            try? handle.close()
        }
        if completedCycles == expectedCycles { NSApp.terminate(nil) }
    }
}

@MainActor
private final class AppDelegate: NSObject, NSApplicationDelegate {
    private var window: NSWindow?
    private var readyPath = ""
    private var activationTimer: Timer?

    func applicationDidFinishLaunching(_ notification: Notification) {
        guard CommandLine.arguments.count >= 3 else {
            NSApp.terminate(nil)
            return
        }
        let markerPath = CommandLine.arguments[1]
        readyPath = CommandLine.arguments[2]
        let expectedCycles = CommandLine.arguments.count > 3
            ? (Int(CommandLine.arguments[3]) ?? 1) : 1
        let view = ReturnKeyView(markerPath: markerPath, expectedCycles: expectedCycles)
        let window = NSWindow(
            contentRect: view.frame,
            styleMask: [.titled],
            backing: .buffered,
            defer: false)
        window.title = "AirPods Voice 输入法回车测试"
        window.contentView = view
        window.makeFirstResponder(view)
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        self.window = window
        signalReadyWhenFrontmost(attemptsRemaining: 30)
    }

    private func signalReadyWhenFrontmost(attemptsRemaining: Int) {
        let ownPID = ProcessInfo.processInfo.processIdentifier
        if NSWorkspace.shared.frontmostApplication?.processIdentifier == ownPID {
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
