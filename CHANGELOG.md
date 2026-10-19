# Changelog

## Unreleased - UTF-8 release text handling
- Explicitly read README, JSON metadata, service-worker text and .gitignore as UTF-8, matching the existing UTF-8 writers. This prevents repeated Windows PowerShell ANSI decoding from corrupting and expanding non-ASCII text.
- Add Project/Release/Tests/Test-Utf8.ps1: isolated tests of the real release functions, including 40 README updates, BOM/no-BOM input, JSON text, service-worker updates and .gitignore entries.
- Existing damaged README contents still need replacing; this change prevents further encoding damage.


## v0.1.0
- Initial repository structure.

