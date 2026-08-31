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

private let weTypeStoppedMarker = "AVCaptureSession_Tundra stopRunning"
private let logURL = URL(fileURLWithPath: "/tmp/airpods-voice-input-method/app.log")
private let stopRequestURL = URL(fileURLWithPath:
    ProcessInfo.processInfo.environment["AIRPODS_VOICE_INPUT_STOP_REQUEST_PATH"]
        ?? "/tmp/airpods-voice-input-method/stop.request")
private let showRequestURL = URL(fileURLWithPath:
    ProcessInfo.processInfo.environment["AIRPODS_VOICE_INPUT_SHOW_REQUEST_PATH"]
        ?? "/tmp/airpods-voice-input-method/show.request")
private let finalTextCommitDelay: TimeInterval = 0.50
private let finalSendDelay: TimeInterval = 0.25
private let focusRecoveryRetryInterval: TimeInterval = 0.10
private let maximumFocusRecoveryRetries = 10
private let singlePressDuplicateWindow: TimeInterval = 0.35
private let maximumFnHoldDuration: TimeInterval = 60.0
private let consumerUsagePage: UInt32 = 0x0c
private let playPauseUsage: UInt32 = 0xcd
private let bluetoothMediaRemoteSender = "SenderBundleIdentifier = <com.apple.bluetoothd>"
private let legacyBundleIdentifier = "com.yaron.airpods-siri-voice-bridge"
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
        "airpods-voice-input-relaunch", String(delay), launcherURL.path, targetURL.path,
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

private func isPlayPausePress(usagePage: UInt32, usage: UInt32, value: Int) -> Bool {
    usagePage == consumerUsagePage && usage == playPauseUsage && value != 0
}

private func isBluetoothMediaRemoteSource(_ sourceID: String?) -> Bool {
    sourceID?.contains(bluetoothMediaRemoteSender) == true
}

private func mediaRemoteSourceID(_ event: MPRemoteCommandEvent) -> String? {
    let object = event as NSObject
    let selector = NSSelectorFromString("sourceID")
    guard object.responds(to: selector) else { return nil }
    return object.value(forKey: "sourceID") as? String
}

private func processIsRunning(_ pid: pid_t) -> Bool {
    errno = 0
    return kill(pid, 0) == 0 || errno != ESRCH
}

private func postCGFnRelease() {
    guard let source = CGEventSource(stateID: .hidSystemState),
          let event = CGEvent(keyboardEventSource: source, virtualKey: 63, keyDown: false) else {
        return
    }
    event.type = .flagsChanged
    var flags = CGEventSource.flagsState(.hidSystemState)
    flags.remove(.maskSecondaryFn)
    event.flags = flags
    event.post(tap: .cghidEventTap)
}

private func runFnWatchdog(cancelURL: URL) -> Int32 {
    var byte: UInt8 = 0
    while true {
        let result = read(STDIN_FILENO, &byte, 1)
        if result == 0 { break }
        if result < 0 && errno != EINTR { break }
    }
    guard !FileManager.default.fileExists(atPath: cancelURL.path) else {
        try? FileManager.default.removeItem(at: cancelURL)
        return 0
    }
    let openResult = fnInjectorOpen()
    guard openResult == 0 else { return openResult }
    let releaseResult = fnInjectorPost(0)
    postCGFnRelease()
    fnInjectorClose()
    return releaseResult
}

private func keyboardRecoveryEventCallback(
    proxy: CGEventTapProxy, type: CGEventType, event: CGEvent,
    userInfo: UnsafeMutableRawPointer?
) -> Unmanaged<CGEvent>? {
    guard let userInfo else { return Unmanaged.passUnretained(event) }
    let controller = Unmanaged<AirPodsVoiceController>.fromOpaque(userInfo).takeUnretainedValue()
    MainActor.assumeIsolated {
        controller.handleKeyboardRecoveryEvent(type: type, event: event)
    }
    return Unmanaged.passUnretained(event)
}

@MainActor
private func applyStatusItemVisibilityPolicy(_ item: NSStatusItem) {
    item.autosaveName = nil
    item.behavior = []
    item.isVisible = true
}

