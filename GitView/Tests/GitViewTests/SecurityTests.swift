import Foundation
import XCTest
@testable import Shared

/// A hostile repository run against every Git operation GitView uses. Each
/// attack writes a marker file if it manages to run code; no test may find one.
final class SecurityTests: XCTestCase {
    private var sandbox: URL!
    private var repository: URL!
    private var marker: URL!
    private var service: GitService!
    private let executor = ProcessExecutor()

    override func setUp() async throws {
        sandbox = FileManager.default.temporaryDirectory.appendingPathComponent("GitView Security \(UUID().uuidString)")
        repository = sandbox.appendingPathComponent("hostile repo")
        marker = sandbox.appendingPathComponent("PWNED")
        try FileManager.default.createDirectory(at: repository, withIntermediateDirectories: true)
        service = try GitService()
        try await git("init", "-q", "-b", "main")
        try await git("config", "user.name", "Test")
        try await git("config", "user.email", "test@example.com")
        try await git("config", "commit.gpgsign", "false")
        try "base\n".write(to: repository.appendingPathComponent("file.txt"), atomically: true, encoding: .utf8)
        try await git("add", "file.txt")
        try await git("commit", "-q", "-m", "Base")
    }

    override func tearDown() async throws {
        RepositoryTrustStore.shared.revoke(repository)
        try? FileManager.default.removeItem(at: sandbox)
    }

    @discardableResult
    private func git(_ arguments: String..., in directory: URL? = nil) async throws -> String {
        let result = try await executor.run(executableURL: service.gitExecutableURL, arguments: arguments, workingDirectory: directory ?? repository)
        XCTAssertTrue(result.success, "git \(arguments.joined(separator: " ")): \(result.standardError)")
        return result.standardOutput
    }

    /// An executable script that creates the marker file.
    private func payload(named name: String) throws -> String {
        let script = sandbox.appendingPathComponent(name)
        try "#!/bin/sh\ntouch '\(marker.path)'\nexit 1\n".write(to: script, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: script.path)
        return script.path
    }

    private var wasExploited: Bool {
        FileManager.default.fileExists(atPath: marker.path)
    }

    // MARK: - B. Malicious repository settings

    func testHostileSettingsAreReportedAndNothingRunsUntilTrusted() async throws {
        let evil = try payload(named: "evil.sh")
        try await git("config", "core.fsmonitor", evil)
        try await git("config", "filter.lfs2.clean", evil)
        try await git("config", "core.sshCommand", evil)
        try await git("config", "credential.helper", "!" + evil)
        try await git("config", "http.sslVerify", "false")
        try await git("config", "url.ext::sh -c touch% /tmp/x.insteadOf", "https://example.com/")
        try await git("config", "core.fsmonitor.harmless", "true")   // not a real setting: ignored
        let hook = repository.appendingPathComponent(".git/hooks/pre-commit")
        try "#!/bin/sh\ntouch '\(marker.path)'\n".write(to: hook, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: hook.path)
        // A checked-out submodule's own settings run during the parent's `git status`.
        let module = repository.appendingPathComponent(".git/modules/libs/inner")
        try FileManager.default.createDirectory(at: module, withIntermediateDirectories: true)
        try "[core]\n\tfsmonitor = \(evil)\n".write(to: module.appendingPathComponent("config"), atomically: true, encoding: .utf8)

        let report = await service.safetyReport(in: repository)
        let settings = Set(report.risks.map(\.setting))
        for expected in ["core.fsmonitor", "filter.lfs2.clean", "core.sshcommand", "credential.helper", "http.sslverify", "url.ext::sh -c touch% /tmp/x.insteadof", "hook pre-commit"] {
            XCTAssertTrue(settings.contains(expected), "missing \(expected) in \(settings)")
        }
        XCTAssertTrue(report.risks.contains { $0.location == "submodule libs/inner" && $0.setting == "core.fsmonitor" })
        XCTAssertFalse(settings.contains("core.fsmonitor.harmless"))
        XCTAssertFalse(wasExploited, "Reading the settings must not run anything")

        // Declining: nothing runs and the repository does not open.
        do {
            _ = try await service.loadRepository(at: repository, trust: { _ in false })
            XCTFail("An untrusted repository must not open")
        } catch {
            XCTAssertEqual(error as? GitServiceError, .repositoryNotTrusted("hostile repo"))
        }
        XCTAssertFalse(wasExploited, "Declined repository ran code")

        // Trusting remembers this exact set of settings…
        _ = try await service.loadRepository(at: repository, trust: { _ in true })
        let trusted = await service.safetyReport(in: repository)
        XCTAssertTrue(RepositoryTrustStore.shared.isTrusted(trusted))
        // …and asks again when they change.
        try "#!/bin/sh\necho changed\n".write(to: hook, atomically: true, encoding: .utf8)
        let changed = await service.safetyReport(in: repository)
        XCTAssertFalse(RepositoryTrustStore.shared.isTrusted(changed))
    }

