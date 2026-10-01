# PowerShellTools

Reusable PowerShell development tools.

## Structure

- Core - Shared framework
- UpdateProject - Project update tool
- LanguageProject - Localisation management tool

Each tool should depend on Core and remain independent of the other tools.

## Update all repos

Run `.\UpdateRepos.ps1` from this folder on either laptop. It fetches every repo next to PowerShellTools, fast-forwards every repo that is behind and has no local changes, clones every missing GitHub repo (including `-App` repos), then reports anything still ahead, diverged, uncommitted or stashed. Missing private repos are only found when `gh` is installed and logged in.

- `-L` - list only: report status and missing repos without pulling or cloning.
- `-NoFetch` - with `-L`, skip the fetch.
- `-Exclude` - folder name patterns to skip (default `* - Copy`).
