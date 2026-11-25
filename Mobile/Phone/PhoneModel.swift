import Foundation
import MinutesKit
import Observation
import UIKit

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
    /// このアカウントのサーバーの一覧を一度でも読めたか。読めるまで（起動・ログインの直後）は、一覧が空でも「会議はまだありません」と言わない。
    /// 読み直し（引き下げ・アカウントのシート・前に出したとき）のあいだは true のまま（一覧の表示を変えない）。ログアウトで戻す
    private(set) var meetingsLoaded = false
    /// 一覧の上に出す知らせ（読み込みの失敗など）
    var banner: String?
    /// ログインの画面に出す知らせ（アカウントを消したあと）。次にログインしたら消す
    private(set) var signInNotice: String?

    let recorder: MeetingRecorder
    let uploads: UploadEngine
    let store: RecordingStore
    /// App 内課金（P6）
    let billing: BillingStore

    private static let noticeAcceptedKey = "recordingNoticeAccepted"

    init(store: RecordingStore = .standard) {
        self.store = store
        recorder = MeetingRecorder(source: "iphone", store: store)
        uploads = UploadEngine(store: store) { CloudEnvironment.client() }
        billing = BillingStore()
        isSignedIn = TokenStore.shared.isSignedIn
        user = TokenStore.shared.stored?.user
        recorder.onProgress = { [weak self] clientId in
            self?.uploads.kick(clientId)
            self?.reloadLocal()
        }
        uploads.onChange = { [weak self] _ in self?.reloadLocal() }
        // サーバーが購入を受け付けた: 量を読み直し、使える量で断られた送信（complete の 402）をやり直す
        billing.onChange = { [weak self] in
            self?.uploads.kickAll()
            Task { await self?.refresh() }
        }
    }

    /// テスト（StoreKit の試し。Mobile/PhoneTests）の中で動いているか。テストが取引を自分で送るので、アプリは取引を聞かない
    private static var isRunningTests: Bool { ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil }

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
        // App 内課金: 取引（自動更新・ほかの端末での購入・返金）は起動してすぐから聞き、終わっていない取引といまの権利をサーバーへ送る
        guard !Self.isRunningTests else {
            Task { await refresh() }
            return
        }
        billing.startListening()
        Task {
            await refresh()
            await billing.syncWithServer()
        }
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
        for recording in serverRecordings where recording.source == "iphone" || recording.source == "watch" || recording.isSyncedMeeting {
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
            // iPhone の一覧（iPhone・Watch の録音と、同期した Mac の会議）。古いサーバーは scope を見ないので、下でも選ぶ
            async let recordings = client.recordings(scope: .meetings)
            async let account = client.account()
            serverRecordings = try await recordings
            // 一覧と同じ更新で立てる（空の一覧なら、読み込みの印から「まだありません」へ一度で切り替わる）
            meetingsLoaded = true
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

    /// パスキーでログインする（端末にあるパスキーを選ぶ）。サーバーにないパスキーなら、端末の一覧から外すよう知らせる。
    func signInWithPasskey() async throws {
        try signedIn(try await passkeySession(), method: .passkey)
    }

    private func signedIn(_ session: MinutesCloudSession, method: TokenStore.Method) throws {
        let user = session.userID.map { MinutesCloudUser(id: $0, email: session.email) }
        try TokenStore.shared.save(token: session.token, user: user, method: method)
        self.user = user
        isSignedIn = true
        banner = nil
        signInNotice = nil
        uploads.kickAll()
        LoginRelay.shared.sendLogin()
        Task {
            await refresh()
            // ログインする前の購入（App Store・ほかの端末）も、このアカウントに送る
            if !Self.isRunningTests { await billing.syncWithServer() }
            // メールのコードで入った人に、パスキーを 1 度だけ勧める（ログインしたばかりのセッションなら、確かめ直さずに作れる）
            if method == .email { await offerPasskeyIfUseful() }
        }
    }

    // MARK: パスキー

    /// このアカウントのパスキー（アカウントの画面）。まだ読んでいない・読めなかったら nil
    private(set) var passkeys: [MinutesCloudPasskey]?
    /// ログインのあとに、パスキーを作るかを 1 度だけ聞く（RootView のシート）
    var passkeyOfferPending = false
    private let passkeyAuthorization = PasskeyAuthorization()
    private static let passkeyOfferedKey = "passkeyOffered"

    /// パスキーの一覧に出す名前（端末の種類。端末に付けた名前は送らない）
    private static var passkeyName: String { UIDevice.current.model }

    /// パスキーの一覧を読めなかった（アカウントの画面に出す）
    private(set) var passkeysUnavailable = false

    func loadPasskeys() async {
        guard isSignedIn else { return }
        do {
            passkeys = try await client.passkeys()
            passkeysUnavailable = false
        } catch where Self.isCancellation(error) {
            // 画面を離れた。前の一覧のまま
        } catch {
            passkeysUnavailable = passkeys == nil
        }
    }

    /// パスキーを作る。ログインから 1 日を過ぎていたら PasskeyFailure.needsReauthentication（確かめ直してから、もう一度呼ぶ）
    func createPasskey() async throws {
        let ceremony: MinutesCloudPasskeyCeremony<MinutesCloudPasskeyCreationOptions>
        do {
            ceremony = try await client.passkeyCreationOptions()
        } catch let error as MinutesCloudError where error.code == "SESSION_NOT_FRESH" {
            throw PasskeyFailure.needsReauthentication
        }
        let registration = try await passkeyAuthorization.register(ceremony.options)
        try await client.registerPasskey(registration, name: Self.passkeyName, cookie: ceremony.cookie)
        UserDefaults.standard.set(true, forKey: Self.passkeyOfferedKey)
        await loadPasskeys()
    }

    /// パスキーをアカウントから外し、端末のパスキーの一覧からも外すよう知らせる
    func deletePasskey(_ passkey: MinutesCloudPasskey) async throws {
        try await client.deletePasskey(id: passkey.id)
        if let credentialID = passkey.credentialIDData { await PasskeyAuthorization.reportUnknown(credentialID: credentialID) }
        passkeys?.removeAll { $0.id == passkey.id }
        await loadPasskeys()
    }

    /// 確かめ直す（パスキーを作る前。サーバーはログインから 1 日以内のセッションでしか作らせない）。
    /// 新しいセッションが、いまと同じ利用者のときだけ使う。別のアカウントに入ったら、そのセッションを取り消して断る。
    func reauthenticate(email: String, code: String) async throws {
        try await adoptReauthentication(try await client.signIn(email: email, code: code.trimmingCharacters(in: .whitespacesAndNewlines)), method: .email)
    }

    func reauthenticateWithApple(identityToken: String, nonce: MinutesCloudAppleNonce) async throws {
        try await adoptReauthentication(try await client.signInWithApple(identityToken: identityToken, rawNonce: nonce.raw), method: .apple)
    }

    func reauthenticateWithPasskey() async throws {
        try await adoptReauthentication(try await passkeySession(), method: .passkey)
    }

    /// どの方法でこの iPhone にログインしたか（確かめ直しで出す方法を選ぶ）
    var signInMethod: TokenStore.Method? { TokenStore.shared.stored?.method }

    private func adoptReauthentication(_ session: MinutesCloudSession, method: TokenStore.Method) async throws {
        guard let current = user?.id, session.userID == current else {
            // 別のアカウント（Apple の別のメールなど）: 入ったセッションはすぐ取り消し、いまのログインのまま
            let other = MinutesCloudClient(baseURL: client.baseURL, session: client.session) { session.token }
            try? await other.signOut()
            throw PasskeyFailure.differentAccount
        }
        // いまの印は取り消さない（Watch が新しい印を受け取るまで使う。使わなくなった印は期限で切れる）
        try signedIn(session, method: method)
    }

    private func passkeySession() async throws -> MinutesCloudSession {
        let ceremony = try await client.passkeySignInOptions()
        let assertion = try await passkeyAuthorization.assert(ceremony.options)
        do {
            return try await client.signIn(passkey: assertion, cookie: ceremony.cookie)
        } catch let error as MinutesCloudError where error.code == "PASSKEY_NOT_FOUND" {
            await PasskeyAuthorization.reportUnknown(credentialID: assertion.credentialID)
            throw error
        }
    }

    /// パスキーを勧めるか（この端末でまだ勧めていない・アカウントにパスキーがない）
    private func offerPasskeyIfUseful() async {
        guard !UserDefaults.standard.bool(forKey: Self.passkeyOfferedKey) else { return }
        await loadPasskeys()
        // 録音を始めていたら勧めない（録音の画面の上にシートを出さない）
        guard passkeys?.isEmpty == true, isSignedIn, !recorder.isActive else { return }
        UserDefaults.standard.set(true, forKey: Self.passkeyOfferedKey)
        passkeyOfferPending = true
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
        // 次にログインしたアカウントの一覧を読み終えるまで、「まだありません」と言わない
        meetingsLoaded = false
        passkeys = nil
        passkeysUnavailable = false
        passkeyOfferPending = false
        billing.reset()
        LoginRelay.shared.sendLogin()
    }

    /// アカウントを消す（サーバーの録音・文字起こし・要約も消える）。この端末の録音も消す。
    /// アカウントのパスキーは、端末のパスキーの一覧からも外すよう知らせる（読めなければ知らせずに消す）。
    func deleteAccount(appleAuthorizationCode: String?) async throws -> MinutesCloudAccountDeletion {
        let passkeyIDs = ((try? await client.passkeys()) ?? []).compactMap(\.credentialIDData)
        let result = try await client.deleteAccount(appleAuthorizationCode: appleAuthorizationCode, appleClientID: Bundle.main.bundleIdentifier)
        for credentialID in passkeyIDs { await PasskeyAuthorization.reportUnknown(credentialID: credentialID) }
        for upload in localUploads {
            uploads.cancel(upload.clientId)
            try? store.delete(clientId: upload.clientId)
        }
        signedOutLocally()
        reloadLocal()
        signInNotice = "アカウントを消しました"
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

    /// やることの済みを付ける・外す（サーバーの会議。iPhone・Watch の録音も、同期した Mac の会議も。Mac にも届く。P7）。
    func setActionDone(_ item: MeetingItem, actionID: String, done: Bool) async throws {
        guard let server = item.server else { return }
        try await client.setActionDone(recordingID: server.id, actionID: actionID, done: done)
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
