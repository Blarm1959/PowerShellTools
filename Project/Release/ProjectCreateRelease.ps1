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
      - Create and verify a complete project ZIP
      - Support default Downloads output and -Output overrides
      - Support -NoZip and -ZipOnly
      - Display a project summary
#>

# Version History
# 1.3.0 - ZIP creation, verification, output handling, -NoZip and -ZipOnly.
# 1.2.2 - Reliable two-space JSON formatter with no behavioural changes.
# 1.2.1 - README spacing and newline consistency.
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

$ScriptVersion = "1.3.0"
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
    ZipPath        = $null
    ZipSizeBytes   = $null
    ZipEntryCount  = $null
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

    if ($ProjectContext.ZipOnly -and $VersionChoiceCount -gt 0)
    {
        Stop-ProjectRelease `
            "-ZipOnly cannot be combined with -Minor, -Major or -Version."
    }

    if ($ProjectContext.NoZip -and
        -not [string]::IsNullOrWhiteSpace($ProjectContext.OutputFolder))
    {
        Stop-ProjectRelease `
            "-Output cannot be used with -NoZip."
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

    if ($null -eq $Value)
    {
        return "null"
    }

    if ($Value -is [string] -or
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
        $Value -is [guid] -or
        $Value -is [version])
    {
        return ConvertTo-JsonScalar -Value $Value
    }

    if ($Value -is [System.Collections.IDictionary])
    {
        $Keys = @($Value.Keys)

        if ($Keys.Count -eq 0)
        {
            return "{}"
        }

        $Lines = @("{")

        for ($Index = 0; $Index -lt $Keys.Count; $Index++)
        {
            $Key = [string]$Keys[$Index]
            $FormattedKey = ConvertTo-JsonScalar -Value $Key
            $FormattedValue = Format-ProjectJsonValue `
                -Value $Value[$Keys[$Index]] `
                -IndentLevel ($IndentLevel + 1)

            $Comma = if ($Index -lt ($Keys.Count - 1)) { "," } else { "" }
            $Lines += "$ChildIndent$FormattedKey`: $FormattedValue$Comma"
        }

        $Lines += "$Indent}"
        return $Lines -join [Environment]::NewLine
    }

    if ($Value -is [System.Collections.IEnumerable] -and
        $Value -isnot [string])
    {
        $Items = @($Value)

        if ($Items.Count -eq 0)
        {
            return "[]"
        }

        $Lines = @("[")

        for ($Index = 0; $Index -lt $Items.Count; $Index++)
        {
            $FormattedValue = Format-ProjectJsonValue `
                -Value $Items[$Index] `
                -IndentLevel ($IndentLevel + 1)

            $Comma = if ($Index -lt ($Items.Count - 1)) { "," } else { "" }
            $Lines += "$ChildIndent$FormattedValue$Comma"
        }

        $Lines += "$Indent]"
        return $Lines -join [Environment]::NewLine
    }

    $Properties = @(
        $Value.PSObject.Properties |
            Where-Object { $_.MemberType -in @("NoteProperty", "Property") }
    )

    if ($Properties.Count -eq 0)
    {
        return ConvertTo-JsonScalar -Value $Value
    }

    $Lines = @("{")

    for ($Index = 0; $Index -lt $Properties.Count; $Index++)
    {
        $Property = $Properties[$Index]
        $FormattedName = ConvertTo-JsonScalar -Value $Property.Name
        $FormattedValue = Format-ProjectJsonValue `
            -Value $Property.Value `
            -IndentLevel ($IndentLevel + 1)

        $Comma = if ($Index -lt ($Properties.Count - 1)) { "," } else { "" }
        $Lines += "$ChildIndent$FormattedName`: $FormattedValue$Comma"
    }

    $Lines += "$Indent}"
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

    $Json = Format-ProjectJsonValue `
        -Value $InputObject `
        -IndentLevel 0

    return $Json.TrimEnd() + [Environment]::NewLine
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

#region ZIP Output

function Get-DefaultDownloadsFolder
{
    [CmdletBinding()]
    param()

    $DownloadsFolder = $null
    $KnownFolderName =
        "{374DE290-123F-4565-9164-39C4925E467B}"

    try
    {
        $UserShellFoldersPath =
            "HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\User Shell Folders"

        $DownloadsFolder = (
            Get-ItemProperty `
                -LiteralPath $UserShellFoldersPath `
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

    return [System.IO.Path]::GetFullPath($DownloadsFolder)
}

function Initialize-ZipOutput
{
    [CmdletBinding()]
    param
    (
        [Parameter(Mandatory = $true)]
        [PSCustomObject]$ProjectContext
    )

    if ($ProjectContext.NoZip)
    {
        return
    }

    if ([string]::IsNullOrWhiteSpace($ProjectContext.OutputFolder))
    {
        $ProjectContext.OutputFolder =
            Get-DefaultDownloadsFolder
    }
    else
    {
        try
        {
            $ProjectContext.OutputFolder =
                [System.IO.Path]::GetFullPath(
                    $ProjectContext.OutputFolder
                )
        }
        catch
        {
            Stop-ProjectRelease `
                "Output folder is invalid: $($ProjectContext.OutputFolder)"
        }
    }

    if (-not (Test-Path -LiteralPath $ProjectContext.OutputFolder))
    {
        if ($ProjectContext.DryRun)
        {
            Write-Status `
                -Status Warning `
                -Message "Dry run: output folder would be created: $($ProjectContext.OutputFolder)"
        }
        else
        {
            try
            {
                [void](New-Item `
                    -ItemType Directory `
                    -Path $ProjectContext.OutputFolder `
                    -Force `
                    -ErrorAction Stop)

                Write-Status `
                    -Status Success `
                    -Message "Created output folder: $($ProjectContext.OutputFolder)"
            }
            catch
            {
                Stop-ProjectRelease `
                    "Unable to create output folder: $($ProjectContext.OutputFolder)"
            }
        }
    }
    elseif (-not (Test-Path `
        -LiteralPath $ProjectContext.OutputFolder `
        -PathType Container))
    {
        Stop-ProjectRelease `
            "Output path is not a folder: $($ProjectContext.OutputFolder)"
    }

    $ProjectContext.ZipFilename =
        "$($ProjectContext.ProjectName)-v$($ProjectContext.TargetVersion).zip"

    $ProjectContext.ZipPath = Join-Path `
        -Path $ProjectContext.OutputFolder `
        -ChildPath $ProjectContext.ZipFilename

    if ((Test-Path -LiteralPath $ProjectContext.ZipPath) -and
        -not $ProjectContext.Force)
    {
        Stop-ProjectRelease `
            "ZIP already exists: $($ProjectContext.ZipPath). Use -Force to replace it."
    }
}

function Test-ZipExcludedPath
{
    [CmdletBinding()]
    param
    (
        [Parameter(Mandatory = $true)]
        [ValidateNotNullOrEmpty()]
        [string]$RelativePath,

        [string]$ZipPath,

        [string]$FullPath
    )

    if ($RelativePath -match '(^|[\\/])\.git([\\/]|$)')
    {
        return $true
    }

    if (-not [string]::IsNullOrWhiteSpace($ZipPath) -and
        -not [string]::IsNullOrWhiteSpace($FullPath))
    {
        if ([string]::Equals(
            [System.IO.Path]::GetFullPath($FullPath),
            [System.IO.Path]::GetFullPath($ZipPath),
            [System.StringComparison]::OrdinalIgnoreCase
        ))
        {
            return $true
        }
    }

    return $false
}

function New-ReleaseZip
{
    [CmdletBinding()]
    param
    (
        [Parameter(Mandatory = $true)]
        [PSCustomObject]$ProjectContext
    )

    if ($ProjectContext.NoZip)
    {
        return
    }

    if ($ProjectContext.DryRun)
    {
        Write-Status `
            -Status Warning `
            -Message "Dry run: ZIP was not created."

        Write-Host "       Would create: $($ProjectContext.ZipPath)"
        return
    }

    Write-Status `
        -Status Progress `
        -Message "Creating release ZIP"

    if (Test-Path -LiteralPath $ProjectContext.ZipPath)
    {
        if (-not $ProjectContext.Force)
        {
            throw "ZIP already exists: $($ProjectContext.ZipPath)"
        }

        Remove-Item `
            -LiteralPath $ProjectContext.ZipPath `
            -Force `
            -ErrorAction Stop
    }

    Add-Type -AssemblyName System.IO.Compression -ErrorAction Stop
    Add-Type -AssemblyName System.IO.Compression.FileSystem -ErrorAction Stop

    $ProjectRootName = $ProjectContext.ProjectName
    $ProjectRootPath = $ProjectContext.ProjectFolder.TrimEnd(
        [System.IO.Path]::DirectorySeparatorChar,
        [System.IO.Path]::AltDirectorySeparatorChar
    )

    $Directories = @(
        Get-ChildItem `
            -LiteralPath $ProjectRootPath `
            -Directory `
            -Recurse `
            -Force `
            -ErrorAction Stop |
        Sort-Object FullName
    )

    $Files = @(
        Get-ChildItem `
            -LiteralPath $ProjectRootPath `
            -File `
            -Recurse `
            -Force `
            -ErrorAction Stop |
        Sort-Object FullName
    )

    $Archive = $null

    try
    {
        $Archive = [System.IO.Compression.ZipFile]::Open(
            $ProjectContext.ZipPath,
            [System.IO.Compression.ZipArchiveMode]::Create
        )

        [void]$Archive.CreateEntry("$ProjectRootName/")

        foreach ($Directory in $Directories)
        {
            $RelativePath = $Directory.FullName.Substring(
                $ProjectRootPath.Length
            ).TrimStart('\', '/')

            if (Test-ZipExcludedPath `
                -RelativePath $RelativePath `
                -ZipPath $ProjectContext.ZipPath `
                -FullPath $Directory.FullName)
            {
                continue
            }

            $EntryName =
                "$ProjectRootName/$($RelativePath.Replace('\', '/'))/"

            [void]$Archive.CreateEntry($EntryName)
        }

        foreach ($File in $Files)
        {
            $RelativePath = $File.FullName.Substring(
                $ProjectRootPath.Length
            ).TrimStart('\', '/')

            if (Test-ZipExcludedPath `
                -RelativePath $RelativePath `
                -ZipPath $ProjectContext.ZipPath `
                -FullPath $File.FullName)
            {
                continue
            }

            $EntryName =
                "$ProjectRootName/$($RelativePath.Replace('\', '/'))"

            [void][System.IO.Compression.ZipFileExtensions]::CreateEntryFromFile(
                $Archive,
                $File.FullName,
                $EntryName,
                [System.IO.Compression.CompressionLevel]::Optimal
            )
        }
    }
    finally
    {
        if ($null -ne $Archive)
        {
            $Archive.Dispose()
        }
    }

    if (-not (Test-Path `
        -LiteralPath $ProjectContext.ZipPath `
        -PathType Leaf))
    {
        throw "ZIP was not created: $($ProjectContext.ZipPath)"
    }

    $ZipItem = Get-Item `
        -LiteralPath $ProjectContext.ZipPath `
        -ErrorAction Stop

    if ($ZipItem.Length -le 0)
    {
        throw "ZIP is empty: $($ProjectContext.ZipPath)"
    }

    $VerificationArchive = $null

    try
    {
        $VerificationArchive =
            [System.IO.Compression.ZipFile]::OpenRead(
                $ProjectContext.ZipPath
            )

        $ProjectContext.ZipEntryCount =
            $VerificationArchive.Entries.Count

        $RequiredReleaseEntry =
            "$ProjectRootName/release.json"

        $ReleaseEntry = $VerificationArchive.Entries |
            Where-Object { $_.FullName -eq $RequiredReleaseEntry } |
            Select-Object -First 1

        if ($null -eq $ReleaseEntry)
        {
            throw "ZIP verification failed: release.json is missing."
        }
    }
    finally
    {
        if ($null -ne $VerificationArchive)
        {
            $VerificationArchive.Dispose()
        }
    }

    $ProjectContext.ZipSizeBytes = $ZipItem.Length

    Write-Status `
        -Status Success `
        -Message "ZIP created: $($ProjectContext.ZipFilename)"

    Write-Status `
        -Status Success `
        -Message "ZIP verified: $($ProjectContext.ZipEntryCount) entries"
}

#endregion ZIP Output


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

    $NewCurrentRelease = @(
        "## Current Release"
        ""
        "Version: **$($ProjectContext.TargetTag)**"
        ""
        "Generated by `ProjectCreateRelease.ps1`."
        ""
        ""
    ) -join [Environment]::NewLine

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

function Get-ProjectFileBackups
{
    [CmdletBinding()]
    param
    (
        [Parameter(Mandatory = $true)]
        [PSCustomObject]$ProjectContext,

        [Parameter(Mandatory = $true)]
        [hashtable]$FileContents
    )

    $Backups = @{}

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

    return $Backups
}

function Restore-ProjectFiles
{
    [CmdletBinding()]
    param
    (
        [Parameter(Mandatory = $true)]
        [PSCustomObject]$ProjectContext,

        [Parameter(Mandatory = $true)]
        [hashtable]$Backups
    )

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
}

function Set-ProjectFiles
{
    [CmdletBinding()]
    param
    (
        [Parameter(Mandatory = $true)]
        [PSCustomObject]$ProjectContext,

        [Parameter(Mandatory = $true)]
        [hashtable]$FileContents,

        [Parameter(Mandatory = $true)]
        [hashtable]$Backups
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

    try
    {
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

        Restore-ProjectFiles `
            -ProjectContext $ProjectContext `
            -Backups $Backups

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

    if ($ProjectContext.ZipOnly)
    {
        $ProjectContext.TargetVersion =
            $ProjectContext.CurrentVersion

        $ProjectContext.TargetTag =
            if ([string]::IsNullOrWhiteSpace(
                [string]$ProjectContext.Release.release.tag
            ))
            {
                "v$($ProjectContext.CurrentVersion)"
            }
            else
            {
                [string]$ProjectContext.Release.release.tag
            }

        $ProjectContext.ReleaseType = "ZipOnly"

        Initialize-ZipOutput `
            -ProjectContext $ProjectContext

        try
        {
            New-ReleaseZip `
                -ProjectContext $ProjectContext
        }
        catch
        {
            Stop-ProjectRelease $_.Exception.Message
        }

        return
    }

    Get-TargetVersion `
        -ProjectContext $ProjectContext

    Initialize-ZipOutput `
        -ProjectContext $ProjectContext

    $UpdatedFiles =
        Get-UpdatedMetadataContent `
            -ProjectContext $ProjectContext

    $UpdatedFiles["README.md"] =
        Get-UpdatedReadmeContent `
            -ProjectContext $ProjectContext

    $Backups = @{}

    if (-not $ProjectContext.DryRun)
    {
        try
        {
            $Backups = Get-ProjectFileBackups `
                -ProjectContext $ProjectContext `
                -FileContents $UpdatedFiles
        }
        catch
        {
            Stop-ProjectRelease `
                "Original project files could not be backed up."
        }
    }

    Set-ProjectFiles `
        -ProjectContext $ProjectContext `
        -FileContents $UpdatedFiles `
        -Backups $Backups

    try
    {
        New-ReleaseZip `
            -ProjectContext $ProjectContext
    }
    catch
    {
        if (-not $ProjectContext.DryRun -and $Backups.Count -gt 0)
        {
            Write-Status `
                -Status Warning `
                -Message "ZIP creation failed. Restoring original project files."

            Restore-ProjectFiles `
                -ProjectContext $ProjectContext `
                -Backups $Backups
        }

        if (Test-Path -LiteralPath $ProjectContext.ZipPath)
        {
            Remove-Item `
                -LiteralPath $ProjectContext.ZipPath `
                -Force `
                -ErrorAction SilentlyContinue
        }

        Stop-ProjectRelease $_.Exception.Message
    }
}

#endregion Release Creation

#region Summary

function Format-FileSize
{
    [CmdletBinding()]
    param
    (
        [Nullable[long]]$Bytes
    )

    if ($null -eq $Bytes)
    {
        return $null
    }

    if ($Bytes -ge 1MB)
    {
        return "{0:N2} MB" -f ($Bytes / 1MB)
    }

    if ($Bytes -ge 1KB)
    {
        return "{0:N2} KB" -f ($Bytes / 1KB)
    }

    return "$Bytes bytes"
}

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

    $ZipText =
        if ($ProjectContext.NoZip)
        {
            "No (-NoZip)"
        }
        elseif ($ProjectContext.DryRun)
        {
            "Would create"
        }
        else
        {
            "Yes"
        }

    Write-Host ""
    Write-Host "Project         : $($ProjectContext.ProjectName)"
    Write-Host "Current Version : $($ProjectContext.CurrentVersion)"
    Write-Host "Target Version  : $($ProjectContext.TargetVersion)"
    Write-Host "Release Type    : $($ProjectContext.ReleaseType)"
    Write-Host "Dry Run         : $DryRunText"
    Write-Host "ZIP             : $ZipText"

    if (-not $ProjectContext.NoZip)
    {
        Write-Host "ZIP Path        : $($ProjectContext.ZipPath)"

        if (-not $ProjectContext.DryRun -and
            $null -ne $ProjectContext.ZipSizeBytes)
        {
            Write-Host "ZIP Size        : $(Format-FileSize -Bytes $ProjectContext.ZipSizeBytes)"
            Write-Host "ZIP Entries     : $($ProjectContext.ZipEntryCount)"
        }
    }

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
        -Message "Project release completed successfully."
}

#endregion Main
