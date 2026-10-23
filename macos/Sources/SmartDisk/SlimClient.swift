import Foundation

/// Talks to the Rust core through the `slim` command line (`--json`).
/// The app holds no index of its own: the CLI, Finder and agents all see the same drive.
struct SlimClient: Sendable {
    struct Failure: LocalizedError {
        var message: String
        var errorDescription: String? { message }
    }

    let binary: URL

    /// Bundled binary first, then a development checkout, then common install locations.
    static func locate() -> SlimClient? {
        var candidates: [URL] = []
        if let bundled = Bundle.main.url(forAuxiliaryExecutable: "slim") {
            candidates.append(bundled)
        }
        // Installed apps must only execute their own signed components.
        if Bundle.main.bundleURL.pathExtension == "app" {
            return candidates.first { FileManager.default.isExecutableFile(atPath: $0.path) }.map(SlimClient.init)
        }
        if let env = ProcessInfo.processInfo.environment["SLIM_BIN"] {
            candidates.append(URL(fileURLWithPath: env))
        }
        // macos/.build/<config>/SmartDisk → repository root → target/{release,debug}/slim
        var dir = Bundle.main.executableURL?.resolvingSymlinksInPath().deletingLastPathComponent()
        for _ in 0..<6 {
            guard let d = dir else { break }
            candidates.append(d.appendingPathComponent("target/release/slim"))
            candidates.append(d.appendingPathComponent("target/debug/slim"))
            dir = d.deletingLastPathComponent()
        }
        let home = FileManager.default.homeDirectoryForCurrentUser
        candidates.append(home.appendingPathComponent(".cargo/bin/slim"))
        candidates.append(URL(fileURLWithPath: "/opt/homebrew/bin/slim"))
        candidates.append(URL(fileURLWithPath: "/usr/local/bin/slim"))
        return candidates.first { FileManager.default.isExecutableFile(atPath: $0.path) }.map(SlimClient.init)
    }

    func run(_ args: [String]) async throws -> Data {
        let binary = self.binary
        return try await Task.detached(priority: .userInitiated) {
            let process = Process()
            process.executableURL = binary
            process.arguments = args + ["--json"]
            let out = Pipe(), err = Pipe()
            process.standardOutput = out
            process.standardError = err
            // Not waitUntilExit(): on a concurrency thread it can miss the exit and block forever.
            let exit = AsyncStream.makeStream(of: Int32.self)
            process.terminationHandler = { ended in
                exit.continuation.yield(ended.terminationStatus)
                exit.continuation.finish()
            }
            try process.run()
            // Drain both pipes concurrently: either one can fill before the other closes.
            let errorHandle = err.fileHandleForReading
            let errorReader = Task.detached { errorHandle.readDataToEndOfFile() }
            let data = out.fileHandleForReading.readDataToEndOfFile()
            let errData = await errorReader.value
            var statuses = exit.stream.makeAsyncIterator()
            let status = await statuses.next() ?? -1
            guard status == 0 else {
                let message = String(data: errData, encoding: .utf8)?
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                    .replacingOccurrences(of: "Error: ", with: "") ?? "slim failed"
                throw Failure(message: message.isEmpty ? "slim exited with \(status)" : message)
            }
            return data
        }.value
    }

    func decode<T: Decodable>(_ type: T.Type, _ args: [String]) async throws -> T {
        let data = try await run(args)
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        return try decoder.decode(T.self, from: data)
    }

    // MARK: Commands

    func status() async throws -> DriveStatus { try await decode(DriveStatus.self, ["status"]) }
    func list(_ folder: String) async throws -> [Item] { try await decode([Item].self, ["ls", folder]) }
    func query(_ text: String) async throws -> QueryResult { try await decode(QueryResult.self, ["query", text]) }
    /// Files whose stored text holds all these words, in one folder or everywhere.
    func grep(_ text: String, folder: String?) async throws -> [TextHit] {
        try await decode([TextHit].self, ["grep", text] + (folder.map { ["--folder", $0] } ?? []))
    }
    func parse(_ name: String) async throws -> ParseResult { try await decode(ParseResult.self, ["parse", name]) }
    func why(_ original: String) async throws -> Explanation { try await decode(Explanation.self, ["why", original]) }
    func log(limit: Int = 100) async throws -> [LogRow] { try await decode([LogRow].self, ["log", "--limit", "\(limit)"]) }
    func capabilities() async throws -> Capabilities { try await decode(Capabilities.self, ["capabilities"]) }
    func categories() async throws -> [CategoryInfo] { try await decode([CategoryInfo].self, ["categories"]) }

    func mkdir(_ name: String, filters: FileFilters = FileFilters()) async throws {
        _ = try await run(["mkdir", name] + filters.arguments)
    }
    /// Removes a smart folder, or hides a built-in category.
    func rmdir(_ name: String) async throws { _ = try await run(["rmdir", name]) }
    func showCategory(_ id: String) async throws { _ = try await run(["categories", "show", id]) }
    func rename(_ from: String, to: String) async throws { _ = try await run(["mv", from, to]) }
    func label(_ original: String, folder: String, belongs: Bool?) async throws {
        let flag = belongs.map { $0 ? "--yes" : "--no" } ?? "--reset"
        _ = try await run(["label", original, "--folder", folder, flag])
    }
    func addFolder(_ path: String) async throws { _ = try await run(["folders", "add", path]) }
    func removeFolder(_ path: String) async throws { _ = try await run(["folders", "remove", path]) }
    func set(_ key: String, _ value: String) async throws { _ = try await run(["settings", "set", key, value]) }
    /// Asks the running daemon to check every watched folder again.
    func rescan() async throws { _ = try await run(["rescan"]) }
}