@MainActor
private final class AirPodsVoiceController {
    private let voiceKey: VoiceActivationKey
    private(set) var isRunning = false
    private var logProcess: Process?
    private var logPipe: Pipe?
    private var hidManager: IOHIDManager?
    private var logWatcherGeneration: UInt64 = 0
    private var pendingLog = ""
    private var busy = false
    private var voiceKeyIsDown = false
    private var lastSinglePress = Date.distantPast
    private var targetApplication: NSRunningApplication?
    private var releaseTimer: Timer?
    private var holdIntegrityTimer: Timer?
    private var submitTimer: Timer?
    private var keyboardEventTap: CFMachPort?
    private var keyboardEventTapSource: CFRunLoopSource?
    private var fnWatchdogProcess: Process?
    private var fnWatchdogCancelURL: URL?
    private var fnWatchdogPipe: Pipe?
    private var remoteCommandTargets: [(command: MPRemoteCommand, target: Any)] = []

    init(voiceKey: VoiceActivationKey) {
        self.voiceKey = voiceKey
    }

    func start(watchLogs: Bool = true, monitorKeyboard: Bool = true) -> Bool {
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
            let currentFlags = CGEventSource.flagsState(.hidSystemState)
            if currentFlags.contains(.maskSecondaryFn) {
                guard fnInjectorPost(0) == 0 else {
                    writeLog("Could not clear stale Fn state during startup")
                    fnInjectorClose()
                    return false
                }
                postCGFnRelease()
                writeLog("Cleared stale Fn state during startup")
            }
        }
        guard !monitorKeyboard || startKeyboardRecoveryMonitor() else {
            writeLog("Keyboard recovery monitor could not start")
            fnInjectorClose()
            return false
        }
        let nextLogWatcherGeneration = logWatcherGeneration &+ 1
        guard watchLogs else {
            logWatcherGeneration = nextLogWatcherGeneration
            lastSinglePress = .distantPast
            isRunning = true
            activateRemoteStopControls()
            writeLog("AirPods Voice 输入法 ready in replay mode; voiceKey=\(voiceKey.name)")
            return true
        }

        startConsumerControlMonitor()

