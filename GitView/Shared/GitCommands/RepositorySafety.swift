import CryptoKit
import Foundation

// MARK: - Arguments

/// Checks values that reach Git's command line as names (remotes, branches,
/// commits). A value starting with "-" would be read as an option — for example
/// a repository whose upstream is configured as `--upload-pack=<command>` would
/// make `git fetch` run that command — so such values are refused, and commands
/// also put `--end-of-options` before them.
public enum GitArgument {
    public static func name(_ value: String, kind: String) throws -> String {
        let trimmed = value.trimmingCharacters(in: .whitespaces)
        let hasControl = trimmed.unicodeScalars.contains { CharacterSet.controlCharacters.contains($0) }
        guard !trimmed.isEmpty, !trimmed.hasPrefix("-"), !hasControl else {
            throw GitServiceError.invalidName(kind: kind, value: value)
        }
        return trimmed
    }

    /// Why a clone URL can't be used, or nil. URLs that start with "-" would be
    /// read as options; ext:: and fd:: addresses run local commands.
    public static func cloneURLProblem(_ url: String) -> String? {
        let url = url.trimmingCharacters(in: .whitespaces)
        if url.isEmpty { return "Enter the repository URL." }
        if url.hasPrefix("-") { return "A repository URL can't start with “-”." }
        // Spaces are fine (local paths); line breaks and control characters are not.
        if url.unicodeScalars.contains(where: { CharacterSet.newlines.contains($0) || CharacterSet.controlCharacters.contains($0) }) {
            return "A repository URL can't contain line breaks or control characters."
        }
        let lowered = url.lowercased()
        if lowered.hasPrefix("ext::") || lowered.hasPrefix("fd::") { return "ext:: and fd:: addresses run commands and are not allowed." }
        return nil
    }

    /// A warning for URLs that work but are unsafe.
    public static func cloneURLWarning(_ url: String) -> String? {
        let lowered = url.trimmingCharacters(in: .whitespaces).lowercased()
        if lowered.hasPrefix("http://") || lowered.hasPrefix("git://") {
            return "This address isn't encrypted: anyone on the network can read or change what you download. Use https:// or SSH if the server supports it."
        }
        if let scheme = lowered.range(of: "://"), let at = lowered.firstIndex(of: "@"), at > scheme.upperBound,
           !lowered[scheme.upperBound..<at].contains("/"), lowered[scheme.upperBound..<at].contains(":") {
            return "This address contains a password or token. Git saves it in plain text in the repository's settings; leave it out and sign in when asked instead."
        }
        return nil
    }

    /// A folder name that stays inside the chosen folder.
    public static func folderNameProblem(_ name: String) -> String? {
        if name.isEmpty || name == "." || name == ".." || name.contains("/") || name.contains(":")
            || name.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) {
            return "Enter a valid folder name."
        }
        return nil
    }

    /// A full or abbreviated commit hash.
    public static func commit(_ value: String) throws -> String {
        let isHash = (4...64).contains(value.count) && value.allSatisfy(\.isHexDigit)
        guard isHash else {
            throw GitServiceError.invalidName(kind: "commit", value: value)
        }
        return value
    }
}

// MARK: - Redaction

