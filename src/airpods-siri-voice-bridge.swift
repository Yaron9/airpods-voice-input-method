import AppKit
import CoreGraphics
import Foundation
import IOKit.hid
import MediaPlayer

@_silgen_name("fn_injector_open")
private func fnInjectorOpen() -> Int32
@_silgen_name("fn_injector_post")
private func fnInjectorPost(_ down: Int32) -> Int32
@_silgen_name("fn_injector_close")
private func fnInjectorClose()
@_silgen_name("fn_injector_merge_flags")
private func fnInjectorMergeFlags(_ current: UInt64, _ down: Int32) -> UInt64

private let airPodsInvocationMarker = "SiriNCActionHearstDoubleTap - BluetoothHFP"
private let weTypeStoppedMarker = "AVCaptureSession_Tundra stopRunning"
private let logURL = URL(fileURLWithPath: "/tmp/airpods-fn-test/siri-bridge.log")
private let stopRequestURL = URL(fileURLWithPath: "/tmp/airpods-fn-test/stop.request")
private let siriReleaseDelay: TimeInterval = 0.10
private let focusReactivationDelay: TimeInterval = 0.05
private let finalTextCommitDelay: TimeInterval = 0.35
private let finalSendDelay: TimeInterval = 0.20
private let duplicateWindow: TimeInterval = 1.0
private let maximumFnHoldDuration: TimeInterval = 60.0
private let consumerUsagePage: UInt32 = 0x0c
private let playPauseUsage: UInt32 = 0xcd
private let returnKeyCode: UInt16 = 36
private let logDateFormatter: ISO8601DateFormatter = {
    let formatter = ISO8601DateFormatter()
    formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    return formatter
}()

private struct VoiceActivationKey {
    let name: String
    let keyCode: CGKeyCode
    let modifierFlag: CGEventFlags?
    let usesFnHID: Bool

    static let supportedNames = [
        "fn", "control", "option", "command", "shift",
        "f1", "f2", "f3", "f4", "f5", "f6",
        "f7", "f8", "f9", "f10", "f11", "f12",
    ]

    static func parse(_ value: String) -> VoiceActivationKey? {
        let name = value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let definitions: [String: (CGKeyCode, CGEventFlags?, Bool)] = [
            "fn": (63, nil, true),
            "control": (59, .maskControl, false),
            "option": (58, .maskAlternate, false),
            "command": (55, .maskCommand, false),
            "shift": (56, .maskShift, false),
            "f1": (122, nil, false),
            "f2": (120, nil, false),
            "f3": (99, nil, false),
            "f4": (118, nil, false),
            "f5": (96, nil, false),
            "f6": (97, nil, false),
            "f7": (98, nil, false),
            "f8": (100, nil, false),
            "f9": (101, nil, false),
            "f10": (109, nil, false),
            "f11": (103, nil, false),
            "f12": (111, nil, false),
        ]
        guard let definition = definitions[name] else { return nil }
        return VoiceActivationKey(
            name: name,
            keyCode: definition.0,
            modifierFlag: definition.1,
            usesFnHID: definition.2)
    }
}

private func configuredVoiceKey(arguments: [String] = CommandLine.arguments) -> VoiceActivationKey? {
    guard let optionIndex = arguments.firstIndex(of: "--voice-key") else {
        return VoiceActivationKey.parse("fn")
    }
    let valueIndex = arguments.index(after: optionIndex)
    guard valueIndex < arguments.endIndex else { return nil }
    return VoiceActivationKey.parse(arguments[valueIndex])
}

private func mergedModifierFlags(
    current: CGEventFlags, modifier: CGEventFlags, down: Bool
) -> CGEventFlags {
    down ? current.union(modifier) : current.subtracting(modifier)
}

private func writeLog(_ message: String) {
    let line = "\(logDateFormatter.string(from: Date())) \(message)\n"
    guard let data = line.data(using: .utf8) else { return }
    try? FileManager.default.createDirectory(
        at: logURL.deletingLastPathComponent(), withIntermediateDirectories: true)
    if !FileManager.default.fileExists(atPath: logURL.path) {
        FileManager.default.createFile(atPath: logURL.path, contents: nil)
    }
    if let handle = try? FileHandle(forWritingTo: logURL) {
        _ = try? handle.seekToEnd()
        try? handle.write(contentsOf: data)
        try? handle.close()
    }
    fputs(line, stdout)
    fflush(stdout)
}

