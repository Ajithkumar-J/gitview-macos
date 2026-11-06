import Foundation

public enum GitDiffParser {
    public static let defaultLineLimit = 20_000

    /// Converts unified diff text into display lines with old/new line numbers.
    /// The `diff --git`, `index`, `---` and `+++` headers are dropped because the
    /// viewer already shows which file is selected.
    public static func parse(_ text: String, lineLimit: Int = defaultLineLimit) -> GitDiff {
        var lines = [GitDiffLine]()
        var additions = 0
        var deletions = 0
        var isBinary = false
        var isTruncated = false
        var oldLine = 0
        var newLine = 0
        var insideHunk = false

        for rawLine in text.split(separator: "\n", omittingEmptySubsequences: false) {
            if lines.count >= lineLimit {
                isTruncated = true
                break
            }

            let line = String(rawLine)

            if line.hasPrefix("diff --git ") || line.hasPrefix("diff --cc ") || line.hasPrefix("diff --combined ") {
                insideHunk = false
                continue
            }

            if !insideHunk {
                if line.hasPrefix("index ") || line.hasPrefix("--- ") || line.hasPrefix("+++ ") || line.isEmpty {
                    continue
                }
            }

            if line.hasPrefix("@@") {
                insideHunk = true
                let numbers = hunkStartLines(line)
                oldLine = numbers.old
                newLine = numbers.new
                lines.append(GitDiffLine(kind: .hunkHeader, text: line))
                continue
            }

            guard insideHunk else {
                if line.hasPrefix("Binary files ") || line.hasPrefix("GIT binary patch") {
                    isBinary = true
                }
                lines.append(GitDiffLine(kind: .meta, text: line))
                continue
            }

            if line.hasPrefix("+") {
                additions += 1
                lines.append(GitDiffLine(kind: .addition, newLineNumber: newLine, text: String(line.dropFirst())))
                newLine += 1
            } else if line.hasPrefix("-") {
                deletions += 1
                lines.append(GitDiffLine(kind: .deletion, oldLineNumber: oldLine, text: String(line.dropFirst())))
                oldLine += 1
            } else if line.hasPrefix("\\") {
                lines.append(GitDiffLine(kind: .noNewline, text: line))
            } else if line.hasPrefix(" ") {
                lines.append(GitDiffLine(kind: .context, oldLineNumber: oldLine, newLineNumber: newLine, text: String(line.dropFirst())))
                oldLine += 1
                newLine += 1
            } else if line.isEmpty {
                // Trailing newline of the whole diff output.
                continue
            } else {
                // Combined diffs (merge conflicts) use two-column prefixes; show them verbatim.
                lines.append(GitDiffLine(kind: line.hasPrefix("++") ? .addition : .context, text: line))
            }
        }

        return GitDiff(lines: lines, additions: additions, deletions: deletions, isBinary: isBinary, isTruncated: isTruncated)
    }

    /// Reads `@@ -12,7 +12,9 @@` → (12, 12).
    static func hunkStartLines(_ header: String) -> (old: Int, new: Int) {
        let parts = header.split(separator: " ")
        func start(of token: Substring?) -> Int {
            guard let token else { return 0 }
            let numbers = token.dropFirst().split(separator: ",")
            return Int(numbers.first ?? "") ?? 0
        }
        let old = parts.first(where: { $0.hasPrefix("-") })
        let new = parts.first(where: { $0.hasPrefix("+") })
        return (start(of: old), start(of: new))
    }
}