        let pipe = Pipe()
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/log")
        process.arguments = [
            "stream", "--style", "compact", "--level", "debug", "--predicate",
            "process == \"WeType\" AND eventMessage CONTAINS[c] \"AVCaptureSession_Tundra stopRunning\"",
        ]
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        pipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard !data.isEmpty, let text = String(data: data, encoding: .utf8) else { return }
            Task { @MainActor in
                self?.consumeLog(text, watcherGeneration: nextLogWatcherGeneration)
            }
        }
        do {
            try process.run()
            logProcess = process
            logPipe = pipe
            logWatcherGeneration = nextLogWatcherGeneration
            lastSinglePress = .distantPast
            isRunning = true
            activateRemoteStopControls()
            writeLog("AirPods Voice 输入法 active; voiceKey=\(voiceKey.name); start/stop=AirPods single press")
            return true
        } catch {
            writeLog("Could not start voice-input log watcher: \(error.localizedDescription)")
            return false
        }
    }

    func stop() {
        guard isRunning || voiceKeyIsDown else { return }
        isRunning = false
        logWatcherGeneration &+= 1
        releaseTimer?.invalidate()
        holdIntegrityTimer?.invalidate()
        submitTimer?.invalidate()
        releaseTimer = nil
        holdIntegrityTimer = nil
        submitTimer = nil
        stopKeyboardRecoveryMonitor()
        busy = false
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
        cancelFnWatchdog()
        fnInjectorClose()
    }

    private func startKeyboardRecoveryMonitor() -> Bool {
        guard keyboardEventTap == nil else { return true }
        let mask = CGEventMask(1) << CGEventType.keyDown.rawValue
        guard let tap = CGEvent.tapCreate(
            tap: .cghidEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: mask,
            callback: keyboardRecoveryEventCallback,
            userInfo: Unmanaged.passUnretained(self).toOpaque()) else { return false }
        let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
        keyboardEventTap = tap
        keyboardEventTapSource = source
        writeLog("Physical keyboard recovery monitor active")
        return true
    }

    private func stopKeyboardRecoveryMonitor() {
        if let source = keyboardEventTapSource {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes)
        }
        if let tap = keyboardEventTap { CFMachPortInvalidate(tap) }
        keyboardEventTapSource = nil
        keyboardEventTap = nil
    }

    func handleKeyboardRecoveryEvent(type: CGEventType, event: CGEvent) {
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            if let tap = keyboardEventTap { CGEvent.tapEnable(tap: tap, enable: true) }
            return
        }
        guard type == .keyDown, voiceKeyIsDown else { return }
        let sourcePID = event.getIntegerValueField(.eventSourceUnixProcessID)
        if CommandLine.arguments.contains("--keyboard-safety-test") {
            writeLog("Keyboard safety test observed keyDown; sourcePID=\(sourcePID)")
        }
        guard sourcePID != Int64(ProcessInfo.processInfo.processIdentifier) else { return }
        if voiceKey.usesFnHID {
            event.flags.remove(.maskSecondaryFn)
        } else if let modifierFlag = voiceKey.modifierFlag {
            event.flags.remove(modifierFlag)
        }
        writeLog("Physical keyboard input interrupted voice hold; releasing voice key")
        endVoiceKeyHold(reason: "physical keyboard input")
    }

    private func startFnWatchdog() -> Bool {
        guard voiceKey.usesFnHID else { return true }
        guard fnWatchdogProcess == nil, let executableURL = Bundle.main.executableURL else {
            return false
        }
        let cancelURL = logURL.deletingLastPathComponent()
            .appendingPathComponent("fn-watchdog-\(UUID().uuidString).cancel")
        try? FileManager.default.removeItem(at: cancelURL)
        let process = Process()
        let lifePipe = Pipe()
        process.executableURL = executableURL
        process.arguments = ["--fn-watchdog", cancelURL.path]
        process.standardInput = lifePipe
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        process.terminationHandler = { _ in try? FileManager.default.removeItem(at: cancelURL) }
        do {
            try process.run()
            fnWatchdogProcess = process
            fnWatchdogCancelURL = cancelURL
            fnWatchdogPipe = lifePipe
            return true
        } catch {
            writeLog("Could not start Fn watchdog: \(error.localizedDescription)")
            return false
        }
    }

    private func cancelFnWatchdog() {
        guard let cancelURL = fnWatchdogCancelURL else { return }
        FileManager.default.createFile(atPath: cancelURL.path, contents: Data())
        try? fnWatchdogPipe?.fileHandleForWriting.close()
        fnWatchdogProcess = nil
        fnWatchdogCancelURL = nil
        fnWatchdogPipe = nil
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

    private func consumeLog(_ text: String, watcherGeneration: UInt64) {
        guard isRunning, watcherGeneration == logWatcherGeneration else {
            writeLog("Ignored queued input-method log chunk from inactive watcher session")
            return
        }
        pendingLog.append(text)
        let lines = pendingLog.split(separator: "\n", omittingEmptySubsequences: false)
        pendingLog = String(lines.last ?? "")
        for line in lines.dropLast() { handleLogLine(String(line)) }
    }

    func handleLogLine(_ line: String) {
        guard line.contains(weTypeStoppedMarker) else { return }
        if voiceKeyIsDown { endVoiceKeyHold(reason: "WeType recording stopped") }
    }

    func handleAirPodsSinglePress() {
        writeLog("AirPods single press received; recording=\(voiceKeyIsDown)")
        guard isRunning else { return }
        let now = Date()
        guard now.timeIntervalSince(lastSinglePress) >= singlePressDuplicateWindow else {
            writeLog("Ignored duplicate AirPods single press")
            return
        }
        lastSinglePress = now
        if voiceKeyIsDown {
            endVoiceKeyHold(reason: "AirPods single press", submit: true)
            return
        }
        guard !busy else {
            writeLog("Ignored AirPods single press while submission is busy")
            return
        }
        busy = true
        targetApplication = NSWorkspace.shared.frontmostApplication
        let targetID = targetApplication?.bundleIdentifier ?? "unknown"
        let targetPID = targetApplication?.processIdentifier ?? 0
        writeLog("Single-click voice input starting; bundle=\(targetID); pid=\(targetPID)")
        beginVoiceKeyHold()
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
            let target = command.addTarget { [weak self] event in
                let sourceID = mediaRemoteSourceID(event)
                guard isBluetoothMediaRemoteSource(sourceID) else {
                    writeLog("Ignored non-Bluetooth media remote command; command=\(name); source=\(sourceID ?? "unknown")")
                    return .commandFailed
                }
                Task { @MainActor in
                    writeLog("Bluetooth media remote command received; command=\(name)")
                    self?.handleAirPodsSinglePress()
                }
                return .success
            }
            remoteCommandTargets.append((command, target))
        }
        let infoCenter = MPNowPlayingInfoCenter.default()
        infoCenter.nowPlayingInfo = [
            MPMediaItemPropertyTitle: "Voice Input",
            MPMediaItemPropertyArtist: "AirPods Voice 输入法",
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

    private func beginVoiceKeyHold() {
        guard startFnWatchdog() else {
            writeLog("Voice input refused because Fn watchdog is unavailable")
            busy = false
            return
        }
        guard postVoiceKey(down: true) else {
            cancelFnWatchdog()
            busy = false
            return
        }
        voiceKeyIsDown = true
        if voiceKey.usesFnHID {
            holdIntegrityTimer = Timer.scheduledTimer(
                withTimeInterval: 0.10, repeats: true
            ) { [weak self] _ in
                Task { @MainActor in self?.restoreFnHoldIfNeeded() }
            }
        }
        activateRemoteStopControls()
        writeLog("Voice key \(voiceKey.name) down; voice input held until AirPods single press")
        releaseTimer = Timer.scheduledTimer(withTimeInterval: maximumFnHoldDuration, repeats: false) { [weak self] _ in
            Task { @MainActor in self?.endVoiceKeyHold(reason: "60-second safety timeout") }
        }
    }

    private func endVoiceKeyHold(reason: String, submit: Bool = false) {
        releaseTimer?.invalidate()
        holdIntegrityTimer?.invalidate()
        releaseTimer = nil
        holdIntegrityTimer = nil
        let submitApplication = targetApplication
        if voiceKeyIsDown {
            _ = postVoiceKey(down: false)
            voiceKeyIsDown = false
            writeLog("Voice key \(voiceKey.name) up; voice input stopped; reason=\(reason)")
        }
        targetApplication = nil
        busy = submit
        guard submit else {
            busy = false
            return
        }
        submitTimer?.invalidate()
        submitTimer = Timer.scheduledTimer(withTimeInterval: finalTextCommitDelay, repeats: false) { [weak self] _ in
            Task { @MainActor in
                self?.submitVoiceInputIfFocusIsSafe(to: submitApplication)
            }
        }
    }

    private func restoreFnHoldIfNeeded() {
        guard voiceKeyIsDown, voiceKey.usesFnHID,
              !CGEventSource.flagsState(.hidSystemState).contains(.maskSecondaryFn) else {
            return
        }
        let result = fnInjectorPost(1)
        if result == 0 {
            writeLog("Fn hold was cleared externally; reasserted while voice input is active")
        } else {
            writeLog("Fn hold reassertion failed: 0x\(String(UInt32(bitPattern: result), radix: 16))")
            endVoiceKeyHold(reason: "Fn hold integrity failure")
        }
    }

    private func submitVoiceInputIfFocusIsSafe(
        to application: NSRunningApplication?, sendStage: Bool = false,
        focusRetriesRemaining: Int = maximumFocusRecoveryRetries
    ) {
        submitTimer = nil
        guard let application, !application.isTerminated else {
            writeLog("Return key skipped; original target is no longer running")
            busy = false
            return
        }
        guard NSWorkspace.shared.frontmostApplication?.processIdentifier
                == application.processIdentifier else {
            guard focusRetriesRemaining > 0 else {
                writeLog("Return key skipped; original target did not regain focus")
                busy = false
                return
            }
            if focusRetriesRemaining == maximumFocusRecoveryRetries {
                let stage = sendStage ? "send" : "commit"
                writeLog("Waiting for original target to regain focus; stage=\(stage)")
            }
            submitTimer = Timer.scheduledTimer(
                withTimeInterval: focusRecoveryRetryInterval, repeats: false
            ) { [weak self] _ in
                Task { @MainActor in
                    self?.submitVoiceInputIfFocusIsSafe(
                        to: application,
                        sendStage: sendStage,
                        focusRetriesRemaining: focusRetriesRemaining - 1)
                }
            }
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
            busy = false
            return
        }
        keyDown.flags = []
        keyUp.flags = []
        keyDown.post(tap: .cghidEventTap)
        keyUp.post(tap: .cghidEventTap)
        if sendStage {
            writeLog("Return key posted; stage=send; voice input submitted")
            busy = false
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
            if !down { postCGFnRelease() }
            if !down { cancelFnWatchdog() }
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
    guard isPlayPausePress(usagePage: 0x0c, usage: 0xcd, value: 1),
          !isPlayPausePress(usagePage: 0x0c, usage: 0xcd, value: 0),
          !isPlayPausePress(usagePage: 0x0c, usage: 0xe9, value: 1),
          !isPlayPausePress(usagePage: 0x01, usage: 0xcd, value: 1) else {
        fputs("CONSUMER CONTROL TEST FAILED: play/pause matching is incorrect\n", stderr)
        return false
    }
    let bluetoothSource = "SenderDevice = <Mac>, SenderBundleIdentifier = <com.apple.bluetoothd>, SenderPID = <442>"
    let keyboardSource = "SenderDevice = <Mac>, SenderBundleIdentifier = <com.apple.rcd>, SenderPID = <18882>"
    guard isBluetoothMediaRemoteSource(bluetoothSource),
          !isBluetoothMediaRemoteSource(keyboardSource),
          !isBluetoothMediaRemoteSource(nil) else {
        fputs("MEDIA REMOTE SOURCE TEST FAILED: only bluetoothd may trigger voice input\n", stderr)
        return false
    }
    guard VoiceActivationKey.supportedNames.allSatisfy({ VoiceActivationKey.parse($0) != nil }),
          VoiceActivationKey.parse("OPTION")?.name == "option",
          configuredVoiceKey(arguments: ["app"])?.name == "fn",
          configuredVoiceKey(arguments: ["app", "--voice-key", "option"])?.name == "option",
          configuredVoiceKey(arguments: ["app", "--voice-key"]) == nil,
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
    guard installationPriority(path: "/Applications/App.app", homeDirectory: "/Users/test") == 2,
          installationPriority(path: "/Users/test/Applications/App.app", homeDirectory: "/Users/test") == 1,
          installationPriority(path: "/Users/test/Downloads/App.app", homeDirectory: "/Users/test") == 0,
          shouldYieldToOtherInstance(
            ownPath: "/Users/test/Downloads/App.app", ownPID: 200,
            otherPath: "/Users/test/Applications/App.app", otherPID: 300,
            homeDirectory: "/Users/test"),
          !shouldYieldToOtherInstance(
            ownPath: "/Users/test/Applications/App.app", ownPID: 300,
            otherPath: "/Users/test/Downloads/App.app", otherPID: 200,
            homeDirectory: "/Users/test") else {
        fputs("INSTANCE PRIORITY TEST FAILED\n", stderr)
        return false
    }
    print("MEDIA SOURCE TEST PASSED: only bluetoothd remote events are accepted")
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
        .appendingPathComponent("airpods-voice-input-permission-relaunch-\(UUID().uuidString)")
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
private func makeStatusIcon(running: Bool) -> NSImage? {
    let description = running ? "AirPods Voice 输入法运行中" : "AirPods Voice 输入法已停止"
    guard let symbol = NSImage(systemSymbolName: "airpods", accessibilityDescription: description)
    else { return nil }
    let configuration = NSImage.SymbolConfiguration(pointSize: 15, weight: .medium)
    let image = symbol.withSymbolConfiguration(configuration) ?? symbol
    image.isTemplate = true
    return image
}

@MainActor
private func runStatusIconTest() -> Bool {
    guard let running = makeStatusIcon(running: true),
          let stopped = makeStatusIcon(running: false),
          running.isTemplate, stopped.isTemplate,
          running.size.width > 0, running.size.height > 0,
          stopped.size.width > 0, stopped.size.height > 0 else {
        fputs("STATUS ICON TEST FAILED: AirPods template symbol is unavailable\n", stderr)
        return false
    }
    print("STATUS ICON TEST PASSED: AirPods template symbol is available for both states")
    return true
}

@MainActor
private func runStatusItemVisibilityTest() -> Bool {
    let item = NSStatusBar.system.statusItem(withLength: 18)
    defer { NSStatusBar.system.removeStatusItem(item) }
    item.isVisible = false
    item.autosaveName = "AirPodsVoiceInputMethodHiddenTest"
    item.behavior = [.terminationOnRemoval]
    applyStatusItemVisibilityPolicy(item)
    guard item.isVisible, item.autosaveName != "AirPodsVoiceInputMethodHiddenTest",
          !item.behavior.contains(.terminationOnRemoval) else {
        let autosaveName = item.autosaveName ?? "nil"
        fputs(
            "STATUS VISIBILITY TEST FAILED: visible=\(item.isVisible) autosave=\(autosaveName) behavior=\(item.behavior.rawValue)\n",
            stderr)
        return false
    }
    print("STATUS VISIBILITY TEST PASSED: status item is forced visible and cannot be removed")
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
    private var controlWindow: NSPanel?
    private var controlStatusLabel: NSTextField?
    private var controlToggleButton: NSButton?
    private var permissionRecoveryFlow = AccessibilityPermissionRecoveryFlow()

    func applicationDidFinishLaunching(_ notification: Notification) {
        let selfTest = CommandLine.arguments.contains("--self-test")
        let returnTest = CommandLine.arguments.contains("--return-test")
        let stopStartDuringSubmitTest = CommandLine.arguments.contains(
            "--stop-start-during-submit-test")
        let singleClickCycleTest = CommandLine.arguments.contains("--single-click-cycle-test")
        let keyboardSafetyTest = CommandLine.arguments.contains("--keyboard-safety-test")
        let crashWatchdogTest = CommandLine.arguments.contains("--crash-watchdog-test")
        let replayTest = selfTest || returnTest || stopStartDuringSubmitTest
            || singleClickCycleTest || keyboardSafetyTest || crashWatchdogTest
        if !replayTest {
            guard stopLegacyVersion(), enforcePreferredInstance() else {
                NSApp.terminate(nil)
                return
            }
        }

        let stopRequestTimer = Timer(timeInterval: 0.1, repeats: true) { [weak self] _ in
            if FileManager.default.fileExists(atPath: showRequestURL.path) {
                try? FileManager.default.removeItem(at: showRequestURL)
                Task { @MainActor in self?.showControlWindow() }
            }
            if FileManager.default.fileExists(atPath: stopRequestURL.path) {
                try? FileManager.default.removeItem(at: stopRequestURL)
                writeLog("Graceful stop requested")
                NSApp.terminate(nil)
            }
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
        let controller = AirPodsVoiceController(voiceKey: voiceKey)
        self.controller = controller
        if !replayTest {
            configureStatusMenu()
            showControlWindow()
        }
        guard controller.start(
            watchLogs: !replayTest, monitorKeyboard: !crashWatchdogTest
        ) else {
            if replayTest {
                NSApp.terminate(nil)
            } else {
                updateStatusMenu()
                showStartFailure()
            }
            return
        }
        updateStatusMenu()
        if keyboardSafetyTest || crashWatchdogTest {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
                controller.handleAirPodsSinglePress()
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 10.0) {
                NSApp.terminate(nil)
            }
        } else if singleClickCycleTest {
            for cycle in 0..<4 {
                let start = 0.2 + Double(cycle) * 2.0
                DispatchQueue.main.asyncAfter(deadline: .now() + start) {
                    controller.handleAirPodsSinglePress()
                }
                DispatchQueue.main.asyncAfter(deadline: .now() + start + 0.8) {
                    controller.handleAirPodsSinglePress()
                }
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 8.8) {
                NSApp.terminate(nil)
            }
        } else if stopStartDuringSubmitTest {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
                controller.handleAirPodsSinglePress()
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
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.9) {
                controller.handleAirPodsSinglePress()
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.4) {
                controller.stop()
                NSApp.terminate(nil)
            }
        } else if selfTest {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
                controller.handleAirPodsSinglePress()
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) {
                controller.handleAirPodsSinglePress()
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 3.0) {
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

    func applicationShouldHandleReopen(
        _ sender: NSApplication, hasVisibleWindows flag: Bool
    ) -> Bool {
        writeLog("Application reopened; showing control window")
        showControlWindow()
        return true
    }

    private func stopLegacyVersion() -> Bool {
        let legacyApps = NSRunningApplication.runningApplications(
            withBundleIdentifier: legacyBundleIdentifier)
            .filter { !$0.isTerminated }
        guard !legacyApps.isEmpty else { return true }
        writeLog("Stopping pre-1.0 app before starting the renamed 1.0 release")
        let legacyPIDs = legacyApps.map(\.processIdentifier)
        for app in legacyApps { _ = app.terminate() }
        let deadline = Date().addingTimeInterval(3)
        while legacyPIDs.contains(where: processIsRunning), Date() < deadline {
            Thread.sleep(forTimeInterval: 0.05)
        }
        guard legacyPIDs.allSatisfy({ !processIsRunning($0) }) else {
            writeLog("Pre-1.0 app did not stop; refusing to start a duplicate controller")
            return false
        }
        return true
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
            FileManager.default.createFile(atPath: showRequestURL.path, contents: Data())
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
        let item = NSStatusBar.system.statusItem(withLength: 18)
        applyStatusItemVisibilityPolicy(item)
        statusItem = item
        item.button?.toolTip = "AirPods Voice 输入法"
        item.button?.imagePosition = .imageOnly

        let menu = NSMenu()
        let titleItem = NSMenuItem(title: "AirPods Voice 输入法", action: nil, keyEquivalent: "")
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
            title: "停止", action: #selector(toggleVoiceInput), keyEquivalent: "")
        toggleItem.target = self
        self.toggleItem = toggleItem
        menu.addItem(toggleItem)

        let instructionsItem = NSMenuItem(
            title: "使用说明…", action: #selector(showInstructions), keyEquivalent: "")
        instructionsItem.target = self
        menu.addItem(instructionsItem)

        let controlItem = NSMenuItem(
            title: "显示控制窗口…", action: #selector(showControlWindowFromMenu),
            keyEquivalent: "")
        controlItem.target = self
        menu.addItem(controlItem)
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
        controlStatusLabel?.stringValue = running ? "状态：运行中" : "状态：已停止"
        controlToggleButton?.title = running ? "停止" : "启动"
        statusItem?.button?.toolTip = running
            ? "AirPods Voice 输入法：运行中"
            : "AirPods Voice 输入法：已停止"
        statusItem?.button?.image = makeStatusIcon(running: running)
    }

    @objc private func toggleVoiceInput() {
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

    @objc private func showControlWindowFromMenu() {
        showControlWindow()
    }

    private func showControlWindow() {
        statusItem?.isVisible = true
        if let window = controlWindow {
            NSApp.activate(ignoringOtherApps: true)
            window.makeKeyAndOrderFront(nil)
            updateStatusMenu()
            return
        }

        let title = NSTextField(labelWithString: "AirPods Voice 输入法")
        title.font = .systemFont(ofSize: 18, weight: .semibold)
        let status = NSTextField(labelWithString: "状态：正在启动")
        status.textColor = .secondaryLabelColor
        controlStatusLabel = status

        let toggle = NSButton(
            title: "停止", target: self, action: #selector(toggleVoiceInput))
        toggle.bezelStyle = .rounded
        controlToggleButton = toggle
        let instructions = NSButton(
            title: "使用说明", target: self, action: #selector(showInstructions))
        instructions.bezelStyle = .rounded
        let buttons = NSStackView(views: [toggle, instructions])
        buttons.orientation = .horizontal
        buttons.spacing = 10

        let hint = NSTextField(
            wrappingLabelWithString: "再次打开 App 会显示此窗口；菜单栏图标会同时恢复可见。")
        hint.textColor = .secondaryLabelColor
        let stack = NSStackView(views: [title, status, buttons, hint])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 12
        stack.edgeInsets = NSEdgeInsets(top: 20, left: 20, bottom: 20, right: 20)
        stack.translatesAutoresizingMaskIntoConstraints = false

        let container = NSView()
        container.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            stack.topAnchor.constraint(equalTo: container.topAnchor),
            stack.bottomAnchor.constraint(equalTo: container.bottomAnchor),
            container.widthAnchor.constraint(equalToConstant: 360),
        ])

        let window = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 360, height: 190),
            styleMask: [.titled, .closable, .utilityWindow],
            backing: .buffered,
            defer: false)
        window.title = "AirPods Voice 输入法"
        window.isReleasedWhenClosed = false
        window.contentView = container
        window.center()
        controlWindow = window
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
        updateStatusMenu()
        writeLog("Control window shown; statusItemVisible=\(statusItem?.isVisible == true)")
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
        let secondStep = NSTextField(labelWithString: "2. App 运行时，AirPods 单击将专用于语音输入，不能控制媒体播放。")
        let thirdStep = NSTextField(labelWithString: "3. 在隐私与安全性中，允许本 App 使用“辅助功能”。")
        let usage = NSTextField(labelWithString: "完成后，单击一次开始说话，再单击一次停止并发送。")
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
        alert.messageText = "无法启动 AirPods Voice 输入法"
        alert.alertStyle = .warning

        guard !CGPreflightPostEventAccess() else {
            alert.informativeText = "辅助功能权限已生效，但 App 启动失败。请退出 App 后查看日志。"
            alert.addButton(withTitle: "知道了")
            startFailureAlert = alert
            alert.runModal()
            if startFailureAlert === alert { startFailureAlert = nil }
            return
        }

        _ = permissionRecoveryFlow.handle(.startupDenied)
        alert.informativeText = "请在“系统设置 → 隐私与安全性 → 辅助功能”中允许 AirPods Voice 输入法。已经打开开关时无需重复添加，请点击“已授权，重新启动”，让 macOS 在新进程中刷新权限。"
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

if let watchdogIndex = CommandLine.arguments.firstIndex(of: "--fn-watchdog") {
    let cancelIndex = CommandLine.arguments.index(after: watchdogIndex)
    guard cancelIndex < CommandLine.arguments.endIndex else { exit(64) }
    exit(runFnWatchdog(cancelURL: URL(fileURLWithPath: CommandLine.arguments[cancelIndex])))
}

if CommandLine.arguments.contains("--release-fn") {
    let openResult = fnInjectorOpen()
    guard openResult == 0 else { exit(openResult) }
    let releaseResult = fnInjectorPost(0)
    postCGFnRelease()
    fnInjectorClose()
    exit(releaseResult)
}

if CommandLine.arguments.contains("--fn-is-down") {
    exit(CGEventSource.flagsState(.hidSystemState).contains(.maskSecondaryFn) ? 0 : 1)
}

if CommandLine.arguments.contains("--post-space") {
    guard let source = CGEventSource(stateID: .combinedSessionState),
          let down = CGEvent(keyboardEventSource: source, virtualKey: 49, keyDown: true),
          let up = CGEvent(keyboardEventSource: source, virtualKey: 49, keyDown: false) else {
        exit(1)
    }
    down.flags = CGEventSource.flagsState(.hidSystemState)
    up.flags = []
    down.post(tap: .cghidEventTap)
    usleep(50_000)
    up.post(tap: .cghidEventTap)
    exit(0)
}

if CommandLine.arguments.contains("--parser-test") {
    exit(runParserTests() ? 0 : 1)
}

if CommandLine.arguments.contains("--permission-recovery-test") {
    exit(runPermissionRecoveryTests() ? 0 : 1)
}

if CommandLine.arguments.contains("--status-icon-test") {
    let passed = MainActor.assumeIsolated { runStatusIconTest() }
    exit(passed ? 0 : 1)
}

if CommandLine.arguments.contains("--status-visibility-test") {
    let passed = MainActor.assumeIsolated {
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)
        return runStatusItemVisibilityTest()
    }
    exit(passed ? 0 : 1)
}

MainActor.assumeIsolated {
    let app = NSApplication.shared
    app.setActivationPolicy(.accessory)
    let delegate = AppDelegate()
    app.delegate = delegate
    app.run()
}
