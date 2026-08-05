<#
.SYNOPSIS
    Blarm Generic Project Release Creator

.DESCRIPTION
    Creates and publishes a project release from one of three change sources:

      -Local
          Uses changes already present in the local Git working folder.

      -Zip
          Finds the newest <Project>-Changes*.zip file in Windows Downloads,
          imports only its changed files, and then continues as a local release.

      -Dummy
          Requires a clean working tree and creates a version-only release.

    After the source changes are ready, the tool:
      - validates the project
      - calculates the target version
      - updates release-managed version metadata
      - updates README release history
      - optionally runs npm install
      - validates the resulting metadata
      - commits the project changes
      - records build information in a follow-up commit
      - pushes the commits
      - creates and pushes the Git tag

    Change Packages are transport packages only. They must not be treated as
    complete project or release ZIPs.

.NOTES
    Breaking change from v1.x:
      The tool no longer creates release ZIPs. It now imports an optional
      Change Package and publishes the resulting local working tree.
#>

# Version History
# 2.0.0 - Unified -Local, -Zip and -Dummy release sources; Git commit/tag/push.
# 1.3.0 - Complete-project ZIP creation and verification.
# 1.2.2 - Reliable two-space JSON formatter.
# 1.2.0 - Metadata synchronisation and README release history.

[CmdletBinding()]
param
(
    [Parameter(Mandatory = $true)]
    [ValidateNotNullOrEmpty()]
    [string]$ProjectFolder,

    [switch]$Local,

    [switch]$Zip,

    [switch]$Dummy,

    [switch]$Minor,

    [switch]$Major,

    [string]$Version,

    [switch]$DryRun
)

#region Configuration

$ErrorActionPreference = "Stop"
$ScriptVersion = "2.1.0"
$MaximumHistoryEntries = 25

$ReleaseManagedZipFiles = @(
    "release.json"
    "build-info.json"
    "package-lock.json"
)

$ReleaseManagedZipFolders = @(
    ".git"
    ".vs"
    "node_modules"
)

$ProjectFileOrder = @(
    "release.json"
    "package.json"
    "build-info.json"
    "README.md"
)

