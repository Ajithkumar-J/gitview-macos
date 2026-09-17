# GitView for macOS — MVP Specification

## 1. Overview

### Product Name
**GitView**  
Working name. Can be changed later.

### Purpose

GitView is a lightweight macOS Git utility that provides commonly used Git operations through a simple graphical interface.

The primary goal is to provide a workflow similar to the frequently used parts of **TortoiseGit on Windows**, without attempting to reproduce every TortoiseGit feature.

GitView should allow developers to perform common Git actions without repeatedly entering terminal commands.

---

# 2. Problem Statement

TortoiseGit integrates closely with Windows File Explorer and provides easy access to Git operations through the right-click context menu.

TortoiseGit is not available for macOS.

On macOS, developers typically need to use:

- Terminal Git commands
- VS Code Source Control
- GitHub Desktop
- Sourcetree
- Other third-party Git applications

For developers moving from Windows/TortoiseGit to macOS, frequently used actions such as viewing changes, committing, pulling, pushing, switching branches, and viewing history require a different workflow.

GitView aims to provide a lightweight and familiar alternative.

---

# 3. Goals

The MVP should provide quick access to the most commonly used Git operations.

The main goals are:

1. Detect whether the selected folder is a Git repository.
2. Display the current repository status.
3. Display the current branch.
4. Show modified, added, deleted, untracked, and conflicted files.
5. Allow users to view file differences.
6. Stage and unstage files.
7. Commit changes.
8. Pull changes.
9. Push changes.
10. View Git commit history.
11. View and switch branches.
12. Open the repository in Terminal.
13. Open the repository in VS Code.
14. Provide basic Finder integration.

---

# 4. Non-Goals for MVP

The first version will **not** attempt to reproduce all TortoiseGit functionality.

The following features are excluded from the MVP:

- Interactive rebase
- Advanced merge UI
- Cherry-pick
- Revert commit
- Git bisect
- Git stash management UI
- Git submodule management
- Git worktree management
- Git LFS management
- Credential management
- SSH key management
- Git configuration editor
- Git blame
- Advanced graph visualization
- Pull-request management
- GitHub-specific features
- GitLab-specific features
- Gitea-specific APIs
- Repository cloning UI
- Repository creation
- Remote repository management

These can be considered for later versions.

---

# 5. Target Platform

### Operating System

macOS

Initial supported target:

**macOS 14 Sonoma or later**

Earlier versions may be considered later if required.

### Architecture

Support:

- Apple Silicon
  - M1
  - M2
  - M3
  - M4
  - M5 and later

Intel Mac support is optional and can be evaluated separately.

---

# 6. Technology

### Application

Use:

**Swift + SwiftUI**

### Finder Integration

Use a macOS Finder extension for Finder/context-menu integration.

### Git Operations

GitView will **not implement its own Git engine**.

It will execute the Git installation available on the user's machine.

Example:

```bash
git status
git diff
git add
git commit
git pull
git push
git switch
git log
```

Git command execution should be handled through a dedicated internal service.

Example architecture:

```text
GitView
   │
   ├── SwiftUI
   │
   ├── Finder Extension
   │
   └── Git Service
          │
          └── /usr/bin/git or configured Git executable
```

---

# 7. Application Structure

Suggested solution structure:

```text
GitView
│
├── GitViewApp
│
│   ├── Views
│   ├── ViewModels
│   ├── Models
│   ├── Services
│   └── Utilities
│
├── GitViewFinderExtension
│
├── Shared
│   ├── GitModels
│   ├── GitCommands
│   └── Constants
│
└── Tests
```

---

# 8. Main User Experience

## 8.1 Opening a Repository

The user should be able to open GitView using any of these approaches:

### Option 1 — Finder

Right-click a Git repository folder.

Example:

```text
GitView
   ├── Open GitView
   ├── Git Status
   ├── Pull
   ├── Push
   └── Git Log
```

### Option 2 — GitView Application

Open GitView and select a repository.

### Option 3 — Drag and Drop

Drag a Git repository folder into GitView.

This can be implemented after the basic MVP if necessary.

---

# 9. Repository Dashboard

