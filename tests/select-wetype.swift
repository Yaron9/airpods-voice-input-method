import Carbon
import Foundation

let targetID = "com.tencent.inputmethod.wetype.pinyin" as CFString
let filter = [kTISPropertyInputSourceID!: targetID] as CFDictionary
let sources = TISCreateInputSourceList(filter, true).takeRetainedValue() as NSArray
guard let source = sources.firstObject else {
    fputs("WeType input source is not installed\n", stderr)
    exit(1)
}
let result = TISSelectInputSource((source as! TISInputSource))
guard result == noErr else {
    fputs("Could not select WeType input source: \(result)\n", stderr)
    exit(1)
}
print("Selected WeType input source")
