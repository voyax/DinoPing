import Foundation

/// Writes "Always allow" rules to Claude Code's per-repo settings file
/// (`<cwd>/.claude/settings.local.json`). Conforms to `NativeRuleWriter`
/// so the UI can dispatch generically via `AgentKind.permissionStrategy`.
///
/// See `docs/permissions.md` for the architecture rationale, the pattern
/// derivation rules, and the trade-off vs Claude's own session-scoped
/// "Yes, don't ask again" for file modifications.
///
/// **Idempotency**: `writeAllowRule` is safe to call repeatedly. The
/// rule array is de-duplicated before write. Concurrent writes are
/// serialized through a process-wide lock — multiple AgentPulse panels
/// can't currently race, but the lock is cheap insurance.
public enum ClaudeCodeRuleWriter: NativeRuleWriter {

    // MARK: - NativeRuleWriter conformance

    public static func patternPreview(toolName: String, toolInput: [String: Any], cwd: String) -> String {
        let pattern = derivePattern(toolName: toolName, toolInput: toolInput, cwd: cwd)
        return pattern.formatted
    }

    public static func scopeDescription(toolName: String, toolInput: [String: Any], cwd: String) -> RuleScope {
        // settings.local.json is always per-repo when we have a cwd.
        // We always have one — PermissionRequest.cwd is non-optional.
        .thisRepo
    }

    public static func writeAllowRule(toolName: String, toolInput: [String: Any], cwd: String) throws {
        let pattern = derivePattern(toolName: toolName, toolInput: toolInput, cwd: cwd)
        let entry = pattern.formatted
        let settingsURL = URL(fileURLWithPath: cwd)
            .appendingPathComponent(".claude")
            .appendingPathComponent("settings.local.json")

        lock.lock()
        defer { lock.unlock() }

        // Ensure .claude/ exists. settings.local.json is usually already
        // present — Claude Code creates it for the user — but new repos
        // need us to mkdir.
        let dir = settingsURL.deletingLastPathComponent()
        do {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        } catch {
            throw PermissionRuleError.unwritablePath("could not create \(dir.path): \(error.localizedDescription)")
        }

        var settings = try readSettings(at: settingsURL)
        var permissions = settings["permissions"] as? [String: Any] ?? [:]
        var allow = permissions["allow"] as? [String] ?? []
        if !allow.contains(entry) {
            allow.append(entry)
            permissions["allow"] = allow
            settings["permissions"] = permissions
            try writeSettings(settings, to: settingsURL)
        }
    }

    // MARK: - Pattern derivation
    //
    // Public so tests (and ad-hoc tooling) can verify the output without
    // hitting disk. See `docs/permissions.md` > "Pattern derivation rules"
    // for the heuristic.

    public struct DerivedPattern: Equatable, Sendable {
        public let formatted: String   // e.g. "Bash(pnpm prisma:*)" or "Edit(/src/**)"
    }

    public static func derivePattern(toolName: String, toolInput: [String: Any], cwd: String) -> DerivedPattern {
        switch toolName {
        case "Bash":
            let cmd = (toolInput["command"] as? String) ?? ""
            return .init(formatted: "Bash(\(deriveBashPattern(cmd)))")
        case "Edit", "Write", "Read":
            let path = (toolInput["file_path"] as? String) ?? ""
            return .init(formatted: "\(toolName)(\(deriveFilePathPattern(path: path, cwd: cwd)))")
        default:
            // Tools we don't know how to truncate sensibly — just allow the
            // tool wholesale. The user is opting in via Always, so this
            // matches their intent.
            return .init(formatted: toolName)
        }
    }

    /// Bash: first 1-2 tokens + `:*`, after stripping leading env-var
    /// assignments. Always prefix-match — clicking Always on a specific
    /// invocation means "allow this command shape in general", not
    /// "remember this exact arg list".
    ///
    /// - Strip `VAR=value` prefixes — Bash's `VAR=val cmd args` syntax
    ///   sets env vars for `cmd`. The real "command" is `cmd`, not
    ///   `VAR=val`. Without this strip, patterns like `Bash(B=~/long/path
    ///   echo:*)` end up as the saved rule, which never matches anything
    ///   useful AND wraps onto multiple lines in the UI.
    /// - 2 tokens + `:*` when the 2nd looks like a subcommand (alphanumeric,
    ///   no leading `-`) — e.g. `pnpm prisma migrate dev` → `pnpm prisma:*`
    /// - 1 token + `:*` when the 2nd is a flag or the command is a single
    ///   token — e.g. `curl -s -o /dev/null` → `curl:*`, `pwd` → `pwd:*`
    static func deriveBashPattern(_ command: String) -> String {
        let trimmed = command.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "" }

        var tokens = trimmed.split(separator: " ", omittingEmptySubsequences: true).map(String.init)

