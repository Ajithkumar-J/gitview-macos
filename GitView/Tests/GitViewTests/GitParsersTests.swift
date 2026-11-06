import XCTest
@testable import Shared

final class GitParsersTests: XCTestCase {
    func testParsesPorcelainV2WithBranchHeadersRenamesAndSpaces() {
        let records = [
            "# branch.oid 1234567890abcdef1234567890abcdef12345678",
            "# branch.head feature/login",
            "# branch.upstream origin/feature/login",
            "# branch.ab +2 -3",
            "1 .M N... 100644 100644 100644 aaa bbb Sources/My File.swift",
            "1 MM N... 100644 100644 100644 aaa bbb Both.swift",
            "2 R. N... 100644 100644 100644 aaa bbb R100 New Name.swift",
            "Old Name.swift",
            "u UU N... 100644 100644 100644 100644 aaa bbb ccc Conflict.swift",
            "? notes with space.txt"
        ]

        let summary = GitStatusParser.parsePorcelainV2(records.joined(separator: "\0") + "\0")

        XCTAssertEqual(summary.branchHead, "feature/login")
        XCTAssertEqual(summary.upstream, "origin/feature/login")
        XCTAssertEqual(summary.aheadCount, 2)
        XCTAssertEqual(summary.behindCount, 3)
        XCTAssertFalse(summary.isDetached)
        XCTAssertEqual(summary.files.map(\.path), ["Sources/My File.swift", "Both.swift", "New Name.swift", "Conflict.swift", "notes with space.txt"])
        XCTAssertEqual(summary.files[2].originalPath, "Old Name.swift")

        let files = summary.files
        XCTAssertEqual(files.changes(in: .unstaged).map(\.path), ["Both.swift", "Sources/My File.swift"])
        XCTAssertEqual(files.changes(in: .staged).map(\.path), ["Both.swift", "New Name.swift"])
        XCTAssertEqual(files.changes(in: .staged).last?.kind, .renamed)
        XCTAssertEqual(files.changes(in: .conflicted).map(\.path), ["Conflict.swift"])
        XCTAssertEqual(files.changes(in: .untracked).map(\.path), ["notes with space.txt"])
    }

    func testParsesDetachedAndInitialHeads() {
        let detached = GitStatusParser.parsePorcelainV2("# branch.oid abc\0# branch.head (detached)\0")
        XCTAssertTrue(detached.isDetached)
        XCTAssertEqual(detached.headOID, "abc")

        let initial = GitStatusParser.parsePorcelainV2("# branch.oid (initial)\0# branch.head main\0")
        XCTAssertNil(initial.headOID)
        XCTAssertEqual(initial.branchHead, "main")
    }

    func testParsesLogRecords() {
        let output = [
            "aaaa\u{1f}aa\u{1f}Ajith\u{1f}a@example.com\u{1f}2026-09-01T10:00:00+05:30\u{1f}p1 p2\u{1f}HEAD -> main, origin/main, tag: v1\u{1f}Merge | pipes are fine\u{1e}",
            "\nbbbb\u{1f}bb\u{1f}Arun\u{1f}b@example.com\u{1f}2026-08-30T08:00:00Z\u{1f}\u{1f}\u{1f}Initial\u{1e}"
        ].joined()

        let commits = GitLogParser.parseLog(output)

        XCTAssertEqual(commits.count, 2)
        XCTAssertEqual(commits[0].subject, "Merge | pipes are fine")
        XCTAssertEqual(commits[0].refs, ["HEAD -> main", "origin/main", "tag: v1"])
        XCTAssertTrue(commits[0].isMerge)
        XCTAssertNotEqual(commits[0].date, .distantPast)
        XCTAssertEqual(commits[1].parentHashes, [])
        XCTAssertEqual(commits[1].refs, [])
    }

    func testParsesNameStatusWithRenames() {
        let output = "M\0a.swift\0R087\0old name.swift\0new name.swift\0D\0gone.txt\0"
        let files = GitLogParser.parseNameStatus(output)

        XCTAssertEqual(files.map(\.path), ["a.swift", "new name.swift", "gone.txt"])
        XCTAssertEqual(files[1].originalPath, "old name.swift")
        XCTAssertEqual(files.map(\.kind), [.modified, .renamed, .deleted])
    }

