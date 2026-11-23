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

    func refresh() async {
        guard isSignedIn else { return }
        isRefreshing = true
        defer { isRefreshing = false }
        do {
            async let recordings = client.recordings()
            async let account = client.account()
            serverRecordings = try await recordings
            self.account = try await account
            banner = nil
            if let user = try? await client.currentUser() {
                self.user = user
                TokenStore.shared.update(user: user)
            }
        } catch let error as MinutesCloudError where error.status == 401 {
            signedOutLocally()
            banner = error.localizedDescription
        } catch {
            banner = "一覧を読めませんでした（\(error.localizedDescription)）"
        }
    }

    /// 送っている・サーバーで処理している会議があるか（あれば一覧を読み直し続ける）。
    var hasWorkInProgress: Bool {
        meetings.contains { item in
            if let local = item.local, !local.completed, local.lastError == nil { return true }
            if item.local?.completed == true, item.server == nil { return true }
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
            try? await client.deleteRecording(id: serverId)
        }
        uploads.cancel(item.id)
        try? store.delete(clientId: item.id)
        reloadLocal()
    }

    func retryUpload(_ item: MeetingItem) {
        uploads.kick(item.id)
    }

    func localAudioURL(_ item: MeetingItem) -> URL? {
        guard let upload = item.local, let run = upload.runs.first else { return nil }
        let url = store.runURL(upload, run)
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }
}
