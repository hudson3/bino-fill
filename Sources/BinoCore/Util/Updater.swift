#if os(macOS)
import Foundation

/// Which commit this copy of Bino was built from, and where its repository is.
///
/// `make build` writes the commit next to the binary; `make bundle` also puts it, with
/// the repository's path, into the app's Info.plist.
public struct BuildInfo {
    public var commit: String
    public var repo: URL

    public var shortCommit: String { String(commit.prefix(7)) }
    public var isDirty: Bool { commit.hasSuffix("-dirty") }

    public static func current() -> BuildInfo? {
        let info = Bundle.main.infoDictionary ?? [:]
        if let commit = info["BinoCommit"] as? String, let repo = info["BinoRepo"] as? String {
            return BuildInfo(commit: commit, repo: URL(fileURLWithPath: repo, isDirectory: true))
        }
        // The bare command: <repo>/.build/release/bino, reached through a symlink on the PATH.
        let executable = Bundle.main.executableURL?.resolvingSymlinksInPath() ?? URL(fileURLWithPath: CommandLine.arguments[0]).resolvingSymlinksInPath()
        let stamp = executable.deletingLastPathComponent().appendingPathComponent("bino-commit")
        guard let commit = try? String(contentsOf: stamp, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines),
              !commit.isEmpty else { return nil }
        // `.build/release` is itself a symlink into `.build/<arch>/release`, so walk up to the package.
        var repo = executable.deletingLastPathComponent()
        while repo.path != "/" {
            if FileManager.default.fileExists(atPath: repo.appendingPathComponent("Package.swift").path) {
                return BuildInfo(commit: commit, repo: repo)
            }
            repo = repo.deletingLastPathComponent()
        }
        return nil
    }
}

/// Keeps this Mac's Bino level with the repository's `main`: GitHub is the source of
/// truth, each Mac is a build of it.
public enum Updater {
    public enum Status: Equatable {
        case upToDate
        case available(remote: String)
        /// This build is not on `main` at all (local changes or another branch).
        case ahead
    }

    public struct Failure: Error, CustomStringConvertible {
        public var description: String
    }

    /// A shell with the tools a build needs, whatever started us.
    static let environment: [String: String] = {
        var env = ProcessInfo.processInfo.environment
        env["PATH"] = "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin"
        return env
    }()

    @discardableResult
    static func run(_ arguments: [String], in directory: URL, output: ((String) -> Void)? = nil) async throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = arguments
        process.currentDirectoryURL = directory
        process.environment = environment
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        var collected = ""
        let lines = AsyncStream<String> { continuation in
            pipe.fileHandleForReading.readabilityHandler = { handle in
                let data = handle.availableData
                if data.isEmpty {
                    handle.readabilityHandler = nil
                    continuation.finish()
                } else {
                    continuation.yield(String(decoding: data, as: UTF8.self))
                }
            }
        }
        try process.run()
        for await chunk in lines {
            collected += chunk
            output?(chunk)
        }
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            throw Failure(description: "`\(arguments.joined(separator: " "))` failed:\n" + collected.suffix(600))
        }
        return collected
    }

    /// Asks GitHub where `main` is, without changing anything here.
    public static func check(_ build: BuildInfo) async throws -> Status {
        let reply = try await run(["git", "ls-remote", "origin", "refs/heads/main"], in: build.repo)
        guard let remote = reply.split(whereSeparator: \.isWhitespace).first.map(String.init), remote.count == 40 else {
            throw Failure(description: "GitHub did not say where main is: \(reply.prefix(200))")
        }
        let built = build.commit.replacingOccurrences(of: "-dirty", with: "")
        if remote == built { return build.isDirty ? .ahead : .upToDate }
        // Is the remote commit a descendant of this build? If not, this build is off main.
        let known = try? await run(["git", "cat-file", "-e", "\(remote)^{commit}"], in: build.repo)
        if known != nil {
            let descends = try? await run(["git", "merge-base", "--is-ancestor", built, remote], in: build.repo)
            if descends == nil { return .ahead }
        }
        return .available(remote: remote)
    }

    /// Pulls `main` and rebuilds and reinstalls everything. The running app keeps its old
    /// code until it is reopened.
    public static func install(_ build: BuildInfo, progress: @escaping (String) -> Void) async throws {
        progress("Pulling main…\n")
        try await run(["git", "pull", "--ff-only", "origin", "main"], in: build.repo, output: progress)
        progress("Building and installing (about a minute)…\n")
        try await run(["make", "install"], in: build.repo, output: progress)
    }

    /// Quits the Bino app, if it is running, and opens the newly installed one.
    public static func reopenApp() {
        let script = "osascript -e 'tell application id \"local.bino.fill\" to quit' >/dev/null 2>&1; "
            + "for i in 1 2 3 4 5 6 7 8 9 10; do pgrep -f 'Bino.app/Contents/MacOS/Bino' >/dev/null || break; sleep 1; done; "
            + "open -a /Applications/Bino.app"
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", script]
        process.environment = environment
        try? process.run()
    }
}
#endif
