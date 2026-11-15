import Foundation
import XCTest
@testable import Shared

/// Operations behind the Finder command windows, run against real repositories.
final class GitServiceCommandTests: XCTestCase {
    private var sandbox: URL!
    private var repository: URL!
    private var service: GitService!
    private let executor = ProcessExecutor()

    override func setUp() async throws {
        sandbox = FileManager.default.temporaryDirectory.appendingPathComponent("GitView Commands \(UUID().uuidString)")
        repository = sandbox.appendingPathComponent("work repo")
        try FileManager.default.createDirectory(at: repository, withIntermediateDirectories: true)
        service = try GitService()
        _ = try await service.initRepository(at: repository)
        try await git("checkout", "-q", "-b", "main")
        try await git("config", "user.name", "Test")
        try await git("config", "user.email", "test@example.com")
        try await git("config", "commit.gpgsign", "false")
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: sandbox)
    }

    @discardableResult
    private func git(_ arguments: String..., in directory: URL? = nil) async throws -> String {
        let result = try await executor.run(executableURL: service.gitExecutableURL, arguments: arguments, workingDirectory: directory ?? repository)
        XCTAssertTrue(result.success, "git \(arguments.joined(separator: " ")): \(result.standardError)")
        return result.standardOutput
    }

    private func write(_ text: String, to name: String) throws {
        let url = repository.appendingPathComponent(name)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try text.write(to: url, atomically: true, encoding: .utf8)
    }

    private func files() async throws -> [GitFileStatus] {
        try await service.status(in: repository)
    }

    func testCommitSelectedFilesOnlyAndKeepOtherStagedChanges() async throws {
        // First commit in an empty repository with an untracked file in a spaced folder.
        try write("one\n", to: "Docs Folder/a file.txt")
        try write("two\n", to: "b.txt")
        var status = try await files()
        let first = try await service.commit(message: "Add a", files: status.filter { $0.path == "Docs Folder/a file.txt" }, in: repository)
        XCTAssertEqual(first.subject, "Add a")
        status = try await files()
        XCTAssertEqual(status.map(\.path), ["b.txt"], "Unchecked untracked file stays untracked")
        XCTAssertTrue(status[0].isUntracked)

        // Modify a, stage b: committing only a leaves b staged.
        try write("one\nmore\n", to: "Docs Folder/a file.txt")
        try await git("add", "b.txt")
        status = try await files()
        _ = try await service.commit(message: "Change a", files: status.filter { $0.path.hasPrefix("Docs") }, in: repository)
        status = try await files()
        XCTAssertEqual(status.map(\.path), ["b.txt"])
        XCTAssertEqual(status[0].indexStatus, "A", "Other staged changes are left staged")
        let log = try await service.history(paths: ["Docs Folder"], in: repository)
        XCTAssertEqual(log.map(\.subject), ["Change a", "Add a"])

        // Amend changes only the message when no files are given.
        _ = try await service.commit(message: "Change a (amended)", files: [], amend: true, in: repository)
        let message = try await service.lastCommitMessage(in: repository)
        XCTAssertEqual(message, "Change a (amended)")
        status = try await files()
        XCTAssertEqual(status.map(\.path), ["b.txt"])

        // Validation.
        do {
            _ = try await service.commit(message: "x", files: [], in: repository)
            XCTFail("Committing no files must fail")
        } catch {
            XCTAssertEqual(error as? GitServiceError, .noFilesSelected)
        }
    }

    func testRevertAddAndDiffAgainstHead() async throws {
        try write("base\n", to: "kept.txt")
        try write("base\n", to: "old name.txt")
        _ = try await service.commit(message: "Base", files: try await files(), in: repository)

        // Modified (partly staged), renamed, newly added and untracked files.
        try write("base\nstaged\n", to: "kept.txt")
        try await git("add", "kept.txt")
        try write("base\nstaged\nunstaged\n", to: "kept.txt")
        try await git("mv", "old name.txt", "new name.txt")
        try write("new\n", to: "added.txt")
        try await git("add", "added.txt")
        try write("loose\n", to: "untracked.txt")

        let status = try await files()
        let kept = try XCTUnwrap(status.first { $0.path == "kept.txt" })
        let diff = GitDiffParser.parse(try await service.diffAgainstHead(kept, in: repository))
        XCTAssertEqual(diff.lines.filter { $0.kind == .addition }.map(\.text), ["staged", "unstaged"])

        _ = try await service.revert(status, in: repository)
        let after = try await files()
        XCTAssertEqual(after.map(\.path).sorted(), ["added.txt", "untracked.txt"])
        XCTAssertTrue(after.allSatisfy(\.isUntracked), "Added file is unstaged but kept on disk")
        XCTAssertEqual(try String(contentsOf: repository.appendingPathComponent("kept.txt"), encoding: .utf8), "base\n")
        XCTAssertTrue(FileManager.default.fileExists(atPath: repository.appendingPathComponent("old name.txt").path))

        _ = try await service.add(paths: ["added.txt"], in: repository)
        let added = try await files().first { $0.path == "added.txt" }
        XCTAssertEqual(added?.indexStatus, "A")
    }

    /// Regression: a fetch refspec for a branch deleted on the server made every
    /// upstream pull fail with "couldn't find remote ref refs/heads/<gone>".
    func testPullUpstreamIgnoresStaleFetchRefspecs() async throws {
        try write("base\n", to: "file.txt")
        _ = try await service.commit(message: "Base", files: try await files(), in: repository)
        let remote = sandbox.appendingPathComponent("remote.git")
        try FileManager.default.createDirectory(at: remote, withIntermediateDirectories: true)
        try await git("init", "--bare", "-q", in: remote)
        try await git("remote", "add", "origin", remote.path)
        try await git("branch", "gone")
        try await git("push", "-q", "-u", "origin", "main", "gone")
        // Narrow refspecs like the user's repository, one of them for a deleted branch.
        try await git("config", "--replace-all", "remote.origin.fetch", "+refs/heads/main:refs/remotes/origin/main")
        try await git("config", "--add", "remote.origin.fetch", "+refs/heads/gone:refs/remotes/origin/gone")

        // Someone else pushes to main.
        let other = sandbox.appendingPathComponent("other")
        try await git("clone", "-q", remote.path, other.path, in: sandbox)
        try "base\nremote change\n".write(to: other.appendingPathComponent("file.txt"), atomically: true, encoding: .utf8)
        try await git("-c", "user.name=O", "-c", "user.email=o@example.com", "commit", "-qam", "Remote change", in: other)
        try await git("push", "-q", "origin", "main", in: other)
        try await git("push", "-q", "origin", "--delete", "gone", in: other)

        let preview = try await service.pullPreview(sourceBranch: nil, localFiles: [], remote: "origin", in: repository)
        XCTAssertEqual(preview.behindCount, 1)
        let incoming = try await service.commits(inRange: "HEAD..FETCH_HEAD", in: repository)
        XCTAssertEqual(incoming.map(\.subject), ["Remote change"])
        _ = try await service.pull(sourceBranch: "origin/main", strategy: .fastForwardOnly, remote: "origin", in: repository)
        XCTAssertEqual(try String(contentsOf: repository.appendingPathComponent("file.txt"), encoding: .utf8), "base\nremote change\n")
    }

    func testBranchesStashPushAndClone() async throws {
        try write("base\n", to: "file.txt")
        _ = try await service.commit(message: "Base", files: try await files(), in: repository)

        // Branch name validation and creation.
        let invalid = await service.branchNameProblem("bad..name", in: repository)
        XCTAssertNotNil(invalid)
        let existing = await service.branchNameProblem("main", in: repository)
        XCTAssertNotNil(existing)
        let valid = await service.branchNameProblem("feature/x", in: repository)
        XCTAssertNil(valid)
        _ = try await service.createBranch(named: "feature/x", from: nil, switchToBranch: true, in: repository)
        let current = try await service.currentBranch(in: repository)
        XCTAssertEqual(current, "feature/x")

        // Stash save / list / pop, including untracked files.
        try write("base\nchanged\n", to: "file.txt")
        try write("new\n", to: "new.txt")
        _ = try await service.stashSave(message: "WIP test", includeUntracked: true, in: repository)
        var status = try await files()
        XCTAssertTrue(status.isEmpty)
        let stashes = try await service.stashes(in: repository)
        XCTAssertEqual(stashes.count, 1)
        XCTAssertTrue(stashes[0].message.contains("WIP test"))
        _ = try await service.stashApply(stashes[0], pop: true, in: repository)
        status = try await files()
        XCTAssertEqual(status.map(\.path).sorted(), ["file.txt", "new.txt"])
        let remaining = try await service.stashes(in: repository)
        XCTAssertTrue(remaining.isEmpty)

        // Push a new branch to a bare remote with upstream, then clone it.
        let remote = sandbox.appendingPathComponent("remote.git")
        try FileManager.default.createDirectory(at: remote, withIntermediateDirectories: true)
        try await git("init", "--bare", "-q", in: remote)
        try await git("remote", "add", "origin", remote.path)
        _ = try await service.push(localBranch: "feature/x", remote: "origin", remoteBranch: "feature/x", setUpstream: true, forceWithLease: false, includeTags: false, in: repository)
        let upstream = try await service.currentUpstreamBranch(in: repository)
        XCTAssertEqual(upstream, "origin/feature/x")
        let remoteExists = await service.refExists("refs/remotes/origin/feature/x", in: repository)
        XCTAssertTrue(remoteExists)
        let outgoing = try await service.commits(inRange: "refs/remotes/origin/feature/x..HEAD", in: repository)
        XCTAssertTrue(outgoing.isEmpty)

        let clone = sandbox.appendingPathComponent("clone copy")
        _ = try await service.clone(url: remote.path, into: clone, branch: "feature/x", recurseSubmodules: false)
        let cloneBranch = try await service.currentBranch(in: clone)
        XCTAssertEqual(cloneBranch, "feature/x")
        _ = try await service.fetch(remote: nil, prune: true, tags: false, in: clone)
    }

    func testCommitRequiresIdentityAndSavesIt() async throws {
        // Empty repository-level values hide any global identity on this machine.
        try await git("config", "user.name", "")
        try await git("config", "user.email", "")
        try write("one\n", to: "a.txt")
        let identity = await service.identity(in: repository)
        XCTAssertFalse(identity.isComplete)
        do {
            _ = try await service.commit(message: "x", files: try await files(), in: repository)
            XCTFail("Committing without an identity must fail")
        } catch {
            XCTAssertEqual(error as? GitServiceError, .identityNotConfigured)
            XCTAssertNotNil((error as? LocalizedError)?.recoverySuggestion)
        }
        let unchanged = await service.hasCommits(in: repository)
        XCTAssertFalse(unchanged, "No commit with an invented identity")

        XCTAssertFalse(GitIdentity(name: "A", email: "not an email").isComplete)
        try await service.saveIdentity(GitIdentity(name: " Ada Lovelace ", email: "ada@example.com"), globally: false, in: repository)
        let saved = await service.identity(in: repository)
        XCTAssertEqual(saved, GitIdentity(name: "Ada Lovelace", email: "ada@example.com"))
        _ = try await service.commit(message: "First", files: try await files(), in: repository)
        let author = try await git("log", "-1", "--format=%an <%ae>")
        XCTAssertEqual(author.trimmingCharacters(in: .whitespacesAndNewlines), "Ada Lovelace <ada@example.com>")
    }

    func testFailureHintsAndSignInPrompt() throws {
        func hint(_ stderr: String) -> String? {
            GitServiceError.commandFailed(GitCommandResult(exitCode: 128, standardOutput: "", standardError: stderr, command: "git")).recoverySuggestion
        }
        XCTAssertTrue(hint("fatal: could not read Username for 'https://github.com': terminal prompts disabled")?.contains("personal access token") == true)
        XCTAssertTrue(hint("remote: Invalid username or password.\nfatal: Authentication failed for 'https://github.com/a/b.git/'")?.contains("Sign-in") == true)
        XCTAssertTrue(hint("git@github.com: Permission denied (publickey).\nfatal: Could not read from remote repository.")?.contains("SSH key") == true)
        XCTAssertTrue(hint("Host key verification failed.\nfatal: Could not read from remote repository.")?.contains("Connect") == true)
        XCTAssertTrue(hint("remote: Permission to a/b.git denied to someone.\nfatal: unable to access 'https://github.com/a/b.git/': The requested URL returned error: 403")?.contains("does not have access") == true)
        XCTAssertTrue(hint("remote: Repository not found.\nfatal: repository 'https://github.com/a/b.git/' not found")?.contains("not found") == true)
        XCTAssertTrue(hint("fatal: unable to access 'https://x/': Could not resolve host: x")?.contains("network") == true)
        XCTAssertNil(hint("error: Your local changes would be overwritten by merge."))

        // Git and SSH are pointed at an executable sign-in prompt.
        let environment = ProcessExecutor.gitProcessEnvironment(baseEnvironment: ["PATH": "/usr/bin"])
        let askPass = try XCTUnwrap(environment["GIT_ASKPASS"])
        XCTAssertEqual(environment["SSH_ASKPASS"], askPass)
        XCTAssertEqual(environment["SSH_ASKPASS_REQUIRE"], "force")
        XCTAssertEqual(environment["GIT_TERMINAL_PROMPT"], "0")
        XCTAssertTrue(FileManager.default.isExecutableFile(atPath: askPass))
        // A prompt configured by the user (or an IDE) is left alone.
        let custom = ProcessExecutor.gitProcessEnvironment(baseEnvironment: ["GIT_ASKPASS": "/custom"])
        XCTAssertEqual(custom["GIT_ASKPASS"], "/custom")
    }

    func testBranchSearchMatchesWordsAnywhereIgnoringCase() async throws {
        XCTAssertTrue(BranchSearch.matches("Fetch-from-release-tag13", query: "release"))
        XCTAssertTrue(BranchSearch.matches("428162_DuckDB_Connector_Release", query: "release"))
        XCTAssertTrue(BranchSearch.matches("Fetch-from-release-tag13", query: "13 RELEASE"))
        XCTAssertFalse(BranchSearch.matches("Fetch-from-release-tag13", query: "release 14"))

        // Branches on a server, none of them fetched by this clone.
        try write("base\n", to: "file.txt")
        _ = try await service.commit(message: "Base", files: try await files(), in: repository)
        let remote = sandbox.appendingPathComponent("remote.git")
        try FileManager.default.createDirectory(at: remote, withIntermediateDirectories: true)
        try await git("init", "--bare", "-q", in: remote)
        try await git("remote", "add", "origin", remote.path)
        for name in ["Release_13_hotfix", "feature/release-notes", "BuildReleaseSource", "main"] {
            try await git("push", "-q", "origin", "HEAD:refs/heads/\(name)")
        }

        let found = try await service.searchRemoteBranches(matching: "release", remote: "origin", in: repository)
        XCTAssertEqual(found.map(\.name), ["origin/BuildReleaseSource", "origin/feature/release-notes", "origin/Release_13_hotfix"])
        XCTAssertTrue(found.allSatisfy(\.isUnfetched))

        // The directory lists the server once and reuses it until asked to refresh.
        let directory = RemoteBranchDirectory()
        let first = try await directory.search("release", remote: "origin", in: repository, service: service)
        XCTAssertEqual(first.count, 3)
        try await git("push", "-q", "origin", "HEAD:refs/heads/release/2026")
        let cached = try await directory.search("release", remote: "origin", in: repository, service: service)
        XCTAssertEqual(cached.count, 3, "Typing again does not contact the server")
        let refreshed = try await directory.search("release", remote: "origin", in: repository, service: service, refresh: true)
        XCTAssertEqual(refreshed.count, 4)

        // A found branch can be fetched and checked out.
        let target = try XCTUnwrap(refreshed.first { $0.name == "origin/Release_13_hotfix" })
        _ = try await service.fetchRemoteBranch(target, in: repository)
        _ = try await service.switchBranch(to: target, in: repository)
        let current = try await service.currentBranch(in: repository)
        XCTAssertEqual(current, "Release_13_hotfix")
    }

    /// Regression: switching to a server branch in a repository that fetches only
    /// some branches failed with "starting point 'origin/x' is not a branch".
    func testSwitchToServerBranchWithNarrowFetchSettings() async throws {
        try write("base\n", to: "file.txt")
        _ = try await service.commit(message: "Base", files: try await files(), in: repository)
        let remote = sandbox.appendingPathComponent("remote.git")
        try FileManager.default.createDirectory(at: remote, withIntermediateDirectories: true)
        try await git("init", "--bare", "-q", in: remote)
        try await git("remote", "add", "origin", remote.path)
        try await git("push", "-q", "origin", "HEAD:refs/heads/development", "HEAD:refs/heads/release/webapp_v17.2", "HEAD:refs/heads/release/webapp_v17.1")
        try await git("config", "--replace-all", "remote.origin.fetch", "+refs/heads/development:refs/remotes/origin/development")
        try await git("fetch", "-q", "origin")

        // Search the way users type it.
        for query in ["webapp_v17.2", "v17_2", "release_webapp 17.2", "WEBAPP V17.2"] {
            let found = try await RemoteBranchDirectory().search(query, remote: "origin", in: repository, service: service)
            XCTAssertEqual(found.first?.name, "origin/release/webapp_v17.2", query)
        }
        XCTAssertTrue(BranchSearch.matches("release/webapp_v17.2", query: "_"))
        XCTAssertFalse(BranchSearch.matches("release/v17.2", query: "_"))
        let ranked = BranchSearch.ranked(["release/webapp_v17.2", "webapp/release_x"], for: "webapp_v17")
        XCTAssertEqual(ranked.first, "release/webapp_v17.2")

        // Fetch + switch from the search result, as the app does.
        let matches = try await service.searchRemoteBranches(matching: "webapp_v17.2", in: repository)
        let target = try XCTUnwrap(matches.first)
        _ = try await service.fetchRemoteBranch(target, in: repository)
        let output = try await service.switchBranch(to: target, in: repository)
        let current = try await service.currentBranch(in: repository)
        XCTAssertEqual(current, "release/webapp_v17.2")
        let upstream = try await service.currentUpstreamBranch(in: repository)
        XCTAssertEqual(upstream, "origin/release/webapp_v17.2", output)
        let refspecs = try await git("config", "--get-all", "remote.origin.fetch")
        XCTAssertTrue(refspecs.contains("refs/heads/release/webapp_v17.2:refs/remotes/origin/release/webapp_v17.2"))
        XCTAssertTrue(refspecs.contains("refs/heads/development:"), "Existing fetch settings are kept")

        // A branch fetched earlier by name (so not "unfetched") but not covered also works.
        try await git("fetch", "-q", "origin", "release/webapp_v17.1:refs/remotes/origin/release/webapp_v17.1")
        _ = try await service.switchBranch(to: GitBranch(name: "origin/release/webapp_v17.1", isCurrent: false, isRemote: true), in: repository)
        let second = try await service.currentUpstreamBranch(in: repository)
        XCTAssertEqual(second, "origin/release/webapp_v17.1")

        XCTAssertTrue(GitService.refspecs(["+refs/heads/*:refs/remotes/origin/*"], cover: "refs/heads/a/b"))
        XCTAssertFalse(GitService.refspecs(["+refs/heads/main:refs/remotes/origin/main"], cover: "refs/heads/a"))
    }

    func testCloneReportsProgressAndMatchesAddresses() async throws {
        // Git's own progress lines.
        let receiving = try XCTUnwrap(GitProgress.parse("Receiving objects:  45% (450/1000), 1.20 MiB | 2.00 MiB/s"))
        XCTAssertEqual(receiving.stage, "Receiving objects")
        XCTAssertEqual(receiving.percent, 45)
        XCTAssertEqual(receiving.detail, "450/1000 · 1.20 MiB | 2.00 MiB/s")
        XCTAssertEqual(try XCTUnwrap(receiving.overallFraction), 0.3875, accuracy: 0.001)
        XCTAssertEqual(GitProgress.parse("remote: Compressing objects: 100% (12/12), done.")?.percent, 100)
        XCTAssertEqual(GitProgress.parse("remote: Enumerating objects: 1234, done.")?.detail, "1234")
        XCTAssertNil(GitProgress.parse("Cloning into 'repo'..."))
        XCTAssertNil(GitProgress.parse("fatal: repository 'x' not found"))
        XCTAssertEqual(
            GitProgress.removingProgressLines("Cloning into 'r'...\nReceiving objects:  10% (1/10)\rReceiving objects: 100% (10/10), done.\nwarning: x"),
            "Cloning into 'r'...\nReceiving objects: 100% (10/10), done.\nwarning: x"
        )

        // The same repository written different ways.
        let forms = ["https://github.com/Owner/Repo.git", "git@github.com:owner/repo.git", "ssh://git@github.com:22/owner/repo", "https://me@github.com/owner/repo/"]
        XCTAssertEqual(Set(forms.map(RemoteURL.normalized)), ["github.com/owner/repo"])
        XCTAssertNotEqual(RemoteURL.normalized("https://github.com/owner/other"), RemoteURL.normalized(forms[0]))

        // A real clone over file:// (a full transfer, like a network clone) reports progress.
        for index in 0..<40 {
            try write(String(repeating: "line \(index)\n", count: 200), to: "dir/file\(index).txt")
        }
        _ = try await service.commit(message: "Files", files: try await files(), in: repository)
        let remote = sandbox.appendingPathComponent("remote.git")
        try await git("clone", "-q", "--bare", repository.path, remote.path, in: sandbox)

        final class Collected: @unchecked Sendable {
            private let lock = NSLock()
            private var items = [GitProgress]()
            func add(_ item: GitProgress) { lock.lock(); items.append(item); lock.unlock() }
            var all: [GitProgress] { lock.lock(); defer { lock.unlock() }; return items }
        }
        let collected = Collected()
        let destination = sandbox.appendingPathComponent("progress clone")
        let output = try await service.clone(url: "file://" + remote.path, into: destination, branch: nil, recurseSubmodules: false, progress: { collected.add($0) })
        XCTAssertTrue(collected.all.contains { $0.stage == "Receiving objects" && $0.percent == 100 }, "\(collected.all)")
        XCTAssertFalse(output.contains("\r"), "Progress redraws are removed from the output")
    }

    func testRevertSingleChangesInsideAFile() async throws {
        // 30 lines so three edits become three separate changes.
        let original = (1...30).map { "line \($0)" }
        try write(original.joined(separator: "\n") + "\n", to: "notes.txt")
        try await git("add", ".")
        try await git("commit", "-q", "-m", "Initial")

        var edited = original
        edited[1] = "first edit"
        edited[14] = "second edit"
        edited.insert("third edit", at: 27)
        let editedText = edited.joined(separator: "\n") + "\n"
        try write(editedText, to: "notes.txt")
        let fileURL = repository.appendingPathComponent("notes.txt")

        var file = try await files()[0]
        XCTAssertTrue(file.allowsPartialRevert)
        var patch = try await service.changes(in: file, in: repository)
        XCTAssertEqual(patch?.hunks.count, 3)
        XCTAssertEqual(patch?.hunks[1].lineDescription, "Line 15")

        // Revert only the middle change.
        let revert = try await service.revertChanges([1], of: XCTUnwrap(patch), in: repository)
        XCTAssertEqual(revert.count, 1)
        XCTAssertFalse(revert.includedIndex)
        var expected = edited
        expected[14] = "line 15"
        XCTAssertEqual(try String(contentsOf: fileURL, encoding: .utf8), expected.joined(separator: "\n") + "\n")

        // Undo brings it back.
        try await service.undoRevert(revert, in: repository)
        XCTAssertEqual(try String(contentsOf: fileURL, encoding: .utf8), editedText)

        // Staged copy with the same changes is reverted too.
        try await git("add", "notes.txt")
        file = try await files()[0]
        patch = try await service.changes(in: file, in: repository)
        let staged = try await service.revertChanges([0, 2], of: XCTUnwrap(patch), in: repository)
        XCTAssertTrue(staged.includedIndex)
        let cached = try await git("diff", "--cached")
        XCTAssertFalse(cached.contains("first edit"))
        XCTAssertTrue(cached.contains("second edit"))
        XCTAssertFalse(try String(contentsOf: fileURL, encoding: .utf8).contains("third edit"))

        // A file edited after it was shown is left alone.
        file = try await files()[0]
        patch = try await service.changes(in: file, in: repository)
        try write("someone else changed it\n", to: "notes.txt")
        do {
            _ = try await service.revertChanges([0], of: XCTUnwrap(patch), in: repository)
            XCTFail("Reverting a stale change should fail")
        } catch let error as GitServiceError {
            XCTAssertNotNil(error.recoverySuggestion)
        }
        XCTAssertEqual(try String(contentsOf: fileURL, encoding: .utf8), "someone else changed it\n")
    }

    func testPatchParsingKeepsLineEndingsAndRejectsOtherShapes() {
        let crlf = "diff --git a/a.txt b/a.txt\nindex 1..2 100644\n--- a/a.txt\n+++ b/a.txt\n@@ -1,3 +1,3 @@ func x()\n one\r\n-two\r\n+TWO\r\n\n"
        let patch = GitFilePatch.parse(crlf)
        XCTAssertEqual(patch?.hunks.count, 1)
        XCTAssertEqual(patch?.hunks[0].context, "func x()")
        XCTAssertEqual(patch?.hunks[0].rawLines, [" one\r", "-two\r", "+TWO\r", " "], "CRLF kept; blank context line restored")
        XCTAssertEqual(patch?.patch(including: [0]).hasSuffix("+TWO\r\n \n"), true)
        XCTAssertEqual(patch?.patch(including: []), "")

        XCTAssertNil(GitFilePatch.parse("diff --git a/b b/b\nBinary files a/b and b/b differ\n"))
        XCTAssertNil(GitFilePatch.parse(crlf + crlf.replacingOccurrences(of: "a.txt", with: "b.txt")), "Only one file at a time")
        XCTAssertNil(GitFilePatch.parse(""))
    }
}

