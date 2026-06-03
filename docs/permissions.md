# Permission system

How AgentPulse handles "Always allow" persistence across multiple AI coding
agents. This is a multi-agent app — Claude Code, Codex CLI, Gemini CLI,
Cursor, Cline, Aider — and the agents have **fundamentally different**
permission models. There is no single allow-list format that works for all.

> **Status:** This doc describes the **target architecture**. The codebase
> currently has Bypass plumbing, an `AllowRules.isAllowed()` pre-hook check,
> and a `~/.agentpulse/rules.json` store — all to be removed as the
> redesign lands. See "Migration" below for the deletion checklist.

## Problem

When the user clicks **Always allow** on a permission card, the rule must
persist somewhere so the next matching request auto-approves without
re-prompting.

The naive approach (`~/.agentpulse/rules.json` maintained by AgentPulse +
`isAllowed()` interception in our hook) has three problems:

1. **Duplicates the agent's own permission system.** Most agents we
   support already have writable persistent rule files. Maintaining a
   parallel store means rules created via the agent's own CLI (e.g.
   Claude's `/permissions`) wouldn't apply, and rules created in
   AgentPulse wouldn't show up there.
2. **Diverges from "in this repo" UX.** The naive store had no `cwd`
   field, so a rule created in repo A also applied in repo B.
3. **Pretends all agents are isomorphic.** Their permission models are
   not (see below).

## Per-agent reality

Verified against primary docs in May 2026. Re-verify if more than a
quarter has passed — agents iterate fast.

