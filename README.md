# GitView for macOS

GitView is a local SwiftUI macOS Git client for inspecting and working with repositories on the Mac. The current MVP focuses on local/internal development use, not Mac App Store distribution.

## Current Features

- **Open repositories** from the Open panel (⌘O), the Recent list, drag and drop, or Finder. Selecting a subfolder or a file opens its repository root.
- **Changes** — files grouped into Merge Conflicts, Staged Changes, Changes and Untracked Files. Stage, unstage, Stage All, Unstage All, and discard (with confirmation). Press Space to stage or unstage the selected file.
- **Diff viewer** — unified diff with old/new line numbers, staged and unstaged diffs, binary detection, and ⌘F find.
- **Commit** staged changes (⌘↩). The commit hash and subject appear in the status bar.
- **Fetch, Pull, Push** — pull shows a preview first (incoming commits and files, possible conflicts, merge/rebase/fast-forward). Push asks before publishing a branch with no upstream. Git output is kept in the Output log (⇧⌘L).
- **History** — latest 100 commits with paging, filter, branch/tag chips, and commit details with changed files and per-file diffs.
- **Branches** — local and remote branches with ahead/behind, filtering, searching the remote for unfetched branches, and switching (double-click). Git errors are shown as-is; nothing is forced or stashed.
- **Open in Terminal** (⌥⌘T), **Open in VS Code** (⌥⌘V; `code` CLI first, then the app), **Reveal in Finder**.
- Refreshes automatically when GitView becomes active.
- Finder context-menu and toolbar submenu: Open GitView, Git Status, Pull, Push, Git Log.

## Requirements

- macOS with Xcode installed.
- Git installed on the Mac.
- Swift toolchain available through Xcode.

GitView resolves Git in this order:

1. `/opt/homebrew/bin/git`
2. `/usr/local/bin/git`
3. `/usr/bin/git`
4. Git found from the process environment

## Build and Run

Open the project in Xcode:

```sh
open GitView.xcodeproj
```

Choose the `GitView` scheme, then build and run.

From Terminal:

```sh
xcodebuild -project GitView.xcodeproj -scheme GitView -configuration Debug build
swift test
```

## Project Layout

```text
GitView
|-- GitViewApp
|   |-- Views
|   |-- ViewModels
|   |-- Models
|   |-- Services
|   `-- Utilities
|-- Shared
|   |-- GitModels
|   |-- GitCommands
|   `-- Constants
|-- GitViewFinderExtension
`-- Tests
```

SwiftUI views should not execute shell commands directly. Git commands should go through the shared Git service and process execution layer.

- `Shared/GitCommands` — `GitService` (all Git operations), `ProcessExecutor`, and parsers for status (porcelain v2 `-z`), log, branches and diffs.
- `GitViewApp/ViewModels/RepositoryViewModel.swift` — per-window state; Git operations run one at a time through an operation queue.
- `GitViewApp/Services` — recent repositories and external apps (Terminal, VS Code, Finder).
- `swift test` covers the parsers and a full workflow against a temporary repository.

The Xcode project lists source files explicitly. When adding a file, also add it to `GitView.xcodeproj` (Xcode: File → Add Files…).

## Finder Integration

GitView includes two Finder entry points:

- A Finder Sync extension with bundle identifier `com.local.GitView.FinderExtension`.
- A macOS Services fallback named `Open in GitView`.

Both open the app with a deep link like:

```text
gitview://open?path=/path/to/repository&action=status
```

`action` is one of `open` (default), `status`, `pull`, `push`, `log`. Links go to the existing window instead of opening a new one.

### Why Installation Matters

Finder will not reliably show the extension just because the source exists or because the app was built once in Xcode. macOS must discover the `.appex` inside an installed `.app` bundle, the extension must be enabled, and Finder often needs to be restarted.

For local testing, install the built app into `~/Applications/GitView.app`.

### Install the Built App Locally

Build the app with a deterministic derived data path:

```sh
xcodebuild \
  -project GitView.xcodeproj \
  -scheme GitView \
  -configuration Debug \
  -derivedDataPath .build/XcodeDerivedData \
  build
```

Copy the built app into `~/Applications`:

```sh
mkdir -p "$HOME/Applications"
rm -rf "$HOME/Applications/GitView.app"
ditto ".build/XcodeDerivedData/Build/Products/Debug/GitView.app" "$HOME/Applications/GitView.app"
```

Launch the installed app once:

```sh
open "$HOME/Applications/GitView.app"
```

### Register the Finder Extension

Register the embedded extension:

```sh
APP="$HOME/Applications/GitView.app"
EXT="$APP/Contents/PlugIns/GitViewFinderExtension.appex"

pluginkit -r "$EXT" 2>/dev/null || true
pluginkit -a "$EXT"
pluginkit -e use -i com.local.GitView.FinderExtension
```

Register the app services:

```sh
/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister \
  -f "$HOME/Applications/GitView.app"
```

Restart Finder:

```sh
killall Finder
open -a Finder
```

### Enable in System Settings

Open:

```text
System Settings -> Login Items & Extensions -> Extensions
```

Then check both places:

1. `By App -> GitView`
2. `By Category -> Finder`

Enable the GitView extension if it appears disabled.

Depending on the macOS version, Finder Sync extensions can appear under different labels in System Settings. If GitView appears under `By App`, enable the listed extension there.

### Verify Finder Can See the Extension

Run:

```sh
pluginkit -m -A -D -v -p com.apple.FinderSync | rg "GitView|com.local.GitView.FinderExtension"
```

Expected result should include:

```text
com.local.GitView.FinderExtension
```

Also verify the installed app has the Services entry:

```sh
plutil -p "$HOME/Applications/GitView.app/Contents/Info.plist" | rg "NSServices|Open in GitView|openInGitViewService"
```

### Use from Finder

1. Open Finder.
2. Select a repository folder.
3. Right-click the folder.
4. Look for the `GitView` submenu (Finder Sync extension) or `Open in GitView` (Services).

Depending on macOS, the item can appear in one of these places:

- Directly in the right-click menu.
- Under `Quick Actions`.
- Under `Services`.

If the menu item still does not show, launch `~/Applications/GitView.app` once, run the registration commands again, then restart Finder.

### Full Reset for Finder Integration

Use this when the extension was previously registered but Finder still does not show it:

```sh
APP="$HOME/Applications/GitView.app"
EXT="$APP/Contents/PlugIns/GitViewFinderExtension.appex"

pluginkit -e ignore -i com.local.GitView.FinderExtension 2>/dev/null || true
pluginkit -r "$EXT" 2>/dev/null || true
pluginkit -a "$EXT"
pluginkit -e use -i com.local.GitView.FinderExtension

/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister -f "$APP"
killall Finder
open "$APP"
open -a Finder
```

Then re-check System Settings and the Finder right-click menu.

## Notes

- GitView ignores working-tree executable-permission changes for all repositories using a per-command `core.filemode=false` override. Content edits remain visible, and repository/global Git configuration is unchanged. Explicitly staged permission changes remain visible.
- The initial MVP intentionally avoids App Sandbox for the main app.
- Finder integration is local-development oriented for now.
- Public distribution, Developer ID signing, notarization, and sandboxing can be added after the core app is stable.
