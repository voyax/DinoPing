import Foundation
import Testing
@testable import AgentPulseCore

/// Pattern derivation is heuristic — these tests pin the rules from
/// `docs/permissions.md` > "Pattern derivation rules". Adjust both the
/// doc and these tests in lockstep if the heuristic changes.
@Suite("ClaudeCodeRuleWriter pattern derivation")
struct ClaudeCodeRuleWriterTests {

    // MARK: - Bash

    @Test func bashSubcommandShapedSecondToken() {
        // Two tokens, second is alphanumeric → first two + ":*"
        #expect(ClaudeCodeRuleWriter.deriveBashPattern("pnpm prisma migrate dev --name X") == "pnpm prisma:*")
        #expect(ClaudeCodeRuleWriter.deriveBashPattern("git log --oneline -10") == "git log:*")
        #expect(ClaudeCodeRuleWriter.deriveBashPattern("cargo test --release") == "cargo test:*")
    }

    @Test func bashFlaggedSecondToken() {
        // Second token starts with `-` → just the command + `:*`. The
        // user clicking Always on `curl -s ...` wants all curls, not
        // pinned to this exact flag list.
        #expect(ClaudeCodeRuleWriter.deriveBashPattern("swift --version") == "swift:*")
        #expect(ClaudeCodeRuleWriter.deriveBashPattern("ls -la /tmp") == "ls:*")
        #expect(ClaudeCodeRuleWriter.deriveBashPattern(#"curl -s -o /dev/null -w "HTTP %{http_code}" https://example.com/"#) == "curl:*")
    }

    @Test func bashSingleToken() {
        #expect(ClaudeCodeRuleWriter.deriveBashPattern("pwd") == "pwd:*")
    }

    /// Bash's `VAR=value cmd args` syntax sets env vars for `cmd` — the
    /// real "command" is `cmd`, not `VAR=value`. The pattern must strip
    /// the env-var prefix or the saved rule never matches anything
    /// useful (and the helper text overflows the card).
    @Test func bashStripsEnvVarAssignments() {
        // Standard uppercase env var
        #expect(ClaudeCodeRuleWriter.deriveBashPattern("NODE_ENV=production npm test") == "npm test:*")
        // Single uppercase letter (the case that surfaced this bug in the wild)
        #expect(ClaudeCodeRuleWriter.deriveBashPattern("B=~/.claude/path echo something") == "echo something:*")
        // Multiple stacked env vars
        #expect(ClaudeCodeRuleWriter.deriveBashPattern("A=1 B=2 cargo test") == "cargo test:*")
        // Env var with no command after it → empty (matches the "empty" case)
        #expect(ClaudeCodeRuleWriter.deriveBashPattern("FOO=bar") == "")
        // Lowercase `count=5` is NOT an env var (more likely a flag value); leave alone
        #expect(ClaudeCodeRuleWriter.deriveBashPattern("count=5 cmd") == "count=5 cmd:*")
    }

    @Test func bashEmptyOrWhitespace() {
        #expect(ClaudeCodeRuleWriter.deriveBashPattern("") == "")
        #expect(ClaudeCodeRuleWriter.deriveBashPattern("   ") == "")
    }

    // MARK: - File paths

    @Test func filePathInsideCwdUsesProjectRelative() {
        // Inside the project root: single leading slash (project-relative)
        let pattern = ClaudeCodeRuleWriter.deriveFilePathPattern(
            path: "/Users/alice/repo/src/foo.swift",
            cwd: "/Users/alice/repo"
        )
        #expect(pattern == "/src/**")
    }

    @Test func filePathNestedInsideCwd() {
        let pattern = ClaudeCodeRuleWriter.deriveFilePathPattern(
            path: "/Users/alice/repo/src/sub/foo.swift",
            cwd: "/Users/alice/repo"
        )
        #expect(pattern == "/src/sub/**")
    }

    @Test func filePathAtRepoRootUsesBareGlob() {
        // File directly at cwd → parent is cwd itself → "/**"
        let pattern = ClaudeCodeRuleWriter.deriveFilePathPattern(
            path: "/Users/alice/repo/README.md",
            cwd: "/Users/alice/repo"
        )
        #expect(pattern == "/**")
    }

    @Test func filePathOutsideCwdAndHomeUsesDoubleSlashAbsolute() {
        // Outside both cwd and $HOME: `/<abspath>/**` — when prefixed
        // with the outer `Edit(...)` wrapper, this becomes the
        // double-slash form Claude requires for absolute paths.
        let pattern = ClaudeCodeRuleWriter.deriveFilePathPattern(
            path: "/tmp/scratch.txt",
            cwd: "/Users/alice/repo"
        )
        // Parent of /tmp/scratch.txt is /tmp → leading "/" + "/tmp/**"
        #expect(pattern == "//tmp/**")
    }

    @Test func filePathUnderHomeButOutsideCwdUsesTilde() {
        // Path under home, not under cwd → `~/...` anchor
        let home = NSHomeDirectory()
        let pattern = ClaudeCodeRuleWriter.deriveFilePathPattern(
            path: "\(home)/.zshrc",
            cwd: "/Users/alice/repo"
        )
        #expect(pattern == "~/**")
    }

    @Test func filePathEmptyFallsBackToRoot() {
        #expect(ClaudeCodeRuleWriter.deriveFilePathPattern(path: "", cwd: "/x") == "/**")
    }

    // MARK: - End-to-end derivePattern

    @Test func derivePatternBashFormatsAsTool() {
        let pattern = ClaudeCodeRuleWriter.derivePattern(
            toolName: "Bash",
            toolInput: ["command": "pnpm prisma migrate dev"],
            cwd: "/repo"
        )
        #expect(pattern.formatted == "Bash(pnpm prisma:*)")
    }

    @Test func derivePatternEditFormatsAsTool() {
        let pattern = ClaudeCodeRuleWriter.derivePattern(
            toolName: "Edit",
            toolInput: ["file_path": "/Users/alice/repo/src/foo.swift"],
            cwd: "/Users/alice/repo"
        )
        #expect(pattern.formatted == "Edit(/src/**)")
    }

    @Test func derivePatternUnknownToolFallsBackToBare() {
        // Unknown tool — return just the tool name. Users opting into
        // Always on an unknown tool get the broadest possible rule;
        // that's the literal intent of clicking "Always".
        let pattern = ClaudeCodeRuleWriter.derivePattern(
            toolName: "WeirdCustomTool",
            toolInput: ["foo": "bar"],
            cwd: "/x"
        )
        #expect(pattern.formatted == "WeirdCustomTool")
    }
}
