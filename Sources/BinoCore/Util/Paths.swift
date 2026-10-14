import Foundation

/// Where Bino keeps its files. `BINO_HOME` redirects everything to another folder,
/// which is how tests and the fake vault stay away from the real one.
public enum BinoPaths {
    /// The user's home on a Mac; the app's own sandbox on a phone.
    static var userHome: URL {
        #if os(macOS)
        return FileManager.default.homeDirectoryForCurrentUser
        #else
        return URL(fileURLWithPath: NSHomeDirectory(), isDirectory: true)
        #endif
    }

    public static var defaultHome: URL {
        userHome.appendingPathComponent("Library/Application Support/Bino", isDirectory: true)
    }

    public static var home: URL {
        if let override = ProcessInfo.processInfo.environment["BINO_HOME"], !override.isEmpty {
            return URL(fileURLWithPath: (override as NSString).expandingTildeInPath, isDirectory: true)
        }
        return defaultHome
    }

    /// True when `BINO_HOME` points somewhere other than the real location.
    public static var isRedirected: Bool {
        home.standardizedFileURL.path != defaultHome.standardizedFileURL.path
    }

    public static var vaultFile: URL { home.appendingPathComponent("vault.bin") }
    public static var vaultKeyFile: URL { home.appendingPathComponent("vault.key") }
    public static var loginIndexFile: URL { home.appendingPathComponent("logins.idx") }
    public static var configFile: URL { home.appendingPathComponent("config.json") }
    /// Which tools are in Main and Other, and in what order.
    public static var toolsFile: URL { home.appendingPathComponent("tools.json") }
    public static var sidecarStateFile: URL { home.appendingPathComponent("sidecar.json") }
    public static var reportsDir: URL { home.appendingPathComponent("reports", isDirectory: true) }

    public static func ensureHome() throws {
        try FileManager.default.createDirectory(
            at: home, withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700])
    }

    /// Writes a file only the current user can read.
    public static func writePrivate(_ data: Data, to url: URL) throws {
        try ensureHome()
        try data.write(to: url, options: [.atomic])
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }
}
