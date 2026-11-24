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
    /// 再生の速さ。止めても、次に再生するときもそのまま（画面を閉じるまで）
    private(set) var rate: Float = 1
    static let rates: [Float] = [1, 1.25, 1.5, 2]
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
                try open(try await download(remoteID, client: client))
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

    /// サーバーの音声を一時フォルダに取る（取ってあれば使う）。AVAudioPlayer は拡張子で読み方を決めるので、中身に合う拡張子にする
    /// （iPhone・Watch の録音は ADTS の AAC。ほかの道で上げた音声は M4A のこともある）。
    private func download(_ recordingID: String, client: MinutesCloudClient) async throws -> URL {
        let directory = FileManager.default.temporaryDirectory
        for ext in ["aac", "m4a"] {
            let cached = directory.appending(path: "minutes-audio-\(recordingID).\(ext)")
            if FileManager.default.fileExists(atPath: cached.path) { return try matchingExtension(cached, recordingID: recordingID) }
        }
        let partial = directory.appending(path: "minutes-audio-\(recordingID).download")
        try await client.downloadAudio(recordingID: recordingID, to: partial)
        return try matchingExtension(partial, recordingID: recordingID)
    }

    /// 中身（先頭の数バイト）に合う拡張子の名前に置き直す（M4A なら .m4a、ほかは ADTS の .aac）
    private func matchingExtension(_ file: URL, recordingID: String) throws -> URL {
        let head = (try? FileHandle(forReadingFrom: file)).flatMap { handle in
            defer { try? handle.close() }
            return try? handle.read(upToCount: 8)
        } ?? Data()
        let isMP4 = head.count >= 8 && head[4..<8].elementsEqual("ftyp".utf8)
        let url = FileManager.default.temporaryDirectory.appending(path: "minutes-audio-\(recordingID).\(isMP4 ? "m4a" : "aac")")
        guard url != file else { return file }
        try? FileManager.default.removeItem(at: url)
        try FileManager.default.moveItem(at: file, to: url)
        return url
    }

    private func open(_ url: URL) throws {
        let player = try AVAudioPlayer(contentsOf: url)
        // 速さを変えるには、用意の前に許す（AVAudioPlayer.enableRate）
        player.enableRate = true
        player.rate = rate
        player.prepareToPlay()
        self.player = player
        duration = player.duration
    }

    func play() {
        guard let player else { return }
        try? AVAudioSession.sharedInstance().setCategory(.playback, mode: .spokenAudio)
        try? AVAudioSession.sharedInstance().setActive(true)
        player.rate = rate
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

    /// 前後へ送る（15 秒戻す・送るなど）。音声の端で止める
    func skip(by seconds: Double) {
        guard let player else { return }
        seek(to: player.currentTime + seconds)
    }

    /// 次の速さにする（1 → 1.25 → 1.5 → 2 → 1）
    func cycleRate() {
        let index = Self.rates.firstIndex(of: rate) ?? 0
        rate = Self.rates[(index + 1) % Self.rates.count]
        player?.rate = rate
    }

    func stop() {
        ticker?.cancel()
        player?.stop()
        isPlaying = false
    }
}
