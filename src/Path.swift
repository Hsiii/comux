import AppKit
import Foundation

enum CodexMuxPaths {
    static let root = URL(fileURLWithPath: NSHomeDirectory())
        .appendingPathComponent(".codexmux", isDirectory: true)
    static let cache = root.appendingPathComponent("cache.json", isDirectory: false)
    static let config = root.appendingPathComponent("accounts.json", isDirectory: false)
    static let codexHome = URL(fileURLWithPath: ProcessInfo.processInfo.environment["CODEX_HOME"] ?? "\(NSHomeDirectory())/.codex")
    static let codexAuth = codexHome.appendingPathComponent("auth.json", isDirectory: false)
}
