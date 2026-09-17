import Foundation

public struct GitCommandResult: Sendable, Equatable {
    public let exitCode: Int32
    public let standardOutput: String
    public let standardError: String
    public let command: String

    public var success: Bool {
        exitCode == 0
    }

    public init(exitCode: Int32, standardOutput: String, standardError: String, command: String) {
        self.exitCode = exitCode
        self.standardOutput = standardOutput
        self.standardError = standardError
        self.command = command
    }
}
