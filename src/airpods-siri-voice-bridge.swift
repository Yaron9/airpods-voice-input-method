import AppKit
import CoreGraphics
import Darwin
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

private let airPodsHearstMarker = "SiriNCActionHearstDoubleTap - BluetoothHFP"
private let airPodsCloseMarker = "SiriNCActionClose - BluetoothHFP"
private let airPodsInvocationMarkers = [airPodsHearstMarker, airPodsCloseMarker]
private let weTypeStoppedMarker = "AVCaptureSession_Tundra stopRunning"
private let logURL = URL(fileURLWithPath: "/tmp/airpods-fn-test/siri-bridge.log")
private let stopRequestURL = URL(fileURLWithPath:
    ProcessInfo.processInfo.environment["AIRPODS_BRIDGE_STOP_REQUEST_PATH"]
        ?? "/tmp/airpods-fn-test/stop.request")
private let siriReleaseDelay: TimeInterval = 0.10
private let focusReactivationDelay: TimeInterval = 0.05
private let finalTextCommitDelay: TimeInterval = 0.50
private let finalSendDelay: TimeInterval = 0.25
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

private func installationPriority(path: String, homeDirectory: String = NSHomeDirectory()) -> Int {
    let normalizedPath = URL(fileURLWithPath: path).standardizedFileURL.path
    if normalizedPath.hasPrefix("/Applications/") { return 2 }
    let userApplications = URL(fileURLWithPath: homeDirectory)
        .appendingPathComponent("Applications").standardizedFileURL.path + "/"
    if normalizedPath.hasPrefix(userApplications) { return 1 }
    return 0
}

private func shouldYieldToOtherInstance(
    ownPath: String, ownPID: pid_t, otherPath: String, otherPID: pid_t,
    homeDirectory: String = NSHomeDirectory()
) -> Bool {
    let ownPriority = installationPriority(path: ownPath, homeDirectory: homeDirectory)
    let otherPriority = installationPriority(path: otherPath, homeDirectory: homeDirectory)
    return otherPriority > ownPriority || (otherPriority == ownPriority && otherPID < ownPID)
}

@discardableResult
private func scheduleDelayedLaunch(
    targetURL: URL,
    launcherURL: URL = URL(fileURLWithPath: "/usr/bin/open"),
    delay: TimeInterval = 0.5
) throws -> Process {
    let helper = Process()
    helper.executableURL = URL(fileURLWithPath: "/bin/sh")
    helper.arguments = [
        "-c", "sleep \"$1\"; exec \"$2\" \"$3\"",
        "airpods-voice-bridge-relaunch", String(delay), launcherURL.path, targetURL.path,
    ]
    helper.standardOutput = FileHandle.nullDevice
    helper.standardError = FileHandle.nullDevice
    try helper.run()
    return helper
}

private enum AccessibilityPermissionRecoveryEvent {
    case startupDenied
    case openSettings
    case userConfirmedAuthorization
}

private enum AccessibilityPermissionRecoveryAction: Equatable {
    case showAuthorizationHelp
    case keepAuthorizationHelpOpen
    case relaunch
    case none
}

private struct AccessibilityPermissionRecoveryFlow {
    private var startupWasDenied = false

    mutating func handle(
        _ event: AccessibilityPermissionRecoveryEvent
    ) -> AccessibilityPermissionRecoveryAction {
        switch event {
        case .startupDenied:
            startupWasDenied = true
            return .showAuthorizationHelp
        case .openSettings:
            guard startupWasDenied else { return .none }
            return .keepAuthorizationHelpOpen
        case .userConfirmedAuthorization:
            guard startupWasDenied else { return .none }
            return .relaunch
        }
    }
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
    airPodsInvocationMarkers.contains { line.contains($0) }
}

private func airPodsEventAlreadyResetsSiriSession(_ line: String) -> Bool {
    line.contains(airPodsCloseMarker)
}

private func isPlayPausePress(usagePage: UInt32, usage: UInt32, value: Int) -> Bool {
    usagePage == consumerUsagePage && usage == playPauseUsage && value != 0
}

private func readyReplacementSiriHost(excluding oldHostPID: pid_t?) -> NSRunningApplication? {
    NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.Siri").first {
        $0.processIdentifier != oldHostPID && $0.isFinishedLaunching
    }
}

