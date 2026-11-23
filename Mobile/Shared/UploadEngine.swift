import Foundation
import MinutesKit

/// 端末の録音を Pictors のサーバーへ上げる（iPhone と Watch で共通。製品版の P4）。
/// 録音を作る・区切りを上げる・complete の 3 つを、どれも裏の URLSession のファイルからの送信で行う（アプリが眠っても OS が続ける）。
/// - 送信の結果は delegate の中で、その場で upload.json に書く（裏で起こされてすぐ眠っても失わない。P1 の所見）。
/// - 同じ送信が重なっても、サーバーは client_id と、走と位置で重ねるので二重にはならない。
/// - 失敗した送信はすぐには繰り返さない。次のきっかけ（録音が進んだ・アプリが前に出た・ほかの送信が終わった・ログインした）で続ける。
final class UploadEngine: NSObject, @unchecked Sendable {
    static let sessionIdentifier = (Bundle.main.bundleIdentifier ?? "jp.pictors.minutes") + ".upload"

    let store: RecordingStore
    private let makeClient: @Sendable () -> MinutesCloudClient?
    /// 記録（upload.json）と送信の状態を守る鍵。録音する側と同じ鍵（RecordingStore.lock）
    private var lock: NSRecursiveLock { RecordingStore.lock }
    private let queue = DispatchQueue(label: "jp.pictors.minutes.upload")
    /// 送っている途中の送信（taskDescription）
    private var inFlight: Set<String> = []
    private var bodies: [Int: Data] = [:]
    /// 閉じたファイルと区切りを比べ終えた走（client_id/走）
    private var verified: Set<String> = []
    private var session: URLSession!
    /// 裏で起こされたときに OS へ返す完了の知らせ（iPhone: application(_:handleEventsForBackgroundURLSession:completionHandler:)）
    @MainActor var backgroundCompletion: (() -> Void)?
    /// 録音の送り具合が変わった（client_id）
    @MainActor var onChange: ((String) -> Void)?

    init(store: RecordingStore = .standard, makeClient: @escaping @Sendable () -> MinutesCloudClient?) {
        self.store = store
        self.makeClient = makeClient
        super.init()
        let configuration = URLSessionConfiguration.background(withIdentifier: Self.sessionIdentifier)
        configuration.sessionSendsLaunchEvents = true
        configuration.isDiscretionary = false
        configuration.httpCookieAcceptPolicy = .never
        configuration.httpShouldSetCookies = false
        configuration.httpCookieStorage = nil
        configuration.urlCache = nil
        session = URLSession(configuration: configuration, delegate: self, delegateQueue: nil)
    }

    /// 起動したとき: 前の起動から続いている送信を数え直してから、残りを続ける。
    func restore() {
        session.getAllTasks { [self] tasks in
            lock.withLock { inFlight = Set(tasks.compactMap(\.taskDescription)) }
            kickAll()
        }
    }

    func kickAll() {
        queue.async { [self] in
            for upload in store.all() where !upload.completed { step(clientId: upload.clientId) }
        }
    }

    func kick(_ clientId: String) {
        queue.async { [self] in step(clientId: clientId) }
    }

    /// この録音の送っている途中の送信をやめる（録音を消すとき）。
    func cancel(_ clientId: String) {
        session.getAllTasks { [self] tasks in
            for task in tasks where task.taskDescription.flatMap(TaskKey.init)?.clientId == clientId { task.cancel() }
            lock.withLock { inFlight = inFlight.filter { TaskKey($0)?.clientId != clientId } }
        }
    }

    // MARK: 進める