private func isAirPodsSiriInvocation(_ line: String) -> Bool {
    line.contains(airPodsInvocationMarker)
}

private func isPlayPausePress(usagePage: UInt32, usage: UInt32, value: Int) -> Bool {
    usagePage == consumerUsagePage && usage == playPauseUsage && value != 0
}

private func terminateSiriAudioOwners() {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/killall")
    process.arguments = ["Siri", "SiriNCService"]
    process.standardOutput = FileHandle.nullDevice
    process.standardError = FileHandle.nullDevice
    do {
        try process.run()
        process.waitUntilExit()
        writeLog("Siri audio owners terminated; status=\(process.terminationStatus)")
    } catch {
        writeLog("Could not terminate Siri audio owners: \(error.localizedDescription)")
    }
}

@MainActor
private final class AirPodsVoiceController {
    private let voiceKey: VoiceActivationKey
    private(set) var isRunning = false
    private var logProcess: Process?
    private var logPipe: Pipe?
    private var hidManager: IOHIDManager?
    private var pendingLog = ""
    private var busy = false
    private var voiceKeyIsDown = false
    private var lastInvocation = Date.distantPast
    private var targetApplication: NSRunningApplication?
    private var startTimer: Timer?
    private var releaseTimer: Timer?
    private var submitTimer: Timer?
    private var remoteCommandTargets: [(command: MPRemoteCommand, target: Any)] = []

    init(voiceKey: VoiceActivationKey) {
        self.voiceKey = voiceKey
    }

