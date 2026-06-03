import AgentPulseCore
import SwiftUI

/// Inline approval card shown inside a session card when an agent needs
/// the user's permission. New layout (May 2026 redesign): orange
/// question header, monospaced code box, optional Reply text field, and
/// three primary buttons (Allow / Always / Deny) plus a jump-to-terminal
/// icon. The Always button hides automatically when the originating
/// agent has no writable allow-list config (see
/// `AgentKind.permissionStrategy`).
///
/// Reply field: free text the user types as feedback to the agent.
/// Sent through to `onDeny(reason:)` — Claude Code passes it back to the
/// model. On Allow / Always the reply is discarded (the hook protocol
/// has no payload for an approval).
struct PermissionBanner: View {
    let request: PermissionRequest
    let queuePosition: Int
    let queueTotal: Int
    /// How "Always" persists for this session's agent. Drives:
    /// - whether the Always button is visible
    /// - the helper text below the buttons
    let strategy: PermissionStrategy
    let onAllow: () -> Void
    let onAlwaysAllow: () -> Void
    /// `reason` is the Reply field's text, or nil if empty.
    let onDeny: (_ reason: String?) -> Void
    let onJump: () -> Void

    @State private var appeared = false
    @State private var reply: String = ""

    /// Reply text with whitespace stripped, or nil if empty. Used in
    /// both the Enter-to-submit handler and the Deny click handler so
    /// "  \n  " doesn't sneak through as a non-empty reason.
    private var trimmedReply: String? {
        let t = reply.trimmingCharacters(in: .whitespacesAndNewlines)
        return t.isEmpty ? nil : t
    }

    var body: some View {
        // No background of its own — the parent SessionCard's `isWaiting`
        // state already paints the orange-tinted fill + border for the
        // whole card. Stacking another orange container here produced
        // the "double tint" mismatch with the design.
        VStack(alignment: .leading, spacing: 10) {
            questionHeader

            contentView

            replyField

            buttonRow

            helperText
        }
        .opacity(appeared ? 1 : 0)
        .offset(y: appeared ? 0 : -8)
        .animation(.spring(duration: 0.3), value: appeared)
        .onAppear { appeared = true }
    }

    // MARK: - Question header
    //
    // The single orange line that tells the user, in plain English,
    // what the agent is asking for. Replaces the old "tool name +
    // icon + age timestamp" header — age is on the session card's
    // row4Meta, and the question is more useful than a tool name.

    @ViewBuilder
    private var questionHeader: some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Text(questionText)
                .font(.system(size: 13, weight: .semibold))
                .tracking(-0.1)
                .foregroundStyle(Color.ap.textOrange)

            Spacer(minLength: 4)