    func testParsesBranchTracking() {
        XCTAssertEqual(GitLogParser.parseTrack("[ahead 2, behind 1]").ahead, 2)
        XCTAssertEqual(GitLogParser.parseTrack("[ahead 2, behind 1]").behind, 1)
        XCTAssertEqual(GitLogParser.parseTrack("[behind 4]").behind, 4)
        XCTAssertTrue(GitLogParser.parseTrack("[gone]").gone)
        XCTAssertEqual(GitLogParser.parseTrack("").ahead, 0)

        let line = "refs/heads/main\u{1f}main\u{1f}*\u{1f}origin/main\u{1f}[ahead 1]\u{1f}2026-09-01T10:00:00+05:30\u{1f}Subject\nrefs/remotes/origin/HEAD\u{1f}origin\u{1f} \u{1f}\u{1f}\u{1f}2026-09-01T10:00:00+05:30\u{1f}Subject\nrefs/remotes/origin/dev\u{1f}origin/dev\u{1f} \u{1f}\u{1f}\u{1f}2026-09-01T10:00:00+05:30\u{1f}Dev"
        let branches = GitLogParser.parseBranches(line)

        XCTAssertEqual(branches.map(\.name), ["main", "origin/dev"])
        XCTAssertTrue(branches[0].isCurrent)
        XCTAssertEqual(branches[0].aheadCount, 1)
        XCTAssertTrue(branches[1].isRemote)
        XCTAssertEqual(branches[1].remoteName, "origin")
        XCTAssertEqual(branches[1].localTrackingName, "dev")
    }

    func testParsesUnifiedDiffWithLineNumbers() {
        let diff = """
        diff --git a/a.swift b/a.swift
        index 111..222 100644
        --- a/a.swift
        +++ b/a.swift
        @@ -10,3 +10,4 @@ func load()
         let a = 1
        --- removed line that looks like a header
        +let b = 2
        +let c = 3
         return a
        \\ No newline at end of file

        """

        let parsed = GitDiffParser.parse(diff)

        XCTAssertEqual(parsed.additions, 2)
        XCTAssertEqual(parsed.deletions, 1)
        XCTAssertEqual(parsed.lines.first?.kind, .hunkHeader)
        XCTAssertEqual(parsed.lines[1], GitDiffLine(kind: .context, oldLineNumber: 10, newLineNumber: 10, text: "let a = 1"))
        XCTAssertEqual(parsed.lines[2], GitDiffLine(kind: .deletion, oldLineNumber: 11, text: "-- removed line that looks like a header"))
        XCTAssertEqual(parsed.lines[3], GitDiffLine(kind: .addition, newLineNumber: 11, text: "let b = 2"))
        XCTAssertEqual(parsed.lines[5], GitDiffLine(kind: .context, oldLineNumber: 12, newLineNumber: 13, text: "return a"))
        XCTAssertEqual(parsed.lines.last?.kind, .noNewline)
    }

    func testDetectsBinaryDiffAndTruncates() {
        let binary = GitDiffParser.parse("diff --git a/x.png b/x.png\nindex 1..2 100644\nBinary files a/x.png and b/x.png differ\n")
        XCTAssertTrue(binary.isBinary)

        let long = "@@ -1,5 +1,5 @@\n" + Array(repeating: " line", count: 50).joined(separator: "\n")
        let truncated = GitDiffParser.parse(long, lineLimit: 10)
        XCTAssertTrue(truncated.isTruncated)
        XCTAssertEqual(truncated.lines.count, 10)
    }

    func testDeepLinkRoundTrip() throws {
        let link = GitViewDeepLink(path: "/Users/me/My Repo", action: .pull)
        let url = try XCTUnwrap(link.url)
        XCTAssertEqual(GitViewDeepLink(url: url), link)
        XCTAssertEqual(GitViewDeepLink(url: URL(string: "gitview://open?path=/tmp")!)?.action, .open)
        XCTAssertNil(GitViewDeepLink(url: URL(string: "https://open?path=/tmp")!))
    }
}
