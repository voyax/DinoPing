import AgentPulseCore
import SwiftUI

/// Renders a code diff with red/green highlighting, similar to Vibe Island.
struct DiffView: View {
    let filePath: String
    let oldString: String
    let newString: String

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // File header
            HStack(spacing: 6) {
                Text(fileName)
                    .font(.system(size: 11, weight: .medium, design: .monospaced))
                    .foregroundStyle(.white.opacity(0.9))

                Text(diffSummary)
                    .font(.system(size: 10, weight: .medium, design: .monospaced))
                    .foregroundStyle(.white.opacity(0.5))
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.white.opacity(0.08))

            // Removed lines
            ForEach(Array(oldLines.enumerated()), id: \.offset) { index, line in
                HStack(spacing: 0) {
                    Text("\(index + 1)")
                        .font(.system(size: 9, design: .monospaced))
                        .foregroundStyle(.red.opacity(0.5))
                        .frame(width: 24, alignment: .trailing)
                        .padding(.trailing, 4)

                    Text("−")
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundStyle(.red.opacity(0.7))
                        .frame(width: 14)

                    Text(line)
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundStyle(.red.opacity(0.9))
                        .lineLimit(1)
                }
                .padding(.horizontal, 6)
                .padding(.vertical, 1)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color.red.opacity(0.12))
            }

            // Added lines
            ForEach(Array(newLines.enumerated()), id: \.offset) { index, line in
                HStack(spacing: 0) {
                    Text("\(index + 1)")
                        .font(.system(size: 9, design: .monospaced))
                        .foregroundStyle(.green.opacity(0.5))
                        .frame(width: 24, alignment: .trailing)
                        .padding(.trailing, 4)

                    Text("+")
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundStyle(.green.opacity(0.7))
                        .frame(width: 14)

                    Text(line)
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundStyle(.green.opacity(0.9))
                        .lineLimit(1)
                }
                .padding(.horizontal, 6)
                .padding(.vertical, 1)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color.green.opacity(0.12))
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 6))
        .overlay(
            RoundedRectangle(cornerRadius: 6)
                .stroke(Color.white.opacity(0.08), lineWidth: 1)
        )
    }

    private var fileName: String {
        (filePath as NSString).lastPathComponent
    }

    private var oldLines: [String] {
        let lines = oldString.components(separatedBy: "\n")
        return Array(lines.prefix(6)) // Max 6 lines
    }

    private var newLines: [String] {
        let lines = newString.components(separatedBy: "\n")
        return Array(lines.prefix(6))
    }

    private var diffSummary: String {
        "+\(newString.components(separatedBy: "\n").count) -\(oldString.components(separatedBy: "\n").count)"
    }
}
