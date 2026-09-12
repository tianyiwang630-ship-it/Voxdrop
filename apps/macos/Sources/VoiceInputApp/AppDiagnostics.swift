import Foundation
import OSLog

enum AppDiagnostics {
    static let launchID = UUID().uuidString.lowercased()
    static let logger = Logger(subsystem: AppIdentity.bundleIdentifier, category: "Lifecycle")

    static func sessionID(_ id: UUID?) -> String {
        id?.uuidString.lowercased() ?? "none"
    }
}