$ProjectContext = [PSCustomObject]@{
    ProjectFolder       = $ProjectFolder
    ProjectName         = $null
    Release             = $null
    Package             = $null
    BuildInfo           = $null
    CurrentVersion      = $null
    TargetVersion       = $null
    TargetTag           = $null
    ReleaseType         = $null
    SourceMode          = $null
    SourceZip           = $null
    DownloadsFolder     = $null
    ImportedFiles       = @()
    IgnoredFiles        = @()
    InitialGitChanges   = @()
    CommitMessage       = $null
    ReleaseHistoryNote  = $null
    ContentCommit       = $null
    FinalCommit         = $null
    BuiltUtc            = $null
    DryRun              = [bool]$DryRun
    HasPackageJson      = $false
}

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
            Write-Host "[....] $Message" -ForegroundColor Cyan
        }

        "Success"
        {
            Write-Host "[ OK ] $Message" -ForegroundColor Green
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

    Write-Host ""
    Write-Host "=========================================================" -ForegroundColor Red
    Write-Host " RELEASE FAILED" -ForegroundColor Red
    Write-Host "=========================================================" -ForegroundColor Red
    Write-Host ""
    Write-Host $Message -ForegroundColor Red
    Write-Host ""

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

#region Native Commands and Git

function Invoke-NativeCommand
{
    [CmdletBinding()]
    param
    (
        [Parameter(Mandatory = $true)]
        [ValidateNotNullOrEmpty()]
        [string]$Command,

        [string[]]$Arguments = @()
    )

    & $Command @Arguments

    if ($LASTEXITCODE -ne 0)
    {
        throw "'$Command $($Arguments -join ' ')' failed with exit code $LASTEXITCODE."
    }
}

function Get-GitStatus
{
    [CmdletBinding()]
    param()

    $Status = @(git.exe status --porcelain)

    if ($LASTEXITCODE -ne 0)
    {
        throw "Unable to read Git status."
    }

    return $Status
}

function Get-GitHead
{
    [CmdletBinding()]
    param()

    $Head = (git.exe rev-parse HEAD).Trim()

    if ($LASTEXITCODE -ne 0 -or [string]::IsNullOrWhiteSpace($Head))
    {
        throw "Unable to determine the current Git commit."
    }

    return $Head
}

function Test-GitRepository
{
    [CmdletBinding()]
    param
    (
        [Parameter(Mandatory = $true)]
        [PSCustomObject]$ProjectContext
    )

    $GitFolder = Join-Path `
        -Path $ProjectContext.ProjectFolder `
        -ChildPath ".git"

    if (-not (Test-Path -LiteralPath $GitFolder -PathType Container))
    {
        Stop-ProjectRelease `
            "The project does not contain a .git folder."
    }

    try
    {
        Push-Location $ProjectContext.ProjectFolder

        $InsideWorkTree = (
            git.exe rev-parse --is-inside-work-tree
        ).Trim()

        if ($LASTEXITCODE -ne 0 -or $InsideWorkTree -ne "true")
        {
            throw "The project folder is not a Git working tree."
        }
    }
    catch
    {
        Stop-ProjectRelease $_.Exception.Message
    }
    finally
    {
        Pop-Location
    }

    Write-Status `
        -Status Success `
        -Message "Git repository found"
}

function Test-TargetTagAvailable
{
    [CmdletBinding()]
    param
    (
        [Parameter(Mandatory = $true)]
        [PSCustomObject]$ProjectContext
    )

    try
    {
        Push-Location $ProjectContext.ProjectFolder

        Invoke-NativeCommand `
            -Command "git.exe" `
            -Arguments @("fetch", "--tags", "--quiet")

        $ExistingTag = git.exe tag --list $ProjectContext.TargetTag

        if ($LASTEXITCODE -ne 0)
        {
            throw "Unable to check Git tags."
        }

        if (-not [string]::IsNullOrWhiteSpace(
            ($ExistingTag -join "").Trim()
        ))
        {
            throw "Git tag '$($ProjectContext.TargetTag)' already exists."
        }
    }
    catch
    {
        Stop-ProjectRelease $_.Exception.Message
    }
    finally
    {
        Pop-Location
    }

    Write-Status `
        -Status Success `
        -Message "Git tag is available: $($ProjectContext.TargetTag)"
}

#endregion Native Commands and Git

#region Project Initialisation and Validation

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
        $ProjectContext.ProjectFolder = (
            Resolve-Path `
                -LiteralPath $ProjectContext.ProjectFolder `
                -ErrorAction Stop
        ).Path
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

function Test-CommandLine
{
    [CmdletBinding()]
    param
    (
        [Parameter(Mandatory = $true)]
        [PSCustomObject]$ProjectContext
    )

    $SourceCount = 0

    if ($Local)
    {
        $SourceCount++
    }

    if ($Zip)
    {
        $SourceCount++
    }

    if ($Dummy)
    {
        $SourceCount++
    }

    if ($SourceCount -ne 1)
    {
        Stop-ProjectRelease `
            "Specify exactly one change source: -Local, -Zip or -Dummy."
    }

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

    if ($Local)
    {
        $ProjectContext.SourceMode = "Local"
    }
    elseif ($Zip)
    {
        $ProjectContext.SourceMode = "Zip"
    }
    else
    {
        $ProjectContext.SourceMode = "Dummy"
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

#endregion Project Initialisation and Validation

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

function ConvertTo-JsonScalar
{
    [CmdletBinding()]
    param
    (
        $Value
    )

    if ($null -eq $Value)
    {
        return "null"
    }

    return ($Value | ConvertTo-Json -Compress -Depth 100)
}

function Format-ProjectJsonValue
{
    [CmdletBinding()]
    param
    (
        $Value,

        [Parameter(Mandatory = $true)]
        [ValidateRange(0, 100)]
        [int]$IndentLevel
    )

    $Indent = "  " * $IndentLevel
    $ChildIndent = "  " * ($IndentLevel + 1)

    if ($null -eq $Value -or
        $Value -is [string] -or
        $Value -is [char] -or
        $Value -is [bool] -or
        $Value -is [byte] -or
        $Value -is [sbyte] -or
        $Value -is [int16] -or
        $Value -is [uint16] -or
        $Value -is [int32] -or
        $Value -is [uint32] -or
        $Value -is [int64] -or
        $Value -is [uint64] -or
        $Value -is [single] -or
        $Value -is [double] -or
        $Value -is [decimal] -or
        $Value -is [datetime] -or
        $Value -is [guid])
    {
        return ConvertTo-JsonScalar -Value $Value
    }

    if ($Value -is [System.Collections.IDictionary])
    {
        $Entries = @($Value.GetEnumerator())

        if ($Entries.Count -eq 0)
        {
            return "{}"
        }

        $Lines = [System.Collections.Generic.List[string]]::new()
        $Lines.Add("{")

        for ($Index = 0; $Index -lt $Entries.Count; $Index++)
        {
            $Entry = $Entries[$Index]
            $NameJson = ConvertTo-JsonScalar -Value ([string]$Entry.Key)
            $FormattedValue = Format-ProjectJsonValue `
                -Value $Entry.Value `
                -IndentLevel ($IndentLevel + 1)

            $ValueLines = $FormattedValue -split '\r?\n'
            $Comma = if ($Index -lt ($Entries.Count - 1)) { "," } else { "" }

            $Lines.Add("$ChildIndent$NameJson`: $($ValueLines[0])")

            for ($LineIndex = 1; $LineIndex -lt $ValueLines.Count; $LineIndex++)
            {
                $Suffix = if ($LineIndex -eq ($ValueLines.Count - 1))
                {
                    $Comma
                }
                else
                {
                    ""
                }

                $Lines.Add("$($ValueLines[$LineIndex])$Suffix")
            }

            if ($ValueLines.Count -eq 1 -and $Comma)
            {
                $Lines[$Lines.Count - 1] =
                    $Lines[$Lines.Count - 1] + $Comma
            }
        }

        $Lines.Add("$Indent}")
        return $Lines -join [Environment]::NewLine
    }

    if ($Value -is [System.Collections.IEnumerable] -and
        $Value -isnot [string] -and
        $Value -isnot [PSCustomObject])
    {
        $Items = @($Value)

        if ($Items.Count -eq 0)
        {
            return "[]"
        }

        $Lines = [System.Collections.Generic.List[string]]::new()
        $Lines.Add("[")

        for ($Index = 0; $Index -lt $Items.Count; $Index++)
        {
            $FormattedItem = Format-ProjectJsonValue `
                -Value $Items[$Index] `
                -IndentLevel ($IndentLevel + 1)

            $ItemLines = $FormattedItem -split '\r?\n'
            $Comma = if ($Index -lt ($Items.Count - 1)) { "," } else { "" }

            $Lines.Add("$ChildIndent$($ItemLines[0])")

            for ($LineIndex = 1; $LineIndex -lt $ItemLines.Count; $LineIndex++)
            {
                $Suffix = if ($LineIndex -eq ($ItemLines.Count - 1))
                {
                    $Comma
                }
                else
                {
                    ""
                }

                $Lines.Add("$($ItemLines[$LineIndex])$Suffix")
            }

            if ($ItemLines.Count -eq 1 -and $Comma)
            {
                $Lines[$Lines.Count - 1] =
                    $Lines[$Lines.Count - 1] + $Comma
            }
        }

        $Lines.Add("$Indent]")
        return $Lines -join [Environment]::NewLine
    }

    $Properties = @($Value.PSObject.Properties)

    if ($Properties.Count -eq 0)
    {
        return "{}"
    }

    $Lines = [System.Collections.Generic.List[string]]::new()
    $Lines.Add("{")

    for ($Index = 0; $Index -lt $Properties.Count; $Index++)
    {
        $Property = $Properties[$Index]
        $NameJson = ConvertTo-JsonScalar -Value $Property.Name
        $FormattedValue = Format-ProjectJsonValue `
            -Value $Property.Value `
            -IndentLevel ($IndentLevel + 1)

        $ValueLines = $FormattedValue -split '\r?\n'
        $Comma = if ($Index -lt ($Properties.Count - 1)) { "," } else { "" }

        $Lines.Add("$ChildIndent$NameJson`: $($ValueLines[0])")

        for ($LineIndex = 1; $LineIndex -lt $ValueLines.Count; $LineIndex++)
        {
            $Suffix = if ($LineIndex -eq ($ValueLines.Count - 1))
            {
                $Comma
            }
            else
            {
                ""
            }

            $Lines.Add("$($ValueLines[$LineIndex])$Suffix")
        }

        if ($ValueLines.Count -eq 1 -and $Comma)
        {
            $Lines[$Lines.Count - 1] =
                $Lines[$Lines.Count - 1] + $Comma
        }
    }

    $Lines.Add("$Indent}")
    return $Lines -join [Environment]::NewLine
}

function ConvertTo-ProjectJson
{
    [CmdletBinding()]
    param
    (
        [Parameter(Mandatory = $true)]
        $InputObject
    )

    return (
        Format-ProjectJsonValue `
            -Value $InputObject `
            -IndentLevel 0
    ).TrimEnd() + [Environment]::NewLine
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
        $Content.TrimEnd() + [Environment]::NewLine,
        $Encoding
    )
}

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

#endregion File and JSON Helpers

#region Project Metadata

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

    
    $ProjectContext.ProjectName =
        [string][string]$ProjectContext.Release.project

    $ProjectContext.CurrentVersion =
        [string][string]$ProjectContext.Release.version

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

    $ProjectContext.HasPackageJson = Test-Path `
        -LiteralPath $PackagePath `
        -PathType Leaf

    Write-Status `
        -Status Success `
        -Message "Project metadata loaded"
}

function Refresh-ImportedProjectContent
{
    [CmdletBinding()]
    param
    (
        [Parameter(Mandatory = $true)]
        [PSCustomObject]$ProjectContext
    )

    if ($ProjectContext.SourceMode -ne "Zip" -or
        $ProjectContext.DryRun)
    {
        return
    }

    # package.json may contain genuine application changes from the Change
    # Package. Reload it after import so those changes are preserved when the
    # release-owned version field is updated.
    $PackagePath = Join-Path `
        -Path $ProjectContext.ProjectFolder `
        -ChildPath "package.json"

    $ProjectContext.Package =
        Read-JsonFile -Path $PackagePath -DisplayName "package.json"

    Write-Status `
        -Status Success `
        -Message "Imported project metadata reloaded"
}

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

        if ($Forced -le $Current)
        {
            Stop-ProjectRelease `
                "Forced version must be greater than the current version."
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

    $ProjectContext.BuiltUtc =
        (Get-Date).ToUniversalTime().ToString("o")

    $ProjectContext.CommitMessage =
        "Release $($ProjectContext.ProjectName) $($ProjectContext.TargetTag)"

    if (-not [string]::IsNullOrWhiteSpace(
        [string]$ProjectContext.Release.release.commit
    ))
    {
        $ProjectContext.CommitMessage =
            [string]$ProjectContext.Release.release.commit
    }

    switch ($ProjectContext.SourceMode)
    {
        "Local"
        {
            $ProjectContext.ReleaseHistoryNote =
                "Released from local project changes."
        }

        "Zip"
        {
            $ProjectContext.ReleaseHistoryNote =
                "Released from imported Change Package."
        }

        "Dummy"
        {
            $ProjectContext.ReleaseHistoryNote =
                "Version-only test release."
        }
    }

    Write-Status `
        -Status Success `
        -Message "Target version: $($ProjectContext.TargetVersion) ($($ProjectContext.ReleaseType))"
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
        -InputObject $ProjectContext.Release `
        -Name "version" `
        -Value $ProjectContext.TargetVersion

    Set-ObjectProperty `
        -InputObject $ProjectContext.Release `
        -Name "githubSource" `
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

    if ($null -ne $ProjectContext.BuildInfo.PSObject.Properties["builtUtc"])
    {
        Set-ObjectProperty `
            -InputObject $ProjectContext.BuildInfo `
            -Name "builtUtc" `
            -Value ""
    }
    elseif ($null -ne $ProjectContext.BuildInfo.PSObject.Properties["builtAt"])
    {
        Set-ObjectProperty `
            -InputObject $ProjectContext.BuildInfo `
            -Name "builtAt" `
            -Value ""
    }
    else
    {
        Set-ObjectProperty `
            -InputObject $ProjectContext.BuildInfo `
            -Name "builtUtc" `
            -Value ""
    }

    Set-ObjectProperty `
        -InputObject $ProjectContext.BuildInfo `
        -Name "notes" `
        -Value "Build information will be completed after the content commit."

    return @{
        "release.json" =
            ConvertTo-ProjectJson -InputObject $ProjectContext.Release

        "package.json" =
            ConvertTo-ProjectJson -InputObject $ProjectContext.Package

        "build-info.json" =
            ConvertTo-ProjectJson -InputObject $ProjectContext.BuildInfo
    }
}

function Set-ServiceWorkerVersion
{
    [CmdletBinding()]
    param
    (
        [Parameter(Mandatory = $true)]
        [string]$Path,

        [Parameter(Mandatory = $true)]
        [string]$Version
    )

    if (-not (Test-Path -LiteralPath $Path -PathType Leaf))
    {
        return $false
    }

    $Content = Get-Content -LiteralPath $Path -Raw
    $Original = $Content
    $Lines = $Content -split "`r?`n"

    for ($Index = 0; $Index -lt $Lines.Count; $Index++)
    {
        if ($Lines[$Index] -match '(?i)(cache|version)')
        {
            $Lines[$Index] = [regex]::Replace(
                $Lines[$Index],
                '(?i)v?\d+\.\d+\.\d+(?:-\d+)?',
                $Version
            )
        }
    }

    $Content = ($Lines -join [Environment]::NewLine).TrimEnd() +
        [Environment]::NewLine

    if ($Content -ne $Original)
    {
        Write-TextFileUtf8NoBom -Path $Path -Content $Content
        return $true
    }

    return $false
}

function Set-ManifestVersion
{
    [CmdletBinding()]
    param
    (
        [Parameter(Mandatory = $true)]
        [string]$Path,

        [Parameter(Mandatory = $true)]
        [string]$Version
    )

    if (-not (Test-Path -LiteralPath $Path -PathType Leaf))
    {
        return $false
    }

    $Manifest = Read-JsonFile `
        -Path $Path `
        -DisplayName "manifest.json"

    if ($null -eq $Manifest.PSObject.Properties["version"])
    {
        return $false
    }

    $Manifest.version = $Version

    Write-TextFileUtf8NoBom `
        -Path $Path `
        -Content (ConvertTo-ProjectJson -InputObject $Manifest)

    return $true
}

function Assert-ReleaseMetadata
{
    [CmdletBinding()]
    param
    (
        [Parameter(Mandatory = $true)]
        [PSCustomObject]$ProjectContext
    )

    $Problems = [System.Collections.Generic.List[string]]::new()

    foreach ($Name in @(
        "release.json"
        "package.json"
        "build-info.json"
    ))
    {
        $Path = Join-Path `
            -Path $ProjectContext.ProjectFolder `
            -ChildPath $Name

        if (-not (Test-Path -LiteralPath $Path -PathType Leaf))
        {
            continue
        }

        $Json = Read-JsonFile -Path $Path -DisplayName $Name

        $ActualVersion =
            if ($Name -eq "release.json")
            {
                [string]$Json.version
            }
            else
            {
                [string]$Json.version
            }

        if ($ActualVersion -ne $ProjectContext.TargetVersion)
        {
            $Problems.Add(
                "$Name version is '$ActualVersion' instead of '$($ProjectContext.TargetVersion)'."
            )
        }

        if ($Name -eq "build-info.json" -and
            [string]$Json.tag -ne $ProjectContext.TargetTag)
        {
            $Problems.Add(
                "build-info.json tag is '$($Json.tag)' instead of '$($ProjectContext.TargetTag)'."
            )
        }
    }

    if ($Problems.Count -gt 0)
    {
        throw "Release metadata validation failed:`n - $($Problems -join "`n - ")"
    }
}

#endregion Project Metadata

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
        $Readme = Get-Content -LiteralPath $ReadmePath -Raw -ErrorAction Stop
    }
    catch
    {
        Stop-ProjectRelease "README.md could not be read."
    }

    $BeginMarker = "<!-- PROJECTCREATERELEASE:BEGIN -->"
    $EndMarker   = "<!-- PROJECTCREATERELEASE:END -->"

    if (($Readme.IndexOf($BeginMarker) -lt 0) -or
        ($Readme.IndexOf($EndMarker) -lt 0))
    {
        Write-Status -Status Warning -Message "README release history markers not found."
        Write-Status -Status Warning -Message "README was left unchanged."

        return $Readme.TrimEnd() + [Environment]::NewLine
    }

    $HistoryRows = @()
    $HistoryRows += "| $($ProjectContext.TargetTag) | $($ProjectContext.ReleaseType) | Generated for updater regression testing. |"

    $Replacement = @(
        $BeginMarker
        ""
        "## Release History"
        ""
        "| Version | Type | Notes |"
        "|---------|------|-------|"
        $HistoryRows
        ""
        $EndMarker
    ) -join [Environment]::NewLine

    $Pattern = "(?s)<!-- PROJECTCREATERELEASE:BEGIN -->.*?<!-- PROJECTCREATERELEASE:END -->"

    $Readme = [regex]::Replace(
        $Readme,
        $Pattern,
        [System.Text.RegularExpressions.MatchEvaluator]{ param($m) $Replacement }
    )

    return $Readme.TrimEnd() + [Environment]::NewLine
}

#endregion README

#region Change Source

function Get-WindowsDownloadsFolder
{
    [CmdletBinding()]
    param()

    $DownloadsFolder = $null
    $KnownFolderName =
        "{374DE290-123F-4565-9164-39C4925E467B}"

    try
    {
        $RegistryPath =
            "HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\User Shell Folders"

        $DownloadsFolder = (
            Get-ItemProperty `
                -LiteralPath $RegistryPath `
                -Name $KnownFolderName `
                -ErrorAction Stop
        ).$KnownFolderName

        if (-not [string]::IsNullOrWhiteSpace($DownloadsFolder))
        {
            $DownloadsFolder =
                [Environment]::ExpandEnvironmentVariables($DownloadsFolder)
        }
    }
    catch
    {
        $DownloadsFolder = $null
    }

    if ([string]::IsNullOrWhiteSpace($DownloadsFolder))
    {
        $DownloadsFolder = Join-Path `
            -Path ([Environment]::GetFolderPath("UserProfile")) `
            -ChildPath "Downloads"
    }

    if (-not (Test-Path -LiteralPath $DownloadsFolder -PathType Container))
    {
        Stop-ProjectRelease `
            "Windows Downloads folder not found: $DownloadsFolder"
    }

    return [System.IO.Path]::GetFullPath($DownloadsFolder)
}

function Get-LatestChangePackage
{
    [CmdletBinding()]
    param
    (
        [Parameter(Mandatory = $true)]
        [PSCustomObject]$ProjectContext
    )

    $ProjectContext.DownloadsFolder =
        Get-WindowsDownloadsFolder

    $Pattern =
        "$($ProjectContext.ProjectName)-Changes*.zip"

    $Packages = @(
        Get-ChildItem `
            -LiteralPath $ProjectContext.DownloadsFolder `
            -Filter $Pattern `
            -File |
        Sort-Object `
            -Property LastWriteTime, Name `
            -Descending
    )

    if ($Packages.Count -eq 0)
    {
        Stop-ProjectRelease `
            "No '$Pattern' file was found in $($ProjectContext.DownloadsFolder)"
    }

    $ProjectContext.SourceZip = $Packages[0]

    Write-Status `
        -Status Success `
        -Message "Change Package found: $($ProjectContext.SourceZip.Name)"
}

function Test-ZipEntryPath
{
    [CmdletBinding()]
    param
    (
        [Parameter(Mandatory = $true)]
        [ValidateNotNullOrEmpty()]
        [string]$EntryPath
    )

    $Normalised = $EntryPath.Replace("\", "/")

    if ($Normalised.StartsWith("/") -or
        $Normalised -match '^[A-Za-z]:' -or
        $Normalised -match '(^|/)\.\.(/|$)')
    {
        throw "Unsafe path in Change Package: $EntryPath"
    }
}

function Get-ChangePackageRoot
{
    [CmdletBinding()]
    param
    (
        [Parameter(Mandatory = $true)]
        [string]$ExtractedFolder,

        [Parameter(Mandatory = $true)]
        [string]$ProjectName
    )

    $Items = @(
        Get-ChildItem `
            -LiteralPath $ExtractedFolder `
            -Force
    )

    if ($Items.Count -eq 1 -and
        $Items[0].PSIsContainer -and
        $Items[0].Name -eq $ProjectName)
    {
        return $Items[0].FullName
    }

    return $ExtractedFolder
}

function Test-IgnoredChangePackagePath
{
    [CmdletBinding()]
    param
    (
        [Parameter(Mandatory = $true)]
        [ValidateNotNullOrEmpty()]
        [string]$RelativePath
    )

    $Normalised = $RelativePath.Replace("\", "/").TrimStart("/")
    $Segments = @($Normalised -split "/")

    if ($Segments.Count -eq 0)
    {
        return $false
    }

    if ($ReleaseManagedZipFolders -contains $Segments[0])
    {
        return $true
    }

    if ($Segments.Count -eq 1 -and
        $ReleaseManagedZipFiles -contains $Segments[0])
    {
        return $true
    }

    return $false
}

function Import-ChangePackage
{
    [CmdletBinding()]
    param
    (
        [Parameter(Mandatory = $true)]
        [PSCustomObject]$ProjectContext
    )

    Get-LatestChangePackage `
        -ProjectContext $ProjectContext

    $TemporaryFolder = Join-Path `
        -Path $env:TEMP `
        -ChildPath (
            "BlarmChangePackage-" +
            [guid]::NewGuid().ToString("N")
        )

    try
    {
        [void](New-Item `
            -ItemType Directory `
            -Path $TemporaryFolder `
            -Force)

        Add-Type `
            -AssemblyName System.IO.Compression.FileSystem `
            -ErrorAction Stop

        $Archive = $null

        try
        {
            $Archive = [System.IO.Compression.ZipFile]::OpenRead(
                $ProjectContext.SourceZip.FullName
            )

            if ($Archive.Entries.Count -eq 0)
            {
                throw "The Change Package is empty."
            }

            foreach ($Entry in $Archive.Entries)
            {
                Test-ZipEntryPath -EntryPath $Entry.FullName
            }
        }
        finally
        {
            if ($null -ne $Archive)
            {
                $Archive.Dispose()
            }
        }

        Expand-Archive `
            -LiteralPath $ProjectContext.SourceZip.FullName `
            -DestinationPath $TemporaryFolder `
            -Force

        $PackageRoot = Get-ChangePackageRoot `
            -ExtractedFolder $TemporaryFolder `
            -ProjectName $ProjectContext.ProjectName

        $Files = @(
            Get-ChildItem `
                -LiteralPath $PackageRoot `
                -File `
                -Recurse `
                -Force |
            Sort-Object FullName
        )

        if ($Files.Count -eq 0)
        {
            throw "The Change Package contains no files."
        }

        $ImportedFiles = [System.Collections.Generic.List[string]]::new()
        $IgnoredFiles = [System.Collections.Generic.List[string]]::new()

        foreach ($File in $Files)
        {
            $RelativePath = $File.FullName.Substring(
                $PackageRoot.Length
            ).TrimStart("\", "/")

            if (Test-IgnoredChangePackagePath `
                -RelativePath $RelativePath)
            {
                $IgnoredFiles.Add($RelativePath)
                continue
            }

            $DestinationPath = Join-Path `
                -Path $ProjectContext.ProjectFolder `
                -ChildPath $RelativePath

            if ($ProjectContext.DryRun)
            {
                $ImportedFiles.Add($RelativePath)
                continue
            }

            $DestinationFolder = Split-Path `
                -Path $DestinationPath `
                -Parent

            if (-not (Test-Path `
                -LiteralPath $DestinationFolder `
                -PathType Container))
            {
                [void](New-Item `
                    -ItemType Directory `
                    -Path $DestinationFolder `
                    -Force)
            }

            Copy-Item `
                -LiteralPath $File.FullName `
                -Destination $DestinationPath `
                -Force

            $ImportedFiles.Add($RelativePath)
        }

        $ProjectContext.ImportedFiles = @($ImportedFiles)
        $ProjectContext.IgnoredFiles = @($IgnoredFiles)

        foreach ($IgnoredFile in $ProjectContext.IgnoredFiles)
        {
            Write-Status `
                -Status Warning `
                -Message "Ignored release-managed file: $IgnoredFile"
        }

        if ($ProjectContext.ImportedFiles.Count -eq 0)
        {
            throw "The Change Package contained no importable changed files."
        }

        if ($ProjectContext.DryRun)
        {
            Write-Status `
                -Status Warning `
                -Message "Dry run: Change Package files were not copied."

            foreach ($ImportedFile in $ProjectContext.ImportedFiles)
            {
                Write-Host "       Would import: $ImportedFile"
            }
        }
        else
        {
            foreach ($ImportedFile in $ProjectContext.ImportedFiles)
            {
                Write-Status `
                    -Status Success `
                    -Message "Imported: $ImportedFile"
            }
        }
    }
    catch
    {
        Stop-ProjectRelease $_.Exception.Message
    }
    finally
    {
        if (Test-Path -LiteralPath $TemporaryFolder)
        {
            Remove-Item `
                -LiteralPath $TemporaryFolder `
                -Recurse `
                -Force `
                -ErrorAction SilentlyContinue
        }
    }
}

function Initialize-ChangeSource
{
    [CmdletBinding()]
    param
    (
        [Parameter(Mandatory = $true)]
        [PSCustomObject]$ProjectContext
    )

    try
    {
        Push-Location $ProjectContext.ProjectFolder

        $ProjectContext.InitialGitChanges =
            @(Get-GitStatus)
    }
    catch
    {
        Stop-ProjectRelease $_.Exception.Message
    }
    finally
    {
        Pop-Location
    }

    switch ($ProjectContext.SourceMode)
    {
        "Local"
        {
            if ($ProjectContext.InitialGitChanges.Count -eq 0)
            {
                Stop-ProjectRelease `
                    "No local changes were found. Use -Dummy for a version-only release."
            }

            Write-Status `
                -Status Success `
                -Message "Release source: Local"
        }

        "Zip"
        {
            if ($ProjectContext.InitialGitChanges.Count -gt 0)
            {
                Stop-ProjectRelease `
                    "The Git working tree must be clean before importing a Change Package."
            }

            Import-ChangePackage `
                -ProjectContext $ProjectContext

            if (-not $ProjectContext.DryRun)
            {
                try
                {
                    Push-Location $ProjectContext.ProjectFolder
                    $ImportedStatus = @(Get-GitStatus)
                }
                catch
                {
                    Stop-ProjectRelease $_.Exception.Message
                }
                finally
                {
                    Pop-Location
                }

                if ($ImportedStatus.Count -eq 0)
                {
                    Stop-ProjectRelease `
                        "The Change Package produced no Git changes."
                }

                Write-Status `
                    -Status Success `
                    -Message "Release source: Zip"
            }
        }

        "Dummy"
        {
            if ($ProjectContext.InitialGitChanges.Count -gt 0)
            {
                Stop-ProjectRelease `
                    "-Dummy requires a clean Git working tree."
            }

            Write-Status `
                -Status Success `
                -Message "Release source: Dummy"
        }
    }
}

#endregion Change Source

#region Release File Updates

function Set-ReleaseFiles
{
    [CmdletBinding()]
    param
    (
        [Parameter(Mandatory = $true)]
        [PSCustomObject]$ProjectContext
    )

    $UpdatedFiles =
        Get-UpdatedMetadataContent `
            -ProjectContext $ProjectContext

    $UpdatedFiles["README.md"] =
        Get-UpdatedReadmeContent `
            -ProjectContext $ProjectContext

    if ($ProjectContext.DryRun)
    {
        Write-Status `
            -Status Warning `
            -Message "Dry run: release-managed files were not changed."

        foreach ($FileName in $ProjectFileOrder)
        {
            Write-Host "       Would update: $FileName"
        }

        $ServiceWorkerPath = Join-Path `
            -Path $ProjectContext.ProjectFolder `
            -ChildPath "service-worker.js"

        if (Test-Path -LiteralPath $ServiceWorkerPath -PathType Leaf)
        {
            Write-Host "       Would synchronise: service-worker.js"
        }

        $ManifestPath = Join-Path `
            -Path $ProjectContext.ProjectFolder `
            -ChildPath "manifest.json"

        if (Test-Path -LiteralPath $ManifestPath -PathType Leaf)
        {
            Write-Host "       Would synchronise: manifest.json"
        }

        return
    }

    Write-Status `
        -Status Progress `
        -Message "Synchronising release metadata"

    foreach ($FileName in @(
        "release.json"
        "package.json"
        "build-info.json"
    ))
    {
        $FilePath = Join-Path `
            -Path $ProjectContext.ProjectFolder `
            -ChildPath $FileName

        Write-TextFileUtf8NoBom `
            -Path $FilePath `
            -Content $UpdatedFiles[$FileName]

        Write-Status `
            -Status Success `
            -Message "Updated: $FileName"
    }

    Write-Status `
        -Status Progress `
        -Message "Updating README"

    $ReadmePath = Join-Path `
        -Path $ProjectContext.ProjectFolder `
        -ChildPath "README.md"

    Write-TextFileUtf8NoBom `
        -Path $ReadmePath `
        -Content $UpdatedFiles["README.md"]

    Write-Status `
        -Status Success `
        -Message "Updated: README.md"

    $ServiceWorkerPath = Join-Path `
        -Path $ProjectContext.ProjectFolder `
        -ChildPath "service-worker.js"

    if (Set-ServiceWorkerVersion `
        -Path $ServiceWorkerPath `
        -Version $ProjectContext.TargetVersion)
    {
        Write-Status `
            -Status Success `
            -Message "Updated: service-worker.js"
    }

    $ManifestPath = Join-Path `
        -Path $ProjectContext.ProjectFolder `
        -ChildPath "manifest.json"

    if (Set-ManifestVersion `
        -Path $ManifestPath `
        -Version $ProjectContext.TargetVersion)
    {
        Write-Status `
            -Status Success `
            -Message "Updated: manifest.json"
    }

    Assert-ReleaseMetadata `
        -ProjectContext $ProjectContext

    Write-Status `
        -Status Success `
        -Message "Release metadata validated"
}

#endregion Release File Updates

#region Package Handling

function Invoke-PackageInstall
{
    [CmdletBinding()]
    param
    (
        [Parameter(Mandatory = $true)]
        [PSCustomObject]$ProjectContext
    )

    if (-not $ProjectContext.HasPackageJson)
    {
        return
    }

    if ($ProjectContext.DryRun)
    {
        Write-Host "       Would validate: release metadata"
        Write-Host "       Would run: npm install"
        return
    }

    Write-Status `
        -Status Progress `
        -Message "Running npm install"

    try
    {
        Push-Location $ProjectContext.ProjectFolder

        Invoke-NativeCommand `
            -Command "npm.cmd" `
            -Arguments @("install")
    }
    catch
    {
        Stop-ProjectRelease `
            "npm install failed: $($_.Exception.Message)"
    }
    finally
    {
        Pop-Location
    }

    Assert-ReleaseMetadata `
        -ProjectContext $ProjectContext

    Write-Status `
        -Status Success `
        -Message "npm install completed"
}

#endregion Package Handling

#region Git Publication

function Ensure-GitIgnoreEntry
{
    [CmdletBinding()]
    param
    (
        [Parameter(Mandatory = $true)]
        [string]$GitIgnorePath,

        [Parameter(Mandatory = $true)]
        [string]$Entry
    )

    $Lines = @()

    if (Test-Path -LiteralPath $GitIgnorePath -PathType Leaf)
    {
        $Lines = @(Get-Content -LiteralPath $GitIgnorePath)
    }

    if ($Lines -contains $Entry)
    {
        return
    }

    if ($Lines.Count -gt 0 -and
        -not [string]::IsNullOrWhiteSpace($Lines[-1]))
    {
        $Lines += ""
    }

    $Lines += $Entry

    [System.IO.File]::WriteAllLines(
        $GitIgnorePath,
        $Lines,
        (New-Object System.Text.UTF8Encoding($false))
    )
}

function Set-FinalBuildInfo
{
    [CmdletBinding()]
    param
    (
        [Parameter(Mandatory = $true)]
        [PSCustomObject]$ProjectContext
    )

    $BuildInfoPath = Join-Path `
        -Path $ProjectContext.ProjectFolder `
        -ChildPath "build-info.json"

    $BuildInfo = Read-JsonFile `
        -Path $BuildInfoPath `
        -DisplayName "build-info.json"

    Set-ObjectProperty `
        -InputObject $BuildInfo `
        -Name "version" `
        -Value $ProjectContext.TargetVersion

    Set-ObjectProperty `
        -InputObject $BuildInfo `
        -Name "tag" `
        -Value $ProjectContext.TargetTag

    Set-ObjectProperty `
        -InputObject $BuildInfo `
        -Name "commit" `
        -Value $ProjectContext.ContentCommit

    if ($null -ne $BuildInfo.PSObject.Properties["builtUtc"])
    {
        Set-ObjectProperty `
            -InputObject $BuildInfo `
            -Name "builtUtc" `
            -Value $ProjectContext.BuiltUtc
    }
    elseif ($null -ne $BuildInfo.PSObject.Properties["builtAt"])
    {
        Set-ObjectProperty `
            -InputObject $BuildInfo `
            -Name "builtAt" `
            -Value $ProjectContext.BuiltUtc
    }
    else
    {
        Set-ObjectProperty `
            -InputObject $BuildInfo `
            -Name "builtUtc" `
            -Value $ProjectContext.BuiltUtc
    }

    Set-ObjectProperty `
        -InputObject $BuildInfo `
        -Name "notes" `
        -Value "Build metadata recorded by ProjectCreateRelease.ps1."

    Write-TextFileUtf8NoBom `
        -Path $BuildInfoPath `
        -Content (ConvertTo-ProjectJson -InputObject $BuildInfo)
}

function Publish-ProjectRelease
{
    [CmdletBinding()]
    param
    (
        [Parameter(Mandatory = $true)]
        [PSCustomObject]$ProjectContext
    )

    if ($ProjectContext.DryRun)
    {
        Write-Status `
            -Status Warning `
            -Message "Dry run: Git commit, push and tag were not performed."

        Write-Host "       Would commit: $($ProjectContext.CommitMessage)"
        Write-Host "       Would tag: $($ProjectContext.TargetTag)"
        Write-Host "       Would push commits and tag"
        return
    }

    try
    {
        Push-Location $ProjectContext.ProjectFolder

        Write-Status `
            -Status Progress `
            -Message "Preparing Git release"

        $GitIgnorePath = Join-Path `
            -Path $ProjectContext.ProjectFolder `
            -ChildPath ".gitignore"

        Ensure-GitIgnoreEntry `
            -GitIgnorePath $GitIgnorePath `
            -Entry ".vs/"

        Invoke-NativeCommand `
            -Command "git.exe" `
            -Arguments @(
                "rm"
                "-r"
                "--cached"
                "--ignore-unmatch"
                ".vs"
            )

        Assert-ReleaseMetadata `
            -ProjectContext $ProjectContext

        Invoke-NativeCommand `
            -Command "git.exe" `
            -Arguments @("add", "--all")

        $PendingChanges = @(Get-GitStatus)

        if ($PendingChanges.Count -eq 0)
        {
            throw "No Git changes remain to commit."
        }

        Invoke-NativeCommand `
            -Command "git.exe" `
            -Arguments @(
                "commit"
                "-m"
                $ProjectContext.CommitMessage
            )

        Write-Status `
            -Status Success `
            -Message "Project changes committed"

        $ProjectContext.ContentCommit =
            Get-GitHead

        Set-FinalBuildInfo `
            -ProjectContext $ProjectContext

        Invoke-NativeCommand `
            -Command "git.exe" `
            -Arguments @(
                "add"
                "--"
                "build-info.json"
            )

        $BuildInfoChanges = @(
            git.exe status --porcelain -- build-info.json
        )

        if ($LASTEXITCODE -ne 0)
        {
            throw "Unable to check build-info.json status."
        }

        if ($BuildInfoChanges.Count -gt 0)
        {
            Invoke-NativeCommand `
                -Command "git.exe" `
                -Arguments @(
                    "commit"
                    "-m"
                    "Record build metadata for $($ProjectContext.TargetTag)"
                )

            Write-Status `
                -Status Success `
                -Message "Build information recorded"
        }

        $ProjectContext.FinalCommit =
            Get-GitHead

        Invoke-NativeCommand `
            -Command "git.exe" `
            -Arguments @("push")

        Write-Status `
            -Status Success `
            -Message "Changes pushed"

        Invoke-NativeCommand `
            -Command "git.exe" `
            -Arguments @(
                "tag"
                $ProjectContext.TargetTag
            )

        Invoke-NativeCommand `
            -Command "git.exe" `
            -Arguments @(
                "push"
                "origin"
                $ProjectContext.TargetTag
            )

        Write-Status `
            -Status Success `
            -Message "Tag created and pushed: $($ProjectContext.TargetTag)"

        $FinalStatus = @(Get-GitStatus)

        if ($FinalStatus.Count -gt 0)
        {
            throw "The Git working tree is not clean after publishing."
        }
    }
    catch
    {
        Stop-ProjectRelease $_.Exception.Message
    }
    finally
    {
        Pop-Location
    }
}

#endregion Git Publication

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
    Write-Host "=========================================================" -ForegroundColor Green

    if ($ProjectContext.DryRun)
    {
        Write-Host " RELEASE DRY RUN COMPLETE" -ForegroundColor Green
    }
    else
    {
        Write-Host " RELEASE COMPLETE" -ForegroundColor Green
    }

    Write-Host "=========================================================" -ForegroundColor Green
    Write-Host ""
    Write-Host "Project         : $($ProjectContext.ProjectName)"
    Write-Host "Source          : $($ProjectContext.SourceMode)"

    if ($null -ne $ProjectContext.SourceZip)
    {
        Write-Host "Change Package  : $($ProjectContext.SourceZip.Name)"
    }

    Write-Host "Current Version : $($ProjectContext.CurrentVersion)"
    Write-Host "Target Version  : $($ProjectContext.TargetVersion)"
    Write-Host "Release Type    : $($ProjectContext.ReleaseType)"
    Write-Host "Tag             : $($ProjectContext.TargetTag)"
    Write-Host "Dry Run         : $DryRunText"

    if (-not [string]::IsNullOrWhiteSpace(
        $ProjectContext.FinalCommit
    ))
    {
        Write-Host "Commit          : $($ProjectContext.FinalCommit.Substring(
            0,
            [Math]::Min(12, $ProjectContext.FinalCommit.Length)
        ))"
    }

    Write-Host ""
}

#endregion Summary

#region Main

try
{
    Show-Banner

    Test-CommandLine `
        -ProjectContext $ProjectContext

    Initialize-Project `
        -ProjectContext $ProjectContext

    Test-GitRepository `
        -ProjectContext $ProjectContext

    Test-ProjectFiles `
        -ProjectContext $ProjectContext

    Get-ReleaseInfo `
        -ProjectContext $ProjectContext

    Initialize-ChangeSource `
        -ProjectContext $ProjectContext

    Refresh-ImportedProjectContent `
        -ProjectContext $ProjectContext

    Get-TargetVersion `
        -ProjectContext $ProjectContext

    Test-TargetTagAvailable `
        -ProjectContext $ProjectContext

    Set-ReleaseFiles `
        -ProjectContext $ProjectContext

    Invoke-PackageInstall `
        -ProjectContext $ProjectContext

    Publish-ProjectRelease `
        -ProjectContext $ProjectContext

    Write-ProjectSummary `
        -ProjectContext $ProjectContext

    exit 0
}
catch
{
    Stop-ProjectRelease $_.Exception.Message
}

#endregion Main