| Agent | Has writable pattern allow-list? | Storage | Format example |
|---|---|---|---|
| **Claude Code** | ✅ first-class | `<repo>/.claude/settings.local.json` (or `~/.claude/settings.json`) | `"permissions": { "allow": ["Bash(pnpm prisma:*)", "Edit(/src/**)"] }` |
| **Codex CLI** | ✅ first-class | `<repo>/.codex/rules/*.rules` (project, requires trust) + `~/.codex/rules/default.rules` (user) | `prefix_rule(pattern=["pnpm", "prisma"], decision="allow")` |
| **Gemini CLI** | ✅ first-class | `<repo>/.gemini/settings.json` (or `~/.gemini/`) | `"tools": { "core": ["run_shell_command(git)"] }` (note: key is `core`, not `allowed`) |
| **Cursor CLI** | ✅ first-class | `<repo>/.cursor/cli.json` (or `~/.cursor/cli-config.json`) | `"permissions": { "allow": ["Shell(git)", "Read(src/**/*.ts)"] }` |
| **Cursor IDE** | ⚠️ internal SQLite | `~/Library/Application Support/Cursor/.../state.vscdb` | `composerState.yoloCommandAllowlist`. Writing while Cursor is open corrupts state — unsafe to touch externally |
| **Cline** (IDE & SDK) | ⚠️ no external write API | UI state / SDK runtime config | `toolPolicies.autoApprove` exists in the SDK but is passed at session-construction time, not persisted to a file an external app can write |
| **Aider** | ❌ blanket only | YAML config | Only `--yes-always` (all-or-nothing). Pattern allow-list is an [open feature request](https://github.com/paul-gauthier/aider/issues/1327) |

**Key insight:** four agents (Claude / Codex / Gemini / Cursor CLI) all
support a writable persistent pattern allow-list. They differ in:
- File format: JSON for Claude, Gemini, Cursor CLI; a custom `prefix_rule(...)`
  DSL for Codex (the `.rules` file is not TOML — it's an OpenAI-internal
  rule language)
- Pattern syntax: `Bash(...)` (Claude) vs `Shell(...)` (Cursor CLI) vs
  `run_shell_command(...)` (Gemini) vs `prefix_rule(pattern=[...])` (Codex)
- Per-repo vs user-global scoping. Claude, Gemini, Cursor CLI all support
  per-repo files natively. Codex supports project-local rules at
  `<repo>/.codex/rules/` but only when that `.codex/` layer is "trusted"
  (run `codex trust` or equivalent first) — fall back to user-global
  `~/.codex/rules/default.rules` when the project isn't trusted

The remaining three (Cursor IDE, Cline, Aider) have no usable external
surface and must hide the **Always** button.

## Strategy

Two tiers, not three. The earlier `.localStore` middle tier was dropped:
no agent we currently support both (a) gives us a hook and (b) lacks a
writable rules file. If we ever add such an agent, reintroduce
`.localStore` then.

```swift
enum PermissionStrategy {
    case native(any NativeRuleWriter.Type)  // Write to agent's own config
    case notSupported                       // No persistent rules possible
}
```

### `.native` — delegate to the agent

The agent has its own allow-list config. We translate `(toolName,
toolInput, cwd)` into the agent's pattern syntax and write a rule.
**Our hook doesn't even fire** for subsequent matching requests — the
agent auto-approves before reaching us. This is the ideal path:

- No duplicate state — the agent's CLI (e.g. `/permissions`) and
  AgentPulse see the same rules
- "In this repo" scoping is free when we write to the per-repo config
  variant
- Removing AgentPulse leaves the rules in place — they keep working in
  the agent's native flow

### `.notSupported` — hide the Always button

The agent has no usable external persistence surface. The **Always**
button is hidden entirely on cards from these agents — promising
"remember this forever" when we can't deliver is a lie. Allow and Deny
still work as one-shot decisions.

## Per-agent mapping

```swift
extension AgentKind {
    var permissionStrategy: PermissionStrategy {
        switch self {
        case .claudeCode: .native(ClaudeCodeRuleWriter.self)
        case .codexCLI:   .native(CodexCLIRuleWriter.self)
        case .geminiCLI:  .native(GeminiCLIRuleWriter.self)
        case .cursor:     .notSupported    // see Cursor caveat below
        case .cline:      .notSupported
        case .aider:      .notSupported
        }
    }
}
```

### Cursor caveat

`AgentKind.cursor` currently covers both Cursor IDE and Cursor CLI
modes. Their permission surfaces are very different:

- **Cursor IDE**: SQLite at `state.vscdb`. Cannot safely write externally.
  → `.notSupported`
- **Cursor CLI** (`cursor-agent` command): JSON at `~/.cursor/cli-config.json`
  or `<repo>/.cursor/cli.json`. Fully writable.
  → would be `.native(CursorCLIRuleWriter)`

For now both are `.notSupported`. To split:
1. Extend `HostDetector` to distinguish `Cursor.app` (IDE) from `cursor-agent`
   (CLI) by parent-process inspection
2. Add `AgentKind.cursorCLI` case or a `subtype` field on `AgentSession`
3. Implement `CursorCLIRuleWriter` (the format is essentially identical
   to Claude Code's, just `Shell(...)` instead of `Bash(...)`)

## What gets written, per agent

### Claude Code → `<repo>/.claude/settings.local.json`

```json
{
  "permissions": {
    "allow": [
      "Bash(pnpm prisma:*)",
      "Edit(/src/**)"
    ]
  }
}
```

**Path syntax** ([claude docs](https://code.claude.com/docs/en/permissions),
verified May 2026):

| Anchor | Meaning | Use case |
|---|---|---|
| `Edit(file)` or `Edit(./file)` | Relative to cwd | Most common |
| `Edit(/src/**)` | **Relative to project root** (the leading `/` is NOT absolute) | Glob inside the repo |
| `Edit(//abs/path/**)` | **Absolute** filesystem path (note: double slash) | Files outside the repo |
| `Edit(~/path)` | Home directory | Per-user files |

**Trailing wildcard:** `Bash(pnpm prisma:*)` and `Bash(pnpm prisma *)`
are equivalent. The Claude TUI writes the space form; either is fine.
A mid-pattern colon is literal, not wildcard — `Bash(git:* push)`
does NOT match `git push origin main`.

**Compound commands:** Claude splits on `&&`, `||`, `;`, `|` etc. and
writes a separate rule per subcommand. Up to 5 rules per compound. We
don't need to replicate this — we write one rule per AgentPulse Always
click, and let the user click again if they want more rules.

**Process wrapper stripping** (handled by Claude, not us): `timeout`,
`time`, `nice`, `nohup`, `stdbuf`, bare `xargs` are stripped before
matching. So a rule `Bash(npm test:*)` already matches `timeout 30
npm test`. We don't need to do anything special — just write the
inner-command rule.

### Codex CLI → `<repo>/.codex/rules/agentpulse.rules` (or `~/.codex/rules/default.rules`)

```
prefix_rule(
    pattern = ["pnpm", "prisma"],
    decision = "allow",
    justification = "AgentPulse user clicked Always"
)
```

**Two layers**, project preferred:

1. **Project layer** `<repo>/.codex/rules/agentpulse.rules` — preferred when
   the project's `.codex/` directory is trusted (user has run `codex trust`
   on the repo at least once). Gives per-repo "in this repo" scoping.
   Codex scans `rules/` under every active config layer at startup.
2. **User layer** `~/.codex/rules/default.rules` — fallback. Used when the
   project `.codex/` layer isn't trusted. Rule applies globally for this user.

`CodexCLIRuleWriter` should probe trust state first: if the project layer
is trusted, write there; otherwise, write to user-global and surface
"globally" in the UI helper text (instead of "in this repo").

Decisions: `"allow"` / `"prompt"` / `"forbidden"`. Codex's own TUI uses
the same `.rules` files when the user picks "don't ask again", so our
writes interoperate cleanly.

### Gemini CLI → `<repo>/.gemini/settings.json`

```json
{
  "tools": {
    "core": ["run_shell_command(git)", "run_shell_command(pnpm prisma)"]
  }
}
```

**Important:** the key is `tools.core`, NOT `tools.allowed`. Per [the
Gemini CLI shell tool docs](https://github.com/google-gemini/gemini-cli/blob/main/docs/tools/shell.md):
*"To restrict `run_shell_command` to a specific set of commands, add
entries to the `core` list under the `tools` category in the format
`run_shell_command(<command>)`."*

Matcher is prefix-based by default — `run_shell_command(git)` matches any
`git ...` invocation. No `:*` suffix needed.

## Pattern derivation rules

The `(toolName, toolInput, cwd)` from a permission request must be
translated into the target agent's pattern. For Claude Code:

### Bash

Take the first N whitespace-separated tokens, append `:*`. Choose N:

- **N = 2** when the second token is a subcommand-shaped word
  (alphanumeric, not starting with `-`). Examples:
  - `pnpm prisma migrate dev` → `Bash(pnpm prisma:*)` ✓
  - `git log --oneline -10` → `Bash(git log:*)` ✓
  - `cargo test --release` → `Bash(cargo test:*)` ✓
- **N = 1** when the second token is a flag (starts with `-`) or
  doesn't exist. Examples:
  - `swift --version` → `Bash(swift --version)` (exact — no `:*`,
    likely a one-off check)
  - `ls -la` → not patternable (`ls` is auto-approved by Claude)
- **Exact match** (no `:*`) when the command is a single token with no
  args, e.g. `pwd`.

This is heuristic. The UI's helper text — `"Always" will allow `<pattern>`
in this repo` — shows the derived pattern *before* the user clicks,
so they can opt out by clicking Allow (one-shot) instead.

### Edit / Write

Use the file's path relative to `cwd` (the session's project root),
truncated to the parent directory + `/**`:

| File | Pattern |
|---|---|
| `<cwd>/src/foo.swift` | `Edit(/src/**)` (project-relative — single leading slash) |
| `<cwd>/src/sub/foo.swift` | `Edit(/src/sub/**)` |
| `/tmp/scratch.txt` (outside cwd) | `Edit(//tmp/**)` (absolute — double slash) |
| `~/.zshrc` | `Edit(~/**)` (home — tilde) |

**Important divergence from Claude's native UX:** Claude's "Yes, don't
ask again" for Edit/Write is **session-scoped only**, not persistent.
By writing to `settings.local.json` AgentPulse promotes it to persistent
across sessions. This is intentional — AgentPulse users explicitly opt
into persistence via the Always button — but the Always helper text
should make this clear: `"Always" will persistently allow ... (Claude's
default is session-scoped for Edit/Write)`.

### Read / Grep / Glob

**Don't show Always for these.** Claude auto-approves read-only tools
by default — Read, Grep, Glob, and a built-in set of read-only Bash
commands (`ls`, `cat`, `pwd`, `head`, `tail`, `grep`, `find`, `wc`,
`which`, `diff`, `stat`, `du`, `cd`, read-only `git`). Permission
cards for these shouldn't even fire in the first place. If one does
(custom hook config?), it's an edge case — render the card but hide
Always.

## UI behavior

The permission banner reads `session.agentKind.permissionStrategy`:

- `.native(let writer)` → Always button visible. Helper text below the
  buttons reads `"Always" will allow <pattern> in this repo` where
  `<pattern>` comes from `writer.patternPreview(toolName: toolInput:)`.
  The "in this repo" wording matches when the writer's target file is
  per-repo. Codex is a special case: when the project `.codex/` layer
  is trusted, write to the project layer and say "in this repo";
  otherwise fall back to user-global and say "globally".
- `.notSupported` → Always button hidden. Optionally show small
  caption `Always not supported for <agent>` so the user understands
  why. Allow / Deny remain.

This is the only place in the view layer that branches per-agent for
permissions — keep it small.

## Reply field

The design introduces an optional Reply text field above the buttons:
*"Reply (optional) — tell the agent what to do instead"*.

- The text is captured in `@State` inside the banner.
- When the user clicks **Deny**, the reply (if non-empty) becomes the
  `reason` in `PermissionDecision.deny(reason: ...)` — Claude Code
  passes this string back to the model as feedback.
- When the user clicks **Allow** or **Always**, the reply is ignored.
  The Allow path doesn't carry a free-form message in the hook protocol.

This gives the user a way to say "no, use `psql migrate` instead"
without leaving the notch.

## Bypass: proposed removal

Earlier the UI had a four-button row: Deny / Allow / Always / **Bypass**.
The Bypass plumbing is a half-built feature in the codebase TODAY
(still present at the time of writing):

- UI labels it dangerous (red, two-step "Confirm?")
- Comments describe it as "disables future prompts for this tool"
- Actual implementation in `AppState.swift:142` maps
  `PermissionDecision.bypass` to `.allow(hookEvent:)` — **identical to
  a one-shot Allow**, no persistence, no special effect

To be removed in this redesign. No functional loss. If a real
"silence this tool" feature is wanted later, build it on top of
`PermissionStrategy.native` (write a wildcard rule like `Bash` or
`Shell` to the agent's config — both Claude and Cursor CLI accept the
bare tool name to mean "all uses").

## Migration

Files / call-sites to remove or update as this redesign lands. Line
numbers verified at commit time — re-grep if working from a later
revision.

### Delete the AllowRules path

The whole `AllowRules` API (the `AllowRule` struct, `isAllowed`, `add`,
`load`, `save`, `remove(toolName:)`, `removeAt(index:)`) goes away. The
`~/.agentpulse/rules.json` file is abandoned in place — no read path
remains. Call sites:

| Location | Change |
|---|---|
| `Sources/AgentPulseCore/Services/AllowRules.swift` | Delete the whole `AllowRule` struct (line 18), `isAllowed()` (line 33), `add()` (line 47), `remove(toolName:)` (line 57), `removeAt(index:)` (line 66), `load()` (line 76), `save()` (line 84). Move `primaryArg()` (line 94) into `PatternDerivation.swift` (or just inline it) since `ClaudeCodeRuleWriter` needs the same first-arg extraction logic. Delete `matchGlob()` — Claude does its own matching |
| `Sources/AgentPulse/App/AppState.swift:107` | Drop the `AllowRules.isAllowed(...)` pre-hook gate. Rules are now enforced by the agent itself before our hook fires |
| `Sources/AgentPulse/Views/Notch/NotchContentView.swift:578-579` | The inline-banner "Always" handler (`AllowRules.primaryArg` + `AllowRules.add`) → replace with `ClaudeCodeRuleWriter.writeAllowRule(toolName: toolInput: cwd:)` via the session's `agentKind.permissionStrategy` |
| `Sources/AgentPulse/Views/Notch/NotchContentView.swift:450` | Comment references "AllowRules" in the right-click menu hint — update to "Permission rules" or drop |
| `Sources/AgentPulse/Views/Notch/NotchPanel.swift:470-471` | Keyboard `^A` (Always) handler → same `ClaudeCodeRuleWriter` call |
| `Sources/AgentPulse/Views/Notch/NotchPanel.swift:39` | `AllowRules.removeAt(index:)` in the right-click rules menu deletion handler — see "Drop the rules-management menu" below |
| `Sources/AgentPulse/Views/Notch/NotchPanel.swift:687` | `AllowRules.load()` for displaying saved rules in the right-click menu — see "Drop the rules-management menu" below |

### Drop the rules-management menu

`NotchPanel.swift:687` populates a right-click menu listing all saved
`AllowRules` with delete buttons. With this redesign:

- Rules now live in each agent's own config file (`.claude/settings.local.json`,
  `.codex/rules/`, etc.). Aggregating them across multiple repos / agents
  for one unified menu is non-trivial UX work.
- Each agent already has its own native rules-management UI: Claude's
  `/permissions`, Codex's TUI rules editor, Gemini's settings command, etc.
- For this redesign, **remove the rules-management menu entirely**.
  Users manage rules in their agent's native UI. Add a hint in the
  right-click menu pointing them there ("Manage rules: run `/permissions`
  in your terminal").

### Drop Bypass plumbing

| Location | Change |
|---|---|
| `Sources/AgentPulseCore/Models/PermissionRequest.swift:105` | Remove `case bypass` from `PermissionDecision` enum |
| `Sources/AgentPulse/App/AppState.swift:142` | Remove `case .bypass` branch |
| `Sources/AgentPulseCore/Services/AgentManager.swift:179` | Remove `bypassPermission(id:)` |
| `Sources/AgentPulse/Views/Components/PermissionBanner.swift` | Remove `onBypass`, `bypassArmedId`, the `bypass` / `bypassConfirm` `PermissionButton.Style` cases, the two-step confirm state machine |
| `Sources/AgentPulse/Views/Notch/NotchContentView.swift:583` | Remove the `onBypass:` callback wired to `agentManager.bypassPermission(id:)` |
| `Sources/AgentPulse/Views/Notch/NotchPanel.swift:478` | Remove `^B` keyboard shortcut handler |

### Rewrite PermissionBanner

`Sources/AgentPulse/Views/Components/PermissionBanner.swift` — full
visual redesign to match the spec: orange question header, monospaced
black code block, optional Reply input field, three buttons (Allow ⌃Y /
Always ⌃A / Deny ⌃N) plus a jump-to-terminal ↗ icon button. Helper
text below shows the pattern that "Always" would persist. Add the
`agentKind.permissionStrategy` branch to hide Always when
`.notSupported`.

### New files

| File | Purpose |
|---|---|
| `Sources/AgentPulseCore/Services/Permissions/PermissionStrategy.swift` | Two-case enum + `NativeRuleWriter` protocol |
| `Sources/AgentPulseCore/Services/Permissions/ClaudeCodeRuleWriter.swift` | Reads / merges / writes `<cwd>/.claude/settings.local.json` |
| `Sources/AgentPulseCore/Services/Permissions/PatternDerivation.swift` | Per-agent pattern derivation. Claude format first; Codex/Gemini/Cursor stubs return their respective syntaxes. Signature: `derive(toolName:toolInput:cwd:agent:) -> (storedPattern: String, displayPattern: String)` |
| `Sources/AgentPulseCore/Services/Permissions/CodexCLIRuleWriter.swift` | **TODO — requires hook integration first.** Writes `<repo>/.codex/rules/agentpulse.rules` or `~/.codex/rules/default.rules` |
| `Sources/AgentPulseCore/Services/Permissions/GeminiCLIRuleWriter.swift` | **TODO — requires hook integration first.** Writes `<cwd>/.gemini/settings.json` |
| `Sources/AgentPulseCore/Services/Permissions/CursorCLIRuleWriter.swift` | **TODO — requires hook integration first.** Writes `<cwd>/.cursor/cli.json` |

### Prerequisite: non-Claude hook integration

The non-Claude writers are useless without the corresponding hook
plumbing — AgentPulse only intercepts permission requests it receives
via its HTTP server, and today only `HookInstaller.installClaudeCodeHooks()`
exists in `Sources/AgentPulseCore/Services/HookInstaller.swift`. For
each non-Claude `.native` writer to actually fire, we need:

1. A hook-installer method for that agent (`installCodexCLIHooks()`,
   etc.) that registers AgentPulse's bridge as the agent's approval
   callback
2. The agent's approval-request event shape mapped onto our
   `HookEvent` model
3. `AgentEvent` + `AgentSession.apply` extended for any
   agent-specific event variants

Implementing a writer without these is moot — there's no permission
flow to write rules for. Order of work for each agent: hook integration
first, writer second.

## TODOs

- **`CodexCLIRuleWriter`** — when Codex sessions get hooked up. Format
  is `prefix_rule(pattern=[...], decision="allow")`.
- **`GeminiCLIRuleWriter`** — when Gemini sessions get hooked up.
- **Cursor CLI vs IDE distinction** — extend `HostDetector` to identify
  the `cursor-agent` CLI process, then split `AgentKind.cursor` into
  IDE vs CLI variants.
- **Cline external write surface** — recheck periodically; if Cline
  publishes a file-based auto-approve API, move from `.notSupported`
  to `.native`.
- **Aider pattern allow-list** — track [aider#1327](https://github.com/paul-gauthier/aider/issues/1327).

## Prior art

No open-source project has solved the cross-agent permission abstraction
cleanly:

- [open-vibe-island](https://github.com/Octane0411/open-vibe-island) —
  writes to per-agent configs imperatively, no unified protocol.
- [ping-island](https://github.com/erha19/ping-island) — broadest agent
  matrix; auto-approve only works on Claude Code.
- [claude-island](https://github.com/farouqaldori/claude-island) — Claude
  Code only.

[Claude Code issue #21606](https://github.com/anthropics/claude-code/issues/21606)
and [#32973](https://github.com/anthropics/claude-code/issues/32973)
confirm Claude Code itself doesn't auto-write to `settings.local.json`
on "always allow" for non-Bash tools — so AgentPulse fills a real gap
(persistent Edit/Write allow rules) rather than duplicating an existing
feature.

## Sources

Verified May 2026. Re-verify before major changes.

- [Claude Code permissions docs](https://code.claude.com/docs/en/permissions)
- [Codex CLI rules docs](https://developers.openai.com/codex/rules)
- [Gemini CLI settings reference](https://github.com/google-gemini/gemini-cli/blob/main/docs/cli/settings.md)
- [Cursor CLI permissions reference](https://cursor.com/docs/cli/reference/permissions)
- [Cline auto-approve docs](https://docs.cline.bot/features/auto-approve)
- [Cline SDK permission handling](https://docs.cline.bot/sdk/guides/permission-handling)
- [Aider options reference](https://aider.chat/docs/config/options.html)