            // Queue position when 2+ permissions stacked in the same
            // session (rare, but possible — e.g. agent retried).
            if queueTotal > 1 {
                Text("\(queuePosition) / \(queueTotal)")
                    .font(.system(size: 10, weight: .medium, design: .monospaced))
                    .foregroundStyle(.white.opacity(0.4))
            }
        }
    }

    private var questionText: String {
        switch request.toolName {
        case "Bash": "Run shell command?"
        case "Edit": "Approve edit?"
        case "Write": "Create file?"
        case "Read": "Read file?"       // rare — Claude auto-approves Read
        case "Glob", "Grep": "Allow search?"
        default: "\(request.toolName) — allow?"
        }
    }

    // MARK: - Content area
    //
    // Renders the actual command / diff / file content — what the user
    // is being asked to approve. Monospaced black box per the design.

    @ViewBuilder
    private var contentView: some View {
        if request.hasDiff, let old = request.diffOldString, let new = request.diffNewString {
            DiffView(
                filePath: request.filePath ?? "unknown",
                oldString: old,
                newString: new
            )
        } else if request.toolName == "Bash", let cmd = request.bashCommand {
            bashCommandView(cmd)
        } else if request.toolName == "Write", let content = request.writeContent {
            writeContentView(content)
        } else {
            // Generic key-value renderer covers every other tool —
            // Read, Glob, Grep, WebFetch, Task, TodoWrite, future
            // tools. Important keys (file_path / url / pattern / etc.)
            // get pinned to the top in a stable order; the rest follow
            // alphabetically. New tools work without code changes.
            genericInputView
        }
    }

    /// Keys that are conventionally the "subject" of a tool call. We
    /// pin them to the top of the generic renderer in this order so the
    /// most important info reads first.
    private static let pinnedInputKeys = [
        "file_path", "path", "dir", "url", "command", "pattern",
        "query", "prompt", "description",
    ]

    @ViewBuilder
    private var genericInputView: some View {
        // Build ordered list once: pinned keys in their declared order
        // (that actually exist on this request), then everything else
        // sorted alphabetically for stability.
        let allKeys = Array(request.toolInput.keys)
        let allKeysSet = Set(allKeys)
        let pinned = Self.pinnedInputKeys.filter { allKeysSet.contains($0) }
        let rest = allKeys
            .filter { !Self.pinnedInputKeys.contains($0) }
            .sorted()
        let ordered = pinned + rest

        VStack(alignment: .leading, spacing: 6) {
            ForEach(ordered, id: \.self) { key in
                HStack(alignment: .firstTextBaseline, spacing: 12) {
                    Text(key)
                        .font(.system(size: 10, weight: .medium, design: .monospaced))
                        .foregroundStyle(Color.white.opacity(0.5))
                        .frame(width: 78, alignment: .leading)
                    Text(formattedValue(forKey: key))
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(Color.white.opacity(0.85))
                        // Bumped to match maxValueLines + a 1-line buffer
                        // for the "… +N more" marker. Short values still
                        // render as 1 line; nested JSON gets vertical room.
                        .lineLimit(Self.maxValueLines + 1)
                        .multilineTextAlignment(.leading)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(codeBoxBackground)
    }

    /// Maximum visible lines for a single value before we truncate with
    /// "… +N more". Picked to keep the banner from exploding when a tool
    /// passes a large nested structure (e.g. TodoWrite's `todos` array of
    /// 50 items), while still showing enough for the user to understand
    /// what they're approving.
    private static let maxValueLines = 8

    /// String-formatted value of a toolInput key.
    /// - Path-like keys (file_path / path / dir) → smart-displayed via `displayPath`
    /// - Arrays / dicts → JSON pretty-printed with sorted keys, then
    ///   line-capped — without this, `AnyCodable.value` falls through
    ///   to Swift's `CustomStringConvertible` and renders nested types
    ///   as one giant Swift-syntax blob (`[["text": ..., ...], ...]`),
    ///   which truncates mid-token and hides what's being approved.
    /// - Long string values → truncated to 200 chars
    /// - Primitive scalars (Int / Bool / null) → simple stringification
    private func formattedValue(forKey key: String) -> String {
        guard let value = request.toolInput[key] else { return "—" }
        let pathLikeKeys: Set<String> = ["file_path", "path", "dir"]
        if pathLikeKeys.contains(key), let s = value.stringValue {
            return displayPath(s)
        }
        // Nested structures need JSON formatting to be human-readable.
        // JSONSerialization handles AnyCodable's underlying Any storage
        // directly because the storage is always JSON-compatible (it
        // was decoded from JSON in the first place).
        if value.value is [Any] || value.value is [String: Any] {
            if let data = try? JSONSerialization.data(
                withJSONObject: value.value,
                options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
            ),
            let json = String(data: data, encoding: .utf8) {
                return truncatedToLines(json, max: Self.maxValueLines)
            }
            // Fall through to scalar handling if JSON encoding fails —
            // should be unreachable for AnyCodable-sourced values.
        }
        let raw = value.stringValue ?? "\(value.value)"
        if raw.count > 200 {
            return String(raw.prefix(200)) + "…"
        }
        return raw
    }

    /// Trim `text` to at most `max` lines, appending a `… +N more lines`
    /// marker when truncation happens.
    private func truncatedToLines(_ text: String, max: Int) -> String {
        let lines = text.components(separatedBy: "\n")
        guard lines.count > max else { return text }
        let kept = lines.prefix(max).joined(separator: "\n")
        return kept + "\n  … +\(lines.count - max) more lines"
    }

    private static let maxVisibleLines = 8

    @ViewBuilder
    private func bashCommandView(_ cmd: String) -> some View {
        let lines = cmd.components(separatedBy: "\n")
        let truncated = lines.count > Self.maxVisibleLines
        let visibleCmd = truncated
            ? lines.prefix(Self.maxVisibleLines).joined(separator: "\n")
            : cmd

        VStack(alignment: .leading, spacing: 4) {
            ScrollView([.horizontal], showsIndicators: true) {
                Text(visibleCmd)
                    .font(.system(size: 12, design: .monospaced))
                    .foregroundStyle(.white)
                    .fixedSize(horizontal: true, vertical: true)
            }
            if truncated {
                Text("… +\(lines.count - Self.maxVisibleLines) more lines")
                    .font(.system(size: 9, weight: .medium))
                    .foregroundStyle(.white.opacity(0.4))
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(codeBoxBackground)
    }

    @ViewBuilder
    private func writeContentView(_ content: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            // File path header — bright monospaced so the user
            // immediately sees WHICH file is being created. Smart
            // format: cwd-relative (`./...`) when inside the session's
            // project; home-relative (`~/...`) when in HOME but outside
            // cwd; absolute otherwise. Avoids the `./../../../tmp/...`
            // chain Claude Code's TUI sometimes shows.
            if let path = request.filePath, !path.isEmpty {
                Text(displayPath(path))
                    .font(.system(size: 12, weight: .semibold, design: .monospaced))
                    .foregroundStyle(Color.white)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Divider()
                    .overlay(Color.white.opacity(0.08))
            }
            // File content preview (first 200 chars / 5 lines), dimmed
            // a step below the path so the eye lands on the name first
            // when scanning the banner.
            Text(String(content.prefix(200)))
                .font(.system(size: 11, design: .monospaced))
                .foregroundStyle(.white.opacity(0.75))
                .lineLimit(5)
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(codeBoxBackground)
    }

    /// Shorten `path` for display:
    /// - inside `request.cwd` → `./relative/from/cwd`
    /// - under `$HOME` (outside cwd) → `~/relative/from/home`
    /// - elsewhere → absolute path verbatim
    ///
    /// Matches the project's pattern-derivation logic in
    /// `ClaudeCodeRuleWriter.deriveFilePathPattern` but without the
    /// trailing `/**` glob — this is a path display, not a rule.
    private func displayPath(_ path: String) -> String {
        let std = (path as NSString).standardizingPath
        let cwd = (request.cwd as NSString).standardizingPath
        let home = NSHomeDirectory()

        if std == cwd { return "." }
        if !cwd.isEmpty, std.hasPrefix(cwd + "/") {
            return "./" + String(std.dropFirst(cwd.count + 1))
        }
        if std.hasPrefix(home + "/") {
            return "~/" + String(std.dropFirst(home.count + 1))
        }
        return std
    }

    /// Black rounded box used for command / write content. Per design.
    private var codeBoxBackground: some View {
        RoundedRectangle(cornerRadius: 6, style: .continuous)
            .fill(Color.black.opacity(0.55))
            .overlay(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .stroke(Color.white.opacity(0.06), lineWidth: 0.5)
            )
    }

    // MARK: - Reply field
    //
    // Free-text input. On Deny, becomes the reason string the agent
    // sees back. On Allow / Always, ignored (the hook protocol can't
    // carry a free-form payload for approvals).

    @ViewBuilder
    private var replyField: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "bubble.left")
                .font(.system(size: 11))
                .foregroundStyle(Color.white.opacity(0.55))
                .padding(.top, 6)

            // Manual placeholder overlay instead of `prompt:` — on macOS,
            // SwiftUI's TextField bridges to NSTextField and the prompt
            // Text's foreground modifiers get swallowed, rendering the
            // placeholder in NSTextField's default `placeholderTextColor`
            // (near-black on our dark fill — invisible). ZStack with a
            // conditional Text gives us full color control.
            ZStack(alignment: .leading) {
                if reply.isEmpty {
                    Text("Reply (optional) — tell the agent what to do instead")
                        .font(.system(size: 11))
                        .foregroundStyle(Color.white.opacity(0.55))
                        .allowsHitTesting(false)
                }
                // Single-line TextField + ZStack placeholder overlay.
                // We dropped the NSViewRepresentable + Shift+Return
                // multi-line path because the narrow card width makes
                // multi-line replies awkward in practice — most replies
                // are short one-liners. Plain Enter submits via
                // `.onSubmit`; for longer corrections the user can jump
                // to terminal via the ↗ icon.
                TextField("", text: $reply)
                    .textFieldStyle(.plain)
                    .font(.system(size: 11))
                    .foregroundStyle(.white)
                    .onSubmit {
                        guard let reason = trimmedReply else { return }
                        onDeny(reason)
                    }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
            .background(
                // Dark fill — needs to read as a distinct input area
                // against the orange-tinted parent card.
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(Color.black.opacity(0.28))
                    .overlay(
                        RoundedRectangle(cornerRadius: 6, style: .continuous)
                            .stroke(Color.white.opacity(0.10), lineWidth: 0.5)
                    )
            )
        }
    }

    // MARK: - Buttons
    //
    // Default state — Reply field is empty: full button row
    // (Allow ^Y / Always ^A / Deny ^N / ↗). Always hidden when strategy
    // is .notSupported. Keyboard shortcuts handled by
    // NotchPanel.handleKeyEvent.
    //
    // Typing state — Reply field has text: ALL buttons hidden, replaced
    // by a keyboard hint. The user has committed to "reject + give an
    // instruction"; Allow/Always are semantically incompatible at this
    // point and the buttons add visual noise. Pressing Return submits
    // (via ReplyTextField's onSubmit). To get back to the buttons, clear
    // the reply text.

    @ViewBuilder
    private var buttonRow: some View {
        if trimmedReply != nil {
            replyModeHint
        } else {
            HStack(spacing: 8) {
                PermissionButton(title: "Allow", shortcut: "^Y", style: .allow, action: onAllow)

                if strategy.supportsAlways {
                    PermissionButton(title: "Always", shortcut: "^A", style: .alwaysAllow, icon: "star.fill", action: onAlwaysAllow)
                }

                PermissionButton(title: "Deny", shortcut: "^N", style: .deny, action: { onDeny(nil) })

                // Jump-to-terminal icon button — small square. Lets the
                // user bail out of the notch flow and answer in the
                // agent's native TUI instead.
                Button(action: onJump) {
                    Image(systemName: "arrow.up.right")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(.white.opacity(0.7))
                        .frame(width: 32, height: 30)
                        .background(
                            RoundedRectangle(cornerRadius: 6, style: .continuous)
                                .fill(Color.white.opacity(0.06))
                                .overlay(
                                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                                        .stroke(Color.white.opacity(0.10), lineWidth: 0.5)
                                )
                        )
                }
                .buttonStyle(.plain)
                .help("Jump to the terminal running this agent")
            }
        }
    }

    /// Reply-mode footer that replaces the button row. Single-line
    /// input, so the only relevant key is Return → send. Multi-line
    /// replies aren't supported in this narrow card — users with long
    /// corrections can jump to the agent's terminal via the ↗ icon.
    @ViewBuilder
    private var replyModeHint: some View {
        HStack(spacing: 8) {
            Image(systemName: "return")
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(Color.ap.statusWorking)
            Text("Return")
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(Color.ap.statusWorking)
            Text("to send reply")
                .font(.system(size: 11))
                .foregroundStyle(Color.white.opacity(0.5))
            Spacer(minLength: 4)
        }
        .padding(.vertical, 4)
    }

    // MARK: - Helper text
    //
    // The small footer below the buttons explaining what "Always" would
    // persist — uses the writer's pattern preview to show the EXACT
    // string that would be saved. Empty when strategy is .notSupported
    // (Always button is also hidden in that case) OR when the user is
    // typing a reply (Always becomes irrelevant in reply mode).

    @ViewBuilder
    private var helperText: some View {
        if trimmedReply == nil, case .native(let writer) = strategy {
            let input = request.toolInput.mapValues { $0.value }
            let pattern = writer.patternPreview(toolName: request.toolName, toolInput: input, cwd: request.cwd)
            let scope = writer.scopeDescription(toolName: request.toolName, toolInput: input, cwd: request.cwd)
            HStack(spacing: 0) {
                Text("\u{201C}Always\u{201D} will allow ")
                    .foregroundStyle(Color.white.opacity(0.45))
                Text(pattern)
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(Color.white.opacity(0.7))
                    // Force single line + middle truncation so a pathologically
                    // long pattern (e.g. a command containing a long absolute
                    // path that escaped env-var stripping) doesn't wrap the
                    // chip onto multiple lines and crash into the surrounding
                    // text. `Bash(...:*)` form stays readable from both ends.
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .padding(.horizontal, 4)
                    .background(
                        RoundedRectangle(cornerRadius: 3)
                            .fill(Color.white.opacity(0.06))
                    )
                Text(" \(scope.helperSuffix)")
                    .foregroundStyle(Color.white.opacity(0.45))
                Spacer(minLength: 0)
            }
            .font(.system(size: 10))
        }
    }
}

// MARK: - Permission Button

struct PermissionButton: View {
    let title: String
    let shortcut: String
    let style: Style
    var icon: String? = nil
    let action: () -> Void

    enum Style {
        case deny, allow, alwaysAllow

        var bgColor: Color {
            switch self {
            // Primary CTA — Apple-system blue per the AgentPulse design spec
            // (#0a84ff). The single most-clicked button in the product.
            case .allow: Color.ap.statusWorking
            // Subtle blue-tinted background to read as "primary-like but
            // secondary" — matches the redesigned spec for the Always
            // button (blue text/icon, dark blue fill).
            case .alwaysAllow: Color.ap.statusWorking.opacity(0.18)
            case .deny: Color.white.opacity(0.08)
            }
        }

        var fgColor: Color {
            switch self {
            case .allow: Color.white
            case .alwaysAllow: Color.ap.statusWorking
            case .deny: Color.white.opacity(0.85)
            }
        }

        var strokeColor: Color {
            switch self {
            case .allow: .clear
            case .alwaysAllow: Color.ap.statusWorking.opacity(0.35)
            case .deny: .clear
            }
        }
    }

    var body: some View {
        Button(action: action) {
            HStack(spacing: 5) {
                if let icon {
                    Image(systemName: icon)
                        .font(.system(size: 10, weight: .semibold))
                }
                Text(title)
                    .font(.system(size: 12, weight: style == .allow ? .semibold : .medium))
                    .tracking(style == .allow ? -0.1 : 0)
                if !shortcut.isEmpty {
                    Text(shortcut)
                        .font(.system(size: 9, weight: .medium, design: .monospaced))
                        .opacity(0.55)
                        .padding(.horizontal, 4)
                        .padding(.vertical, 1)
                        .background(
                            RoundedRectangle(cornerRadius: 3)
                                .fill(Color.black.opacity(0.18))
                        )
                }
            }
            .frame(maxWidth: .infinity)
            .frame(height: 30)
            .background(style.bgColor)
            .foregroundStyle(style.fgColor)
            .clipShape(RoundedRectangle(cornerRadius: 6))
            .overlay(
                RoundedRectangle(cornerRadius: 6)
                    .stroke(style.strokeColor, lineWidth: 0.8)
            )
        }
        .buttonStyle(.plain)
    }
}
