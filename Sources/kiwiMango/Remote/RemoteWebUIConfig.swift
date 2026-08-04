import Foundation

/// Shared constants + persisted token for the remote web UI (PLAN-REMOTE-WEBUI.md).
/// Fixed port + persisted token so a bookmarked phone URL keeps working across
/// Mac restarts, instead of chasing a new random port/token every launch.
enum RemoteWebUIConfig {
    static let gatewayPort = 9219
    static let staticServerPort = 9220

    static var supportDir: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let dir = base.appendingPathComponent("kiwiMango", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    static var tokenFile: URL {
        supportDir.appendingPathComponent("gateway-token.txt")
    }
}

extension HermesGatewayClient {
    static func loadOrCreatePersistedToken() -> String {
        let file = RemoteWebUIConfig.tokenFile
        if let existing = try? String(contentsOf: file, encoding: .utf8) {
            let trimmed = existing.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty { return trimmed }
        }
        let generated = "kiwimango-\(UUID().uuidString.replacingOccurrences(of: "-", with: ""))"
        try? generated.write(to: file, atomically: true, encoding: .utf8)
        return generated
    }
}
