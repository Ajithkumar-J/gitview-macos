import Foundation

public enum GitStatusParser {
    public static func parsePorcelainV1(_ text: String) -> [GitFileStatus] {
        text
            .split(whereSeparator: \.isNewline)
            .compactMap { parseLine(String($0)) }
    }

    private static func parseLine(_ line: String) -> GitFileStatus? {
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