When a repository is opened, GitView should display:

```text
┌─────────────────────────────────────────────────────┐
│ GitView                                             │
│                                                     │
│ dashboard-designer-web-service                      │
│                                                     │
│ Branch: hotfix/boldbi_v16                           │
│                                                     │
│ Remote: origin                                      │
│                                                     │
│ Changes (4)                                         │
│ ─────────────────────────────────────────────────── │
│ M   DashboardController.cs                          │
│ M   DashboardService.cs                             │
│ A   GitHelper.cs                                    │
│ ?   temp.txt                                        │
│                                                     │
│ [Stage All]                    [Refresh]             │
│                                                     │
│ Commit Message                                      │
│ ┌─────────────────────────────────────────────────┐ │
│ │                                                 │ │
│ └─────────────────────────────────────────────────┘ │
│                                                     │
│ [Commit]        [Pull]        [Push]                │
└─────────────────────────────────────────────────────┘
```

---

# 10. Repository Status

GitView should retrieve status using:

```bash
git status --porcelain
```

Prefer:

```bash
git status --porcelain=v2
```

if additional structured information is required.

Files should be grouped into statuses.

### Supported File States

- Modified
- Added
- Deleted
- Renamed
- Untracked
- Staged
- Conflicted

Example UI:

```text
Changes

Modified
  DashboardController.cs
  DashboardService.cs

Added
  GitHelper.cs

Untracked
  temp.txt
```

---

# 11. File Diff

When the user selects a modified file, GitView should display the changes.

Command:

```bash
git diff -- <file>
```

For staged files:

```bash
git diff --cached -- <file>
```

Example:

```text
DashboardController.cs

- var result = LoadDashboard();
+ var result = await LoadDashboardAsync();
```

The first version only requires a basic unified diff viewer.

Advanced side-by-side diff can be added later.

---

# 12. Stage / Unstage

### Stage File

```bash
git add <file>
```

### Stage All

```bash
git add -A
```

### Unstage File

```bash
git restore --staged <file>
```

The UI should provide:

```text
[Stage]
[Unstage]
[Stage All]
[Unstage All]
```

---

# 13. Commit

The user should be able to enter a commit message.

Command:

```bash
git commit -m "<message>"
```

Validation:

- Commit message must not be empty.
- At least one staged file must exist.

Example:

```text
Commit Message

Fix dashboard loading issue

[Commit]
```

After committing:

- Refresh repository status.
- Show commit success message.
- Display generated commit hash.

Example:

```text
Commit successful

Commit:
899438e

Fix dashboard loading issue
```

---

# 14. Pull

Command:

```bash
git pull
```

Initially use the currently configured upstream branch.

Example UI:

```text
Pull from origin/hotfix/boldbi_v16?

[Cancel] [Pull]
```

Git command output should be visible.

Example:

```text
Updating 18ac312..899438e
Fast-forward
3 files changed
```

---

# 15. Push

Command:

```bash
git push
```

If the branch does not have an upstream branch, GitView should detect it.

Possible command:

```bash
git push --set-upstream origin <branch>
```

GitView should ask the user before setting the upstream automatically.

---

# 16. Branch Management

GitView should display the current branch.

Command:

```bash
git branch --show-current
```

List branches:

```bash
git branch --format="%(refname:short)"
```

Remote branches can be added later or optionally retrieved using:

```bash
git branch -a
```

Example:

```text
Branches

✓ hotfix/boldbi_v16
  development
  feature/mobile-app
  feature/dashboard-performance
```

The user can select another branch.

Command:

```bash
git switch <branch>
```

If local changes prevent switching, display the Git error instead of forcing the operation.

---

# 17. Git History

GitView should provide a simple commit history.

Command example:

```bash
git log --pretty=format:"%H|%h|%an|%ae|%ad|%s" --date=iso
```

Example UI:

```text
Git History

● 899438e
  Fix telemetry request limit
  Ajith
  Today

● 72ab321
  Merge hotfix changes
  Rajendran
  Yesterday

● 381ba92
  Update dashboard designer
  Arun
  Aug 30
```

Initial load:

**Latest 100 commits**

