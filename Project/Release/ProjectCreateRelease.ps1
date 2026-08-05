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
      - Load and validate project metadata
      - Determine the target version
      - Synchronise release.json, package.json and build-info.json
      - Update README current release and release history
      - Write deterministic UTF-8 files without BOM
      - Restore original files if an update fails
      - Display a project summary

    ZIP creation will be added in the next phase.
#>

# Version History
# 1.2.1 - JSON formatting polish, README spacing, newline consistency.
# 1.2.0 - Metadata synchronisation, README history, deterministic updates.

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

$ScriptVersion = "1.2.1"
$MaximumHistoryEntries = 25

$ProjectContext = [PSCustomObject]@{
    ProjectFolder  = $ProjectFolder
    ProjectName    = $null
    Release        = $null
    Package        = $null
    BuildInfo      = $null
    CurrentVersion = $null
    TargetVersion  = $null
    TargetTag      = $null
    ReleaseType    = $null
    OutputFolder   = $Output
    ZipFilename    = $null
    DryRun         = [bool]$DryRun
    Force          = [bool]$Force
    NoZip          = [bool]$NoZip
    ZipOnly        = [bool]$ZipOnly
}

$ProjectFileOrder = @(
    "release.json"
    "package.json"
    "build-info.json"
    "README.md"
)

#endregion Configuration

#region Console

function Write-Status
{
    [CmdletBinding()]
    param
    (
        [Parameter(Mandatory = $true)]
        [ValidateSet("Progress", "Success", "Warning", "Failure")]
        [string]$Status,

        [Parameter(Mandatory = $true)]
        [ValidateNotNullOrEmpty()]
        [string]$Message
    )

    switch ($Status)
    {
        "Progress"
        {
            Write-Host "[....] $Message"
        }

        "Success"
        {
            Write-Host "[ OK ] $Message"
        }

        "Warning"
        {
            Write-Host "[WARN] $Message" -ForegroundColor Yellow
        }

        "Failure"
        {
            Write-Host "[FAIL] $Message" -ForegroundColor Red
        }
    }
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

    Write-Status -Status Failure -Message $Message
    exit 1
}

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

#endregion Console

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

    Write-Status `
        -Status Success `
        -Message "Project folder: $($ProjectContext.ProjectFolder)"
}

#endregion Project Initialisation

#region Validation

function Test-CommandLine
{
    [CmdletBinding()]
    param
    (
        [Parameter(Mandatory = $true)]
        [PSCustomObject]$ProjectContext
    )

    $VersionChoiceCount = 0

    if ($Minor)
    {
        $VersionChoiceCount++
    }

    if ($Major)
    {
        $VersionChoiceCount++
    }

    if (-not [string]::IsNullOrWhiteSpace($Version))
    {
        $VersionChoiceCount++
    }

    if ($VersionChoiceCount -gt 1)
    {
        Stop-ProjectRelease `
            "Use only one of -Minor, -Major or -Version."
    }

    if ($ProjectContext.NoZip -and $ProjectContext.ZipOnly)
    {
        Stop-ProjectRelease `
            "-NoZip and -ZipOnly cannot be used together."
    }

    if ($ProjectContext.ZipOnly)
    {
        Stop-ProjectRelease `
            "-ZipOnly will become available when ZIP creation is implemented."
    }

    if (-not [string]::IsNullOrWhiteSpace($ProjectContext.OutputFolder))
    {
        Write-Status `
            -Status Warning `
            -Message "-Output is accepted but will not be used until ZIP creation is implemented."
    }

    if (-not $ProjectContext.NoZip -and -not $ProjectContext.DryRun)
    {
        Write-Status `
            -Status Warning `
            -Message "ZIP creation is not yet implemented. Project files will still be updated."
    }
}

function Test-ProjectFiles
{
    [CmdletBinding()]
    param
    (
        [Parameter(Mandatory = $true)]
        [PSCustomObject]$ProjectContext
    )

    Write-Status `
        -Status Progress `
        -Message "Validating required project files"

    foreach ($FileName in $ProjectFileOrder)
    {
        $FilePath = Join-Path `
            -Path $ProjectContext.ProjectFolder `
            -ChildPath $FileName

        if (-not (Test-Path -LiteralPath $FilePath -PathType Leaf))
        {
            Stop-ProjectRelease "Missing required file: $FileName"
        }

        Write-Status `
            -Status Success `
            -Message "Found: $FileName"
    }
}

function Test-SemanticVersion
{
    [CmdletBinding()]
    param
    (
        [Parameter(Mandatory = $true)]
        [ValidateNotNullOrEmpty()]
        [string]$Value,

        [Parameter(Mandatory = $true)]
        [ValidateNotNullOrEmpty()]
        [string]$Description
    )

    if ($Value -notmatch '^(0|[1-9]\d*)\.(0|[1-9]\d*)\.(0|[1-9]\d*)$')
    {
        Stop-ProjectRelease `
            "$Description must use X.Y.Z format: $Value"
    }

    return [version]$Value
}

