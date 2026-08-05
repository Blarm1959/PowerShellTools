<#
.SYNOPSIS
    Project Release Creator

.DESCRIPTION
    Thin project wrapper around the generic ProjectCreateRelease.ps1 tool.

    Exactly one change source must be selected:

      -Local
          Release changes already present in this working folder.

      -Zip
          Import the newest <Project>-Changes*.zip Change Package from
          Windows Downloads, then release the imported changes.

      -Dummy
          Create a version-only release from a clean working tree.

.NOTES
    All release creation and Git publication logic resides in the generic tool.
    This file should remain intentionally small.
#>

[CmdletBinding(SupportsShouldProcess = $false)]
param
(
    [switch]$Local,

    [switch]$Zip,

    [switch]$Dummy,

    [switch]$Minor,

    [switch]$Major,

    [string]$Version,

    [switch]$DryRun
)

$ToolPath = Join-Path `
    -Path $PSScriptRoot `
    -ChildPath "..\PowerShellTools\Project\Release\ProjectCreateRelease.ps1"

if (-not (Test-Path -LiteralPath $ToolPath -PathType Leaf))
{
    Write-Host ""
    Write-Host "[FAIL] ProjectCreateRelease.ps1 not found." -ForegroundColor Red
    Write-Host "       Expected:"
    Write-Host "       $ToolPath"
    exit 1
}

& $ToolPath `
    -ProjectFolder $PSScriptRoot `
    -Local:$Local `
    -Zip:$Zip `
    -Dummy:$Dummy `
    -Minor:$Minor `
    -Major:$Major `
    -Version $Version `
    -DryRun:$DryRun

exit $LASTEXITCODE