Provide:

```text
Load More
```

for older commits later.

---

# 18. Commit Details

Selecting a commit should display:

```text
899438e

Fix telemetry request limit

Author
Ajith

Date
September 1, 2026

Files Changed
────────────────────
M DashboardController.cs
M DashboardService.cs

[View Changes]
```

Command:

```bash
git show <commit>
```

---

# 19. Finder Context Menu

The Finder integration is one of the main features.

Right-clicking inside or on a Git repository should expose:

```text
GitView
   ├── Open GitView
   ├── Git Status
   ├── Pull
   ├── Push
   └── Git Log
```

For the MVP, some actions may open the main GitView application rather than running entirely inside Finder.

Example:

```text
Right Click
    ↓
GitView
    ↓
Git Status
    ↓
GitView opens repository status page
```

This keeps the Finder extension lightweight.

---

# 20. Finder Badges

This should be treated as a **Phase 2 feature**, rather than mandatory for the first MVP.

Possible badges:

```text
✓ Clean
● Modified
+ Added
! Conflict
```

Example Finder:

```text
dashboard-designer-web-service   ●
boldbi-development               ✓
mobile-app                       ●
```

---

# 21. Open in Terminal

Menu:

```text
Open in Terminal
```

This should open Terminal with the repository as the current working directory.

Example:

```bash
cd /Users/user/Workspace/dashboard-designer-web-service
```

---

# 22. Open in VS Code

Menu:

```text
Open in VS Code
```

Execute:

```bash
code <repository-path>
```

If the `code` command is unavailable, GitView should attempt to open Visual Studio Code using macOS application APIs.

---

# 23. Git Command Execution Service

Create a centralized service.

Example conceptual interface:

```text
GitService

getRepositoryStatus()
getCurrentBranch()
getBranches()
getDiff()
stageFile()
unstageFile()
commit()
pull()
push()
switchBranch()
getHistory()
getCommitDetails()
```

The UI should never directly execute Git commands.

Architecture:

```text
View
   ↓
ViewModel
   ↓
GitService
   ↓
Process Executor
   ↓
git
```

---

# 24. Git Executable Detection

On application startup, detect Git.

Possible command:

```bash
which git
```

Likely paths:

```text
/usr/bin/git
/opt/homebrew/bin/git
/usr/local/bin/git
```

If Git is unavailable:

```text
Git is not installed.

GitView requires Git to perform repository operations.

[Install Instructions]
```

---

# 25. Repository Detection

When a folder is selected:

```bash
git -C "<folder>" rev-parse --show-toplevel
```

If successful:

Open the repository root.

If unsuccessful:

```text
This folder is not part of a Git repository.
```

This also allows GitView to work when the user selects a subfolder inside a repository.

---

# 26. Command Result Model

Every Git command should return a standard result.

Concept:

```text
GitCommandResult

ExitCode
StandardOutput
StandardError
Command
Success
```

This makes error handling consistent throughout the application.

---

# 27. Error Handling

GitView should display the actual Git error whenever possible.

Example:

```text
Unable to switch branch.

Your local changes would be overwritten by checkout:

DashboardService.cs

Commit or stash your changes before switching branches.
```

Do not silently modify files to resolve Git errors.

---

# 28. Authentication

GitView will rely entirely on the user's existing Git authentication.

Examples:

- SSH keys
- Git Credential Manager
- macOS Keychain
- HTTPS credentials
- Gitea credentials

GitView will not store passwords or Git credentials.

Example repositories should work normally:

```text
https://gitea.example.com/team/repository.git
```

or:

```text
git@gitea.example.com:team/repository.git
```

---

# 29. Repository Refresh

Repository status should refresh:

- When the repository is opened
- After commit
- After pull
- After push
- After stage/unstage
- After branch switch
- When the user clicks Refresh

Potential later enhancement:

Automatically watch repository files for changes.

---

# 30. Recent Repositories

GitView should remember recently opened repositories.

Example home screen:

```text
GitView

Recent Repositories

dashboard-designer-web-service
~/Workspace/dashboard-designer-web-service

boldbi-development
~/Workspace/boldbi-development

mobile-app
~/Workspace/mobile/v2

                    [Open Repository]
```

