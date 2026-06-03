import Foundation

/// Verbatim copies of Claude Code's rejection message constants.
///
/// Claude Code's UI (`components/messages/UserToolResultMessage/UserToolErrorMessage.tsx`)
/// uses prefix-matching on the tool_result content to decide between a
/// soft "Tool use rejected" rendering and the harsh red "Error: ..."
/// fallback. We MUST prefix our PermissionRequest deny `message` field
/// with one of these strings to get the same clean UI as a native
/// terminal denial — otherwise Claude Code labels our user's reply as
/// a tool error.
///
/// Source: `/Users/voya/src/claude-code/utils/messages.ts` lines 212-215.
/// Re-verify against current Claude Code if any UI regression appears
/// (rejection messages can change between versions).
public enum ClaudeCodeMessages {
    /// Sent when the user denies a tool without providing a reason.
    /// Matches Claude Code's `REJECT_MESSAGE` constant exactly.
    public static let reject =
        "The user doesn't want to proceed with this tool use. The tool use was rejected (eg. if it was a file edit, the new_string was NOT written to the file). STOP what you are doing and wait for the user to tell you how to proceed."

    /// Prepended to the user's typed reply when they deny with a
    /// reason. Matches Claude Code's `REJECT_MESSAGE_WITH_REASON_PREFIX`
    /// constant exactly — the trailing `\n` is required for the
    /// prefix-startsWith check to fire correctly.
    public static let rejectWithReasonPrefix =
        "The user doesn't want to proceed with this tool use. The tool use was rejected (eg. if it was a file edit, the new_string was NOT written to the file). To tell you how to proceed, the user said:\n"

    /// Build the full `message` string for `HookResponse.deny`. Returns
    /// the bare `reject` constant when reason is nil/empty, or the
    /// prefix + reason when the user typed something.
    public static func formattedRejection(reason: String?) -> String {
        guard let reason, !reason.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return reject
        }
        return rejectWithReasonPrefix + reason
    }
}
