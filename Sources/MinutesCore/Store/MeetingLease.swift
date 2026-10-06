import CryptoKit
import Darwin
import Foundation

/// OS がプロセス終了時に解放する会議単位の排他ロック。時刻や PID の推測で実行中の仕事を復旧しない。
public final class MeetingLease: Sendable {
    private let descriptor: Int32
    let meetingId: String
    let directory: URL

    init(directory: URL, meetingId: String) throws {
        self.meetingId = meetingId
        self.directory = directory
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let name = SHA256.hash(data: Data(meetingId.utf8)).map { String(format: "%02x", $0) }.joined()
        let path = directory.appendingPathComponent(name + ".lock").path
        let fd = Darwin.open(path, O_CREAT | O_RDWR | O_CLOEXEC, S_IRUSR | S_IWUSR)
        guard fd >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        guard flock(fd, LOCK_EX | LOCK_NB) == 0 else {
            let code = errno
            Darwin.close(fd)
            if code == EWOULDBLOCK { throw StoreError.meetingBusy(meetingId) }
            throw POSIXError(POSIXErrorCode(rawValue: code) ?? .EIO)
        }
        descriptor = fd
    }

    deinit { Darwin.close(descriptor) }
}
