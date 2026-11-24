import Foundation
import MinutesKit
import Observation

/// iPhone のアプリの状態（ログイン・会議の一覧・録音・送信）。
@MainActor
@Observable
final class PhoneModel {
    private(set) var user: MinutesCloudUser?
    private(set) var isSignedIn: Bool
    private(set) var account: MinutesCloudAccount?
    private(set) var serverRecordings: [MinutesCloudRecording] = []
    private(set) var localUploads: [MinutesCloudUpload] = []
    private(set) var isRefreshing = false
    /// 一覧の上に出す知らせ（読み込みの失敗など）
    var banner: String?

    let recorder: MeetingRecorder
    let uploads: UploadEngine
    let store: RecordingStore

    private static let noticeAcceptedKey = "recordingNoticeAccepted"

    init(store: RecordingStore = .standard) {
        self.store = store
        recorder = MeetingRecorder(source: "iphone", store: store)
        uploads = UploadEngine(store: store) { CloudEnvironment.client() }
        isSignedIn = TokenStore.shared.isSignedIn
        user = TokenStore.shared.stored?.user
        recorder.onProgress = { [weak self] clientId in
            self?.uploads.kick(clientId)
            self?.reloadLocal()
        }
        uploads.onChange = { [weak self] _ in self?.reloadLocal() }
    }

    var client: MinutesCloudClient { CloudEnvironment.client() }

    /// 録音の告知と送信先の説明に同意したか（最初の録音の前に一度だけ聞く。ガイドライン 2.5.14）。
    var noticeAccepted: Bool {
        get { UserDefaults.standard.bool(forKey: Self.noticeAcceptedKey) }
        set { UserDefaults.standard.set(newValue, forKey: Self.noticeAcceptedKey) }
    }

    // MARK: 起動

    func onLaunch() {
        recoverUnfinished()
        reloadLocal()
        uploads.restore()
        // Watch にログインを渡す（Watch は受け取った印で録音を直接上げる）
        LoginRelay.shared.activate()
        Task { await refresh() }
    }

    func becameActive() {
        reloadLocal()
        uploads.kickAll()
        Task { await refresh() }
    }

    /// 録音の途中でアプリが終わった録音は、録れたところまでで止めて送る。
    private func recoverUnfinished() {
        for upload in store.all() where !upload.stopped && upload.clientId != recorder.clientId {
            try? store.update(clientId: upload.clientId) { $0.stop() }
        }
    }

    func reloadLocal() {
        localUploads = store.all()
    }

    // MARK: 一覧

    var meetings: [MeetingItem] {
        var items: [String: MeetingItem] = [:]
        for recording in serverRecordings where recording.source == "iphone" || recording.source == "watch" {
            items[recording.clientId] = MeetingItem(id: recording.clientId, local: nil, server: recording)
        }
        for upload in localUploads {
            items[upload.clientId, default: MeetingItem(id: upload.clientId)].local = upload
        }
        return items.values.sorted { $0.startedAt > $1.startedAt }
    }

    private var refreshTask: Task<Void, Never>?

    /// 一覧を読み直す。読んでいる途中なら、その読み込みが終わるのを待つ（同時に 2 つ走らせない）。
    /// 読み込みは呼んだ画面の仕事（引き下げての更新・アカウントのシート・処理中の見回り）とは別の Task で走らせ、画面が閉じたり
    /// 作り直されたりしても取り消さない（取り消すと URLSession が「キャンセルしました」で終わり、一覧の上に誤りとして出ていた）。
    func refresh() async {
        if let running = refreshTask {
            await running.value
            return
        }
        let task = Task { [weak self] in
            await self?.performRefresh()
            self?.refreshTask = nil
        }
        refreshTask = task
        await task.value
    }

    /// 取り消し（画面を離れた・アプリが裏へ回った）か。誤りとして出さない。
    nonisolated static func isCancellation(_ error: Error) -> Bool {
        if error is CancellationError { return true }
        if let urlError = error as? URLError, urlError.code == .cancelled { return true }
        return false
    }

    private func performRefresh() async {
        guard isSignedIn else { return }
        isRefreshing = true
        defer { isRefreshing = false }
        do {
            async let recordings = client.recordings()
            async let account = client.account()
            serverRecordings = try await recordings
            self.account = try await account
            banner = nil
            await resolveMissingServerRecordings()
            if let user = try? await client.currentUser() {
                self.user = user
                TokenStore.shared.update(user: user)
            }
        } catch let error as MinutesCloudError where error.status == 401 {
            banner = error.localizedDescription
            // 録音中は録音の画面を消さない（録音は端末に残り、ログインし直したら送る）
            if !recorder.isActive { signedOutLocally() }
        } catch where Self.isCancellation(error) {
            // 取り消しは誤りではない（前の知らせはそのまま。次の読み込みで消える）
        } catch {
            banner = "一覧を読めませんでした（\(error.localizedDescription)）"
        }
    }