    private func step(clientId: String) {
        lock.lock()
        defer { lock.unlock() }
        guard var upload = try? store.load(clientId: clientId), !upload.completed else { return }
        let sizes = store.fileSizes(upload)
        if upload.isEmpty(fileSizes: sizes) {
            try? store.delete(clientId: clientId)
            notify(clientId)
            return
        }
        guard CloudEnvironment.uploadsAllowed, let client = makeClient(), client.token() != nil else { return }
        guard let serverId = upload.serverId else {
            startCreate(upload, client: client)
            return
        }
        var changed = !upload.planParts(fileSizes: sizes).isEmpty
        // 閉じた走は、切り出したときのバイト列と閉じたファイルを比べる（違えば上げ直す）
        for run in upload.runs where run.finished && !verified.contains("\(clientId)/\(run.index)") {
            let url = store.runURL(upload, run)
            let changedParts = (try? upload.invalidateChangedParts(run: run.index) { MinutesCloudUpload.digest(try MinutesCloudUpload.readPart($0, from: url)) }) ?? []
            if !changedParts.isEmpty {
                changed = true
                Log.network.notice("upload_part_changed run=\(run.index, privacy: .public) parts=\(changedParts.count, privacy: .public)")
            }
            verified.insert("\(clientId)/\(run.index)")
        }
        for part in upload.pendingParts {
            let key = TaskKey(clientId: clientId, kind: .part(run: part.run, offset: part.offset)).description
            guard !inFlight.contains(key), let run = upload.runs.first(where: { $0.index == part.run }) else { continue }
            do {
                let fileURL = store.partURL(clientId: clientId, part: part)
                if part.sha256 == nil || !FileManager.default.fileExists(atPath: fileURL.path) {
                    let data = try MinutesCloudUpload.readPart(part, from: store.runURL(upload, run))
                    try FileManager.default.createDirectory(at: store.partsDirectory(for: clientId), withIntermediateDirectories: true)
                    try data.write(to: fileURL, options: .atomic)
                    upload.recordDigest(run: part.run, offset: part.offset, sha256: MinutesCloudUpload.digest(data))
                    changed = true
                }
                let request = try client.partUploadRequest(recordingID: serverId, run: part.run, offset: part.offset, contentType: MinutesCloudUpload.contentType)
                start(request, file: fileURL, key: key)
            } catch {
                upload.lastError = error.localizedDescription
                changed = true
            }
        }
        if changed { try? store.save(upload) }
        if upload.readyToComplete(fileSizes: sizes) { startComplete(upload, client: client) }
        if changed { notify(clientId) }
    }

    private func startCreate(_ upload: MinutesCloudUpload, client: MinutesCloudClient) {
        let key = TaskKey(clientId: upload.clientId, kind: .create).description
        guard !inFlight.contains(key) else { return }
        do {
            let file = store.partsDirectory(for: upload.clientId).appending(path: "create.json")
            try FileManager.default.createDirectory(at: store.partsDirectory(for: upload.clientId), withIntermediateDirectories: true)
            try MinutesCloudClient.createRecordingBody(upload.recordingRequest).write(to: file, options: .atomic)
            start(try client.createRecordingRequest(), file: file, key: key)
        } catch {
            record(upload.clientId, error: error.localizedDescription)
        }
    }

    private func startComplete(_ upload: MinutesCloudUpload, client: MinutesCloudClient) {
        guard let serverId = upload.serverId else { return }
        let key = TaskKey(clientId: upload.clientId, kind: .complete).description
        guard !inFlight.contains(key) else { return }
        do {
            let file = store.partsDirectory(for: upload.clientId).appending(path: "complete.json")
            try FileManager.default.createDirectory(at: store.partsDirectory(for: upload.clientId), withIntermediateDirectories: true)
            try MinutesCloudClient.completeBody(durationSeconds: upload.durationSeconds, runs: upload.runBytes).write(to: file, options: .atomic)
            start(try client.completeRequest(recordingID: serverId), file: file, key: key)
        } catch {
            record(upload.clientId, error: error.localizedDescription)
        }
    }

    private func start(_ request: URLRequest, file: URL, key: String) {
        let task = session.uploadTask(with: request, fromFile: file)
        task.taskDescription = key
        inFlight.insert(key)
        task.resume()
    }

    private func record(_ clientId: String, error: String) {
        guard var upload = try? store.load(clientId: clientId) else { return }
        upload.lastError = error
        try? store.save(upload)
        notify(clientId)
    }

    private func notify(_ clientId: String) {
        Task { @MainActor [weak self] in self?.onChange?(clientId) }
    }

    // MARK: 結果

