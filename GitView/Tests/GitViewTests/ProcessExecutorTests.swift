import XCTest
@testable import Shared

final class ProcessExecutorTests: XCTestCase {
    func testGitProcessEnvironmentPrependsHomebrewPaths() {
        let environment = ProcessExecutor.gitProcessEnvironment(baseEnvironment: ["PATH": "/custom/bin:/usr/bin"])

        XCTAssertEqual(
            environment["PATH"],
            "/opt/homebrew/bin:/usr/local/bin:/opt/local/bin:/usr/bin:/bin:/usr/sbin:/sbin:/custom/bin"
        )
    }
}