    /// 送り終えたのに一覧（新しい 100 件）にない会議は、1 件ずつ読む。サーバーにない（別のアカウント・ほかの端末で消した）なら、その旨を残して読み直しをやめる。
    private func resolveMissingServerRecordings() async {
        let known = Set(serverRecordings.map(\.id))
        for upload in localUploads {
            guard upload.completed, upload.lastError == nil, let id = upload.serverId, !known.contains(id) else { continue }
            do {
                serverRecordings.append(try await client.recording(id: id))
            } catch let error as MinutesCloudError where error.status == 404 {
                try? store.update(clientId: upload.clientId) { $0.lastError = "このアカウントのサーバーにはありません" }
            } catch {
                continue
            }
        }
        reloadLocal()
    }

    /// 送っている・サーバーで処理している会議があるか（あれば一覧を読み直し続ける）。
    var hasWorkInProgress: Bool {
        meetings.contains { item in
            // 録音中の会議は数えない（録っているあいだずっと読み直さない）
            if item.id == recorder.clientId { return false }
            if let local = item.local, !local.completed, local.lastError == nil { return true }
            if item.local?.completed == true, item.local?.lastError == nil, item.server == nil { return true }
            return ["uploading", "queued", "transcribing", "summarizing"].contains(item.server?.status ?? "")
        }
    }

    /// 画面が出ているあいだ、処理中の会議があれば数秒ごとに読み直す（議事録ができたら一覧と詳細に出る）。
    func watchProgress() async {
        while !Task.isCancelled {
            try? await Task.sleep(for: .seconds(4))
            if isSignedIn, hasWorkInProgress, !isRefreshing { await refresh() }
        }
    }

    func reloadServerRecording(id: String) async {
        guard let recording = try? await client.recording(id: id) else { return }
        if let index = serverRecordings.firstIndex(where: { $0.id == id }) {
            serverRecordings[index] = recording
        } else {
            serverRecordings.insert(recording, at: 0)
        }
    }

    // MARK: ログイン

    func sendCode(email: String) async throws {
        try await client.sendSignInCode(email: email.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    func signIn(email: String, code: String) async throws {
        let session = try await client.signIn(email: email.trimmingCharacters(in: .whitespacesAndNewlines), code: code.trimmingCharacters(in: .whitespacesAndNewlines))
        try signedIn(session, method: .email)
    }

    func signInWithApple(identityToken: String, nonce: MinutesCloudAppleNonce) async throws {
        let session = try await client.signInWithApple(identityToken: identityToken, rawNonce: nonce.raw)
        try signedIn(session, method: .apple)
    }

    private func signedIn(_ session: MinutesCloudSession, method: TokenStore.Method) throws {
        let user = session.userID.map { MinutesCloudUser(id: $0, email: session.email) }
        try TokenStore.shared.save(token: session.token, user: user, method: method)
        self.user = user
        isSignedIn = true
        banner = nil
        uploads.kickAll()
        LoginRelay.shared.sendLogin()
        Task { await refresh() }
    }

    func signOut() async {
        try? await client.signOut()
        signedOutLocally()
    }

    private func signedOutLocally() {
        TokenStore.shared.clear()
        isSignedIn = false
        user = nil
        account = nil
        serverRecordings = []
        LoginRelay.shared.sendLogin()
    }

    /// アカウントを消す（サーバーの録音・文字起こし・要約も消える）。この端末の録音も消す。
    func deleteAccount(appleAuthorizationCode: String?) async throws -> MinutesCloudAccountDeletion {
        let result = try await client.deleteAccount(appleAuthorizationCode: appleAuthorizationCode, appleClientID: Bundle.main.bundleIdentifier)
        for upload in localUploads {
            uploads.cancel(upload.clientId)
            try? store.delete(clientId: upload.clientId)
        }
        signedOutLocally()
        reloadLocal()
        return result
    }

    var signedInWithApple: Bool { TokenStore.shared.stored?.method == .apple }

    // MARK: 会議

    func delete(_ item: MeetingItem) async throws {
        if let server = item.server {
            try await client.deleteRecording(id: server.id)
            serverRecordings.removeAll { $0.id == server.id }
        } else if let serverId = item.local?.serverId {
            // 一覧にない送り済みの録音: サーバーにもうなければ（404）そのまま消す。ほかの失敗は消さずに返す
            do {
                try await client.deleteRecording(id: serverId)
            } catch let error as MinutesCloudError where error.status == 404 {}
        }
        uploads.cancel(item.id)
        try? store.delete(clientId: item.id)
        reloadLocal()
    }

    /// 会議の題名を直す（サーバーにある会議）。空なら題名を消す。
    func rename(_ item: MeetingItem, title: String) async throws {
        guard let server = item.server else { return }
        let updated = try await client.updateRecording(id: server.id, title: title)
        if let index = serverRecordings.firstIndex(where: { $0.id == server.id }) { serverRecordings[index] = updated }
    }

    /// 話者の名前を直す（文字起こしのあと）。ラベル → 名前（空なら消す）。
    func renameSpeakers(_ item: MeetingItem, names: [String: String]) async throws {
        guard let server = item.server, !names.isEmpty else { return }
        _ = try await client.updateRecording(id: server.id, speakerNames: names)
    }

    func retryUpload(_ item: MeetingItem) {
        uploads.retry(item.id)
    }

    func localAudioURL(_ item: MeetingItem) -> URL? {
        guard let upload = item.local, let run = upload.runs.first else { return nil }
        let url = store.runURL(upload, run)
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }
}
