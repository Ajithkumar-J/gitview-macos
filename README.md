# GitView for macOS

GitView is a local SwiftUI macOS Git client for inspecting and working with repositories on the Mac. The current MVP focuses on local/internal development use, not Mac App Store distribution.

## Current Features

- **Open repositories** from the Open panel (⌘O), the Recent list, drag and drop, or Finder. Selecting a subfolder or a file opens its repository root.
- **Changes** — files grouped into Merge Conflicts, Staged Changes, Changes and Untracked Files. Stage, unstage, Stage All, Unstage All, and discard (with confirmation). Press Space to stage or unstage the selected file.
- **Diff viewer** — unified diff with old/new line numbers, staged and unstaged diffs, binary detection, and ⌘F find.
- **Commit** staged changes (⌘↩). The commit hash and subject appear in the status bar.
- **Fetch, Pull, Push** — pull shows a preview first (incoming commits and files, possible conflicts, merge/rebase/fast-forward). Push asks before publishing a branch with no upstream. Git output is kept in the Output log (⇧⌘L).
- **History** — latest 100 commits with paging, filter, branch/tag chips, and commit details with changed files and per-file diffs.
- **Branches** — local and remote branches with ahead/behind and switching (double-click). Typing in the filter searches local, fetched and server branches at once: every word must appear somewhere in the name, ignoring case (`release 13` finds `Fetch-from-release-tag13`). Spaces, `_`, `-`, `/` and `.` all separate words (`v17_2` finds `release/boldbi_v17.2`), and names containing exactly what you typed are listed first. Branches not fetched yet are listed under *Not Fetched* and are fetched when you switch to them. In repositories that fetch only some branches (`remote.origin.fetch` lists single branches), switching to another branch adds it to that list first, like `git remote set-branches --add`, so it can track its remote branch. The server's branch list is cached for a few minutes; the 🌐 button (or Enter) refreshes it. The Finder Switch dialog and the Pull/Push branch suggestions work the same way. Git errors are shown as-is; nothing is forced or stashed.
- **Open in Terminal** (⌥⌘T), **Open in VS Code** (⌥⌘V; `code` CLI first, then the app), **Reveal in Finder**.
- Refreshes automatically when GitView becomes active.
- **TortoiseGit-style Finder menu**: right-click any file or folder for Git commands; each command opens its own small window (see Finder Integration).
- **Sign-in and setup prompts**: GitView asks for your user name and token (or SSH passphrase) the first time a server needs them, asks whether to trust a new SSH server, and asks for your name and email before your first commit. Failures come with a plain-language explanation next to Git's output.

## Getting Started

### 1. Install Git

GitView uses the Git installed on your Mac. Check in Terminal:

```sh
git --version
```

If macOS offers to install the Command Line Tools, accept. You can also run `xcode-select --install`, or `brew install git` if you use Homebrew.

### 2. Install GitView

1. Move `GitView.app` to **Applications** (or `~/Applications`).
2. Open it once. This registers the Finder menu.
3. If macOS says the app can't be opened, go to **System Settings ▸ Privacy & Security**, scroll down and click **Open Anyway**. You only need to do this once.