    func start(watchLogs: Bool = true) -> Bool {
        guard !isRunning else { return true }
        pendingLog = ""
        guard CGPreflightPostEventAccess() else {
            writeLog("PostEvent permission is not granted; requesting Accessibility access")
            _ = CGRequestPostEventAccess()
            return false
        }
        if voiceKey.usesFnHID {
            let openResult = fnInjectorOpen()
            guard openResult == 0 else {
                writeLog("IOHIDSystem connection failed: 0x\(String(UInt32(bitPattern: openResult), radix: 16))")
                return false
            }
        }
        guard watchLogs else {
            isRunning = true
            writeLog("AirPods voice bridge ready in replay mode; voiceKey=\(voiceKey.name)")
            return true
        }

        startConsumerControlMonitor()

        let pipe = Pipe()
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/log")
        process.arguments = [
            "stream", "--style", "compact", "--level", "debug", "--predicate",
            "(process == \"Siri\" AND eventMessage CONTAINS[c] \"SiriNCActionHearstDoubleTap\" AND eventMessage CONTAINS[c] \"BluetoothHFP\") OR (process == \"WeType\" AND eventMessage CONTAINS[c] \"AVCaptureSession_Tundra stopRunning\")",
        ]
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        pipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard !data.isEmpty, let text = String(data: data, encoding: .utf8) else { return }
            Task { @MainActor in self?.consumeLog(text) }
        }
        do {
            try process.run()
            logProcess = process
            logPipe = pipe
            isRunning = true
            writeLog("AirPods voice bridge active; voiceKey=\(voiceKey.name); start=AirPods long press; stop=AirPods single press")
            return true
        } catch {
            writeLog("Could not start Siri log watcher: \(error.localizedDescription)")
            return false
        }
    }

    func stop() {
        guard isRunning || voiceKeyIsDown else { return }
        isRunning = false
        startTimer?.invalidate()
        releaseTimer?.invalidate()
        submitTimer?.invalidate()
        if voiceKeyIsDown {
            _ = postVoiceKey(down: false)
            voiceKeyIsDown = false
            writeLog("Voice key \(voiceKey.name) up; graceful shutdown cleanup")
        }
        logPipe?.fileHandleForReading.readabilityHandler = nil
        logProcess?.terminate()
        logProcess = nil
        logPipe = nil
        if let manager = hidManager {
            IOHIDManagerUnscheduleFromRunLoop(manager, CFRunLoopGetMain(), CFRunLoopMode.defaultMode.rawValue)
            IOHIDManagerClose(manager, IOOptionBits(kIOHIDOptionsTypeNone))
            hidManager = nil
        }
        deactivateRemoteStopControls()
        fnInjectorClose()
    }

    private func startConsumerControlMonitor() {
        let manager = IOHIDManagerCreate(kCFAllocatorDefault, IOOptionBits(kIOHIDOptionsTypeNone))
        let matching: [String: Any] = [
            kIOHIDDeviceUsagePageKey: consumerUsagePage,
            kIOHIDDeviceUsageKey: UInt32(kHIDUsage_Csmr_ConsumerControl),
            kIOHIDProductKey: "Headset",
            kIOHIDTransportKey: "Audio",
        ]
        IOHIDManagerSetDeviceMatching(manager, matching as CFDictionary)
        IOHIDManagerRegisterInputValueCallback(manager, { context, _, _, hidValue in
            guard let context else { return }
            let element = IOHIDValueGetElement(hidValue)
            let usagePage = IOHIDElementGetUsagePage(element)
            let usage = IOHIDElementGetUsage(element)
            let value = IOHIDValueGetIntegerValue(hidValue)
            guard isPlayPausePress(usagePage: usagePage, usage: usage, value: value) else { return }
            let controller = Unmanaged<AirPodsVoiceController>.fromOpaque(context).takeUnretainedValue()
            Task { @MainActor in controller.handleAirPodsSinglePress() }
        }, Unmanaged.passUnretained(self).toOpaque())
        IOHIDManagerScheduleWithRunLoop(manager, CFRunLoopGetMain(), CFRunLoopMode.defaultMode.rawValue)
        let result = IOHIDManagerOpen(manager, IOOptionBits(kIOHIDOptionsTypeNone))
        guard result == kIOReturnSuccess else {
            writeLog("AirPods single-press monitor unavailable: 0x\(String(UInt32(bitPattern: result), radix: 16))")
            IOHIDManagerUnscheduleFromRunLoop(manager, CFRunLoopGetMain(), CFRunLoopMode.defaultMode.rawValue)
            return
        }
        hidManager = manager
        let deviceCount = (IOHIDManagerCopyDevices(manager) as? Set<IOHIDDevice>)?.count ?? 0
        writeLog("AirPods single-press monitor active; matchedHeadsets=\(deviceCount)")
    }

    private func consumeLog(_ text: String) {
        pendingLog.append(text)
        let lines = pendingLog.split(separator: "\n", omittingEmptySubsequences: false)
        pendingLog = String(lines.last ?? "")
        for line in lines.dropLast() { handleLogLine(String(line)) }
    }

    func handleLogLine(_ line: String) {
        if line.contains(weTypeStoppedMarker) {
            if voiceKeyIsDown { endVoiceKeyHold(reason: "WeType recording stopped") }
            return
        }
        guard isAirPodsSiriInvocation(line) else { return }
        let now = Date()
        if voiceKeyIsDown {
            lastInvocation = now
            writeLog("Second AirPods Siri invocation received; stopping voice input")
            terminateSiriAudioOwners()
            endVoiceKeyHold(reason: "second AirPods invocation")
            return
        }
        guard !busy, now.timeIntervalSince(lastInvocation) >= duplicateWindow else {
            writeLog("Ignored duplicate AirPods Siri invocation")
            return
        }
        busy = true
        lastInvocation = now
        targetApplication = NSWorkspace.shared.frontmostApplication
        let targetID = targetApplication?.bundleIdentifier ?? "unknown"
        let targetPID = targetApplication?.processIdentifier ?? 0
        writeLog("AirPods Siri invocation received")
        writeLog("Captured target application; bundle=\(targetID); pid=\(targetPID)")
        terminateSiriAudioOwners()
        startTimer = Timer.scheduledTimer(withTimeInterval: siriReleaseDelay, repeats: false) { [weak self] _ in
            Task { @MainActor in self?.restoreFocusThenBeginFnHold() }
        }
    }

    func handleAirPodsSinglePress() {
        writeLog("AirPods single press received; recording=\(voiceKeyIsDown)")
        guard voiceKeyIsDown else { return }
        endVoiceKeyHold(reason: "AirPods single press", submit: true)
    }

    func testReturnDelivery() {
        submitVoiceInputIfFocusIsSafe(to: NSWorkspace.shared.frontmostApplication)
    }

    private func activateRemoteStopControls() {
        guard remoteCommandTargets.isEmpty else { return }
        let center = MPRemoteCommandCenter.shared()
        let commands: [(String, MPRemoteCommand)] = [
            ("play", center.playCommand),
            ("pause", center.pauseCommand),
            ("togglePlayPause", center.togglePlayPauseCommand),
            ("stop", center.stopCommand),
        ]
        for (name, command) in commands {
            command.isEnabled = true
            let target = command.addTarget { [weak self] _ in
                Task { @MainActor in
                    writeLog("Media remote command received; command=\(name)")
                    self?.handleAirPodsSinglePress()
                }
                return .success
            }
            remoteCommandTargets.append((command, target))
        }
        let infoCenter = MPNowPlayingInfoCenter.default()
        infoCenter.nowPlayingInfo = [
            MPMediaItemPropertyTitle: "Voice Input",
            MPMediaItemPropertyArtist: "AirPods Siri Voice Bridge",
            MPNowPlayingInfoPropertyIsLiveStream: true,
            MPNowPlayingInfoPropertyPlaybackRate: 1.0,
        ]
        infoCenter.playbackState = .playing
        writeLog("Media remote stop controls active")
    }

    private func deactivateRemoteStopControls() {
        guard !remoteCommandTargets.isEmpty else { return }
        for registration in remoteCommandTargets {
            registration.command.removeTarget(registration.target)
            registration.command.isEnabled = false
        }
        remoteCommandTargets.removeAll()
        let infoCenter = MPNowPlayingInfoCenter.default()
        infoCenter.playbackState = .stopped
        infoCenter.nowPlayingInfo = nil
        writeLog("Media remote stop controls inactive")
    }

    private func restoreFocusThenBeginFnHold() {
        startTimer = nil
        let currentID = NSWorkspace.shared.frontmostApplication?.bundleIdentifier ?? "unknown"
        let activated = targetApplication?.activate() ?? false
        writeLog("Target application reactivated; previousFrontmost=\(currentID); success=\(activated)")
        startTimer = Timer.scheduledTimer(withTimeInterval: focusReactivationDelay, repeats: false) { [weak self] _ in
            Task { @MainActor in self?.beginVoiceKeyHold() }
        }
    }

    private func beginVoiceKeyHold() {
        startTimer = nil
        guard postVoiceKey(down: true) else {
            busy = false
            return
        }
        voiceKeyIsDown = true
        activateRemoteStopControls()
        writeLog("Voice key \(voiceKey.name) down; voice input held until AirPods single press")
        releaseTimer = Timer.scheduledTimer(withTimeInterval: maximumFnHoldDuration, repeats: false) { [weak self] _ in
            Task { @MainActor in self?.endVoiceKeyHold(reason: "60-second safety timeout") }
        }
    }

    private func endVoiceKeyHold(reason: String, submit: Bool = false) {
        releaseTimer?.invalidate()
        releaseTimer = nil
        let submitApplication = targetApplication
        if voiceKeyIsDown {
            _ = postVoiceKey(down: false)
            voiceKeyIsDown = false
            writeLog("Voice key \(voiceKey.name) up; voice input stopped; reason=\(reason)")
        }
        deactivateRemoteStopControls()
        targetApplication = nil
        busy = false
        guard submit else { return }
        submitTimer?.invalidate()
        submitTimer = Timer.scheduledTimer(withTimeInterval: finalTextCommitDelay, repeats: false) { [weak self] _ in
            Task { @MainActor in
                self?.submitVoiceInputIfFocusIsSafe(to: submitApplication)
            }
        }
    }

    private func submitVoiceInputIfFocusIsSafe(
        to application: NSRunningApplication?, sendStage: Bool = false
    ) {
        submitTimer = nil
        guard let application, !application.isTerminated,
              NSWorkspace.shared.frontmostApplication?.processIdentifier == application.processIdentifier else {
            writeLog("Return key skipped; original target no longer has focus")
            return
        }
        guard let source = CGEventSource(stateID: .hidSystemState),
              let keyDown = CGEvent(
                  keyboardEventSource: source,
                  virtualKey: CGKeyCode(returnKeyCode),
                  keyDown: true),
              let keyUp = CGEvent(
                  keyboardEventSource: source,
                  virtualKey: CGKeyCode(returnKeyCode),
                  keyDown: false) else {
            writeLog("Return key failed; could not create CGEvent")
            return
        }
        keyDown.flags = []
        keyUp.flags = []
        keyDown.post(tap: .cghidEventTap)
        keyUp.post(tap: .cghidEventTap)
        if sendStage {
            writeLog("Return key posted; stage=send; voice input submitted")
            return
        }
        writeLog("Return key posted; stage=commit")
        submitTimer = Timer.scheduledTimer(withTimeInterval: finalSendDelay, repeats: false) { [weak self] _ in
            Task { @MainActor in
                self?.submitVoiceInputIfFocusIsSafe(to: application, sendStage: true)
            }
        }
    }

    @discardableResult
    private func postVoiceKey(down: Bool) -> Bool {
        if voiceKey.usesFnHID {
            let result = fnInjectorPost(down ? 1 : 0)
            if result != 0 {
                writeLog("IOHID Fn \(down ? "down" : "up") failed: 0x\(String(UInt32(bitPattern: result), radix: 16))")
                return false
            }
            return true
        }
        guard let source = CGEventSource(stateID: .hidSystemState),
              let event = CGEvent(
                  keyboardEventSource: source,
                  virtualKey: voiceKey.keyCode,
                  keyDown: down) else {
            writeLog("Voice key \(voiceKey.name) event creation failed")
            return false
        }
        if let modifierFlag = voiceKey.modifierFlag {
            event.type = .flagsChanged
            event.flags = mergedModifierFlags(
                current: CGEventSource.flagsState(.hidSystemState),
                modifier: modifierFlag,
                down: down)
        } else {
            event.flags = []
        }
        event.post(tap: .cghidEventTap)
        return true
    }
}