#endregion Validation

#region File and JSON Helpers

function Read-JsonFile
{
    [CmdletBinding()]
    param
    (
        [Parameter(Mandatory = $true)]
        [ValidateNotNullOrEmpty()]
        [string]$Path,

        [Parameter(Mandatory = $true)]
        [ValidateNotNullOrEmpty()]
        [string]$DisplayName
    )

    try
    {
        $Content = Get-Content `
            -LiteralPath $Path `
            -Raw `
            -ErrorAction Stop

        return $Content | ConvertFrom-Json -ErrorAction Stop
    }
    catch
    {
        Stop-ProjectRelease `
            "$DisplayName contains invalid JSON or could not be read."
    }
}

function ConvertTo-ProjectJson
{
    [CmdletBinding()]
    param
    (
        [Parameter(Mandatory = $true)]
        $InputObject
    )

    $Json = $InputObject | ConvertTo-Json -Depth 100

    $FormattedLines = foreach ($Line in ($Json -split '\r?\n'))
    {
        $IndentLength = $Line.Length - $Line.TrimStart().Length
        $IndentLevel = [math]::Floor($IndentLength / 4)
        $TrimmedLine = $Line.TrimStart()

        if ($TrimmedLine -match '^"[^"]+"\s*:\s{2,}')
        {
            $TrimmedLine = [regex]::Replace(
                $TrimmedLine,
                '^("[^"]+"\s*:)\s+',
                '$1 '
            )
        }

        ('  ' * $IndentLevel) + $TrimmedLine
    }

    return ($FormattedLines -join [Environment]::NewLine) +
        [Environment]::NewLine
}

function Write-TextFileUtf8NoBom
{
    [CmdletBinding()]
    param
    (
        [Parameter(Mandatory = $true)]
        [ValidateNotNullOrEmpty()]
        [string]$Path,

        [Parameter(Mandatory = $true)]
        [AllowEmptyString()]
        [string]$Content
    )

    $Encoding = New-Object System.Text.UTF8Encoding($false)

    [System.IO.File]::WriteAllText(
        $Path,
        $Content,
        $Encoding
    )
}

#endregion File and JSON Helpers

#region Release Information

function Get-ReleaseInfo
{
    [CmdletBinding()]
    param
    (
        [Parameter(Mandatory = $true)]
        [PSCustomObject]$ProjectContext
    )

    Write-Status `
        -Status Progress `
        -Message "Loading project metadata"

    $ReleasePath = Join-Path `
        -Path $ProjectContext.ProjectFolder `
        -ChildPath "release.json"

    $PackagePath = Join-Path `
        -Path $ProjectContext.ProjectFolder `
        -ChildPath "package.json"

    $BuildInfoPath = Join-Path `
        -Path $ProjectContext.ProjectFolder `
        -ChildPath "build-info.json"

    $ProjectContext.Release =
        Read-JsonFile -Path $ReleasePath -DisplayName "release.json"

    $ProjectContext.Package =
        Read-JsonFile -Path $PackagePath -DisplayName "package.json"

    $ProjectContext.BuildInfo =
        Read-JsonFile -Path $BuildInfoPath -DisplayName "build-info.json"

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

    [void](Test-SemanticVersion `
        -Value $ProjectContext.CurrentVersion `
        -Description "Current version")

    Write-Status `
        -Status Success `
        -Message "Project metadata loaded"
}