/// Removes credentials before text is shown, logged or kept: user info in URLs
/// (`https://user:token@host`) and well-known token formats.
public enum Redactor {
    private static let rules: [(NSRegularExpression, String)] = [
        // scheme://user[:password]@host → scheme://•••@host
        (#"([A-Za-z][A-Za-z0-9+.\-]*://)[^\s/@'"]+@"#, "$1•••@"),
        // GitHub, GitLab, Slack, AWS, generic bearer tokens.
        (#"\b(gh[pousr]_[A-Za-z0-9]{20,}|github_pat_[A-Za-z0-9_]{20,}|glpat-[A-Za-z0-9_\-]{20,}|xox[abprs]-[A-Za-z0-9\-]{10,}|AKIA[0-9A-Z]{16})\b"#, "•••"),
        (#"(?i)(authorization:\s*(?:basic|bearer)\s+)[^\s]+"#, "$1•••"),
    ].map { (try! NSRegularExpression(pattern: $0.0), $0.1) }

    public static func redact(_ text: String) -> String {
        guard !text.isEmpty else { return text }
        var result = text
        for (expression, template) in rules {
            let range = NSRange(result.startIndex..., in: result)
            result = expression.stringByReplacingMatches(in: result, range: range, withTemplate: template)
        }
        return result
    }
}

// MARK: - Display

/// Makes text from a repository safe to show: control characters (terminal
/// escape sequences) and invisible bidirectional overrides — which can make
/// "invoice\u{202E}fdp.exe" look like "invoiceexe.pdf" — become visible markers.
public enum DisplayText {
    private static let bidiControls: Set<UInt32> = [0x061C, 0x200E, 0x200F, 0x202A, 0x202B, 0x202C, 0x202D, 0x202E, 0x2066, 0x2067, 0x2068, 0x2069]

    public static func visible(_ text: String, keepNewlines: Bool = true) -> String {
        var output = String.UnicodeScalarView()
        for scalar in text.unicodeScalars {
            let value = scalar.value
            if bidiControls.contains(value) {
                output.append(contentsOf: String(format: "<U+%04X>", value).unicodeScalars)
            } else if value < 0x20 || value == 0x7F || (0x80..<0xA0).contains(value) {
                if keepNewlines, scalar == "\n" || scalar == "\t" {
                    output.append(scalar)
                } else if value == 0x1B {
                    output.append("␛")
                } else if value < 0x20 {
                    output.append(Unicode.Scalar(0x2400 + value)!)   // ␀…␟
                } else {
                    output.append("�")
                }
            } else {
                output.append(scalar)
            }
        }
        return String(output)
    }
}

// MARK: - Repository trust

/// A setting or hook in a repository that makes Git run a program, or weakens
/// security, when GitView runs Git there.
public struct RepositoryRisk: Hashable, Sendable, Identifiable {
    public let setting: String
    public let value: String
    public let effect: String
    /// "this repository" or "submodule <name>".
    public let location: String

    public var id: String { "\(location)|\(setting)|\(value)" }
}

public struct RepositorySafetyReport: Equatable, Sendable {
    public let root: URL
    public let risks: [RepositoryRisk]
    /// Changes whenever the risky settings or hook contents change.
    public let fingerprint: String

    public var isSafe: Bool { risks.isEmpty }
}

/// Repository settings can run programs: Git honours `core.fsmonitor` on every
/// status refresh, filters on staging and checkout, `core.sshCommand` and
/// `credential.helper` on fetch, hooks on commit… A repository downloaded from
/// someone else can carry such settings in `.git/config`. GitView reads the
/// repository's own settings (reading never runs anything) and asks before
/// running Git in a repository that has any; the user's global settings are trusted.
public enum RepositorySafety {
    static let thisRepository = "this repository"

    /// What a setting does, or nil when it is harmless.
    public static func effect(ofSetting key: String, value: String) -> String? {
        let key = key.lowercased()
        let value = value.trimmingCharacters(in: .whitespaces)
        let parts = key.split(separator: ".", omittingEmptySubsequences: false).map(String.init)
        guard parts.count >= 2 else { return nil }
        let section = parts[0]
        let name = parts[parts.count - 1]
        let isOff = ["false", "no", "off", "0"].contains(value.lowercased())

        switch key {
        case "core.fsmonitor":
            return ["", "true", "false", "yes", "no", "on", "off", "1", "0"].contains(value.lowercased())
                ? nil : "runs every time GitView refreshes the list of changed files"
        case "core.hookspath":
            return "runs hooks from this folder when you commit, switch branch, pull or push"
        case "core.sshcommand", "core.gitproxy", "core.alternaterefscommand":
            return "runs when GitView fetches, pulls or pushes"
        case "core.askpass":
            return "runs when Git asks for a password"
        case "core.worktree":
            return "makes Git work on files in another folder (\(value))"
        case "core.editor", "sequence.editor":
            return "runs if Git opens an editor"
        case "diff.external":
            return "runs when a diff is shown"
        case "uploadpack.packobjectshook":
            return "runs when this repository is fetched from"
        default:
            break
        }

        switch (section, name) {
        case ("filter", "clean"), ("filter", "smudge"), ("filter", "process"):
            return "runs on files when GitView refreshes, stages, commits or switches branches"
        case ("diff", "command"), ("diff", "textconv"):
            return "runs when a diff is shown"
        case ("merge", "driver"):
            return "runs when a pull merges changes"
        case ("credential", "helper"):
            return value.isEmpty ? nil : "runs when Git signs in to a server (and receives your credentials)"
        case ("remote", "uploadpack"), ("remote", "receivepack"):
            return "runs when GitView fetches, pulls or pushes"
        case ("gpg", "program"):
            return "runs when you commit (commit signing)"
        case ("url", "insteadof"), ("url", "pushinsteadof"):
            return key.contains("ext::") || key.contains("fd::") ? "rewrites remote addresses to a command" : nil
        case ("protocol", "allow"):
            return value.lowercased() == "always" ? "allows remote addresses that run commands (ext::)" : nil
        case ("submodule", "update"):
            return value.hasPrefix("!") ? "runs a command when submodules update" : nil
        case ("http", "sslverify"):
            return isOff ? "turns off HTTPS certificate checks, so someone on the network could read or change the traffic" : nil
        case ("alias", _):
            return nil
        default:
            return nil
        }
    }

    static func hookEffect(_ hook: String) -> String {
        switch hook {
        case "pre-commit", "prepare-commit-msg", "commit-msg", "post-commit", "pre-merge-commit":
            "runs when you commit"
        case "post-checkout":
            "runs when you switch branch or clone"
        case "post-merge":
            "runs when you pull"
        case "pre-push":
            "runs when you push"
        case "pre-rebase", "post-rewrite":
            "runs when you rebase or amend"
        case "reference-transaction":
            "runs on almost every change to branches"
        default:
            "runs during Git commands"
        }
    }

    /// `git config --list --show-scope -z` output: alternating scope and "key\nvalue".
    static func localSettings(fromScopedList output: String) -> [(key: String, value: String)] {
        let fields = output.split(separator: "\0", omittingEmptySubsequences: false).map(String.init)
        var settings = [(key: String, value: String)]()
        var index = 0
        while index + 1 < fields.count {
            let scope = fields[index]
            let entry = fields[index + 1]
            index += 2
            guard scope == "local" || scope == "worktree" else { continue }
            settings.append(split(entry))
        }
        return settings
    }

    /// `git config --file <f> --list -z` output: "key\nvalue" entries.
    static func settings(fromList output: String) -> [(key: String, value: String)] {
        output.split(separator: "\0").map { split(String($0)) }
    }

    private static func split(_ entry: String) -> (key: String, value: String) {
        guard let newline = entry.firstIndex(of: "\n") else { return (entry, "") }
        return (String(entry[..<newline]), String(entry[entry.index(after: newline)...]))
    }

    static func fingerprint(_ risks: [RepositoryRisk], hookDigests: [String]) -> String {
        let text = (risks.map(\.id).sorted() + hookDigests.sorted()).joined(separator: "\n")
        return SHA256.hash(data: Data(text.utf8)).map { String(format: "%02x", $0) }.joined()
    }
}

public extension GitService {
    /// Risky settings and hooks of the repository and its submodules. Only reads files.
    func safetyReport(in root: URL) async -> RepositorySafetyReport {
        var risks = [RepositoryRisk]()
        var hookDigests = [String]()

        if let result = try? await runGit(["config", "--list", "--show-scope", "-z"], workingDirectory: root), result.success {
            for (key, value) in RepositorySafety.localSettings(fromScopedList: result.standardOutput) {
                if let effect = RepositorySafety.effect(ofSetting: key, value: value) {
                    risks.append(RepositoryRisk(setting: key, value: value, effect: effect, location: RepositorySafety.thisRepository))
                }
            }
        }

        // Hooks: executable files in the hooks folder (core.hooksPath or .git/hooks).
        if let result = try? await runGit(["rev-parse", "--path-format=absolute", "--git-path", "hooks"], workingDirectory: root), result.success {
            let folder = URL(fileURLWithPath: result.standardOutput.trimmingCharacters(in: .whitespacesAndNewlines))
            for hook in Self.executableHooks(in: folder) {
                risks.append(RepositoryRisk(setting: "hook \(hook.lastPathComponent)", value: hook.path, effect: RepositorySafety.hookEffect(hook.lastPathComponent), location: RepositorySafety.thisRepository))
                let contents = (try? Data(contentsOf: hook, options: .mappedIfSafe)) ?? Data()
                hookDigests.append(hook.path + ":" + SHA256.hash(data: contents).map { String(format: "%02x", $0) }.joined())
            }
        }

        // Submodules keep their own settings in <git dir>/modules/**/config, and
        // `git status` runs Git inside each checked-out submodule.
        if let result = try? await runGit(["rev-parse", "--path-format=absolute", "--git-common-dir"], workingDirectory: root), result.success {
            let modules = URL(fileURLWithPath: result.standardOutput.trimmingCharacters(in: .whitespacesAndNewlines)).appendingPathComponent("modules")
            for config in Self.submoduleConfigs(under: modules) {
                guard let list = try? await runGit(["config", "--file", config.path, "--includes", "--list", "-z"], workingDirectory: root), list.success else { continue }
                let name = config.deletingLastPathComponent().path.replacingOccurrences(of: modules.path + "/", with: "").replacingOccurrences(of: "/modules/", with: "/")
                for (key, value) in RepositorySafety.settings(fromList: list.standardOutput) {
                    if let effect = RepositorySafety.effect(ofSetting: key, value: value) {
                        risks.append(RepositoryRisk(setting: key, value: value, effect: effect, location: "submodule \(name)"))
                    }
                }
            }
        }

        return RepositorySafetyReport(root: root, risks: risks, fingerprint: RepositorySafety.fingerprint(risks, hookDigests: hookDigests))
    }

    private static func executableHooks(in folder: URL) -> [URL] {
        let fileManager = FileManager.default
        guard let names = try? fileManager.contentsOfDirectory(atPath: folder.path) else { return [] }
        return names.sorted().compactMap { name in
            guard !name.hasSuffix(".sample"), !name.hasPrefix(".") else { return nil }
            let url = folder.appendingPathComponent(name)
            var isDirectory: ObjCBool = false
            guard fileManager.fileExists(atPath: url.path, isDirectory: &isDirectory), !isDirectory.boolValue,
                  fileManager.isExecutableFile(atPath: url.path) else { return nil }
            return url
        }
    }

    private static func submoduleConfigs(under modules: URL) -> [URL] {
        guard let enumerator = FileManager.default.enumerator(at: modules, includingPropertiesForKeys: [.isRegularFileKey], options: [.skipsHiddenFiles]) else {
            return []
        }
        var configs = [URL]()
        for case let url as URL in enumerator {
            if enumerator.level > 12 { enumerator.skipDescendants(); continue }
            // Skip object stores and other large folders.
            if ["objects", "refs", "logs", "hooks", "info", "lfs"].contains(url.lastPathComponent) { enumerator.skipDescendants(); continue }
            if url.lastPathComponent == "config", (try? url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true {
                configs.append(url)
            }
        }
        return configs.sorted { $0.path < $1.path }
    }
}

/// Repositories the user chose to trust despite risky settings. The trust is
/// tied to a fingerprint of those settings and hooks: if they change, GitView asks again.
public final class RepositoryTrustStore: @unchecked Sendable {
    public static let shared = RepositoryTrustStore(defaults: .standard)
    private static let key = "TrustedRepositories"
    private let defaults: UserDefaults

    public init(defaults: UserDefaults) {
        self.defaults = defaults
    }

    public func isTrusted(_ report: RepositorySafetyReport) -> Bool {
        report.isSafe || trusted[report.root.standardizedFileURL.path] == report.fingerprint
    }

    public func trust(_ report: RepositorySafetyReport) {
        var list = trusted
        list[report.root.standardizedFileURL.path] = report.fingerprint
        defaults.set(list, forKey: Self.key)
    }

    public func revoke(_ root: URL) {
        var list = trusted
        list[root.standardizedFileURL.path] = nil
        defaults.set(list, forKey: Self.key)
    }

    private var trusted: [String: String] {
        defaults.dictionary(forKey: Self.key) as? [String: String] ?? [:]
    }
}
