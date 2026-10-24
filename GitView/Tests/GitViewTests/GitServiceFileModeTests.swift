import Foundation
import XCTest
@testable import Shared

final class GitServiceFileModeTests: XCTestCase {
    func testPermissionNoiseIsIgnoredWithoutLosingContentEditsOrStagingModes() async throws {
        let repository = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: repository, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: repository) }
        let executor = ProcessExecutor()
        let git = URL(fileURLWithPath: "/usr/bin/git")
        func run(_ arguments: [String]) async throws -> GitCommandResult {
            let result = try await executor.run(executableURL: git, arguments: arguments, workingDirectory: repository)
            XCTAssertTrue(result.success, result.standardError)
            return result
        }
        _ = try await run(["init"])
        _ = try await run(["config", "core.filemode", "true"])
        let noise = repository.appendingPathComponent("noise.txt")
        let edited = repository.appendingPathComponent("edited.txt")
        for file in [noise, edited] {
            try "original\n".write(to: file, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: file.path)
        }
        _ = try await run(["add", "."])
        _ = try await run(["-c", "user.name=Test", "-c", "user.email=test@example.com", "commit", "-m", "Initial"])
        for file in [noise, edited] {
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: file.path)
        }
        try "updated\n".write(to: edited, atomically: false, encoding: .utf8)
        let service = try GitService(gitExecutableURL: git)
        let files = try await service.status(in: repository)
        XCTAssertEqual(files.map(\.path), ["edited.txt"])
        let diff = try await service.diff(for: XCTUnwrap(files.first), mode: .unstaged, in: repository)
        XCTAssertTrue(diff.contains("+updated"))
        XCTAssertFalse(diff.contains("new mode"))
        _ = try await service.commitSelected(files: files, message: "Content edit", in: repository)
        let committed = try await run(["show", "--format=", "--summary", "HEAD"])
        XCTAssertFalse(committed.standardOutput.contains("mode change"))
        let config = try await run(["config", "--get", "core.filemode"])
        XCTAssertEqual(config.standardOutput.trimmingCharacters(in: .whitespacesAndNewlines), "true")
        _ = try await run(["update-index", "--chmod=+x", "noise.txt"])
        let staged = try await service.status(in: repository)
        XCTAssertEqual(staged.map(\.path), ["noise.txt"])
        let stagedDiff = try await service.diff(for: XCTUnwrap(staged.first), mode: .staged, in: repository)
        XCTAssertTrue(stagedDiff.contains("new mode 100755"))
    }
}