    func testOrdinaryRepositoryOpensWithoutAsking() async throws {
        try await git("config", "core.fsmonitor", "false")
        try await git("config", "credential.helper", "")
        let report = await service.safetyReport(in: repository)
        XCTAssertTrue(report.isSafe, "\(report.risks)")
        _ = try await service.loadRepository(at: repository, trust: { _ in
            XCTFail("No prompt for an ordinary repository")
            return false
        })
    }

    // MARK: - A. Option injection through repository data

    func testUpstreamSettingsCannotInjectOptions() async throws {
        let evil = try payload(named: "upload.sh")
        let remote = sandbox.appendingPathComponent("remote.git")
        try FileManager.default.createDirectory(at: remote, withIntermediateDirectories: true)
        try await git("init", "--bare", "-q", in: remote)
        try await git("remote", "add", "origin", remote.path)
        try await git("push", "-q", "-u", "origin", "main")

        // The upstream branch name is an option. (Ref names can't contain spaces,
        // so this payload lives in a path without them; the matching
        // remote-tracking ref makes @{u} resolve, as a real attack would.)
        let spaceless = FileManager.default.temporaryDirectory.appendingPathComponent("gitview-pwn-\(UUID().uuidString).sh").path
        try "#!/bin/sh\ntouch '\(marker.path)'\nexit 1\n".write(toFile: spaceless, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: spaceless)
        defer { try? FileManager.default.removeItem(atPath: spaceless) }
        try await git("config", "branch.main.merge", "refs/heads/--upload-pack=\(spaceless)")
        try await git("update-ref", "refs/remotes/origin/--upload-pack=\(spaceless)", "HEAD")
        do {
            _ = try await service.pullPreview(sourceBranch: nil, localFiles: [], remote: "origin", in: repository)
            XCTFail("Pull with an option as upstream must be refused")
        } catch {
            guard case GitServiceError.invalidName = error else { return XCTFail("\(error)") }
        }
        do {
            _ = try await service.pull(sourceBranch: nil, strategy: .fastForwardOnly, remote: "origin", in: repository)
            XCTFail("Pull with an option as upstream must be refused")
        } catch {
            guard case GitServiceError.invalidName = error else { return XCTFail("\(error)") }
        }

        // The remote name is an option.
        try await git("config", "remote.--upload-pack=\(evil).url", remote.path)
        for call in [
            { _ = try await self.service.fetch(remote: "--upload-pack=\(evil)", prune: false, tags: false, in: self.repository) },
            { _ = try await self.service.remoteBranchNames(remote: "--upload-pack=\(evil)", in: self.repository) },
            { _ = try await self.service.push(localBranch: "main", remote: "--receive-pack=\(evil)", remoteBranch: "main", setUpstream: false, forceWithLease: false, includeTags: false, in: self.repository) },
            { _ = try await self.service.clone(url: "--upload-pack=\(evil)", into: self.sandbox.appendingPathComponent("c"), branch: nil, recurseSubmodules: false) },
            { _ = try await self.service.clone(url: "ext::sh -c \(evil)", into: self.sandbox.appendingPathComponent("c"), branch: nil, recurseSubmodules: false) },
            { _ = try await self.service.commitDetail(hash: "--output=\(self.marker.path)", in: self.repository) },
        ] as [() async throws -> Void] {
            do {
                try await call()
                XCTFail("Hostile argument accepted")
            } catch {
                guard case GitServiceError.invalidName = error else { return XCTFail("\(error)") }
            }
        }

        // A branch whose name starts with "-" (possible with plumbing commands).
        try await git("update-ref", "refs/heads/-evil", "HEAD")
        do {
            _ = try await service.switchBranch(to: GitBranch(name: "-evil", isCurrent: false), in: repository)
            XCTFail("Switching to an option-like branch must be refused")
        } catch {
            guard case GitServiceError.invalidName = error else { return XCTFail("\(error)") }
        }
        XCTAssertFalse(wasExploited)
    }

    // MARK: - A/B. Hostile file names and special files

