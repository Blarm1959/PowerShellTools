<#
.SYNOPSIS
    Blarm Generic Project Release Creator

.DESCRIPTION
    Generic release creation tool used by all Blarm projects.

    The project folder is supplied by the project's local
    CreateRelease.ps1 wrapper.

    Current implementation:
      - Validate the supplied project folder
      - Validate required project files
      - Load and validate release.json
      - Read the project name and current version
      - Display a project summary

    Future versions will:
      - Calculate the target version
      - Synchronise project metadata
      - Update README release history
      - Create a release ZIP
      - Support dry-run and additional validation
#>

[CmdletBinding()]
param
(
    [Parameter(Mandatory = $true)]
    [ValidateNotNullOrEmpty()]
    [string]$ProjectFolder,

    [switch]$Minor,

    [switch]$Major,

    [string]$Version,

    [switch]$NoZip,

    [switch]$ZipOnly,

    [string]$Output,

    [switch]$DryRun,

    [switch]$Force
)

#region Configuration

$ScriptVersion = "1.0.0"

$ProjectContext = [PSCustomObject]@{
    ProjectFolder  = $ProjectFolder
    ProjectName    = $null
    Release        = $null
    CurrentVersion = $null
    TargetVersion  = $null
    OutputFolder   = $Output
    ZipFilename    = $null
    DryRun         = [bool]$DryRun
    Force          = [bool]$Force
}

#endregion Configuration

#region Console Helpers

function Write-Progress
{
    [CmdletBinding()]
    param
    (
        [Parameter(Mandatory = $true)]
        [ValidateNotNullOrEmpty()]
        [string]$Message
    )

    Write-Host "[....] $Message"
}

function Write-Success
{
    [CmdletBinding()]
    param
    (
        [Parameter(Mandatory = $true)]
        [ValidateNotNullOrEmpty()]
        [string]$Message
    )

    Write-Host "[ OK ] $Message"
}

function Stop-ProjectRelease
{
    [CmdletBinding()]
    param
    (
        [Parameter(Mandatory = $true)]
        [ValidateNotNullOrEmpty()]
        [string]$Message
    )

    Write-Host "[FAIL] $Message" -ForegroundColor Red
    exit 1
}

#endregion Console Helpers

#region Banner

function Show-Banner
{
    [CmdletBinding()]
    param()

    Write-Host ""
    Write-Host "========================================================="
    Write-Host " Blarm Generic Project Release Creator"
    Write-Host " Version $ScriptVersion"
    Write-Host "========================================================="
    Write-Host ""
}

#endregion Banner

#region Project Initialisation

function Initialize-Project
{
    [CmdletBinding()]
    param
    (
        [Parameter(Mandatory = $true)]
        [PSCustomObject]$ProjectContext
    )

    if (-not (Test-Path -LiteralPath $ProjectContext.ProjectFolder))
    {
        Stop-ProjectRelease `
            "Project folder does not exist: $($ProjectContext.ProjectFolder)"
    }

    $ProjectItem = Get-Item `
        -LiteralPath $ProjectContext.ProjectFolder `
        -ErrorAction SilentlyContinue

    if ($null -eq $ProjectItem -or -not $ProjectItem.PSIsContainer)
    {
        Stop-ProjectRelease `
            "Project path is not a folder: $($ProjectContext.ProjectFolder)"
    }

    try
    {
        $ProjectContext.ProjectFolder =
            (Resolve-Path `
                -LiteralPath $ProjectContext.ProjectFolder `
                -ErrorAction Stop).Path
    }
    catch
    {
        Stop-ProjectRelease `
            "Unable to resolve project folder: $($ProjectContext.ProjectFolder)"
    }

    Write-Success "Project folder: $($ProjectContext.ProjectFolder)"
}

#endregion Project Initialisation

#region Project Validation

function Test-ProjectFiles
{
    [CmdletBinding()]
    param
    (
        [Parameter(Mandatory = $true)]
        [PSCustomObject]$ProjectContext
    )

    Write-Progress "Validating required project files"

    $RequiredFiles = @(
        "release.json"
        "package.json"
        "build-info.json"
        "README.md"
    )

    foreach ($FileName in $RequiredFiles)
    {
        $FilePath = Join-Path `
            -Path $ProjectContext.ProjectFolder `
            -ChildPath $FileName

        if (-not (Test-Path -LiteralPath $FilePath -PathType Leaf))
        {
            Stop-ProjectRelease "Missing required file: $FileName"
        }

        Write-Success "Found: $FileName"
    }
}

#endregion Project Validation

#region Release Information

function Get-ReleaseInfo
{
    [CmdletBinding()]
    param
    (
        [Parameter(Mandatory = $true)]
        [PSCustomObject]$ProjectContext
    )

    Write-Progress "Loading release.json"

    $ReleasePath = Join-Path `
        -Path $ProjectContext.ProjectFolder `
        -ChildPath "release.json"

    try
    {
        $ReleaseContent = Get-Content `
            -LiteralPath $ReleasePath `
            -Raw `
            -ErrorAction Stop

        $ProjectContext.Release =
            $ReleaseContent | ConvertFrom-Json -ErrorAction Stop
    }
    catch
    {
        Stop-ProjectRelease `
            "release.json contains invalid JSON or could not be read."
    }

    if ($null -eq $ProjectContext.Release)
    {
        Stop-ProjectRelease "release.json did not contain a JSON object."
    }

    if ($null -eq $ProjectContext.Release.project)
    {
        Stop-ProjectRelease `
            "release.json is missing the project section."
    }

    if ($null -eq $ProjectContext.Release.release)
    {
        Stop-ProjectRelease `
            "release.json is missing the release section."
    }

    $ProjectContext.ProjectName =
        [string]$ProjectContext.Release.project.name

    $ProjectContext.CurrentVersion =
        [string]$ProjectContext.Release.release.version

    if ([string]::IsNullOrWhiteSpace($ProjectContext.ProjectName))
    {
        Stop-ProjectRelease `
            "Project name was not found in release.json."
    }

    if ([string]::IsNullOrWhiteSpace($ProjectContext.CurrentVersion))
    {
        Stop-ProjectRelease `
            "Current version was not found in release.json."
    }

    $ParsedVersion = $null

    if (-not [System.Version]::TryParse(
        $ProjectContext.CurrentVersion,
        [ref]$ParsedVersion
    ))
    {
        Stop-ProjectRelease `
            "Current version is invalid: $($ProjectContext.CurrentVersion)"
    }

    Write-Success "release.json loaded"
}

#endregion Release Information

#region Summary

function Write-ProjectSummary
{
    [CmdletBinding()]
    param
    (
        [Parameter(Mandatory = $true)]
        [PSCustomObject]$ProjectContext
    )

    Write-Host ""
    Write-Host "Project : $($ProjectContext.ProjectName)"
    Write-Host "Version : $($ProjectContext.CurrentVersion)"
    Write-Host ""
}

#endregion Summary

#region Main

Show-Banner

Initialize-Project `
    -ProjectContext $ProjectContext

Test-ProjectFiles `
    -ProjectContext $ProjectContext

Get-ReleaseInfo `
    -ProjectContext $ProjectContext

Write-ProjectSummary `
    -ProjectContext $ProjectContext

Write-Success "Initial validation completed successfully."

#endregion Main