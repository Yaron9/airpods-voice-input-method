import AppKit
import Foundation
import MediaPlayer

@MainActor
final class MediaSingleClickProbe {
    private var targets: [(MPRemoteCommand, Any)] = []
    private var received = 0

    func run() {
        let center = MPRemoteCommandCenter.shared()
        let commands: [(String, MPRemoteCommand)] = [
            ("play", center.playCommand),
            ("pause", center.pauseCommand),
            ("toggle", center.togglePlayPauseCommand),
        ]
        for (name, command) in commands {
            command.isEnabled = true
            let target = command.addTarget { [weak self] event in
                guard let self else { return .commandFailed }
                self.received += 1
                let object = event as NSObject
                func inspectedValue(_ key: String) -> Any {
                    let selector = NSSelectorFromString(key)
                    return object.responds(to: selector) ? object.value(forKey: key) : "nil"
                }
                let sourceID = inspectedValue("sourceID")
                let interfaceID = inspectedValue("interfaceID")
                let contextID = inspectedValue("contextID")
                let options = inspectedValue("mediaRemoteOptions")
                print("MEDIA_SINGLE_CLICK_RECEIVED command=\(name) class=\(type(of: event)) sourceID=\(sourceID) interfaceID=\(interfaceID) contextID=\(contextID) options=\(options) timestamp=\(event.timestamp)")
                fflush(stdout)
                if self.received >= 2 {
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                        NSApp.terminate(nil)
                    }
                }
                return .success
            }
            targets.append((command, target))
        }
        MPNowPlayingInfoCenter.default().nowPlayingInfo = [
            MPMediaItemPropertyTitle: "Voice Input Ready",
            MPMediaItemPropertyArtist: "AirPods Voice Bridge Probe",
            MPNowPlayingInfoPropertyIsLiveStream: true,
            MPNowPlayingInfoPropertyPlaybackRate: 1.0,
        ]
        MPNowPlayingInfoCenter.default().playbackState = .playing
        print("MEDIA_SINGLE_CLICK_PROBE_READY")
        fflush(stdout)
    }
}

MainActor.assumeIsolated {
    let app = NSApplication.shared
    let probe = MediaSingleClickProbe()
    probe.run()
    app.run()
}