> Until signed release builds are available, build the app yourself (see [Building from Source](#building-from-source)).

### 3. Turn on the Finder menu

1. Open **System Settings ▸ General ▸ Login Items & Extensions**.
2. Under **Extensions**, open **By App ▸ GitView** (or **By Category ▸ Finder**) and turn GitView on.
3. Right-click any folder in Finder. You should see **Git Clone…** and **Git Create Repository Here…**, or, inside a repository, **Git Commit → “branch”…** and a **GitView** submenu.

If the menu doesn't appear, restart Finder: hold ⌥ (Option), right-click the Finder icon in the Dock, and choose **Relaunch**.

### 4. Tell Git who you are (once)

Every commit records a name and email. The first time you commit, GitView shows a **Tell Git who you are** box in the commit window. Enter your name and the email of your GitHub, GitLab or Azure DevOps account, then click **Save**. GitView saves them for all repositories, the same as:

```sh
git config --global user.name "Your Name"
git config --global user.email you@example.com
```

GitView won't commit until these are set. Otherwise Git would quietly use an address like `you@Your-Mac.local`, and the server can't link those commits to your account.

### 5. Sign in to your Git server (once)

You don't sign in to GitView itself. Git signs in to each server the first time a command needs it (Clone, Fetch, Pull or Push), and GitView shows the prompt.

**HTTPS remotes** (`https://…`)

1. GitView asks for your **user name**, then your **password**.
2. In the password field, paste a **personal access token**, not your account password. GitHub, GitLab, Azure DevOps and Bitbucket all reject account passwords for Git.
   - **GitHub:** Settings ▸ Developer settings ▸ Personal access tokens. A classic token needs the `repo` scope; a fine-grained token needs *Contents: Read and write*.
   - **GitLab:** Preferences ▸ Access tokens, with `read_repository` and `write_repository`.
   - **Azure DevOps:** User settings ▸ Personal access tokens, with *Code: Read & write*.
   - **Bitbucket:** Personal settings ▸ App passwords, with *Repositories: Read and Write*.
3. Git saves the token in your **Keychain**, so you won't be asked again. If the server later rejects it (it expired or was revoked), Git removes it and GitView asks again.

If you already use the GitHub CLI (`gh auth login`, then `gh auth setup-git`) or Git Credential Manager, GitView uses those and won't prompt at all.

**SSH remotes** (`git@…`)

1. Create a key and add the public key to your account's SSH settings:

   ```sh
   ssh-keygen -t ed25519 -C "you@example.com"
   pbcopy < ~/.ssh/id_ed25519.pub   # copies the public key to paste on the website
   ```

2. The first time you connect to a server, GitView asks **Trust This Server?** and shows its fingerprint. Choose **Connect**.
3. If your key has a passphrase, GitView asks for it. To skip this, add the key to your Keychain once with `ssh-add --apple-use-keychain ~/.ssh/id_ed25519`.

## Everyday Use

Right-click in Finder, the same way you would with TortoiseGit on Windows:

| To… | Right-click on | Choose |
|---|---|---|
| Get a repository | An empty folder | **Git Clone…** (a URL you copied is filled in for you) |
| Start a new repository | A project folder | **Git Create Repository Here…** |
| See what changed | The repository, a folder or a file | **GitView ▸ Check for Modifications** (or **Diff** on a single file) |
| Commit | The repository, or only the files/folders to include | **Git Commit → “branch”…**, tick the files, write a message, then **Commit** (⌘↩) or **Commit & Push** |
| Get others' changes | The repository | **GitView ▸ Pull…** (shows incoming commits before anything changes) or **Fetch…** |
| Share your commits | The repository | **GitView ▸ Push…** (lists outgoing commits and offers to publish a new branch) |
| Change branch | The repository | **GitView ▸ Switch/Checkout…** |
| Start a branch | The repository | **GitView ▸ Create Branch…** |
| Put work aside | The repository | **GitView ▸ Stash Changes…**, later **Stash List / Pop…** |
| See history | The repository, a folder or a file | **GitView ▸ Show Log** (a file shows only its own history) |
| Undo local edits | Files or folders | **GitView ▸ Revert…** (asks first) |
| Track new files | Files or folders | **GitView ▸ Add…** |
| Use the full app | Anything in the repository | **GitView ▸ Open in GitView** |

Each command opens its own small window and shows Git's output when it finishes. When something fails, a 💡 note above the output says what to do. If GitView was opened only for that command, it quits when you close the window.

The **main window** (Open in GitView, or open the app and press ⌘O) shows changes, staging, the diff, commit, history and branches together. ⇧⌘L shows the output of every Git command it ran.

## Troubleshooting

| Problem | Fix |
|---|---|
| No GitView items in Finder's right-click menu | Open GitView once, turn it on in System Settings ▸ Login Items & Extensions, then relaunch Finder (⌥-right-click the Dock icon ▸ Relaunch). Developers: see [Full Reset](#full-reset-for-finder-integration). |
| "Sign-in was cancelled or the server rejected it" | Run the command again and enter a **token** as the password. To replace a saved token, open **Keychain Access**, search for the server (for example `github.com`), delete the entry, then try again. |
| "The server did not accept your SSH key" | Add `~/.ssh/id_ed25519.pub` to your account, or use the HTTPS URL with a token. |
| "Enter your name and email first" in the commit window | Fill in the **Tell Git who you are** box (see step 4 above). |
| Fetch fails with `couldn't find remote ref refs/heads/<branch>` | The repository is set to fetch a branch that was deleted on the server. Remove that entry: `git config --unset remote.origin.fetch 'refs/heads/<branch>:'`. Pull still works meanwhile, because GitView pulls the named branch directly. |
| GitView shows a blank icon in the Dock or Spotlight | macOS is showing a cached icon. Run `touch ~/Applications/GitView.app` (or wherever GitView is installed), then `killall Dock`. |
| "GitView could not reach the server" | Check your network or VPN; company Git servers often need the VPN. |

## Building from Source

### Requirements

- macOS with Xcode installed.
- Git installed on the Mac.
- Swift toolchain available through Xcode.

GitView resolves Git in this order:

1. `/opt/homebrew/bin/git`
2. `/usr/local/bin/git`
3. `/usr/bin/git`
4. Git found from the process environment

### Build and Run

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
- `GitViewApp/Commands` — the per-command windows opened from Finder (`CommandSession` + one dialog per command); Git operations for them are in `Shared/GitCommands/GitService+Commands.swift`.
- `swift test` covers the parsers and a full workflow against a temporary repository.
- Sign-in prompts: Git and SSH run with `GIT_TERMINAL_PROMPT=0` and with `GIT_ASKPASS` / `SSH_ASKPASS` set to a small script that GitView writes to `~/Library/Application Support/GitView/git-askpass.sh` (source in `ProcessExecutor.swift`). The script runs `GitView --askpass "<question>"`, which shows a native dialog with no Dock icon (see `AskPassPrompt` in `AppDelegate.swift`) and prints the answer. Outside the app bundle, for example in tests, it falls back to an `osascript` dialog. Saved credentials come from Git's own credential helper (Keychain by default). A `GIT_ASKPASS` that is already set, for example by an IDE, is left alone.

The app icon lives in `GitView/GitViewApp/Assets.xcassets/AppIcon.appiconset` and is drawn by `swift scripts/generate-app-icon.swift`; edit the script and rerun it to change the icon.

The Xcode project lists source files explicitly. When adding a file, also add it to `GitView.xcodeproj` (Xcode: File → Add Files…).

## Finder Integration

GitView includes two Finder entry points:

- A Finder Sync extension with bundle identifier `com.local.GitView.FinderExtension`.
- A macOS Services fallback named `Open in GitView`.

The context menu works like TortoiseGit and adapts to what you right-click:

| Right-click on | Menu |
|---|---|
| A folder that is not in a repository | **Git Clone…**, **Git Create Repository Here…** |
| Anything inside a repository | **Git Commit → “branch”…** and a **GitView** submenu: Diff (files only), Show Log, Check for Modifications, Pull…, Fetch…, Push…, Switch/Checkout…, Create Branch…, Stash Changes…, Stash List / Pop…, Add…, Revert…, Open in GitView |

Every command except Open in GitView opens its own window, scoped to the selected files or folders (for example, Commit on `Sources/` lists only changes under `Sources/`, and Show Log on a file shows that file's history). The window shows Git's output when the command finishes and offers the natural next step (Push… after a commit, Pull… after switching branch, Open after a clone). When GitView was launched only for a Finder command, it quits when that window closes.

The extension never runs Git. It reads `.git` (read-only sandbox exception) to decide which menu to show and opens the app with a deep link:

```text
gitview://open?path=/path/one&path=/path/two&action=commit
```

`action` is one of `open` (default), `commit`, `status`, `diff`, `log`, `add`, `revert`, `pull`, `fetch`, `push`, `switch`, `branch`, `stash`, `stash-pop`, `clone`, `init`. `open` goes to a main window (opening one if none is visible); everything else opens a command window. GitView brings itself to the front for every link.

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
# ditto keeps the build folder's old date; macOS caches app icons by path and
# date, so without this Spotlight, the Dock and Finder can keep a blank icon.
touch "$HOME/Applications/GitView.app"
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