private func waitForReadyReplacementSiriHost(
    excluding oldHostPID: pid_t?, timeout: TimeInterval
) -> NSRunningApplication? {
    let deadline = Date().addingTimeInterval(timeout)
    repeat {
        if let host = readyReplacementSiriHost(excluding: oldHostPID) { return host }
        usleep(10_000)
    } while Date() < deadline
    return readyReplacementSiriHost(excluding: oldHostPID)
}

@discardableResult
private func resetSiriSession() -> Bool {
    let oldHostPID = NSRunningApplication.runningApplications(
        withBundleIdentifier: "com.apple.Siri").first?.processIdentifier
    let terminator = Process()
    terminator.executableURL = URL(fileURLWithPath: "/usr/bin/killall")
    // SiriNCService alone releases the microphone but leaves the AirPods DoAP
    // stream in Stream Ready. Restart the host as well so the next long press is
    // a fresh activation, then immediately prewarm it to avoid launchd's delay.
    terminator.arguments = ["Siri", "SiriNCService"]
    terminator.standardOutput = FileHandle.nullDevice
    terminator.standardError = FileHandle.nullDevice
    do {
        try terminator.run()
        terminator.waitUntilExit()
    } catch {
        writeLog("Could not reset Siri session: \(error.localizedDescription)")
        return false
    }

    if let oldHostPID {
        let deadline = Date().addingTimeInterval(0.5)
        while kill(oldHostPID, 0) == 0, Date() < deadline {
            usleep(10_000)
        }
    }

    var newHost = waitForReadyReplacementSiriHost(excluding: oldHostPID, timeout: 0.5)
    var launchStatus: Int32 = 0
    var launchAttempts = 0
    while newHost == nil, launchAttempts < 2 {
        launchAttempts += 1
        let launcher = Process()
        launcher.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        launcher.arguments = ["-gj", "-a", "Siri"]
        launcher.standardOutput = FileHandle.nullDevice
        launcher.standardError = FileHandle.nullDevice
        do {
            try launcher.run()
            launcher.waitUntilExit()
            launchStatus = launcher.terminationStatus
            newHost = waitForReadyReplacementSiriHost(
                excluding: oldHostPID, timeout: 1.0)
        } catch {
            writeLog("Could not prewarm Siri host after reset: \(error.localizedDescription)")
            return false
        }
    }
    let newHostPID = newHost?.processIdentifier
    let hostReady = newHostPID != nil && newHostPID != oldHostPID
    writeLog(
        "Siri host restarted and prewarmed; hostReady=\(hostReady); "
            + "terminateStatus=\(terminator.terminationStatus); launchStatus=\(launchStatus); "
            + "launchAttempts=\(launchAttempts); oldPID=\(oldHostPID ?? 0); "
            + "newPID=\(newHostPID ?? 0)")
    return hostReady
}

@MainActor
private final class AirPodsVoiceController {
    private let voiceKey: VoiceActivationKey
    private let siriSessionReset: () -> Bool
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