        // Skip leading env-var assignments (`KEY=value` tokens). Multiple
        // assignments are common: `NODE_ENV=production DEBUG=1 npm test`.
        while let first = tokens.first, isEnvVarAssignment(first) {
            tokens.removeFirst()
        }

        guard let first = tokens.first else { return "" }

        // Single token (e.g. `pwd`) or flagged invocation (e.g. `curl -s ...`)
        // → just the command name + `:*`. The user wants to allow this
        // command in general, not pin to exact args.
        if tokens.count == 1 || tokens[1].hasPrefix("-") {
            return "\(first):*"
        }

        // Subcommand-shaped 2nd token → cmd + subcmd + `:*`.
        return "\(first) \(tokens[1]):*"
    }

    /// True when `token` looks like a Bash env-var assignment: name
    /// matches `[A-Z_][A-Z0-9_]*`, followed by `=`, followed by anything.
    /// Lowercase names are accepted only via the leading-underscore form
    /// (e.g. `_temp=...`); plain lowercase like `count=5` is more
    /// commonly a CLI flag value than an env var, so we don't strip it.
    private static func isEnvVarAssignment(_ token: String) -> Bool {
        guard let eqIndex = token.firstIndex(of: "=") else { return false }
        let name = token[token.startIndex..<eqIndex]
        guard let firstChar = name.first,
              firstChar.isUppercase || firstChar == "_" else { return false }
        return name.allSatisfy { $0.isUppercase || $0.isNumber || $0 == "_" }
    }

    /// File paths: project-relative `/foo/**` when inside cwd, absolute `//foo/**`
    /// when outside, `~/foo/**` for home, or `/**` fallback. Always end with
    /// `/**` to glob descendants.
    static func deriveFilePathPattern(path: String, cwd: String) -> String {
        guard !path.isEmpty else { return "/**" }

        // Normalize: collapse trailing slashes, resolve `..` etc.
        let normalized = (path as NSString).standardizingPath
        let normalizedCwd = (cwd as NSString).standardizingPath
        let home = NSHomeDirectory()

        // Parent directory of the target file is what we glob — `src/foo.swift`
        // → `src/**` so all of src/ is covered after Always.
        let parentDir = (normalized as NSString).deletingLastPathComponent

        // Inside cwd: project-relative — `/` prefix means "relative to project root"
        if !normalizedCwd.isEmpty,
           parentDir.hasPrefix(normalizedCwd) {
            let suffix = String(parentDir.dropFirst(normalizedCwd.count))
            // Drop any leading slash from the stripped suffix to avoid `//src`.
            let cleaned = suffix.hasPrefix("/") ? String(suffix.dropFirst()) : suffix
            if cleaned.isEmpty { return "/**" }
            return "/\(cleaned)/**"
        }

        // Under home dir but outside cwd: `~/` anchor
        if parentDir.hasPrefix(home) {
            let suffix = String(parentDir.dropFirst(home.count))
            let cleaned = suffix.hasPrefix("/") ? String(suffix.dropFirst()) : suffix
            if cleaned.isEmpty { return "~/**" }
            return "~/\(cleaned)/**"
        }

        // Absolute path outside cwd and home: `//` prefix per Claude's syntax.
        return "/\(parentDir)/**"   // becomes "//absolute/path/**"
    }

    // MARK: - Settings file I/O

    private static let lock = NSLock()

    private static func readSettings(at url: URL) throws -> [String: Any] {
        guard FileManager.default.fileExists(atPath: url.path) else {
            return [:]
        }
        let data: Data
        do {
            data = try Data(contentsOf: url)
        } catch {
            throw PermissionRuleError.ioFailure("read \(url.path): \(error.localizedDescription)")
        }
        if data.isEmpty { return [:] }
        let parsed: Any
        do {
            parsed = try JSONSerialization.jsonObject(with: data, options: [])
        } catch {
            throw PermissionRuleError.malformedExistingConfig(
                "\(url.path) is not valid JSON: \(error.localizedDescription) — refusing to overwrite"
            )
        }
        guard let dict = parsed as? [String: Any] else {
            throw PermissionRuleError.malformedExistingConfig(
                "\(url.path) is JSON but not an object — refusing to overwrite"
            )
        }
        return dict
    }

    private static func writeSettings(_ settings: [String: Any], to url: URL) throws {
        let data: Data
        do {
            // .prettyPrinted + sortedKeys = stable diffs in git when the
            // user inspects settings.local.json after we've touched it.
            data = try JSONSerialization.data(
                withJSONObject: settings,
                options: [.prettyPrinted, .sortedKeys]
            )
        } catch {
            throw PermissionRuleError.ioFailure("encode: \(error.localizedDescription)")
        }
        do {
            try data.write(to: url, options: .atomic)
        } catch {
            throw PermissionRuleError.ioFailure("write \(url.path): \(error.localizedDescription)")
        }
    }
}
