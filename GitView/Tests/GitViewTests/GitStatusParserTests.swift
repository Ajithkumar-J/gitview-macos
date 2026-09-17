import XCTest
@testable import Shared

final class GitStatusParserTests: XCTestCase {
    func testParsesCommonStatusLines() {
        let output = """
         M Sources/App.swift
        A  Sources/NewFile.swift
        D  Sources/Removed.swift
        ?? Notes.txt
        UU Package.swift
        R  Old.swift -> New.swift
        """

        let files = GitStatusParser.parsePorcelainV1(output)

        XCTAssertEqual(files.count, 6)
        XCTAssertEqual(files[0].path, "Sources/App.swift")
        XCTAssertEqual(files[0].state, .modified)
        XCTAssertEqual(files[1].state, .staged)
        XCTAssertEqual(files[2].state, .staged)
        XCTAssertEqual(files[3].state, .untracked)
        XCTAssertEqual(files[4].state, .conflicted)
        XCTAssertEqual(files[5].path, "New.swift")
        XCTAssertEqual(files[5].originalPath, "Old.swift")
    }
}
