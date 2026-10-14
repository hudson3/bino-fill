import Foundation

/// One "pick one of these" question for the local decision model.
public struct DecisionRequest: Codable {
    public var state: String
    public var question: String
    public var options: [String]

    public init(state: String, question: String, options: [String]) {
        self.state = state; self.question = question; self.options = options
    }
}

public struct Decision: Codable {
    public var choice: String
    /// The model's probability for its choice, 0 to 1.
    public var confidence: Double
    public var probs: [String: Double]

    public init(choice: String, confidence: Double, probs: [String: Double] = [:]) {
        self.choice = choice; self.confidence = confidence; self.probs = probs
    }
}

/// Anything that can answer decision requests. The real one talks to the local sidecar;
/// tests supply their own.
public protocol DecisionMaker {
    func decide(_ requests: [DecisionRequest]) async throws -> [Decision]
}

public enum DeciderError: Error, CustomStringConvertible {
    case notConfigured
    case failedToStart(String)
    case badReply(String)

    public var description: String {
        switch self {
        case .notConfigured:
            return "The decision model is not set up. Run `make setup` in the bino-fill folder."
        case .failedToStart(let why): return "The decision model did not start: \(why)"
        case .badReply(let why): return "The decision model gave an unusable answer (\(why))."
        }
    }
}

/// Where the sidecar lives, written by `make setup`.
public struct BinoConfig: Codable {
    public var python: String
    public var server: String
    public var model: String

    public static func load() -> BinoConfig? {
        if let data = try? Data(contentsOf: BinoPaths.configFile),
           let config = try? JSONDecoder().decode(BinoConfig.self, from: data) {
            return config
        }
        // A redirected (test) home falls back to the real config so tests use the same model.
        if BinoPaths.isRedirected,
           let data = try? Data(contentsOf: BinoPaths.defaultHome.appendingPathComponent("config.json")) {
            return try? JSONDecoder().decode(BinoConfig.self, from: data)
        }
        return nil
    }
}

/// Talks to the local model server, starting it when needed.
#if os(macOS)
public final class SidecarDecider: DecisionMaker {
    private struct ServerState: Codable {
        var port: Int
        var token: String
        var pid: Int32
        var model: String
    }

    private struct ChooseReply: Codable {
        var results: [Decision]
    }

    // The model is shared between the real and test homes; its state always lives with the real one.
    private let stateFile = BinoPaths.defaultHome.appendingPathComponent("sidecar.json")
    private var state: ServerState?

    public init() {}

    private func readState() -> ServerState? {
        guard let data = try? Data(contentsOf: stateFile) else { return nil }
        return try? JSONDecoder().decode(ServerState.self, from: data)
    }

    private func request(_ state: ServerState, path: String, body: Data?) -> URLRequest {
        var request = URLRequest(url: URL(string: "http://127.0.0.1:\(state.port)\(path)")!)
        request.setValue("Bearer \(state.token)", forHTTPHeaderField: "Authorization")
        request.timeoutInterval = 120
        if let body {
            request.httpMethod = "POST"
            request.httpBody = body
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }
        return request
    }

    private func healthy(_ state: ServerState) async -> Bool {
        var probe = request(state, path: "/health", body: nil)
        probe.timeoutInterval = 2
        guard let (_, response) = try? await URLSession.shared.data(for: probe) else { return false }
        return (response as? HTTPURLResponse)?.statusCode == 200
    }

    /// True when a model server is already up and answering.
    public func isRunning() async -> Bool {
        if let current = state, await healthy(current) { return true }
        if let existing = readState(), await healthy(existing) {
            state = existing
            return true
        }
        return false
    }

    /// Makes sure the model server is running and returns how long that took.
    @discardableResult
    public func ensureRunning() async throws -> TimeInterval {
        // A cancelled caller's health check fails at once, which would look like "not
        // running" and start a second copy of the model.
        try Task.checkCancellation()
        let started = Date()
        if let current = state, await healthy(current) { return 0 }
        if let existing = readState(), await healthy(existing) {
            state = existing
            return Date().timeIntervalSince(started)
        }
        guard let config = BinoConfig.load(),
              FileManager.default.isExecutableFile(atPath: config.python),
              FileManager.default.fileExists(atPath: config.server)
        else { throw DeciderError.notConfigured }

        try Task.checkCancellation()
        try? FileManager.default.createDirectory(at: BinoPaths.defaultHome, withIntermediateDirectories: true)
        try? FileManager.default.removeItem(at: stateFile)
        let process = Process()
        process.executableURL = URL(fileURLWithPath: config.python)
        process.arguments = [config.server, "--model", config.model, "--state-file", stateFile.path]
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = FileHandle.nullDevice
        let logURL = BinoPaths.defaultHome.appendingPathComponent("sidecar.log")
        FileManager.default.createFile(atPath: logURL.path, contents: nil)
        process.standardError = (try? FileHandle(forWritingTo: logURL)) ?? FileHandle.nullDevice
        do {
            try process.run()
        } catch {
            throw DeciderError.failedToStart(error.localizedDescription)
        }

        // First start downloads the model; later starts take a few seconds.
        let deadline = Date().addingTimeInterval(900)
        while Date() < deadline {
            if let fresh = readState(), fresh.pid == process.processIdentifier, await healthy(fresh) {
                state = fresh
                return Date().timeIntervalSince(started)
            }
            if !process.isRunning {
                let log = (try? String(contentsOf: logURL, encoding: .utf8)) ?? ""
                throw DeciderError.failedToStart(String(log.suffix(400)))
            }
            try await Task.sleep(nanoseconds: 300_000_000)
        }
        throw DeciderError.failedToStart("timed out waiting for the model to load")
    }

    public func decide(_ requests: [DecisionRequest]) async throws -> [Decision] {
        guard !requests.isEmpty else { return [] }
        try await ensureRunning()
        guard let state else { throw DeciderError.notConfigured }
        let body = try JSONEncoder().encode(["items": requests])
        let (data, response) = try await URLSession.shared.data(for: request(state, path: "/choose", body: body))
        guard (response as? HTTPURLResponse)?.statusCode == 200 else {
            throw DeciderError.badReply(String(data: data, encoding: .utf8) ?? "no body")
        }
        guard let reply = try? JSONDecoder().decode(ChooseReply.self, from: data),
              reply.results.count == requests.count
        else { throw DeciderError.badReply("wrong shape") }
        return reply.results
    }

    /// Stops the model server if one is running.
    public func stop() {
        guard let existing = readState() else { return }
        kill(existing.pid, SIGTERM)
        try? FileManager.default.removeItem(at: stateFile)
    }
}
#endif
