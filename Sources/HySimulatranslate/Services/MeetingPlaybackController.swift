import AVFoundation
import Foundation

@MainActor
final class MeetingPlaybackController: NSObject, ObservableObject, @preconcurrency AVAudioPlayerDelegate {
    @Published private(set) var isPlaying = false
    @Published private(set) var currentTime: TimeInterval = 0
    @Published private(set) var duration: TimeInterval = 0
    @Published private(set) var highlightedSegmentID: UUID?

    private var player: AVAudioPlayer?
    private var segments: [TranscriptSegmentRecord] = []
    private var timer: Timer?

    func load(url: URL, segments: [TranscriptSegmentRecord]) throws {
        unload()
        let player = try AVAudioPlayer(contentsOf: url)
        player.delegate = self
        player.prepareToPlay()
        self.player = player
        self.segments = segments
        duration = player.duration
        currentTime = 0
        highlightedSegmentID = Self.highlightedSegmentID(at: 0, segments: segments)
    }

    func unload() {
        player?.stop()
        player = nil
        segments = []
        isPlaying = false
        currentTime = 0
        duration = 0
        highlightedSegmentID = nil
        stopTimer()
    }

    func play() {
        guard player?.play() == true else { return }
        isPlaying = true
        startTimer()
    }

    func pause() {
        player?.pause()
        isPlaying = false
        stopTimer()
        updateTime()
    }

    func seek(to time: TimeInterval) {
        let bounded = min(max(0, time), duration)
        player?.currentTime = bounded
        currentTime = bounded
        highlightedSegmentID = Self.highlightedSegmentID(at: bounded, segments: segments)
    }

    func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        isPlaying = false
        stopTimer()
        updateTime()
    }

    nonisolated static func highlightedSegmentID(at time: TimeInterval, segments: [TranscriptSegmentRecord]) -> UUID? {
        segments.first { time >= $0.startTime && time < $0.endTime }?.id
    }

    private func startTimer() {
        stopTimer()
        timer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.updateTime() }
        }
    }

    private func stopTimer() {
        timer?.invalidate()
        timer = nil
    }

    private func updateTime() {
        guard let player else { return }
        currentTime = player.currentTime
        highlightedSegmentID = Self.highlightedSegmentID(at: currentTime, segments: segments)
    }
}
