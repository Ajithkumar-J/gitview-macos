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
}
