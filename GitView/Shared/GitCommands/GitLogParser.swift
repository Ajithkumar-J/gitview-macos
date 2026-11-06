import Foundation

/// Formats and parsers for `git log`, `git show` and `git for-each-ref`.
/// Fields are separated by U+001F (unit separator) and records by U+001E
/// (record separator) so commit subjects can contain any printable text.
public enum GitLogParser {
    static let fieldSeparator: Character = "\u{1f}"
    static let recordSeparator: Character = "\u{1e}"

    /// hash, short hash, author name, author email, author date, parents, decorations, subject
    public static let logFormat = "--pretty=format:%H%x1f%h%x1f%an%x1f%ae%x1f%aI%x1f%P%x1f%D%x1f%s%x1e"

    /// Same as `logFormat` plus committer name/email/date and the full message body.
    public static let detailFormat = "--format=%H%x1f%h%x1f%an%x1f%ae%x1f%aI%x1f%P%x1f%D%x1f%s%x1f%cn%x1f%ce%x1f%cI%x1f%B"

    public static let branchFormat = "--format=%(refname)%1f%(refname:short)%1f%(HEAD)%1f%(upstream:short)%1f%(upstream:track)%1f%(committerdate:iso-strict)%1f%(subject)"

    public static func parseLog(_ text: String) -> [GitCommit] {
        text
            .split(separator: recordSeparator)
            .compactMap { record in
                let fields = record
                    .trimmingCharacters(in: .newlines)
                    .split(separator: fieldSeparator, omittingEmptySubsequences: false)
                    .map(String.init)
                return commit(from: fields)
            }
    }

    public static func parseCommitDetail(header: String, nameStatus: String) -> GitCommitDetail? {
        let fields = header
            .split(separator: fieldSeparator, maxSplits: 11, omittingEmptySubsequences: false)
            .map(String.init)

        guard fields.count == 12, let commit = commit(from: Array(fields[0..<8])) else {
            return nil
        }

        return GitCommitDetail(
            commit: commit,
            committerName: fields[8],
            committerEmail: fields[9],
            committerDate: parseDate(fields[10]) ?? commit.date,
            message: fields[11].trimmingCharacters(in: .whitespacesAndNewlines),
            files: parseNameStatus(nameStatus)
        )
    }

    /// Parses `git diff/show --name-status -z` output.
    public static func parseNameStatus(_ text: String) -> [GitCommitFile] {
        let tokens = text.split(separator: "\0", omittingEmptySubsequences: true).map {
            $0.trimmingCharacters(in: .newlines)
        }
        var files = [GitCommitFile]()
        var index = 0

        while index < tokens.count {
            let status = tokens[index]
            index += 1
            guard let code = status.first else {
                continue
            }

            if code == "R" || code == "C" {
                guard index + 1 < tokens.count else { break }
                files.append(GitCommitFile(path: tokens[index + 1], originalPath: tokens[index], kind: GitChangeKind(statusCode: code)))
                index += 2
            } else {
                guard index < tokens.count else { break }
                files.append(GitCommitFile(path: tokens[index], kind: GitChangeKind(statusCode: code)))
                index += 1
            }
        }

        return files
    }

    public static func parseBranches(_ text: String) -> [GitBranch] {
        text
            .split(whereSeparator: \.isNewline)
            .compactMap { line in
                let fields = line.split(separator: fieldSeparator, omittingEmptySubsequences: false).map(String.init)
                guard fields.count == 7 else {
                    return nil
                }

                let fullName = fields[0]
                // Skip symbolic refs like refs/remotes/origin/HEAD.
                if fullName.hasSuffix("/HEAD") {
                    return nil
                }

                let isRemote = fullName.hasPrefix("refs/remotes/")
                let track = parseTrack(fields[4])

                return GitBranch(
                    name: fields[1],
                    isCurrent: fields[2] == "*",
                    isRemote: isRemote,
                    upstream: fields[3].isEmpty ? nil : fields[3],
                    aheadCount: track.ahead,
                    behindCount: track.behind,
                    isUpstreamGone: track.gone,
                    lastCommitDate: parseDate(fields[5]),
                    lastCommitSubject: fields[6].isEmpty ? nil : fields[6]
                )
            }
    }

    /// Parses `%(upstream:track)`, e.g. `[ahead 2, behind 1]` or `[gone]`.
    static func parseTrack(_ text: String) -> (ahead: Int, behind: Int, gone: Bool) {
        let trimmed = text.trimmingCharacters(in: CharacterSet(charactersIn: "[] "))
        if trimmed == "gone" {
            return (0, 0, true)
        }

        var ahead = 0
        var behind = 0
        for part in trimmed.split(separator: ",") {
            let words = part.split(separator: " ")
            guard words.count == 2, let value = Int(words[1]) else { continue }
            if words[0] == "ahead" { ahead = value }
            if words[0] == "behind" { behind = value }
        }
        return (ahead, behind, false)
    }

    static func parseDate(_ text: String) -> Date? {
        try? Date(text.trimmingCharacters(in: .whitespacesAndNewlines), strategy: .iso8601)
    }

    private static func commit(from fields: [String]) -> GitCommit? {
        guard fields.count >= 8, !fields[0].isEmpty else {
            return nil
        }

        return GitCommit(
            hash: fields[0],
            shortHash: fields[1],
            authorName: fields[2],
            authorEmail: fields[3],
            date: parseDate(fields[4]) ?? .distantPast,
            parentHashes: fields[5].split(separator: " ").map(String.init),
            refs: fields[6]
                .components(separatedBy: ", ")
                .map { $0.trimmingCharacters(in: .whitespaces) }
                .filter { !$0.isEmpty },
            subject: fields[7]
        )
    }
}
