# PowerShellTools

Reusable PowerShell development tools.

## Structure

- Core - Shared framework
- UpdateProject - Project update tool
- LanguageProject - Localisation management tool

Each tool should depend on Core and remain independent of the other tools.

## Check all repos

Run `.\CheckRepos.ps1` from this folder on either laptop. It fetches every repo next to PowerShellTools and reports anything behind, ahead, diverged, uncommitted or stashed, then lists GitHub repos not cloned on this laptop (private ones too when `gh` is installed). Use `-NoFetch` to skip the fetch.
