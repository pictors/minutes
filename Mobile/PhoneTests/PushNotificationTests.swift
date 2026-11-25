import MinutesKit
import XCTest
@testable import Minutes

/// 処理が終わったときの通知（SPEC §5.7）: 埋め込みのプロファイルからの APNs の環境の読み方と、サーバーの通知の中身の読み方。
/// 手元のサーバーは要らない。
final class PushNotificationTests: XCTestCase {
    /// プロファイルの形（CMS の包みの中の plist）。包みのかわりに、前後にでたらめなバイト列を置く（読むのは <?xml から </plist> まで）。
    private func profile(entitlements: String) -> Data {
        var data = Data([0x30, 0x82, 0x2a, 0x10, 0x06, 0x09, 0x2a, 0x86])
        data.append(Data("""
        <?xml version="1.0" encoding="UTF-8"?>
        <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
        <plist version="1.0">
        <dict>
        <key>Name</key><string>iOS Team Provisioning Profile: jp.pictors.minutes</string>
        <key>Entitlements</key><dict>\(entitlements)</dict>
        </dict>
        </plist>
        """.utf8))
        data.append(Data([0xa0, 0x82, 0x0b, 0x00, 0x30, 0x82]))
        return data
    }

    func testAPSEnvironmentFromProvisioningProfile() {
        XCTAssertEqual(MinutesCloudPushEnvironment.apsEnvironment(inProvisioningProfile: profile(entitlements: "<key>aps-environment</key><string>development</string>")), "development")
        XCTAssertEqual(MinutesCloudPushEnvironment.apsEnvironment(inProvisioningProfile: profile(entitlements: "<key>aps-environment</key><string>production</string>")), "production")
        // 通知の機能がないプロファイル・プロファイルでないもの
        XCTAssertNil(MinutesCloudPushEnvironment.apsEnvironment(inProvisioningProfile: profile(entitlements: "<key>get-task-allow</key><true/>")))
        XCTAssertNil(MinutesCloudPushEnvironment.apsEnvironment(inProvisioningProfile: Data([0x00, 0x01, 0x02])))
        // シミュレータは sandbox（APNs の開発の環境）
        XCTAssertEqual(MinutesCloudPushEnvironment.current, .sandbox)
    }

    func testPayload() throws {
        let userInfo: [AnyHashable: Any] = [
            "aps": ["alert": ["title": "議事録ができました", "body": "11月25日 14:02 から Apple Watch で録った会議（58 分）"], "sound": "default"],
            "minutes": ["event": "done", "recording_id": "8d0c1f9e-0000-4000-8000-000000000001", "client_id": "watch-fictional-1"],
        ]
        let payload = try XCTUnwrap(PushPayload(userInfo))
        XCTAssertEqual(payload.event, "done")
        XCTAssertEqual(payload.recordingID, "8d0c1f9e-0000-4000-8000-000000000001")
        XCTAssertEqual(payload.clientID, "watch-fictional-1")
        // Minutes の欄のない通知・会議を指さない通知は、Minutes の通知として扱わない
        XCTAssertNil(PushPayload(["aps": ["alert": "ほかの通知"]]))
        XCTAssertNil(PushPayload(["minutes": ["event": "done", "recording_id": "r1"]]))
        XCTAssertNil(PushPayload(["minutes": ["event": "done", "client_id": ""]]))
    }
}
