# Release Backlog

Work still needed before GitView can be shared outside this Mac. Items marked 🔒 are the open security items from [SECURITY.md](SECURITY.md).

## Identity and signing

- [ ] Replace the placeholder bundle IDs (`com.local.GitView`, `com.local.GitView.FinderExtension`) with real ones, and set `DEVELOPMENT_TEAM`.
- [ ] 🔒 Get a Developer ID Application certificate (personal Apple Developer account or the company's).
- [ ] 🔒 Build the **Release** configuration and sign the app and extension with Developer ID. Hardened Runtime is already enabled in the project.
- [ ] 🔒 Launch the signed build and check: main window, Finder menu, each command window, and the sign-in prompt (`GITVIEW_ASKPASS=1`). Ad-hoc signing can't test Hardened Runtime on Debug builds; see the note in SECURITY.md.
- [ ] 🔒 Notarise with `xcrun notarytool` and staple the ticket.
- [ ] 🔒 Verify with `codesign --verify --deep --strict --verbose=2`, `spctl -a -vv` and `codesign -d --entitlements -` (the app and the `.appex`).

## Packaging and distribution

- [ ] Add `scripts/package.sh`. It should:
  - build Release
  - sign, notarise and staple
  - create a DMG (with the app and an Applications shortcut)
  - `touch` the app so macOS doesn't show a cached icon
- [ ] Set version and build numbers, and write release notes.
- [ ] Decide how people get it: a shared drive or Teams, GitHub Releases, or a Homebrew cask.
- [ ] Write install instructions for recipients: README "Getting Started" covers most of it; link the DMG.

## Updates and privacy

- [ ] 🔒 Auto-updates: Sparkle with EdDSA-signed updates served over HTTPS, or document manual updates.
- [ ] 🔒 Add a privacy manifest (`PrivacyInfo.xcprivacy`) declaring UserDefaults use (reason `CA92.1`).

## CI and scanning

- [ ] 🔒 Add Semgrep or CodeQL (Swift) to CI.
- [ ] Run in CI on every push:
  - `swift test` (including `SecurityTests`) with the Address and Thread sanitizers
  - `xcodebuild analyze`
  - `gitleaks`

## Features still open (not blocking release)

- [ ] Finder status badges (✓ ● + !), like TortoiseGit's overlays
- [ ] Delete branch; merge, rebase, tag, cherry-pick and revert commit
- [ ] Automatic refresh while the window is open (file watching)
- [ ] Side-by-side diff and a commit graph
- [ ] A timeout or cancel button for long network commands