Store only repository paths and basic metadata.

---

# 31. Main Navigation

Suggested layout:

```text
Repository
├── Changes
├── History
└── Branches
```

Toolbar:

```text
Pull | Push | Refresh | Terminal | VS Code
```

This keeps the application intentionally simple.

---

# 32. Proposed MVP UI

```text
┌─────────────────────────────────────────────────────────────┐
│ GitView       dashboard-designer-web-service                │
├─────────────────┬───────────────────────────────────────────┤
│                 │ Branch: hotfix/boldbi_v16                 │
│ Changes      4  │                                           │
│ History         │ Changes                                   │
│ Branches        │                                           │
│                 │ ☑ M DashboardController.cs                │
│                 │ ☑ M DashboardService.cs                   │
│                 │ ☐ ? temp.txt                              │
│                 │                                           │
│                 │ ────────────────────────────────────────  │
│                 │ Commit message                            │
│                 │                                           │
│                 │ Fix dashboard loading issue               │
│                 │                                           │
│                 │                 [Commit]                  │
├─────────────────┴───────────────────────────────────────────┤
│ Pull     Push     Refresh     Terminal     VS Code           │
└─────────────────────────────────────────────────────────────┘
```

---

# 33. MVP Development Phases

## Phase 1 — Git Core

Implement:

- Git executable detection
- Repository detection
- Git command runner
- Repository status
- Current branch
- Basic data models

No advanced UI required initially.

---

## Phase 2 — Main Application

Implement:

- Repository selector
- Recent repositories
- Status screen
- Changed file list
- Stage
- Unstage
- Commit

At this point GitView becomes usable.

---

## Phase 3 — Diff Viewer

Implement:

- File selection
- Unified Git diff
- Staged diff
- Basic syntax rendering

---

## Phase 4 — Remote Operations

Implement:

- Pull
- Push
- Upstream detection
- Git command output
- Error handling

---

## Phase 5 — Branches

Implement:

- Branch list
- Current branch
- Switch branch
- Refresh after switching

---

## Phase 6 — History

Implement:

- Commit history
- Commit details
- Changed files
- Commit diff

---

## Phase 7 — Finder Integration

Implement:

```text
Finder Right Click
     ↓
GitView
     ├── Open
     ├── Status
     ├── Pull
     ├── Push
     └── Log
```

---

# 34. Future Enhancements

After the MVP is stable, possible additions include:

### Version 1.1

- Create branch
- Delete local branch
- Fetch
- Stash
- Pop stash
- Discard file changes
- Commit amend

### Version 1.2

- Side-by-side diff viewer
- Commit graph
- Remote branch support
- Cherry-pick
- Revert commit
- Tags

### Version 1.3

- Finder file status badges
- Finder toolbar integration
- Automatic repository refresh

### Version 2

Potential provider integrations:

- GitHub
- GitLab
- Gitea
- Bitbucket

Features could include:

- Pull requests
- Issues
- Repository browsing
- Review comments

These integrations should remain separate from the core Git functionality.

---

# 35. MVP Acceptance Criteria

GitView MVP can be considered complete when a user can:

1. Open an existing Git repository.
2. See the current branch.
3. See modified/untracked/staged files.
4. Select a file and view its diff.
5. Stage a file.
6. Unstage a file.
7. Stage all changes.
8. Enter a commit message.
9. Commit changes.
10. Pull from the configured upstream.
11. Push to the configured upstream.
12. View local branches.
13. Switch between branches.
14. View recent Git commits.
15. View commit details.
16. Open the repository in Terminal.
17. Open the repository in VS Code.
18. Access GitView from Finder.

---

# 36. Guiding Principle

GitView should remain:

**Simple, fast, native and Git-focused.**

If a feature can already be handled cleanly by Git itself, GitView should expose that operation instead of building unnecessary complexity.

The target experience is:

```text
Finder → Right Click → GitView → Git operation
```

rather than:

```text
Finder → Terminal → cd → remember command → execute Git command
```

The MVP should focus on the everyday Git operations developers repeatedly use.