#endregion Release Information

#region Version Handling

function Get-TargetVersion
{
    [CmdletBinding()]
    param
    (
        [Parameter(Mandatory = $true)]
        [PSCustomObject]$ProjectContext
    )

    Write-Status `
        -Status Progress `
        -Message "Determining target version"

    $Current = Test-SemanticVersion `
        -Value $ProjectContext.CurrentVersion `
        -Description "Current version"

    if (-not [string]::IsNullOrWhiteSpace($Version))
    {
        $Forced = Test-SemanticVersion `
            -Value $Version `
            -Description "Forced version"

        if (-not $ProjectContext.Force -and $Forced -le $Current)
        {
            Stop-ProjectRelease `
                "Forced version must be greater than the current version. Use -Force to override."
        }

        $ProjectContext.TargetVersion = $Forced.ToString()
        $ProjectContext.ReleaseType = "Forced"
    }
    elseif ($Major)
    {
        $ProjectContext.TargetVersion =
            ([version]::new($Current.Major + 1, 0, 0)).ToString()

        $ProjectContext.ReleaseType = "Major"
    }
    elseif ($Minor)
    {
        $ProjectContext.TargetVersion =
            ([version]::new($Current.Major, $Current.Minor + 1, 0)).ToString()

        $ProjectContext.ReleaseType = "Minor"
    }
    else
    {
        $ProjectContext.TargetVersion =
            ([version]::new(
                $Current.Major,
                $Current.Minor,
                $Current.Build + 1
            )).ToString()

        $ProjectContext.ReleaseType = "Patch"
    }

    $ProjectContext.TargetTag =
        "v$($ProjectContext.TargetVersion)"

    Write-Status `
        -Status Success `
        -Message "Target version: $($ProjectContext.TargetVersion) ($($ProjectContext.ReleaseType))"
}

#endregion Version Handling

#region Metadata Synchronisation

function Set-ObjectProperty
{
    [CmdletBinding()]
    param
    (
        [Parameter(Mandatory = $true)]
        $InputObject,

        [Parameter(Mandatory = $true)]
        [ValidateNotNullOrEmpty()]
        [string]$Name,

        $Value
    )

    $Property = $InputObject.PSObject.Properties[$Name]

    if ($null -eq $Property)
    {
        $InputObject | Add-Member `
            -MemberType NoteProperty `
            -Name $Name `
            -Value $Value
    }
    else
    {
        $InputObject.$Name = $Value
    }
}

function Get-UpdatedMetadataContent
{
    [CmdletBinding()]
    param
    (
        [Parameter(Mandatory = $true)]
        [PSCustomObject]$ProjectContext
    )

    Set-ObjectProperty `
        -InputObject $ProjectContext.Release.release `
        -Name "version" `
        -Value $ProjectContext.TargetVersion

    Set-ObjectProperty `
        -InputObject $ProjectContext.Release.release `
        -Name "tag" `
        -Value $ProjectContext.TargetTag

    Set-ObjectProperty `
        -InputObject $ProjectContext.Package `
        -Name "version" `
        -Value $ProjectContext.TargetVersion

    Set-ObjectProperty `
        -InputObject $ProjectContext.BuildInfo `
        -Name "version" `
        -Value $ProjectContext.TargetVersion

    Set-ObjectProperty `
        -InputObject $ProjectContext.BuildInfo `
        -Name "tag" `
        -Value $ProjectContext.TargetTag

    Set-ObjectProperty `
        -InputObject $ProjectContext.BuildInfo `
        -Name "commit" `
        -Value ""

    Set-ObjectProperty `
        -InputObject $ProjectContext.BuildInfo `
        -Name "builtUtc" `
        -Value ""

    Set-ObjectProperty `
        -InputObject $ProjectContext.BuildInfo `
        -Name "notes" `
        -Value "Build information will be completed by ProjectUpdate.ps1."

    return @{
        "release.json" =
            ConvertTo-ProjectJson -InputObject $ProjectContext.Release

        "package.json" =
            ConvertTo-ProjectJson -InputObject $ProjectContext.Package

        "build-info.json" =
            ConvertTo-ProjectJson -InputObject $ProjectContext.BuildInfo
    }
}

#endregion Metadata Synchronisation

#region README

function Get-UpdatedReadmeContent
{
    [CmdletBinding()]
    param
    (
        [Parameter(Mandatory = $true)]
        [PSCustomObject]$ProjectContext
    )

    $ReadmePath = Join-Path `
        -Path $ProjectContext.ProjectFolder `
        -ChildPath "README.md"

    try
    {
        $Readme = Get-Content `
            -LiteralPath $ReadmePath `
            -Raw `
            -ErrorAction Stop
    }
    catch
    {
        Stop-ProjectRelease "README.md could not be read."
    }

    $NewCurrentRelease = @"
## Current Release

Version: **$($ProjectContext.TargetTag)**

Generated by `ProjectCreateRelease.ps1`.

"@

    $CurrentReleasePattern =
        '(?ms)^## Current Release\s*.*?(?=^---\s*$|^## Release History\s*$)'

    if ($Readme -match $CurrentReleasePattern)
    {
        $Readme = [regex]::Replace(
            $Readme,
            $CurrentReleasePattern,
            $NewCurrentRelease
        )
    }
    else
    {
        Stop-ProjectRelease `
            "README.md is missing a valid '## Current Release' section."
    }

    if ($Readme -notmatch '(?m)^## Release History\s*$')
    {
        Stop-ProjectRelease `
            "README.md is missing the '## Release History' section."
    }

    $HistoryMatch = [regex]::Match(
        $Readme,
        '(?ms)^## Release History\s*(?<History>.*)$'
    )

    $ExistingHistory = $HistoryMatch.Groups["History"].Value.Trim()
    $ExistingRows = @()

    foreach ($Line in ($ExistingHistory -split '\r?\n'))
    {
        if ($Line -match '^\|\s*v\d+\.\d+\.\d+\s*\|')
        {
            $ExistingRows += $Line.Trim()
        }
    }

    $NewHistoryRow =
        "| $($ProjectContext.TargetTag) | $($ProjectContext.ReleaseType) | Generated for updater regression testing. |"

    $HistoryRows = @($NewHistoryRow)

    foreach ($Row in $ExistingRows)
    {
        if ($Row -notmatch "^\|\s*$([regex]::Escape($ProjectContext.TargetTag))\s*\|")
        {
            $HistoryRows += $Row
        }
    }

    $HistoryRows = @(
        $HistoryRows |
            Select-Object -First $MaximumHistoryEntries
    )

    $NewHistory = @(
        "## Release History"
        ""
        "| Version | Type | Notes |"
        "|---------|------|-------|"
        $HistoryRows
        ""
    ) -join [Environment]::NewLine

    $Readme = [regex]::Replace(
        $Readme,
        '(?ms)^## Release History\s*.*$',
        $NewHistory
    )

    return $Readme.TrimEnd() + [Environment]::NewLine
}

#endregion README

#region File Transaction

function Set-ProjectFiles
{
    [CmdletBinding()]
    param
    (
        [Parameter(Mandatory = $true)]
        [PSCustomObject]$ProjectContext,

        [Parameter(Mandatory = $true)]
        [hashtable]$FileContents
    )

    if ($ProjectContext.DryRun)
    {
        Write-Status `
            -Status Warning `
            -Message "Dry run: project files were not changed."

        foreach ($FileName in $ProjectFileOrder)
        {
            if ($FileContents.ContainsKey($FileName))
            {
                Write-Host "       Would update: $FileName"
            }
        }

        return
    }

    $Backups = @{}

    try
    {
        foreach ($FileName in $ProjectFileOrder)
        {
            if (-not $FileContents.ContainsKey($FileName))
            {
                continue
            }

            $FilePath = Join-Path `
                -Path $ProjectContext.ProjectFolder `
                -ChildPath $FileName

            $Backups[$FileName] =
                Get-Content `
                    -LiteralPath $FilePath `
                    -Raw `
                    -ErrorAction Stop
        }

        Write-Status `
            -Status Progress `
            -Message "Synchronising project metadata"

        foreach ($FileName in @(
            "release.json"
            "package.json"
            "build-info.json"
        ))
        {
            if (-not $FileContents.ContainsKey($FileName))
            {
                continue
            }

            $FilePath = Join-Path `
                -Path $ProjectContext.ProjectFolder `
                -ChildPath $FileName

            Write-TextFileUtf8NoBom `
                -Path $FilePath `
                -Content $FileContents[$FileName]

            Write-Status `
                -Status Success `
                -Message "Updated: $FileName"
        }

        if ($FileContents.ContainsKey("README.md"))
        {
            Write-Status `
                -Status Progress `
                -Message "Updating README"

            $ReadmePath = Join-Path `
                -Path $ProjectContext.ProjectFolder `
                -ChildPath "README.md"

            Write-TextFileUtf8NoBom `
                -Path $ReadmePath `
                -Content $FileContents["README.md"]

            Write-Status `
                -Status Success `
                -Message "Updated: README.md"
        }
    }
    catch
    {
        Write-Status `
            -Status Warning `
            -Message "An update failed. Restoring original project files."

        foreach ($FileName in $ProjectFileOrder)
        {
            if (-not $Backups.ContainsKey($FileName))
            {
                continue
            }

            try
            {
                $FilePath = Join-Path `
                    -Path $ProjectContext.ProjectFolder `
                    -ChildPath $FileName

                Write-TextFileUtf8NoBom `
                    -Path $FilePath `
                    -Content $Backups[$FileName]
            }
            catch
            {
                Write-Status `
                    -Status Warning `
                    -Message "Could not restore: $FileName"
            }
        }

        Stop-ProjectRelease `
            "Project files could not be updated."
    }
}

#endregion File Transaction

#region Release Creation

function New-ProjectRelease
{
    [CmdletBinding()]
    param
    (
        [Parameter(Mandatory = $true)]
        [PSCustomObject]$ProjectContext
    )

    Get-TargetVersion `
        -ProjectContext $ProjectContext

    $UpdatedFiles =
        Get-UpdatedMetadataContent `
            -ProjectContext $ProjectContext

    $UpdatedFiles["README.md"] =
        Get-UpdatedReadmeContent `
            -ProjectContext $ProjectContext

    Set-ProjectFiles `
        -ProjectContext $ProjectContext `
        -FileContents $UpdatedFiles
}

#endregion Release Creation

#region Summary

function Write-ProjectSummary
{
    [CmdletBinding()]
    param
    (
        [Parameter(Mandatory = $true)]
        [PSCustomObject]$ProjectContext
    )

    $DryRunText =
        if ($ProjectContext.DryRun)
        {
            "Yes"
        }
        else
        {
            "No"
        }

    Write-Host ""
    Write-Host "Project         : $($ProjectContext.ProjectName)"
    Write-Host "Current Version : $($ProjectContext.CurrentVersion)"
    Write-Host "Target Version  : $($ProjectContext.TargetVersion)"
    Write-Host "Release Type    : $($ProjectContext.ReleaseType)"
    Write-Host "Dry Run         : $DryRunText"
    Write-Host ""
}

#endregion Summary

#region Main

Show-Banner

Test-CommandLine `
    -ProjectContext $ProjectContext

Initialize-Project `
    -ProjectContext $ProjectContext

Test-ProjectFiles `
    -ProjectContext $ProjectContext

Get-ReleaseInfo `
    -ProjectContext $ProjectContext

New-ProjectRelease `
    -ProjectContext $ProjectContext

Write-ProjectSummary `
    -ProjectContext $ProjectContext

if ($ProjectContext.DryRun)
{
    Write-Status `
        -Status Success `
        -Message "Dry run completed successfully."
}
else
{
    Write-Status `
        -Status Success `
        -Message "Project release metadata updated successfully."
}

#endregion Main
