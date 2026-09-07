import Carbon
import Foundation

private func sourceID(_ source: TISInputSource) -> String? {
    guard let value = TISGetInputSourceProperty(source, kTISPropertyInputSourceID) else {
        return nil
    }
    return unsafeBitCast(value, to: CFString.self) as String
}

guard CommandLine.arguments.count >= 2 else { exit(64) }

if CommandLine.arguments[1] == "current" {
    let current = TISCopyCurrentKeyboardInputSource().takeRetainedValue()
    guard let identifier = sourceID(current) else { exit(1) }
    print(identifier)
    exit(0)
}

guard CommandLine.arguments[1] == "select", CommandLine.arguments.count == 3 else {
    exit(64)
}
let requestedID = CommandLine.arguments[2]
let sources = TISCreateInputSourceList(nil, true).takeRetainedValue() as! [TISInputSource]
guard let requested = sources.first(where: { sourceID($0) == requestedID }) else { exit(2) }
guard TISEnableInputSource(requested) == noErr,
      TISSelectInputSource(requested) == noErr else { exit(3) }
exit(0)