    /// 送信の結果を upload.json に書く。続けてよければ true（失敗はすぐには繰り返さない）。
    private func handle(_ key: TaskKey, status: Int?, body: Data, error: Error?) -> Bool {
        guard var upload = try? store.load(clientId: key.clientId) else { return false }
        defer {
            try? store.save(upload)
            notify(key.clientId)
        }
        guard let status else {
            upload.lastError = "送れませんでした（\(error?.localizedDescription ?? "回線")）。つながったら続きを送ります"
            return false
        }
        let code = MinutesCloudClient.errorCode(from: body)
        let ok = (200..<300).contains(status)
        switch key.kind {
        case .create:
            if ok, let recording = try? MinutesCloudClient.decodeRecording(from: body) {
                upload.serverId = recording.id
                upload.lastError = nil
                if recording.status != "uploading" {
                    // 前に処理まで進んだ同じ録音（client_id が同じ）
                    upload.completed = true
                    store.removeParts(clientId: key.clientId)
                    return false
                }
                return true
            }
        case let .part(run, offset):
            if ok {
                upload.markUploaded(run: run, offset: offset)
                upload.lastError = nil
                try? FileManager.default.removeItem(at: store.partURL(clientId: key.clientId, part: .init(run: run, offset: offset, size: 0)))
                return true
            }
            if status == 409, code == "already_completed" {
                upload.completed = true
                upload.lastError = nil
                store.removeParts(clientId: key.clientId)
                return false
            }
        case .complete:
            if ok {
                upload.completed = true
                upload.lastError = nil
                store.removeParts(clientId: key.clientId)
                return false
            }
            if status == 400, code == "parts_missing" {
                // サーバーに届いていない区切りがある: すべて上げ直す（同じ境目なので重なるだけ）
                for run in upload.runs { upload.resendRun(run.index) }
                verified = verified.filter { !$0.hasPrefix(key.clientId + "/") }
                upload.lastError = MinutesCloudError.http(status: status, code: code, requestID: nil).localizedDescription
                return true
            }
        }
        if status == 404, code == "not_found" {
            // サーバーで消された録音（ほかの端末で消した・別のアカウント）。作り直さない
            upload.completed = true
            upload.lastError = "サーバーで消された録音です（送るのをやめました）"
            return false
        }
        upload.lastError = MinutesCloudError.http(status: status, code: code, requestID: nil).localizedDescription
        return false
    }
}

extension UploadEngine: URLSessionDataDelegate {
    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        lock.withLock { bodies[dataTask.taskIdentifier, default: Data()].append(data) }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        lock.lock()
        defer { lock.unlock() }
        let body = bodies.removeValue(forKey: task.taskIdentifier) ?? Data()
        guard let description = task.taskDescription, let key = TaskKey(description) else { return }
        inFlight.remove(description)
        if (error as? URLError)?.code == .cancelled { return }
        let status = (task.response as? HTTPURLResponse)?.statusCode
        if handle(key, status: status, body: body, error: error) { step(clientId: key.clientId) }
    }

    func urlSessionDidFinishEvents(forBackgroundURLSession session: URLSession) {
        Task { @MainActor [weak self] in
            self?.backgroundCompletion?()
            self?.backgroundCompletion = nil
        }
    }
}

/// 裏の送信の印（taskDescription）。アプリが起こし直されても、どの録音のどの送信かが分かる。
struct TaskKey: CustomStringConvertible, Equatable {
    enum Kind: Equatable {
        case create
        case part(run: Int, offset: Int)
        case complete
    }

    var clientId: String
    var kind: Kind

    init(clientId: String, kind: Kind) {
        self.clientId = clientId
        self.kind = kind
    }

    init?(_ description: String) {
        let fields = description.split(separator: "|", omittingEmptySubsequences: false).map(String.init)
        switch (fields.first, fields.count) {
        case ("create", 2): self.init(clientId: fields[1], kind: .create)
        case ("complete", 2): self.init(clientId: fields[1], kind: .complete)
        case ("part", 4):
            guard let run = Int(fields[2]), let offset = Int(fields[3]) else { return nil }
            self.init(clientId: fields[1], kind: .part(run: run, offset: offset))
        default: return nil
        }
    }

    var description: String {
        switch kind {
        case .create: "create|\(clientId)"
        case .complete: "complete|\(clientId)"
        case let .part(run, offset): "part|\(clientId)|\(run)|\(offset)"
        }
    }
}
