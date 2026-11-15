# GitView Security

GitView runs Git on folders the user picks, including repositories made by other people. This document lists the threats considered, how GitView handles each, how it is tested, and what is still open before a public release.

Run the security tests with `swift test --filter SecurityTests`. They build a hostile repository and check that none of its attacks run code: every attack tries to create a marker file, and each test asserts that the file never appears.

## Status

| Area | Check | Status |
|---|---|---|
| A. Command execution | Git runs as an argument array (`Process`), never through a shell | ✅ Pass |
| | Names from repositories or users (remotes, branches, commits) are refused if they start with `-` or contain control characters, and `--end-of-options` comes before them | ✅ Fixed, tested |
| | Paths always follow `--` | ✅ Pass, tested with hostile names |
| | Git comes from fixed locations (`/opt/homebrew/bin`, `/usr/local/bin`, `/usr/bin`); relative `PATH` entries are ignored | ✅ Fixed |
| | Inherited variables that redirect Git or weaken it are removed (`GIT_DIR`, `GIT_CONFIG_*`, `GIT_EXEC_PATH`, `GIT_TRACE*`, `GIT_SSL_NO_VERIFY`, `DYLD_*` …) | ✅ Fixed, tested |
| | `ext::` and `fd::` transports, which run commands, are always refused | ✅ Fixed, tested |
| B. Malicious repositories | Before running any command that could trigger them, GitView reads the repository's own settings and hooks, and its submodules' settings. This only reads files. If anything would run a program, it asks first. | ✅ Fixed, tested |
| | Trust is tied to a fingerprint of those settings and hook contents; any change asks again | ✅ Tested |
| | Hostile file names: `;`, `$()`, backticks, quotes, newlines, a leading `-`, NFD Unicode, right-to-left override | ✅ Tested on status, diff, stage and commit |
| | Symlinks are shown as links, never followed; FIFOs are ignored | ✅ Tested |
| | Repositories owned by another user are refused by Git (`safe.directory`); GitView explains why | ✅ Hint added |
| | Clone checks: URL can't start with `-` or be `ext::`/`fd::`; the folder name can't escape the chosen folder; warnings for `http://`, `git://` and passwords in the URL; submodules off by default | ✅ Fixed, tested |
| C. Credentials | GitView stores no credentials. Git's credential helper keeps them (Keychain or Git Credential Manager). | ✅ Pass |
| | `user:token@` in URLs and GitHub, GitLab, Slack and AWS tokens are redacted from output, errors, the output log and command lines | ✅ Fixed, tested |
| | The sign-in prompt is GitView's own signed binary, not a script. It never logs or stores answers. | ✅ Fixed |
| | Unknown SSH hosts need an explicit **Connect**; Return cancels. A changed host key shows a man-in-the-middle warning. | ✅ Fixed |
| | Tools GitView starts (`code`) get a clean environment, without GitView's prompt settings | ✅ Fixed, tested |
| D. Finder extension | Sandboxed, with no network access. Read-only access is limited to the home folder, `/Volumes` and `/Users/Shared`. It never runs Git. | ✅ Narrowed |
| | Reads `.git` and `HEAD` non-blocking, regular files of at most 4 KB, never following symlinks (so a FIFO or huge file can't hang Finder) | ✅ Fixed |
| | The branch name in the menu is stripped of control and bidi characters and limited to 60 characters | ✅ Fixed |
| | Logs with `os.Logger`; paths are private | ✅ Fixed |
| | The only link to the app is a `gitview://` URL; no XPC, sockets or App Group. | ✅ Pass |
| E. Network and URL scheme | `gitview://` links accept only absolute local paths (no `..` or control characters, at most 1,000) and open at most 12 command windows | ✅ Fixed, tested |
| | No command runs without a click, except read-only previews: Pull fetches the branch to show incoming commits, and Push and Pull list server branches | ✅ Pass |
| | `http.sslVerify=false` in a repository's settings triggers the trust prompt | ✅ Fixed, tested |
| | Signed auto-updates | ⏳ None yet (planned for release, e.g. Sparkle with EdDSA) |
| F. Platform hardening | Hardened Runtime enabled for the app and the extension | ✅ Enabled; ⏳ verify on a Developer ID build |
| | No `disable-library-validation`, `allow-dyld-environment-variables` or `allow-jit` entitlements | ✅ Pass |
| | No world-writable files in the bundle; no privileged helpers; no Full Disk Access requested | ✅ Pass |
| | Developer ID signing and notarisation; `codesign --verify --deep --strict` and `spctl -a -vv` | ⏳ Release step |
| G. Code and dependencies | Xcode static analyzer | ✅ No findings |
| | Address and Thread Sanitizers over the full test suite | ✅ No findings |
| | Secret scan with gitleaks (history and working tree) | ✅ No leaks |
| | Third-party dependencies | ✅ None (system Git only) |
| | Semgrep or CodeQL | ⏳ Not run (not installed); recommended in CI |
| H. Rendering | No WebView, HTML or Markdown rendering of repository content | ✅ Pass |
| | Control characters and bidi overrides in file names, branch names, commit messages, diffs and output are shown as visible markers (`␛`, `<U+202E>`) | ✅ Fixed, tested |
| | Output kept per command is capped at 64 MB | ✅ Fixed |
| I. Privacy | No analytics, crash reporting or network use of GitView's own | ✅ Pass |
| | Stored locally: recent repository paths and trusted repository fingerprints (UserDefaults) | ✅ Documented |
| | Privacy manifest (`PrivacyInfo.xcprivacy`) | ⏳ Release step |

## Settings that make GitView ask before opening

These are read from the repository's own (`local`/`worktree`) settings, including included files, and from submodules' settings. The user's global settings are trusted.

- `core.fsmonitor` (unless it's on or off), `core.hooksPath`, `core.sshCommand`, `core.gitProxy`, `core.askPass`, `core.alternateRefsCommand`, `core.worktree`, `core.editor`, `sequence.editor`
- `filter.*.clean|smudge|process`, `diff.external`, `diff.*.command|textconv`, `merge.*.driver`
- `credential.helper`, `credential.*.helper`, `gpg.program`, `gpg.*.program`
- `remote.*.uploadpack|receivepack`, `url.*.insteadOf` pointing at `ext::` or `fd::`, `protocol.allow=always`, `submodule.*.update=!command`
- `http.sslVerify=false`, `http.*.sslVerify=false`
- Executable hooks in the hooks folder

## Accepted risks

- **The main app is not sandboxed.** A Git client has to run `git` on any folder the user picks. The extension is sandboxed and has no network access.
- **Hooks and settings in repositories the user trusted run as usual**, the same as in Terminal, TortoiseGit or VS Code.
- **No timeout on network commands.** A slow server keeps the window busy until Git gives up. The window can be closed.
- **Clone reads the clipboard** to pre-fill a URL that looks like a repository address. The text stays on the Mac.

See [RELEASE.md](RELEASE.md) for the queued release work.

## Before each release

1. `swift test`, including `SecurityTests`, with `--sanitize=address` and `--sanitize=thread`
2. `xcodebuild … analyze`
3. `gitleaks git .` and `gitleaks dir GitView`
4. Build Release, sign with Developer ID (Hardened Runtime), notarise and staple
5. `codesign --verify --deep --strict --verbose=2 GitView.app` and `spctl -a -vv GitView.app`
6. `codesign -d --entitlements - GitView.app` (and for the `.appex`): only the entitlements listed above
7. Keep Git up to date: GitView uses the system or Homebrew Git, and Git regularly fixes issues in clone
