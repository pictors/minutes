import AVFoundation
import Foundation
import MinutesCore
import Observation

/// 会議音声の再生（system.m4a と mic.m4a を同時に再生する）。時刻クリックで該当位置から再生。
@MainActor
@Observable
final class AudioPlayback {
    private(set) var isPlaying = false
    private(set) var currentTime: Double = 0
    private(set) var meetingId: String?
    /// 再生速度（1.0 / 1.25 / 1.5 / 2.0）。文字起こしの確認では速めが便利。
    var rate: Float = 1.0 {
        didSet { for player in players { player.rate = rate } }
    }
    static let rates: [Float] = [1.0, 1.25, 1.5, 2.0]
    private var players: [AVAudioPlayer] = []
    private var timer: Timer?
    private var loadTask: Task<Void, Never>?

    /// プレーヤーの作成（ファイルの解析・バッファの準備）はメインスレッドの外で行い、会議の切り替えを待たせない。
    /// 読み込み中に別の会議へ切り替えたら、前の結果は捨てる。
    func load(meeting: MeetingRecord) {
        stop()
        players = []
        loadTask?.cancel()
        meetingId = meeting.id
        guard let directory = meeting.audioDirectoryURL else { return }
        let urls = [RecordingSession.systemArchiveName, RecordingSession.micArchiveName].map { directory.appendingPathComponent($0) }
        let rate = rate
        let meetingId = meeting.id
        loadTask = Task { [weak self] in
            let loaded = await Task.detached(priority: .userInitiated) { LoadedPlayers(urls: urls, rate: rate) }.value
            guard let self, !Task.isCancelled, self.meetingId == meetingId else { return }
            players = loaded.players
        }
    }

    var isAvailable: Bool { !players.isEmpty }

    /// 前後にスキップする（秒）。
    func skip(by seconds: Double) {
        seek(to: currentTime + seconds)
    }

    /// 会議音声の長さ（秒）。system と mic は同時に始まるので先頭トラックで代表させる。
    var duration: Double { players.first?.duration ?? 0 }

    /// 再生位置を移動する。再生中なら新しい位置から続けて再生する。
    func seek(to seconds: Double) {
        guard !players.isEmpty else { return }
        if isPlaying {
            play(from: seconds)
        } else {
            for player in players { player.currentTime = min(max(0, seconds), player.duration) }
            currentTime = players[0].currentTime
        }
    }

    func play(from seconds: Double) {
        guard !players.isEmpty else { return }
        for player in players {
            player.currentTime = min(max(0, seconds), player.duration)
        }
        let startTime = players[0].deviceCurrentTime + 0.05
        for player in players {
            player.rate = rate
            player.play(atTime: startTime)
        }
        isPlaying = true
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.tick() }
        }
    }

    func toggle() {
        if isPlaying { pause() } else { play(from: currentTime) }
    }

    func pause() {
        for player in players { player.pause() }
        isPlaying = false
        timer?.invalidate()
    }

    func stop() {
        for player in players { player.stop() }
        isPlaying = false
        currentTime = 0
        timer?.invalidate()
    }

    private func tick() {
        guard let first = players.first else { return }
        currentTime = first.currentTime
        if !first.isPlaying { isPlaying = false; timer?.invalidate() }
    }
}

/// バックグラウンドで作ったプレーヤー。作成後は触らずにメインアクターへ渡すだけなので Sendable として扱う。
private struct LoadedPlayers: @unchecked Sendable {
    let players: [AVAudioPlayer]

    init(urls: [URL], rate: Float) {
        players = urls.compactMap { url in
            guard let player = try? AVAudioPlayer(contentsOf: url) else { return nil }
            player.enableRate = true
            player.rate = rate
            player.prepareToPlay()
            return player
        }
    }
}