private func runParserTests() -> Bool {
    let cases: [(String, Bool)] = [
        ("#HotKey: event modifiers 100 type: 10", false),
        ("SiriNCActionHotkeyActivate - Accessibility", false),
        ("SiriNCActionHearstDoubleTap - Keyboard", false),
        ("SiriNCActionHearstDoubleTap - BluetoothHFP", true),
        ("prefix SiriNCActionHearstDoubleTap - BluetoothHFP suffix", true),
    ]
    for (line, expected) in cases where isAirPodsSiriInvocation(line) != expected {
        fputs("PARSER TEST FAILED: \(line)\n", stderr)
        return false
    }
    guard isPlayPausePress(usagePage: 0x0c, usage: 0xcd, value: 1),
          !isPlayPausePress(usagePage: 0x0c, usage: 0xcd, value: 0),
          !isPlayPausePress(usagePage: 0x0c, usage: 0xe9, value: 1),
          !isPlayPausePress(usagePage: 0x01, usage: 0xcd, value: 1) else {
        fputs("CONSUMER CONTROL TEST FAILED: play/pause matching is incorrect\n", stderr)
        return false
    }
    guard VoiceActivationKey.supportedNames.allSatisfy({ VoiceActivationKey.parse($0) != nil }),
          VoiceActivationKey.parse("OPTION")?.name == "option",
          configuredVoiceKey(arguments: ["bridge"])?.name == "fn",
          configuredVoiceKey(arguments: ["bridge", "--voice-key", "option"])?.name == "option",
          configuredVoiceKey(arguments: ["bridge", "--voice-key"]) == nil,
          VoiceActivationKey.parse("unknown") == nil else {
        fputs("VOICE KEY CONFIG TEST FAILED\n", stderr)
        return false
    }
    let currentModifiers: CGEventFlags = [.maskShift, .maskCommand]
    let withOption = mergedModifierFlags(
        current: currentModifiers, modifier: .maskAlternate, down: true)
    let withoutOption = mergedModifierFlags(
        current: withOption, modifier: .maskAlternate, down: false)
    guard withOption.contains([.maskShift, .maskCommand, .maskAlternate]),
          withoutOption == currentModifiers else {
        fputs("CONFIGURABLE MODIFIER TEST FAILED: existing flags were not preserved\n", stderr)
        return false
    }
    let existing = CGEventFlags.maskShift.rawValue | CGEventFlags.maskCommand.rawValue
    let withFn = fnInjectorMergeFlags(existing, 1)
    let withoutFn = fnInjectorMergeFlags(withFn, 0)
    guard withFn & existing == existing,
          withFn & CGEventFlags.maskSecondaryFn.rawValue != 0,
          withoutFn == existing else {
        fputs("MODIFIER TEST FAILED: existing modifier flags were not preserved\n", stderr)
        return false
    }
    print("PARSER TEST PASSED: only BluetoothHFP AirPods Siri invocation is accepted")
    print("CONSUMER CONTROL TEST PASSED: only Play/Pause key-down is accepted")
    print("VOICE KEY CONFIG TEST PASSED: supported names parse and default to fn")
    print("CONFIGURABLE MODIFIER TEST PASSED: existing flags survive key down and up")
    print("MODIFIER TEST PASSED: Shift/Command survive Fn down and up")
    return true
}

