import Foundation
import Testing
@testable import Minnas

@Suite struct LifecycleTests {
    @Test func appVersionUsesInfoDictionaryValue() {
        #expect(AppInfo.version(from: ["CFBundleShortVersionString": "9.8.7"]) == "9.8.7")
    }

    @Test func appVersionFallsBackWithoutInfoDictionaryValue() {
        #expect(AppInfo.version(from: nil) == AppInfo.fallbackVersion)
        #expect(AppInfo.version(from: [:]) == AppInfo.fallbackVersion)
    }

    @Test func fallbackVersionMatchesAppPlist() throws {
        let repositoryRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let plistURL = repositoryRoot.appendingPathComponent("App/Info.plist")
        let data = try Data(contentsOf: plistURL)
        let plist = try #require(
            PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any]
        )
        let plistVersion = try #require(plist["CFBundleShortVersionString"] as? String)
        #expect(AppInfo.fallbackVersion == plistVersion)
    }

    @Test func systemAudioPermissionNamesMatchEngine() {
        #expect(AppDelegate.systemAudioPermissionName(for: .sck) == "Screen Recording")
        #expect(AppDelegate.systemAudioPermissionName(for: .taps) == "System Audio Recording")
    }
}
