import Foundation

enum AppIdentity {
    static let displayName = "言落"
    static let englishName = "VoxDrop"
    static let bundleIdentifier = "com.local.VoxDrop"
    static let legacyBundleIdentifier = "com.local.VoiceInput"

    static var applicationSupportDirectory: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent(bundleIdentifier, isDirectory: true)
    }

    static var legacyApplicationSupportDirectory: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent(legacyBundleIdentifier, isDirectory: true)
    }
}
