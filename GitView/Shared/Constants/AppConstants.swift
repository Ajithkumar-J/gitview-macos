import Foundation

public enum AppConstants {
    public static let appName = "GitView"
    public static let gitExecutableCandidates = [
        "/opt/homebrew/bin/git",
        "/usr/local/bin/git",
        "/usr/bin/git"
    ]

    public static let executableSearchPaths = [
        "/opt/homebrew/bin",
        "/usr/local/bin",
        "/opt/local/bin",
        "/usr/bin",
        "/bin",
        "/usr/sbin",
        "/sbin"
    ]
}
