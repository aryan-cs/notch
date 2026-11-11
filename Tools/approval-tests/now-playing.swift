// Plays silence as macOS's Now Playing for a while, so Notch shows its music
// display (album art and visualizer) during a test. Build it as an app:
//
//   mkdir -p NowPlaying.app/Contents/MacOS
//   swiftc now-playing.swift -o NowPlaying.app/Contents/MacOS/NowPlaying
//   (plus an Info.plist with a bundle identifier), then: open NowPlaying.app --args 20
import AppKit
import AVFoundation
import MediaPlayer

let seconds = Double(CommandLine.arguments.dropFirst().first ?? "20") ?? 20
let app = NSApplication.shared
app.setActivationPolicy(.accessory)

let wav = FileManager.default.temporaryDirectory.appendingPathComponent("notch-silence.wav")
do {
    let format = AVAudioFormat(standardFormatWithSampleRate: 44100, channels: 2)!
    let file = try AVAudioFile(forWriting: wav, settings: format.settings)
    let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(44100 * (seconds + 5)))!
    buffer.frameLength = buffer.frameCapacity
    try file.write(from: buffer)
}
let player = AVPlayer(url: wav)
// macOS only makes an app Now Playing once it takes play and pause commands.
for command in [MPRemoteCommandCenter.shared().playCommand, MPRemoteCommandCenter.shared().pauseCommand,
                MPRemoteCommandCenter.shared().togglePlayPauseCommand] {
    command.isEnabled = true
    command.addTarget { _ in .success }
}
player.play()
MPNowPlayingInfoCenter.default().nowPlayingInfo = [
    MPMediaItemPropertyTitle: "Notch test",
    MPMediaItemPropertyArtist: "Silence",
    MPMediaItemPropertyPlaybackDuration: seconds,
    MPNowPlayingInfoPropertyElapsedPlaybackTime: 0.0,
    MPNowPlayingInfoPropertyPlaybackRate: 1.0,
]
MPNowPlayingInfoCenter.default().playbackState = .playing
DispatchQueue.main.asyncAfter(deadline: .now() + seconds) {
    player.pause()
    MPNowPlayingInfoCenter.default().playbackState = .stopped
    MPNowPlayingInfoCenter.default().nowPlayingInfo = nil
    DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { exit(0) }
}
app.run()
