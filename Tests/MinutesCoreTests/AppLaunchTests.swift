import CoreServices
import Foundation
import MinutesCore
import Testing

@Suite("起動のしかたと最初の窓")
struct AppLaunchTests {
    private func openApplication(property: OSType? = nil) -> NSAppleEventDescriptor {
        let event = NSAppleEventDescriptor(eventClass: kCoreEventClass, eventID: kAEOpenApplication, targetDescriptor: nil,
                                           returnID: AEReturnID(kAutoGenerateReturnID), transactionID: AETransactionID(kAnyTransactionID))
        if let property { event.setParam(NSAppleEventDescriptor(enumCode: property), forKeyword: keyAEPropData) }
        return event
    }

    @Test("起動の Apple イベント: ログイン項目・利用者・URL")
    func kind() {
        #expect(LaunchKind(event: openApplication()) == .user)
        #expect(LaunchKind(event: openApplication(property: keyAELaunchedAsLogInItem)) == .loginItem)
        #expect(LaunchKind(event: openApplication(property: keyAELaunchedAsServiceItem)) == .other)
        // URL を開くための起動（'GURL'/'GURL'。定数は Carbon にあるので値で書く）
        let getURL = "GURL".utf8.reduce(UInt32(0)) { $0 << 8 | UInt32($1) }
        let url = NSAppleEventDescriptor(eventClass: getURL, eventID: getURL, targetDescriptor: nil,
                                         returnID: AEReturnID(kAutoGenerateReturnID), transactionID: AETransactionID(kAnyTransactionID))
        #expect(LaunchKind(event: url) == .other)
        #expect(LaunchKind(event: nil) == .user)
    }

    @Test("最初の窓: 利用者が開いたらメイン、ログイン時は出さない、案内とデータベースの失敗が先")
    func window() {
        #expect(LaunchWindow.choose(kind: .user, needsOnboarding: false, startupFailed: false) == .main)
        #expect(LaunchWindow.choose(kind: .loginItem, needsOnboarding: false, startupFailed: false) == nil)
        #expect(LaunchWindow.choose(kind: .other, needsOnboarding: false, startupFailed: false) == nil)
        #expect(LaunchWindow.choose(kind: .user, needsOnboarding: true, startupFailed: false) == .onboarding)
        #expect(LaunchWindow.choose(kind: .loginItem, needsOnboarding: true, startupFailed: false) == .onboarding)
        #expect(LaunchWindow.choose(kind: .loginItem, needsOnboarding: true, startupFailed: true) == .main)
    }
}
