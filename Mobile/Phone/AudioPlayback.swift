@preconcurrency import AVFoundation
import MinutesKit
import Observation

/// 会議の音声の再生（再生位置を全文の強調と合わせる）。サーバーの音声は一度ファイルに取ってから再生する。
@MainActor
@Observable
final class AudioPlayback {
    private(set) var isPlaying = false
    private(set) var isLoading = false
    private(set) var error: String?
    private(set) var currentTime: Double = 0
    private(set) var duration: Double = 0
    private var player: AVAudioPlayer?
    private var ticker: Task<Void, Never>?
    private var pendingSeek: Double?

    var isReady: Bool { player != nil }

    /// 音声を用意する（サーバーの音声があればそれを取り、なければこの iPhone の録音）。
    func load(remoteID: String?, localURL: URL?, client: MinutesCloudClient) async {
        guard player == nil, !isLoading else { return }
        isLoading = true
        defer { isLoading = false }
        do {
            if let remoteID {
                let url = FileManager.default.temporaryDirectory.appending(path: "minutes-audio-\(remoteID).aac")
                if !FileManager.default.fileExists(atPath: url.path) { try await client.downloadAudio(recordingID: remoteID, to: url) }
                try open(url)
            } else if let localURL {
                try open(localURL)
            }
            error = nil
            if let pendingSeek {
                self.pendingSeek = nil
                seek(to: pendingSeek)
                play()
            }
        } catch {
            self.error = "音声を読めません（\(error.localizedDescription)）"
        }
    }

    private func open(_ url: URL) throws {
        let player = try AVAudioPlayer(contentsOf: url)
        player.prepareToPlay()
        self.player = player
        duration = player.duration
    }

    func play() {
        guard let player else { return }
        try? AVAudioSession.sharedInstance().setCategory(.playback, mode: .spokenAudio)
        try? AVAudioSession.sharedInstance().setActive(true)
        player.play()
        isPlaying = true
        ticker?.cancel()
        ticker = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(200))
                guard let self, let player = self.player else { return }
                self.currentTime = player.currentTime
                if !player.isPlaying {
                    self.isPlaying = false
                    return
                }
            }
        }
    }

    func pause() {
        player?.pause()
        ticker?.cancel()
        isPlaying = false
        currentTime = player?.currentTime ?? currentTime
    }

    func toggle() {
        if isPlaying { pause() } else { play() }
    }

    func seek(to seconds: Double) {
        guard let player else {
            pendingSeek = seconds
            return
        }
        player.currentTime = max(0, min(seconds, player.duration))
        currentTime = player.currentTime
    }

    func stop() {
        ticker?.cancel()
        player?.stop()
        isPlaying = false
    }
}
