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

// MARK: - Changes within one file

/// One change ("hunk") of a file's diff: a run of added and removed lines with
/// a little unchanged context around it.
public struct GitHunk: Identifiable, Sendable, Equatable {
    /// Position in the file's diff, starting at 0.
    public let id: Int
    /// `@@ -12,7 +12,9 @@ func name()`
    public let header: String
    /// The hunk's lines exactly as Git printed them, with their ` `, `+`, `-` or `\` prefix.
    public let rawLines: [String]
    public let oldStart: Int
    public let oldCount: Int
    public let newStart: Int
    public let newCount: Int
    public let lines: [GitDiffLine]

    public var additions: Int { lines.filter { $0.kind == .addition }.count }
    public var deletions: Int { lines.filter { $0.kind == .deletion }.count }

    /// Text after the second `@@`, usually the enclosing function.
    public var context: String {
        let parts = header.components(separatedBy: "@@")
        guard parts.count >= 3 else { return "" }
        return parts[2...].joined(separator: "@@").trimmingCharacters(in: .whitespaces)
    }

    /// "Lines 12–18" in the current file, or "Removed lines 5–7" when the change only removes.
    public var lineDescription: String {
        func describe(_ numbers: [Int], _ one: String, _ many: String) -> String? {
            guard let first = numbers.first, let last = numbers.last else { return nil }
            return first == last ? "\(one) \(first)" : "\(many) \(first)–\(last)"
        }
        let added = lines.compactMap { $0.kind == .addition ? $0.newLineNumber : nil }
        let removed = lines.compactMap { $0.kind == .deletion ? $0.oldLineNumber : nil }
        return describe(added, "Line", "Lines")
            ?? describe(removed, "Removed line", "Removed lines")
            ?? "Line \(newStart)"
    }
}

/// A single file's diff split into hunks, so parts of it can be reverted.
public struct GitFilePatch: Sendable, Equatable {
    /// `diff --git`, `index`, `---` and `+++` lines.
    public let header: [String]
    public let hunks: [GitHunk]

    /// Parses `git diff` output for exactly one file. Returns nil for binary
    /// files, several files, or a diff without text changes.
    public static func parse(_ text: String) -> GitFilePatch? {
        // Split on bytes so Windows line endings ("\r\n" is one Swift Character) survive.
        var lines = text.utf8.split(separator: UInt8(ascii: "\n"), omittingEmptySubsequences: false)
            .map { String(decoding: $0, as: UTF8.self) }
        if lines.last == "" { lines.removeLast() }

        var header = [String]()
        var hunks = [GitHunk]()
        var current: (header: String, raw: [String])?
        var fileCount = 0

        func finishHunk() {
            guard let hunk = current else { return }
            hunks.append(makeHunk(id: hunks.count, header: hunk.header, rawLines: hunk.raw))
            current = nil
        }

        for line in lines {
            if line.hasPrefix("diff --git ") {
                fileCount += 1
                guard fileCount == 1 else { return nil }
                header.append(line)
            } else if line.hasPrefix("@@") {
                finishHunk()
                current = (line, [])
            } else if current != nil {
                // diff.suppressBlankEmpty prints empty context lines without their space.
                let line = line.isEmpty ? " " : line
                guard let first = line.first, " +-\\".contains(first) else { return nil }
                current?.raw.append(line)
            } else {
                if line.hasPrefix("Binary files ") || line.hasPrefix("GIT binary patch") { return nil }
                header.append(line)
            }
        }
        finishHunk()

        guard fileCount == 1, !hunks.isEmpty,
              header.contains(where: { $0.hasPrefix("--- ") }), header.contains(where: { $0.hasPrefix("+++ ") }) else {
            return nil
        }
        return GitFilePatch(header: header, hunks: hunks)
    }

    /// A patch containing only the chosen hunks, ready for `git apply`.
    public func patch(including ids: Set<Int>) -> String {
        let chosen = hunks.filter { ids.contains($0.id) }
        guard !chosen.isEmpty else { return "" }
        return (header + chosen.flatMap { [$0.header] + $0.rawLines }).joined(separator: "\n") + "\n"
    }

    private static func makeHunk(id: Int, header: String, rawLines: [String]) -> GitHunk {
        let (oldStart, oldCount, newStart, newCount) = ranges(header)
        var oldLine = oldStart
        var newLine = newStart
        var display = [GitDiffLine]()
        for raw in rawLines {
            let text = String(raw.dropFirst())
            switch raw.first {
            case "+":
                display.append(GitDiffLine(kind: .addition, newLineNumber: newLine, text: text))
                newLine += 1
            case "-":
                display.append(GitDiffLine(kind: .deletion, oldLineNumber: oldLine, text: text))
                oldLine += 1
            case "\\":
                display.append(GitDiffLine(kind: .noNewline, text: raw))
            default:
                display.append(GitDiffLine(kind: .context, oldLineNumber: oldLine, newLineNumber: newLine, text: text))
                oldLine += 1
                newLine += 1
            }
        }
        return GitHunk(id: id, header: header, rawLines: rawLines, oldStart: oldStart, oldCount: oldCount,
                       newStart: newStart, newCount: newCount, lines: display)
    }

    /// `@@ -12,7 +14 @@` → (12, 7, 14, 1). A missing count means 1.
    static func ranges(_ header: String) -> (Int, Int, Int, Int) {
        func parse(_ token: Substring?) -> (Int, Int) {
            guard let token else { return (0, 0) }
            let parts = token.dropFirst().split(separator: ",")
            return (Int(parts.first ?? "") ?? 0, parts.count > 1 ? Int(parts[1]) ?? 0 : 1)
        }
        let tokens = header.split(separator: " ")
        let old = parse(tokens.first { $0.hasPrefix("-") })
        let new = parse(tokens.first { $0.hasPrefix("+") })
        return (old.0, old.1, new.0, new.1)
    }
}
