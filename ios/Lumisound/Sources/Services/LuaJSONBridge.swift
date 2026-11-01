import Foundation

// MARK: - LuaJSONBridge
//
// Shared plumbing for every Lua-scripted feature added after theming
// (effects, smart-playlist rules, visualizer styles). `LuaThemeEngine` keeps
// its own private copy of this same bootstrap (see that file's header) since
// it predates this helper and touching its already-shipped, working code
// just to de-duplicate a few lines isn't worth the regression risk — every
// NEW engine uses this one instead of growing a fifth copy.
//
// The shape is always the same: a script (bundled or user-imported) is
// wrapped so it fully resolves to one JSON value via a single `evaluate`
// call, then decoded into a typed Swift value. No persistent-engine reuse,
// no per-call Swift<->Lua argument bridging — same "resolve once" contract
// LuaThemeEngine already uses for presets.
enum LuaJSONBridge {
    enum BridgeError: LocalizedError {
        case unexpectedResult
        case decodeFailed(Error)

        var errorDescription: String? {
            switch self {
            case .unexpectedResult:
                return "The Lua script didn't return the expected JSON result."
            case .decodeFailed(let error):
                return "Couldn't parse the script's result: \(error.localizedDescription)"
            }
        }
    }

    /// Runs `source` (which must end by returning a JSON-encoded string —
    /// typically `return json.encode(someTable)`) and decodes that JSON as
    /// `T`. `convertFromSnakeCase` matches the convention every bundled Lua
    /// script here uses for table keys (`eq_bands`, `pitch_semitones`, …).
    /// Escapes `s` as a Lua double-quoted string literal, safe to splice
    /// directly into generated Lua source. Every engine that injects
    /// JSON-encoded, externally-sourced data (song titles/artists — which can
    /// contain arbitrary text, e.g. from a YouTube uploader) into a harness
    /// script MUST route it through this rather than a raw `[==[ ... ]==]`
    /// long-bracket literal: a long bracket's closing sequence is a fixed,
    /// guessable string, so any field value containing it terminates the
    /// literal early and lets the rest of that value execute as Lua source
    /// in the harness's own scope. A quoted literal has no naturally
    /// occurring terminator — every byte that could end the string early
    /// (`"`, `\`) or that Lua would otherwise mis-tokenize is escaped.
    static func quotedLuaString(_ s: String) -> String {
        luaQuote(s: s)
    }

    static func run<T: Decodable>(
        _ source: String,
        chunkName: String,
        as type: T.Type,
        convertFromSnakeCase: Bool = true
    ) throws -> T {
        // Sandboxed Lua 5.4 + json module in the Rust core (rust/core/src/lua.rs).
        let jsonString = try luaEvalString(source: source, chunkName: chunkName)
        guard let data = jsonString.data(using: .utf8) else {
            throw BridgeError.unexpectedResult
        }
        let decoder = JSONDecoder()
        if convertFromSnakeCase {
            decoder.keyDecodingStrategy = .convertFromSnakeCase
        }
        do {
            return try decoder.decode(T.self, from: data)
        } catch {
            throw BridgeError.decodeFailed(error)
        }
    }
}

// MARK: - LuaUserScriptLibrary
//
// A small, reusable "folder of importable .lua scripts under Documents"
// concept shared by every new scriptable feature's community-sharing flow —
// each feature gets its own subdirectory name, but the scan/import/delete
// logic is identical.
enum LuaUserScriptLibrary {
    struct ScriptRef: Identifiable, Hashable {
        let id: String          // filename without extension
        let displayName: String
        let url: URL
        let isBundled: Bool
    }

    private static func displayName(from url: URL) -> String {
        url.deletingPathExtension().lastPathComponent
            .replacingOccurrences(of: "_", with: " ")
            .capitalized
    }

    static func directory(named subdirectory: String) -> URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent(subdirectory, isDirectory: true)
    }

    /// Bundled example scripts under `Resources/<subdirectory>/*.lua`.
    static func bundledScripts(subdirectory: String) -> [ScriptRef] {
        guard let urls = Bundle.main.urls(forResourcesWithExtension: "lua", subdirectory: subdirectory) else { return [] }
        return urls
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
            .map { ScriptRef(id: $0.deletingPathExtension().lastPathComponent, displayName: displayName(from: $0), url: $0, isBundled: true) }
    }

    /// User-imported scripts under `Documents/<subdirectory>`.
    static func userScripts(subdirectory: String) -> [ScriptRef] {
        let dir = directory(named: subdirectory)
        guard let urls = try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil) else { return [] }
        return urls
            .filter { $0.pathExtension.lowercased() == "lua" }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
            .map { ScriptRef(id: $0.deletingPathExtension().lastPathComponent, displayName: displayName(from: $0), url: $0, isBundled: false) }
    }

    /// Imports raw script source text into `subdirectory`, saving it under a
    /// sanitized version of `suggestedName` (de-duplicated with a numeric
    /// suffix if needed) — the actual "paste/import a shared script" entry
    /// point every community-sharing UI calls.
    @discardableResult
    static func importScript(source: String, suggestedName: String, subdirectory: String) throws -> ScriptRef {
        let dir = directory(named: subdirectory)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let safeName = suggestedName
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .joined(separator: "_")
            .lowercased()
        let base = safeName.isEmpty ? "custom" : safeName
        var candidate = dir.appendingPathComponent("\(base).lua")
        var suffix = 1
        while FileManager.default.fileExists(atPath: candidate.path) {
            candidate = dir.appendingPathComponent("\(base)_\(suffix).lua")
            suffix += 1
        }
        try source.write(to: candidate, atomically: true, encoding: .utf8)
        return ScriptRef(id: candidate.deletingPathExtension().lastPathComponent, displayName: displayName(from: candidate), url: candidate, isBundled: false)
    }

    static func deleteUserScript(_ ref: ScriptRef) {
        guard !ref.isBundled else { return }
        try? FileManager.default.removeItem(at: ref.url)
    }
}
