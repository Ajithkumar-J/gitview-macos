import Foundation
import XCTest
@testable import Shared

/// Runs the everyday workflow against a real temporary repository.
final class GitServiceWorkflowTests: XCTestCase {
    private var repository: URL!
    private var service: GitService!
    private let executor = ProcessExecutor()

    override func setUp() async throws {
        repository = FileManager.default.temporaryDirectory.appendingPathComponent("GitView Tests \(UUID().uuidString)")
        try FileManager.default.createDirectory(at: repository, withIntermediateDirectories: true)
        service = try GitService()
        try await git("init", "-b", "main")
        try await git("config", "user.name", "Test")
        try await git("config", "user.email", "test@example.com")
        try await git("config", "commit.gpgsign", "false")
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: repository)
    }

    @discardableResult
    private func git(_ arguments: String...) async throws -> String {
        let result = try await executor.run(executableURL: service.gitExecutableURL, arguments: arguments, workingDirectory: repository)
        XCTAssertTrue(result.success, "git \(arguments.joined(separator: " ")): \(result.standardError)")
        return result.standardOutput
    }

    private func write(_ text: String, to name: String) throws {
        let url = repository.appendingPathComponent(name)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try text.write(to: url, atomically: true, encoding: .utf8)
    }

    func testStageUnstageCommitHistoryAndBranches() async throws {
        // Empty repository: no commits, no history, files untracked.
        try write("hello\n", to: "Folder With Space/first file.txt")
        var snapshot = try await service.loadRepository(at: repository.appendingPathComponent("Folder With Space"), trust: { _ in false })
        XCTAssertEqual(snapshot.rootPath.standardizedFileURL.resolvingSymlinksInPath().path, repository.standardizedFileURL.resolvingSymlinksInPath().path)
        XCTAssertEqual(snapshot.branch, "main")
        XCTAssertFalse(snapshot.hasCommits)
        XCTAssertEqual(snapshot.changes(in: .untracked).map(\.path), ["Folder With Space/first file.txt"])
        let emptyHistory = try await service.history(in: repository)
        XCTAssertEqual(emptyHistory, [])

        // Commit validation.
        do {
            _ = try await service.commit(message: "Nothing", in: repository)
            XCTFail("Commit without staged files must fail")
        } catch {
            XCTAssertEqual(error as? GitServiceError, .nothingStaged)
        }

        // Stage, unstage before the first commit, stage again, commit.
        try await service.stage(snapshot.files, in: repository)
        snapshot = try await service.loadRepository(at: repository, trust: { _ in false })
        XCTAssertEqual(snapshot.changes(in: .staged).map(\.path), ["Folder With Space/first file.txt"])
        try await service.unstage(snapshot.files, in: repository)
        snapshot = try await service.loadRepository(at: repository, trust: { _ in false })
        XCTAssertEqual(snapshot.stagedCount, 0)
        try await service.stageAll(in: repository)
        let outcome = try await service.commit(message: "Initial commit\n\nBody text", in: repository)
        XCTAssertEqual(outcome.subject, "Initial commit")
        XCTAssertFalse(outcome.shortHash.isEmpty)

        // Partially staged file shows up in both lists with matching diffs.
        try write("hello\nstaged\n", to: "Folder With Space/first file.txt")
        try await service.stageAll(in: repository)
        try write("hello\nstaged\nunstaged\n", to: "Folder With Space/first file.txt")
        snapshot = try await service.loadRepository(at: repository, trust: { _ in false })
        let staged = try XCTUnwrap(snapshot.changes(in: .staged).first)
        let unstaged = try XCTUnwrap(snapshot.changes(in: .unstaged).first)
        let stagedDiff = GitDiffParser.parse(try await service.diff(for: staged, in: repository))
        let unstagedDiff = GitDiffParser.parse(try await service.diff(for: unstaged, in: repository))
        XCTAssertEqual(stagedDiff.lines.filter { $0.kind == .addition }.map(\.text), ["staged"])
        XCTAssertEqual(unstagedDiff.lines.filter { $0.kind == .addition }.map(\.text), ["unstaged"])

        // Discarding unstaged changes keeps the staged part.
        _ = try await service.discardChanges(unstaged, in: repository)
        snapshot = try await service.loadRepository(at: repository, trust: { _ in false })
        XCTAssertEqual(snapshot.changes(in: .unstaged), [])
        XCTAssertEqual(snapshot.changes(in: .staged).count, 1)
        _ = try await service.commit(message: "Second", in: repository)

        // History and commit details.
        let history = try await service.history(in: repository)
        XCTAssertEqual(history.map(\.subject), ["Second", "Initial commit"])
        XCTAssertTrue(history[0].refs.contains("HEAD -> main"))
        let detail = try await service.commitDetail(hash: history[1].hash, in: repository)
        XCTAssertEqual(detail.body, "Body text")
        XCTAssertEqual(detail.files.map(\.path), ["Folder With Space/first file.txt"])
        XCTAssertEqual(detail.files.first?.kind, .added)
        let commitDiff = GitDiffParser.parse(try await service.diff(for: detail.files[0], inCommit: history[1].hash, in: repository))
        XCTAssertEqual(commitDiff.additions, 1)
        let page = try await service.history(limit: 1, skip: 1, in: repository)
        XCTAssertEqual(page.map(\.subject), ["Initial commit"])

        // Branches.
        try await git("branch", "feature/one")
        var branches = try await service.branches(in: repository)
        XCTAssertEqual(Set(branches.map(\.name)), ["main", "feature/one"])
        XCTAssertEqual(branches.first(where: \.isCurrent)?.name, "main")
        let feature = try XCTUnwrap(branches.first(where: { $0.name == "feature/one" }))
        _ = try await service.switchBranch(to: feature, in: repository)
        branches = try await service.branches(in: repository)
        XCTAssertEqual(branches.first(where: \.isCurrent)?.name, "feature/one")
    }

    func testSwitchBranchFailureSurfacesGitError() async throws {
        try write("one\n", to: "file.txt")
        try await git("add", ".")
        try await git("commit", "-m", "one")
        try await git("switch", "-c", "other")
        try write("two\n", to: "file.txt")
        try await git("commit", "-am", "two")
        try await git("switch", "main")
        try write("local edit\n", to: "file.txt")

        do {
            _ = try await service.switchBranch(to: GitBranch(name: "other", isCurrent: false), in: repository)
            XCTFail("Switching with conflicting local changes must fail")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("would be overwritten"), error.localizedDescription)
        }
    }

    func testNonRepositoryIsReported() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }

        do {
            _ = try await service.loadRepository(at: folder, trust: { _ in false })
            XCTFail("Expected notARepository")
        } catch GitServiceError.notARepository {
            // Expected.
        }
    }
}
