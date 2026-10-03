import AppKit
import Foundation

private final class ReturnKeyView: NSView {
    private let markerPath: String
    private let expectedCycles: Int
    private var returnCount = 0
    private var completedCycles = 0
    private let voiceLogPath: String?
    private var commitReadyAt = Date.distantPast

    init(markerPath: String, expectedCycles: Int, voiceLogPath: String? = nil) {
        self.markerPath = markerPath
        self.expectedCycles = expectedCycles
        self.voiceLogPath = voiceLogPath
        super.init(frame: NSRect(x: 0, y: 0, width: 320, height: 120))
    }

    required init?(coder: NSCoder) { nil }
    override var acceptsFirstResponder: Bool { true }

    override func keyDown(with event: NSEvent) {
        guard event.keyCode == 36 else {
            super.keyDown(with: event)
            return
        }
        // Model an IME that is still finishing recognition after Fn release,
        // then asynchronously inserts the committed text. Early Return events
        // must not count as delivered sends.
        if let voiceLogPath {
            let log = (try? String(contentsOfFile: voiceLogPath, encoding: .utf8)) ?? ""
            let stopLine = log.split(separator: "\n").last {
                $0.contains("voice input stopped; reason=AirPods single press")
            }
            let formatter = ISO8601DateFormatter()
            formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            guard let timestamp = stopLine?.split(separator: " ").first,
                  let stoppedAt = formatter.date(from: String(timestamp)),
                  Date().timeIntervalSince(stoppedAt) >= 0.7 else {
                print("Return ignored: recognition is not ready")
                return
            }
            guard Date() >= commitReadyAt else {
                print("Return ignored: text insertion is not ready")
                return
            }
        }
        returnCount += 1
        if voiceLogPath != nil && returnCount == 1 {
            commitReadyAt = Date().addingTimeInterval(0.35)
        }
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

    func applicationDidFinishLaunching(_ notification: Notification) {
        guard CommandLine.arguments.count >= 3 else {
            NSApp.terminate(nil)
            return
        }
        let markerPath = CommandLine.arguments[1]
        let readyPath = CommandLine.arguments[2]
        let expectedCycles = CommandLine.arguments.count > 3
            ? (Int(CommandLine.arguments[3]) ?? 1) : 1
        let voiceLogPath = CommandLine.arguments.count > 4 ? CommandLine.arguments[4] : nil
        let view = ReturnKeyView(markerPath: markerPath, expectedCycles: expectedCycles,
                                 voiceLogPath: voiceLogPath)
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
        FileManager.default.createFile(atPath: readyPath, contents: Data())
    }
}

MainActor.assumeIsolated {
    let app = NSApplication.shared
    app.setActivationPolicy(.regular)
    let delegate = AppDelegate()
    app.delegate = delegate
    app.run()
}