@MainActor
private final class AppDelegate: NSObject, NSApplicationDelegate {
    private var controller: AirPodsVoiceController?
    private var stopRequestTimer: Timer?
    private var statusItem: NSStatusItem?
    private var statusLineItem: NSMenuItem?
    private var toggleItem: NSMenuItem?
    private var voiceKey: VoiceActivationKey?
    private var instructionsPopover: NSPopover?

    func applicationDidFinishLaunching(_ notification: Notification) {
        let stopRequestTimer = Timer(timeInterval: 0.1, repeats: true) { _ in
            guard FileManager.default.fileExists(atPath: stopRequestURL.path) else { return }
            try? FileManager.default.removeItem(at: stopRequestURL)
            writeLog("Graceful stop requested")
            NSApp.terminate(nil)
        }
        self.stopRequestTimer = stopRequestTimer
        RunLoop.main.add(stopRequestTimer, forMode: .common)

        let selfTest = CommandLine.arguments.contains("--self-test")
        let returnTest = CommandLine.arguments.contains("--return-test")
        guard let voiceKey = configuredVoiceKey() else {
            let supported = VoiceActivationKey.supportedNames.joined(separator: ", ")
            writeLog("Invalid --voice-key value; supported=\(supported)")
            NSApp.terminate(nil)
            return
        }
        self.voiceKey = voiceKey
        let controller = AirPodsVoiceController(voiceKey: voiceKey)
        self.controller = controller
        if !(selfTest || returnTest) {
            configureStatusMenu()
        }
        guard controller.start(watchLogs: !(selfTest || returnTest)) else {
            if selfTest || returnTest {
                NSApp.terminate(nil)
            } else {
                updateStatusMenu()
                showStartFailure()
            }
            return
        }
        updateStatusMenu()
        if selfTest {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
                controller.handleLogLine("SELF-TEST SiriNCActionHearstDoubleTap - BluetoothHFP")
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.2 + siriReleaseDelay + focusReactivationDelay + 2.0) {
                controller.handleAirPodsSinglePress()
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.2 + siriReleaseDelay + focusReactivationDelay + 3.0) {
                NSApp.terminate(nil)
            }
        } else if returnTest {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                controller.testReturnDelivery()
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
                NSApp.terminate(nil)
            }
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        stopRequestTimer?.invalidate()
        controller?.stop()
    }

    private func configureStatusMenu() {
        // Keep the item narrow so it is less likely to fall behind a MacBook notch.
        // autosaveName preserves the position after the user Command-drags it.
        let item = NSStatusBar.system.statusItem(withLength: 18)
        item.autosaveName = "AirPodsVoiceBridgeStatusItem"
        item.behavior = [.terminationOnRemoval]
        statusItem = item
        item.button?.toolTip = "AirPods Voice Bridge"
        item.button?.imagePosition = .imageOnly

        let menu = NSMenu()
        let titleItem = NSMenuItem(title: "AirPods Voice Bridge", action: nil, keyEquivalent: "")
        titleItem.isEnabled = false
        menu.addItem(titleItem)

        let statusLineItem = NSMenuItem(title: "状态：正在启动", action: nil, keyEquivalent: "")
        statusLineItem.isEnabled = false
        self.statusLineItem = statusLineItem
        menu.addItem(statusLineItem)

        let keyName = voiceKey?.name.uppercased() ?? "FN"
        let keyItem = NSMenuItem(title: "语音键：\(keyName)", action: nil, keyEquivalent: "")
        keyItem.isEnabled = false
        menu.addItem(keyItem)
        menu.addItem(.separator())

        let toggleItem = NSMenuItem(
            title: "停止", action: #selector(toggleBridge), keyEquivalent: "")
        toggleItem.target = self
        self.toggleItem = toggleItem
        menu.addItem(toggleItem)

        let instructionsItem = NSMenuItem(
            title: "使用说明…", action: #selector(showInstructions), keyEquivalent: "")
        instructionsItem.target = self
        menu.addItem(instructionsItem)
        menu.addItem(.separator())

        let quitItem = NSMenuItem(
            title: "退出", action: #selector(quitApplication), keyEquivalent: "q")
        quitItem.target = self
        menu.addItem(quitItem)
        item.menu = menu
        updateStatusMenu()
    }

    private func updateStatusMenu() {
        let running = controller?.isRunning == true
        statusLineItem?.title = running ? "状态：运行中" : "状态：已停止"
        toggleItem?.title = running ? "停止" : "启动"
        let symbolName = running ? "waveform.circle.fill" : "waveform.circle"
        let image = NSImage(systemSymbolName: symbolName, accessibilityDescription: running ? "运行中" : "已停止")
        image?.isTemplate = true
        statusItem?.button?.image = image
    }

    @objc private func toggleBridge() {
        guard let controller else { return }
        if controller.isRunning {
            controller.stop()
        } else if !controller.start() {
            showStartFailure()
        }
        updateStatusMenu()
    }

    @objc private func showInstructions() {
        DispatchQueue.main.async { [weak self] in
            self?.presentInstructions()
        }
    }

    private func presentInstructions() {
        guard let statusButton = statusItem?.button else { return }
        if instructionsPopover?.isShown == true {
            instructionsPopover?.close()
            return
        }

        let title = NSTextField(labelWithString: "使用前请完成两项设置")
        title.font = .systemFont(ofSize: 15, weight: .semibold)

        let firstStep = NSTextField(labelWithString: "1. 在语音输入法设置中，将语音输入快捷键设为“长按 Fn”。")
        let secondStep = NSTextField(labelWithString: "2. 在 AirPods 设置中，将左耳“按住”设为唤醒 Siri。")
        let usage = NSTextField(labelWithString: "完成后，长按左耳开始说话，单击停止并发送。")
        for label in [firstStep, secondStep, usage] {
            label.maximumNumberOfLines = 0
            label.lineBreakMode = .byWordWrapping
            label.preferredMaxLayoutWidth = 320
        }
        usage.textColor = .secondaryLabelColor

        let stack = NSStackView(views: [title, firstStep, secondStep, usage])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 12
        stack.edgeInsets = NSEdgeInsets(top: 18, left: 18, bottom: 18, right: 18)
        stack.translatesAutoresizingMaskIntoConstraints = false

        let container = NSView()
        container.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            stack.topAnchor.constraint(equalTo: container.topAnchor),
            stack.bottomAnchor.constraint(equalTo: container.bottomAnchor),
            container.widthAnchor.constraint(equalToConstant: 356),
        ])

        let viewController = NSViewController()
        viewController.view = container
        let popover = NSPopover()
        popover.behavior = .transient
        popover.contentViewController = viewController
        popover.contentSize = NSSize(width: 356, height: 190)
        instructionsPopover = popover
        popover.show(relativeTo: statusButton.bounds, of: statusButton, preferredEdge: .minY)
    }

    private func showStartFailure() {
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = "无法启动语音桥接"
        alert.informativeText = "请在“系统设置 → 隐私与安全性 → 辅助功能”中允许 AirPods Voice Bridge，然后再次点击“启动”。"
        alert.alertStyle = .warning
        alert.addButton(withTitle: "知道了")
        alert.runModal()
    }

    @objc private func quitApplication() {
        NSApp.terminate(nil)
    }
}

if CommandLine.arguments.contains("--parser-test") {
    exit(runParserTests() ? 0 : 1)
}

MainActor.assumeIsolated {
    let app = NSApplication.shared
    app.setActivationPolicy(.accessory)
    let delegate = AppDelegate()
    app.delegate = delegate
    app.run()
}
