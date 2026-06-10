import AppKit
import Foundation

enum ComuxPaths {
    static let root = URL(fileURLWithPath: NSHomeDirectory())
        .appendingPathComponent(".comux", isDirectory: true)
    static let oldRoot = URL(fileURLWithPath: NSHomeDirectory())
        .appendingPathComponent(".codex" + "mux", isDirectory: true)
    static let database = root.appendingPathComponent("store.sqlite", isDirectory: false)
    static let cache = root.appendingPathComponent("cache.json", isDirectory: false)
    static let config = root.appendingPathComponent("accounts.json", isDirectory: false)
    static let legacyDisplayNames = root.appendingPathComponent("nicknames.json", isDirectory: false)
    static let oldDatabase = oldRoot.appendingPathComponent("store.sqlite", isDirectory: false)
    static let oldCache = oldRoot.appendingPathComponent("cache.json", isDirectory: false)
    static let oldConfig = oldRoot.appendingPathComponent("accounts.json", isDirectory: false)
    static let oldLegacyDisplayNames = oldRoot.appendingPathComponent("nicknames.json", isDirectory: false)
    static let codexHome = URL(fileURLWithPath: ProcessInfo.processInfo.environment["CODEX_HOME"] ?? "\(NSHomeDirectory())/.codex")
    static let codexAuth = codexHome.appendingPathComponent("auth.json", isDirectory: false)
}