    func testHostileFileNamesWorkEverywhereAndRunNothing() async throws {
        let names = [
            "; touch \(marker.path)",
            "$(touch \(marker.path))",
            "`touch \(marker.path)`",
            "quote\" and 'single'",
            "-rf",
            "--output=\(marker.path)",
            "new\nline.txt",
            "cafe\u{301}.txt",                 // decomposed é (NFD)
            "invoice\u{202E}fdp.exe",          // right-to-left override
            "folder with spaces/ünïcödé ✓.txt",
        ]
        for name in names {
            let url = repository.appendingPathComponent(name)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try "content\n".write(to: url, atomically: true, encoding: .utf8)
        }

        var status = try await service.status(in: repository)
        XCTAssertEqual(status.count, names.count, "\(status.map(\.path))")
        for file in status {
            _ = try await service.diff(for: file, mode: .unstaged, in: repository)
        }
        try await service.stage(status, in: repository)
        status = try await service.status(in: repository)
        XCTAssertTrue(status.allSatisfy(\.hasStagedChanges))
        for file in status {
            let diff = try await service.diff(for: file, mode: .staged, in: repository)
            XCTAssertTrue(diff.contains("+content"), file.path)
        }
        _ = try await service.commit(message: "--amend $(touch \(marker.path))", files: status, in: repository)
        let message = try await service.lastCommitMessage(in: repository)
        XCTAssertEqual(message.trimmingCharacters(in: .whitespacesAndNewlines), "--amend $(touch \(marker.path))")
        let remaining = try await service.status(in: repository)
        XCTAssertTrue(remaining.isEmpty, "\(remaining.map(\.path))")
        XCTAssertFalse(wasExploited)

        // Shown safely: the override and the newline become visible.
        XCTAssertEqual(DisplayText.visible("invoice\u{202E}fdp.exe"), "invoice<U+202E>fdp.exe")
        XCTAssertEqual(DisplayText.visible("a\u{1B}[31mred", keepNewlines: false), "a␛[31mred")
        XCTAssertEqual(DisplayText.visible("new\nline", keepNewlines: false), "new␊line")
    }

    func testSymlinksAndSpecialFilesStayInside() async throws {
        // A symlink to a file outside the repository: Git records the link, never the target.
        try FileManager.default.createSymbolicLink(atPath: repository.appendingPathComponent("secrets").path, withDestinationPath: "/etc/hosts")
        // A FIFO would block anything that reads it.
        XCTAssertEqual(mkfifo(repository.appendingPathComponent("pipe").path, 0o644), 0)

        let status = try await service.status(in: repository)
        let link = try XCTUnwrap(status.first { $0.path == "secrets" })
        XCTAssertFalse(status.contains { $0.path == "pipe" }, "Git ignores FIFOs")
        let diff = try await service.diff(for: link, mode: .unstaged, in: repository)
        XCTAssertTrue(diff.contains("+/etc/hosts"), "Shows the link target path, not the file: \(diff)")
        XCTAssertFalse(diff.contains("localhost"))

        // The Finder extension's reader refuses FIFOs instead of blocking.
        // (Same logic as RepositoryLocator.readSmallFile, checked here via fstat.)
        let descriptor = open(repository.appendingPathComponent("pipe").path, O_RDONLY | O_NONBLOCK)
        var info = stat()
        XCTAssertEqual(fstat(descriptor, &info), 0)
        XCTAssertNotEqual(info.st_mode & S_IFMT, S_IFREG)
        close(descriptor)
    }

    // MARK: - C. Credentials

    func testCredentialsAreRedacted() {
        // Fake tokens are assembled at runtime so secret scanners don't flag this file.
        let github = "ghp" + "_abcdefghijklmnopqrstuvwxyz0123456789"
        let gitlab = "glpat" + "-abcdefghijklmnopqrstu"
        let fineGrained = "github" + "_pat_11ABCDEFG0123456789_abcdefghijklmnopqrstuvwxyz"
        let text = """
        From https://ajith:\(github)@github.com/a/b
        fatal: unable to access 'https://token123@gitea.example.com/x.git/': 403
        remote: \(gitlab) and \(fineGrained)
        Authorization: Bearer abc.def.ghi
        ssh://git@github.com/a/b and git@github.com:a/b.git stay readable
        """
        let redacted = Redactor.redact(text)
        for secret in ["ghp_abcdef", "ajith:", "token123", "glpat-abc", "github_pat_11", "abc.def.ghi"] {
            XCTAssertFalse(redacted.contains(secret), "\(secret) leaked: \(redacted)")
        }
        XCTAssertTrue(redacted.contains("https://•••@github.com/a/b"))
        XCTAssertTrue(redacted.contains("git@github.com:a/b.git"))

        let failure = GitServiceError.commandFailed(GitCommandResult(exitCode: 128, standardOutput: "", standardError: "fatal: could not read from https://u:secret@host/x", command: "git"))
        XCTAssertFalse(failure.localizedDescription.contains("secret"))
    }