    init(voiceKey: VoiceActivationKey, siriSessionReset: @escaping () -> Bool = resetSiriSession) {
        self.voiceKey = voiceKey
        self.siriSessionReset = siriSessionReset
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
            "(process == \"Siri\" AND eventMessage CONTAINS[c] \"BluetoothHFP\" AND (eventMessage CONTAINS[c] \"SiriNCActionHearstDoubleTap\" OR eventMessage CONTAINS[c] \"SiriNCActionClose\")) OR (process == \"WeType\" AND eventMessage CONTAINS[c] \"AVCaptureSession_Tundra stopRunning\")",
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
        startTimer = nil
        releaseTimer = nil
        submitTimer = nil
        busy = false
        lastInvocation = .distantPast
        targetApplication = nil
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
        let timeSinceLastInvocation = now.timeIntervalSince(lastInvocation)
        if voiceKeyIsDown {
            if airPodsEventAlreadyResetsSiriSession(line),
               timeSinceLastInvocation < duplicateWindow {
                writeLog("Ignored duplicate AirPods Siri invocation")
                return
            }
            lastInvocation = now
            if airPodsEventAlreadyResetsSiriSession(line) {
                // BluetoothHFP Close is emitted with DoAP StopStreaming/SiriCancel;
                // that system event has already returned SiriState to idle.
                writeLog("AirPods Siri Close received; remote session already reset; stopping and submitting")
                endVoiceKeyHold(reason: "AirPods single press via Siri", submit: true)
            } else {
                _ = siriSessionReset()
                writeLog("Second AirPods long press received; stopping without submitting")
                endVoiceKeyHold(reason: "second AirPods long press")
            }
            return
        }
        guard !busy, timeSinceLastInvocation >= duplicateWindow else {
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
        guard siriSessionReset() else {
            writeLog("Voice input start aborted; replacement Siri host was not ready")
            targetApplication = nil
            busy = false
            return
        }
        startTimer = Timer.scheduledTimer(withTimeInterval: siriReleaseDelay, repeats: false) { [weak self] _ in
            Task { @MainActor in self?.restoreFocusThenBeginFnHold() }
        }
    }

    func handleAirPodsSinglePress() {
        writeLog("AirPods single press received; recording=\(voiceKeyIsDown)")
        guard voiceKeyIsDown else { return }
        endVoiceKeyHold(
            reason: "AirPods single press", submit: true,
            resetSiriAfterSubmit: true)
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

    private func endVoiceKeyHold(
        reason: String, submit: Bool = false, resetSiriAfterSubmit: Bool = false
    ) {
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
        busy = submit && resetSiriAfterSubmit
        guard submit else {
            busy = false
            return
        }
        submitTimer?.invalidate()
        submitTimer = Timer.scheduledTimer(withTimeInterval: finalTextCommitDelay, repeats: false) { [weak self] _ in
            Task { @MainActor in
                self?.submitVoiceInputIfFocusIsSafe(
                    to: submitApplication,
                    resetSiriAfterSubmit: resetSiriAfterSubmit)
            }
        }
    }

    private func submitVoiceInputIfFocusIsSafe(
        to application: NSRunningApplication?, sendStage: Bool = false,
        resetSiriAfterSubmit: Bool = false
    ) {
        submitTimer = nil
        guard let application, !application.isTerminated,
              NSWorkspace.shared.frontmostApplication?.processIdentifier == application.processIdentifier else {
            writeLog("Return key skipped; original target no longer has focus")
            scheduleSiriResetAfterSubmissionIfNeeded(resetSiriAfterSubmit)
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
            scheduleSiriResetAfterSubmissionIfNeeded(resetSiriAfterSubmit)
            return
        }
        keyDown.flags = []
        keyUp.flags = []
        keyDown.post(tap: .cghidEventTap)
        keyUp.post(tap: .cghidEventTap)
        if sendStage {
            writeLog("Return key posted; stage=send; voice input submitted")
            scheduleSiriResetAfterSubmissionIfNeeded(resetSiriAfterSubmit)
            return
        }
        writeLog("Return key posted; stage=commit")
        submitTimer = Timer.scheduledTimer(withTimeInterval: finalSendDelay, repeats: false) { [weak self] _ in
            Task { @MainActor in
                self?.submitVoiceInputIfFocusIsSafe(
                    to: application, sendStage: true,
                    resetSiriAfterSubmit: resetSiriAfterSubmit)
            }
        }
    }

    private func scheduleSiriResetAfterSubmissionIfNeeded(_ needed: Bool) {
        guard needed else { return }
        submitTimer = Timer.scheduledTimer(withTimeInterval: 0.05, repeats: false) { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                self.submitTimer = nil
                let resetSucceeded = self.siriSessionReset()
                self.busy = false
                writeLog(
                    "Siri session reset after media-routed AirPods stop; "
                        + "success=\(resetSucceeded)")
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
        ("SiriNCActionClose - Keyboard", false),
        ("SiriNCActionHearstDoubleTap - BluetoothHFP", true),
        ("SiriNCActionClose - BluetoothHFP", true),
        ("prefix SiriNCActionHearstDoubleTap - BluetoothHFP suffix", true),
    ]
    for (line, expected) in cases where isAirPodsSiriInvocation(line) != expected {
        fputs("PARSER TEST FAILED: \(line)\n", stderr)
        return false
    }
    guard airPodsEventAlreadyResetsSiriSession(airPodsCloseMarker),
          !airPodsEventAlreadyResetsSiriSession(airPodsHearstMarker) else {
        fputs("SIRI SESSION EVENT TEST FAILED: Close must be the only self-resetting event\n", stderr)
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
    guard installationPriority(path: "/Applications/Bridge.app", homeDirectory: "/Users/test") == 2,
          installationPriority(path: "/Users/test/Applications/Bridge.app", homeDirectory: "/Users/test") == 1,
          installationPriority(path: "/Users/test/Downloads/Bridge.app", homeDirectory: "/Users/test") == 0,
          shouldYieldToOtherInstance(
            ownPath: "/Users/test/Downloads/Bridge.app", ownPID: 200,
            otherPath: "/Users/test/Applications/Bridge.app", otherPID: 300,
            homeDirectory: "/Users/test"),
          !shouldYieldToOtherInstance(
            ownPath: "/Users/test/Applications/Bridge.app", ownPID: 300,
            otherPath: "/Users/test/Downloads/Bridge.app", otherPID: 200,
            homeDirectory: "/Users/test") else {
        fputs("INSTANCE PRIORITY TEST FAILED\n", stderr)
        return false
    }
    print("PARSER TEST PASSED: only BluetoothHFP AirPods Siri invocation is accepted")
    print("CONSUMER CONTROL TEST PASSED: only Play/Pause key-down is accepted")
    print("VOICE KEY CONFIG TEST PASSED: supported names parse and default to fn")
    print("CONFIGURABLE MODIFIER TEST PASSED: existing flags survive key down and up")
    print("MODIFIER TEST PASSED: Shift/Command survive Fn down and up")
    print("INSTANCE PRIORITY TEST PASSED: installed app wins over downloaded copies")
    return true
}

private func runPermissionRecoveryTests() -> Bool {
    var flow = AccessibilityPermissionRecoveryFlow()
    guard flow.handle(.startupDenied) == .showAuthorizationHelp,
          flow.handle(.openSettings) == .keepAuthorizationHelpOpen,
          flow.handle(.userConfirmedAuthorization) == .relaunch else {
        fputs("PERMISSION RECOVERY TEST FAILED\n", stderr)
        return false
    }

    let markerURL = FileManager.default.temporaryDirectory
        .appendingPathComponent("airpods-bridge-permission-relaunch-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: markerURL) }
    do {
        let helper = try scheduleDelayedLaunch(
            targetURL: markerURL,
            launcherURL: URL(fileURLWithPath: "/usr/bin/touch"),
            delay: 0)
        helper.waitUntilExit()
    } catch {
        fputs("PERMISSION RECOVERY HELPER TEST FAILED: \(error.localizedDescription)\n", stderr)
        return false
    }
    guard FileManager.default.fileExists(atPath: markerURL.path) else {
        fputs("PERMISSION RECOVERY HELPER TEST FAILED: delayed launcher did not run\n", stderr)
        return false
    }
    print("PERMISSION RECOVERY TEST PASSED: authorization confirmation forces a fresh process")
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
    private var startFailureAlert: NSAlert?
    private var permissionRecoveryFlow = AccessibilityPermissionRecoveryFlow()

    func applicationDidFinishLaunching(_ notification: Notification) {
        let selfTest = CommandLine.arguments.contains("--self-test")
        let returnTest = CommandLine.arguments.contains("--return-test")
        let cycleTest = CommandLine.arguments.contains("--cycle-test")
        let siriStopTest = CommandLine.arguments.contains("--siri-stop-test")
        let longPressStopTest = CommandLine.arguments.contains("--long-press-stop-test")
        let siriResetFailureTest = CommandLine.arguments.contains("--siri-reset-failure-test")
        let stopStartDuringSubmitTest = CommandLine.arguments.contains(
            "--stop-start-during-submit-test")
        let replayTest = selfTest || returnTest || cycleTest || siriStopTest || longPressStopTest
            || siriResetFailureTest || stopStartDuringSubmitTest
        if !replayTest, !enforcePreferredInstance() { return }

        let stopRequestTimer = Timer(timeInterval: 0.1, repeats: true) { _ in
            guard FileManager.default.fileExists(atPath: stopRequestURL.path) else { return }
            try? FileManager.default.removeItem(at: stopRequestURL)
            writeLog("Graceful stop requested")
            NSApp.terminate(nil)
        }
        self.stopRequestTimer = stopRequestTimer
        RunLoop.main.add(stopRequestTimer, forMode: .common)

        guard let voiceKey = configuredVoiceKey() else {
            let supported = VoiceActivationKey.supportedNames.joined(separator: ", ")
            writeLog("Invalid --voice-key value; supported=\(supported)")
            NSApp.terminate(nil)
            return
        }
        self.voiceKey = voiceKey
        let testReset: () -> Bool = stopStartDuringSubmitTest ? { true } : resetSiriSession
        let controller = AirPodsVoiceController(
            voiceKey: voiceKey,
            siriSessionReset: siriResetFailureTest ? { false } : testReset)
        self.controller = controller
        if !replayTest {
            configureStatusMenu()
        }
        guard controller.start(watchLogs: !replayTest) else {
            if replayTest {
                NSApp.terminate(nil)
            } else {
                updateStatusMenu()
                showStartFailure()
            }
            return
        }
        updateStatusMenu()
        if stopStartDuringSubmitTest {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
                controller.handleLogLine("STOP-START-1 \(airPodsHearstMarker)")
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) {
                controller.handleAirPodsSinglePress()
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.7) {
                controller.stop()
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) {
                _ = controller.start(watchLogs: false)
            }
            // Restart and replay inside duplicateWindow so stale per-session
            // suppression state cannot hide behind the test timing.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.9) {
                controller.handleLogLine("STOP-START-2 \(airPodsHearstMarker)")
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.4) {
                controller.stop()
                NSApp.terminate(nil)
            }
        } else if siriResetFailureTest {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
                controller.handleLogLine("RESET-FAILURE \(airPodsHearstMarker)")
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) {
                NSApp.terminate(nil)
            }
        } else if selfTest {
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
        } else if cycleTest {
            // A real Siri replacement can consume the full retry window before
            // Fn goes down. Keep replay stops well after that worst case.
            let holdDuration = 4.0
            let cycleInterval = 5.8
            let starts = [
                airPodsHearstMarker, airPodsCloseMarker,
                airPodsHearstMarker, airPodsCloseMarker,
            ]
            for (index, marker) in starts.enumerated() {
                let cycle = index + 1
                let start = 0.2 + Double(index) * cycleInterval
                let stop = start + siriReleaseDelay + focusReactivationDelay + holdDuration
                DispatchQueue.main.asyncAfter(deadline: .now() + start) {
                    controller.handleLogLine("CYCLE-\(cycle)-START \(marker)")
                }
                if index == 1 {
                    DispatchQueue.main.asyncAfter(deadline: .now() + start + 0.04) {
                        controller.handleLogLine("CYCLE-2-DUPLICATE \(airPodsCloseMarker)")
                    }
                    DispatchQueue.main.asyncAfter(deadline: .now() + start + 0.75) {
                        controller.handleLogLine("CYCLE-2-DELAYED-DUPLICATE \(airPodsCloseMarker)")
                    }
                }
                DispatchQueue.main.asyncAfter(deadline: .now() + stop) {
                    if index.isMultiple(of: 2) {
                        controller.handleAirPodsSinglePress()
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                            controller.handleLogLine(
                                "CYCLE-\(cycle)-EARLY-RESTART \(airPodsHearstMarker)")
                        }
                    } else {
                        controller.handleLogLine("CYCLE-\(cycle)-STOP \(airPodsCloseMarker)")
                    }
                }
            }
            let finalStop = 0.2 + 3.0 * cycleInterval
                + siriReleaseDelay + focusReactivationDelay + holdDuration
            DispatchQueue.main.asyncAfter(deadline: .now() + finalStop + 1.5) {
                NSApp.terminate(nil)
            }
        } else if siriStopTest || longPressStopTest {
            let start = 0.2
            let stop = start + siriReleaseDelay + focusReactivationDelay + duplicateWindow + 0.2
            DispatchQueue.main.asyncAfter(deadline: .now() + start) {
                controller.handleLogLine("START SiriNCActionHearstDoubleTap - BluetoothHFP")
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + stop) {
                let marker = siriStopTest ? airPodsCloseMarker : airPodsHearstMarker
                controller.handleLogLine("STOP \(marker)")
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + stop + 1.5) {
                NSApp.terminate(nil)
            }
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        stopRequestTimer?.invalidate()
        controller?.stop()
    }

    private func enforcePreferredInstance() -> Bool {
        guard let bundleIdentifier = Bundle.main.bundleIdentifier else { return true }
        let ownPID = ProcessInfo.processInfo.processIdentifier
        let ownPath = Bundle.main.bundleURL.path
        let others = NSRunningApplication.runningApplications(withBundleIdentifier: bundleIdentifier)
            .filter { $0.processIdentifier != ownPID && !$0.isTerminated }

        if let preferred = others.first(where: { other in
            guard let otherPath = other.bundleURL?.path else { return false }
            return shouldYieldToOtherInstance(
                ownPath: ownPath, ownPID: ownPID,
                otherPath: otherPath, otherPID: other.processIdentifier)
        }) {
            writeLog("Another preferred app copy is already running; path=\(preferred.bundleURL?.path ?? "unknown")")
            _ = preferred.activate(options: [.activateIgnoringOtherApps])
            NSApp.terminate(nil)
            return false
        }

        for other in others {
            guard let otherPath = other.bundleURL?.path,
                  shouldYieldToOtherInstance(
                    ownPath: otherPath, ownPID: other.processIdentifier,
                    otherPath: ownPath, otherPID: ownPID) else { continue }
            writeLog("Closing lower-priority app copy; path=\(otherPath)")
            _ = other.terminate()
        }
        return true
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

        let title = NSTextField(labelWithString: "使用前请完成三项设置")
        title.font = .systemFont(ofSize: 15, weight: .semibold)

        let firstStep = NSTextField(labelWithString: "1. 在语音输入法设置中，将语音输入快捷键设为“长按 Fn”。")
        let secondStep = NSTextField(labelWithString: "2. 在 AirPods 设置中，将左耳“按住”设为唤醒 Siri。")
        let thirdStep = NSTextField(labelWithString: "3. 在隐私与安全性中，允许本 App 使用“辅助功能”。")
        let usage = NSTextField(labelWithString: "完成后，长按左耳开始说话，单击停止并发送。")
        for label in [firstStep, secondStep, thirdStep, usage] {
            label.maximumNumberOfLines = 0
            label.lineBreakMode = .byWordWrapping
            label.preferredMaxLayoutWidth = 320
        }
        usage.textColor = .secondaryLabelColor

        let stack = NSStackView(views: [title, firstStep, secondStep, thirdStep, usage])
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
        popover.contentSize = NSSize(width: 356, height: 230)
        instructionsPopover = popover
        popover.show(relativeTo: statusButton.bounds, of: statusButton, preferredEdge: .minY)
    }

    private func showStartFailure() {
        guard startFailureAlert == nil else { return }
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = "无法启动语音桥接"
        alert.alertStyle = .warning

        guard !CGPreflightPostEventAccess() else {
            alert.informativeText = "辅助功能权限已生效，但桥接器启动失败。请退出 App 后查看日志。"
            alert.addButton(withTitle: "知道了")
            startFailureAlert = alert
            alert.runModal()
            if startFailureAlert === alert { startFailureAlert = nil }
            return
        }

        _ = permissionRecoveryFlow.handle(.startupDenied)
        alert.informativeText = "请在“系统设置 → 隐私与安全性 → 辅助功能”中允许 AirPods Voice Bridge。已经打开开关时无需重复添加，请点击“已授权，重新启动”，让 macOS 在新进程中刷新权限。"
        alert.addButton(withTitle: "已授权，重新启动")
        alert.addButton(withTitle: "打开辅助功能设置")
        alert.addButton(withTitle: "取消")
        startFailureAlert = alert
        authorizationLoop: while true {
            let response = alert.runModal()
            switch response {
            case .alertFirstButtonReturn:
                if permissionRecoveryFlow.handle(.userConfirmedAuthorization) == .relaunch {
                    relaunchApplication()
                }
                break authorizationLoop
            case .alertSecondButtonReturn:
                guard permissionRecoveryFlow.handle(.openSettings) == .keepAuthorizationHelpOpen else {
                    break authorizationLoop
                }
                // Re-enter the modal session first, then put System Settings in front.
                // The authorization prompt remains ready behind it instead of disappearing.
                DispatchQueue.main.async { [weak self] in self?.openAccessibilitySettings() }
            default:
                break authorizationLoop
            }
        }
        if startFailureAlert === alert { startFailureAlert = nil }
    }

    private func openAccessibilitySettings() {
        guard let url = URL(
            string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility"
        ) else { return }
        NSWorkspace.shared.open(url)
    }

    private func relaunchApplication() {
        let appURL = Bundle.main.bundleURL
        guard appURL.pathExtension == "app" else {
            writeLog("Permission recovery relaunch refused; bundle path is not an app: \(appURL.path)")
            return
        }
        do {
            try scheduleDelayedLaunch(targetURL: appURL)
            writeLog("Accessibility authorization confirmed; relaunching app to refresh permission state")
            NSApp.terminate(nil)
        } catch {
            writeLog("Could not schedule permission recovery relaunch: \(error.localizedDescription)")
        }
    }

    @objc private func quitApplication() {
        NSApp.terminate(nil)
    }
}

if CommandLine.arguments.contains("--parser-test") {
    exit(runParserTests() ? 0 : 1)
}

if CommandLine.arguments.contains("--permission-recovery-test") {
    exit(runPermissionRecoveryTests() ? 0 : 1)
}

MainActor.assumeIsolated {
    let app = NSApplication.shared
    app.setActivationPolicy(.accessory)
    let delegate = AppDelegate()
    app.delegate = delegate
    app.run()
}
