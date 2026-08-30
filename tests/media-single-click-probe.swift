import AppKit
import Foundation
import MediaPlayer

@MainActor
final class MediaSingleClickProbe {
    private var targets: [(MPRemoteCommand, Any)] = []

    func run() {
        let center = MPRemoteCommandCenter.shared()
        let commands: [(String, MPRemoteCommand)] = [
            ("play", center.playCommand),
            ("pause", center.pauseCommand),
            ("toggle", center.togglePlayPauseCommand),
        ]
        for (name, command) in commands {
            command.isEnabled = true
            let target = command.addTarget { _ in
                print("MEDIA_SINGLE_CLICK_RECEIVED command=\(name)")
                fflush(stdout)
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                    NSApp.terminate(nil)
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