    func testEnvironmentCannotRedirectGitOrLeakSecrets() {
        let environment = ProcessExecutor.gitProcessEnvironment(baseEnvironment: [
            "PATH": ".:bin:/usr/bin",
            "GIT_DIR": "/tmp/other",
            "GIT_CONFIG_PARAMETERS": "'core.fsmonitor'='evil'",
            "GIT_CONFIG_COUNT": "1", "GIT_CONFIG_KEY_0": "core.sshCommand", "GIT_CONFIG_VALUE_0": "evil",
            "GIT_TRACE_CURL": "1", "GIT_SSL_NO_VERIFY": "1", "GIT_EXEC_PATH": "/tmp", "DYLD_INSERT_LIBRARIES": "/tmp/x.dylib",
            "HOME": "/Users/test",
        ])
        for name in ["GIT_DIR", "GIT_CONFIG_PARAMETERS", "GIT_CONFIG_COUNT", "GIT_CONFIG_KEY_0", "GIT_CONFIG_VALUE_0", "GIT_TRACE_CURL", "GIT_SSL_NO_VERIFY", "GIT_EXEC_PATH", "DYLD_INSERT_LIBRARIES"] {
            XCTAssertNil(environment[name], name)
        }
        XCTAssertEqual(environment["HOME"], "/Users/test")
        let path = environment["PATH"]?.split(separator: ":").map(String.init) ?? []
        XCTAssertTrue(path.allSatisfy { $0.hasPrefix("/") }, "\(path)")

        // Tools started by GitView (VS Code) get no Git prompt settings.
        let tool = ProcessExecutor.toolEnvironment(baseEnvironment: ["PATH": "/usr/bin"])
        XCTAssertNil(tool["GIT_ASKPASS"])
        XCTAssertNil(tool["GITVIEW_ASKPASS"])
    }

    // MARK: - E. URL scheme and clone input

    func testDeepLinksAcceptOnlyLocalAbsolutePaths() {
        func link(_ query: String) -> GitViewDeepLink? {
            GitViewDeepLink(url: URL(string: "gitview://open?\(query)")!)
        }
        XCTAssertNotNil(link("path=/Users/me/repo&action=commit"))
        XCTAssertEqual(link("path=/Users/me/./repo/")?.paths, ["/Users/me/repo"])
        XCTAssertNil(link("path=relative/repo"))
        XCTAssertNil(link("path=/Users/me/../../etc"))
        XCTAssertNil(link("path=/tmp/a%0Ab"))
        XCTAssertNil(link("action=commit"))
        XCTAssertNil(link(Array(repeating: "path=/a", count: GitViewDeepLink.maximumPaths + 1).joined(separator: "&")))
        XCTAssertNil(GitViewDeepLink(url: URL(string: "gitview://evil?path=/a")!))
    }

    func testCloneInputChecks() {
        XCTAssertNil(GitArgument.cloneURLProblem("https://github.com/a/b.git"))
        XCTAssertNil(GitArgument.cloneURLProblem("git@github.com:a/b.git"))
        XCTAssertNotNil(GitArgument.cloneURLProblem("--upload-pack=touch /tmp/x"))
        XCTAssertNotNil(GitArgument.cloneURLProblem("ext::sh -c touch% /tmp/x"))
        XCTAssertNotNil(GitArgument.cloneURLProblem("https://a/b\n--x"))
        XCTAssertNil(GitArgument.cloneURLProblem("/Users/me/My Repos/project"))
        XCTAssertNotNil(GitArgument.cloneURLWarning("http://example.com/a.git"))
        XCTAssertNotNil(GitArgument.cloneURLWarning("https://me:token@example.com/a.git"))
        XCTAssertNil(GitArgument.cloneURLWarning("https://me@example.com/a.git"))
        XCTAssertNotNil(GitArgument.folderNameProblem(".."))
        XCTAssertNotNil(GitArgument.folderNameProblem("a/b"))
        XCTAssertNil(GitArgument.folderNameProblem("repo"))
    }
}
