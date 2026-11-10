import Foundation

public struct GitStatusSummary: Equatable, Sendable {
    public var branchHead: String?
    public var isDetached = false
    public var headOID: String?
    public var upstream: String?
    public var aheadCount = 0
    public var behindCount = 0
    public var files: [GitFileStatus] = []

    public init() {}
}

public enum GitStatusParser {
    /// Parses `git status --porcelain` (v1, newline separated). Paths containing
    /// spaces or special characters are quoted by Git in this format, so prefer
    /// `parsePorcelainV2` with `-z` for real repositories.
    public static func parsePorcelainV1(_ text: String) -> [GitFileStatus] {
        text
            .split(whereSeparator: \.isNewline)
            .compactMap { parseV1Line(String($0)) }
    }

    /// Parses `git status --porcelain=v2 --branch -z`.
    public static func parsePorcelainV2(_ text: String) -> GitStatusSummary {
        var summary = GitStatusSummary()
        let records = text.split(separator: "\0", omittingEmptySubsequences: true).map(String.init)
        var index = 0

        while index < records.count {
            let record = records[index]
            index += 1

            if record.hasPrefix("# ") {
                parseHeader(record, into: &summary)
                continue
            }

            guard let type = record.first else {
                continue
            }

            switch type {
            case "1":
                // 1 XY sub mH mI mW hH hI path
                let fields = record.split(separator: " ", maxSplits: 8, omittingEmptySubsequences: false)
                guard fields.count == 9 else { continue }
                let (x, y) = statusPair(fields[1])
                summary.files.append(GitFileStatus(path: String(fields[8]), indexStatus: x, workingTreeStatus: y))
            case "2":
                // 2 XY sub mH mI mW hH hI Xscore path NUL origPath
                let fields = record.split(separator: " ", maxSplits: 9, omittingEmptySubsequences: false)
                guard fields.count == 10 else { continue }
                let (x, y) = statusPair(fields[1])
                let originalPath = index < records.count ? records[index] : nil
                index += 1
                summary.files.append(GitFileStatus(path: String(fields[9]), indexStatus: x, workingTreeStatus: y, originalPath: originalPath))
            case "u":
                // u XY sub m1 m2 m3 mW h1 h2 h3 path
                let fields = record.split(separator: " ", maxSplits: 10, omittingEmptySubsequences: false)
                guard fields.count == 11 else { continue }
                let (x, y) = statusPair(fields[1])
                summary.files.append(GitFileStatus(path: String(fields[10]), indexStatus: x, workingTreeStatus: y))
            case "?":
                summary.files.append(GitFileStatus(path: String(record.dropFirst(2)), indexStatus: "?", workingTreeStatus: "?"))
            default:
                // "!" ignored entries and anything unknown.
                continue
            }
        }

        return summary
    }

    private static func parseHeader(_ record: String, into summary: inout GitStatusSummary) {
        let parts = record.split(separator: " ", maxSplits: 2).map(String.init)
        guard parts.count == 3 else {
            return
        }

        let value = parts[2]
        switch parts[1] {
        case "branch.oid":
            summary.headOID = value == "(initial)" ? nil : value
        case "branch.head":
            if value == "(detached)" {
                summary.isDetached = true
                summary.branchHead = nil
            } else {
                summary.branchHead = value
            }
        case "branch.upstream":
            summary.upstream = value
        case "branch.ab":
            for token in value.split(separator: " ") {
                if token.hasPrefix("+") {
                    summary.aheadCount = Int(token.dropFirst()) ?? 0
                } else if token.hasPrefix("-") {
                    summary.behindCount = Int(token.dropFirst()) ?? 0
                }
            }
        default:
            break
        }
    }

    private static func statusPair(_ field: Substring) -> (Character, Character) {
        let chars = Array(field)
        guard chars.count == 2 else {
            return (" ", " ")
        }

        // Porcelain v2 uses "." for "unchanged"; the rest of GitView uses " ".
        return (chars[0] == "." ? " " : chars[0], chars[1] == "." ? " " : chars[1])
    }

    private static func parseV1Line(_ line: String) -> GitFileStatus? {
        guard line.count >= 3 else {
            return nil
        }

        let chars = Array(line)
        let indexStatus = chars[0]
        let workingTreeStatus = chars[1]
        let pathText = String(chars.dropFirst(3))

        if indexStatus == "R" || indexStatus == "C" {
            let parts = pathText.components(separatedBy: " -> ")
            if parts.count == 2 {
                return GitFileStatus(
                    path: parts[1],
                    indexStatus: indexStatus,
                    workingTreeStatus: workingTreeStatus,
                    originalPath: parts[0]
                )
            }
        }

        return GitFileStatus(
            path: pathText,
            indexStatus: indexStatus,
            workingTreeStatus: workingTreeStatus
        )
    }
}
