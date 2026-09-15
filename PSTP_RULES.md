\# PSTP Project Rules



These rules apply to all projects managed using PowerShellTools / PSTP.



\## Change Packages



Change packages created during ChatGPT development work must be named:



`<Project>-Changes-gN.zip`



Examples:



`EnergyWatch-Changes-g1.zip`

`EnergyWatch-Changes-g2.zip`

`Quarto-Changes-g3.zip`



`gN` is the sequential generation number for change packages. It is separate from the project's release version.



\## Package Contents



A change package should contain only files that have actually been changed for that development step.



Do not normally include files managed by the PSTP release system, including:



\* `release.json`

\* `build-info.json`

\* `package-lock.json`

\* release-history changes in `README.md`



Include one of these only when the development change specifically requires that file to be changed.



\## Version Numbers



ChatGPT-created change packages must not increment or alter the project release version.



Versioning is owned by PSTP / ProjectRelease and is performed locally after the change package has been reviewed and applied.



\## Trace and Debug Files



Before starting or packaging a new development generation, trace, debug, diagnostic, and similar temporary output files from the previous generation should be moved into the project's:



`Old`



folder.



This keeps the current project folder clear so that new trace files can easily be identified.



Do not delete historical trace files unless specifically requested.



\## Source of Truth



These rules are the permanent development conventions for projects using PowerShellTools.



If instructions in a ChatGPT conversation conflict with this file, follow this file unless the user explicitly changes the rule.



