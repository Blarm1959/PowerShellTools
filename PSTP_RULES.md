# PSTP Project Rules

These rules apply to all projects managed using PowerShellTools / PSTP.

## Change Packages

Change packages created during ChatGPT development work must be named:

`<Project>-Changes-gN.zip`

Examples:

`EnergyWatch-Changes-g1.zip`
`EnergyWatch-Changes-g2.zip`
`Quarto-Changes-g3.zip`

`gN` is the sequential generation number for change packages. It is separate from the project's release version.

## Package Contents

A change package should contain only files that have actually been changed for that development step.

Do not normally include files managed by the PSTP release system, including:

- `release.json`
- `build-info.json`
- `package-lock.json`
- release-history changes in `README.md`

Include one of these only when the development change specifically requires that file to be changed.

## Version Numbers

ChatGPT-created change packages must not increment or alter the project release version.

Versioning is owned by PSTP / ProjectRelease and is performed locally after the change package has been reviewed and applied.

## Project Locations

Projects may be stored on different drives on different computers.

For example, a project may be under:

`C:\bxd\...`

or:

`D:\bxd\...`

Project scripts must not assume a fixed drive letter.

Where possible, a project script should determine its own Git repository root dynamically.

## Trace, Debug and Run Output

PSTP itself does not move project trace, debug, diagnostic, test, simulation, or other temporary run-output files.

This is the responsibility of each individual project's own run workflow.

Before starting a new project run or generation, that project should move its known output files from the previous run into:

`<ProjectRoot>\Old`

Only files explicitly known by that project to be temporary/run output should be moved.

Do not move files merely because their filenames contain words such as:

- `trace`
- `debug`
- `diagnostic`
- `log`

Those names may also belong to genuine project source files.

Historical files placed in `Old` should be retained unless specifically requested otherwise.

If a filename already exists in `Old`, preserve the existing historical file rather than silently overwriting it.

## Project Run Scripts

Project run scripts should determine the repository root dynamically rather than hard-coding paths such as `C:\bxd` or `D:\bxd`.

The normal PowerShell approach is:

`git rev-parse --show-toplevel`

Each project should maintain its own explicit list of files or folders that are outputs from a run and should be archived to `Old` before the next run.

## Source of Truth

These rules are the permanent development conventions for projects using PowerShellTools.

If instructions in a ChatGPT conversation conflict with this file, follow this file unless the user explicitly changes the rule.
