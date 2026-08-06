<#
.SYNOPSIS
    Blarm Generic Project Release Creator

.DESCRIPTION
    Creates and publishes project releases or intermediate development commits.

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
# 2.5.0 - Added first-run UX, no-change detection, release plans, metadata diagnostics, project type and timing.
# 2.4.2 - Added complete README creation and managed release-history initialisation.
# 2.4.1 - Improved new-project detection, metadata messages and initial summary output.
# 2.4.0 - Added project bootstrap metadata and simplified explicit versioning.
# 2.3.0 - Added complete -NoBump development commit support.
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
    [switch]$NoBump,
    [string]$Message,
    [string]$Version,

    [switch]$DryRun
)


#region Configuration

$ErrorActionPreference = "Stop"
$ScriptVersion = "2.5.0"
$BootstrapDefaults = [ordered]@{
    Version          = "0.0.1"
    ReleaseType      = "Initial"
    ReleaseNotes     = "Initial project created."
    Port             = 0
    Language         = "en-GB"
    HistoryEntries   = 25
}

$MaximumHistoryEntries = $BootstrapDefaults.HistoryEntries

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
    NoBump              = [bool]$NoBump
    Message             = $Message
    DryRun              = [bool]$DryRun
    HasPackageJson      = $false
    IsNewProject        = $false
    ReadmeWasMissing    = $false
    InitialVersion      = $BootstrapDefaults.Version
    CreatedFiles        = @()
    ProjectType         = "Generic"
    MetadataVersions    = @()
    NoChangesDetected   = $false
    Stopwatch           = [System.Diagnostics.Stopwatch]::StartNew()
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
    param
    (
        [Parameter(Mandatory = $true)]
        [PSCustomObject]$ProjectContext
    )

    $Title =
        if ($ProjectContext.NoBump)
        {
            "Blarm Generic Project Development Commit"
        }
        else
        {
            "Blarm Generic Project Release Creator"
        }

    Write-Host ""
    Write-Host "========================================================="
    Write-Host " $Title"
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

    try
    {
        Push-Location $ProjectContext.ProjectFolder

        $InsideWorkTree = (
            git.exe rev-parse --is-inside-work-tree
        ).Trim()

        if ($LASTEXITCODE -ne 0 -or $InsideWorkTree -ne "true")
        {
            throw "The project folder is not inside a Git working tree."
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
    if ($Local) { $SourceCount++ }
    if ($Zip)   { $SourceCount++ }
    if ($Dummy) { $SourceCount++ }

    if ($SourceCount -gt 1)
    {
        Stop-ProjectRelease "Use only one change source: -Local, -Zip or -Dummy."
    }

    if ($SourceCount -eq 0 -or $Local)
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

    if ($ProjectContext.NoBump -and
        $ProjectContext.SourceMode -eq "Dummy")
    {
        Stop-ProjectRelease @"
-NoBump cannot be combined with -Dummy.

-Dummy always creates a new version, tag and build metadata.
"@
    }

    if ($ProjectContext.NoBump -and
        -not [string]::IsNullOrWhiteSpace($Version))
    {
        Stop-ProjectRelease "-NoBump cannot be combined with -Version."
    }

    if (-not $ProjectContext.NoBump -and
        -not [string]::IsNullOrWhiteSpace($ProjectContext.Message))
    {
        Stop-ProjectRelease "-Message can only be used with -NoBump."
    }

    if (-not [string]::IsNullOrWhiteSpace($Version))
    {
        [void](Test-SemanticVersion `
            -Value $Version `
            -Description "Version")

        $ProjectContext.InitialVersion = $Version
    }
}

function New-InitialReleaseJson
{
    [CmdletBinding()]
    param
    (
        [Parameter(Mandatory = $true)]
        [PSCustomObject]$ProjectContext
    )

    $ProjectName = Split-Path `
        -Path $ProjectContext.ProjectFolder `
        -Leaf

    return [ordered]@{
        schemaVersion  = 1
        project        = $ProjectName
        version        = $ProjectContext.InitialVersion
        githubSource   = "v$($ProjectContext.InitialVersion)"
        zipPrefix      = "$ProjectName-"
        port           = $BootstrapDefaults.Port
        packageChanges = $false
        commit         = "Release $ProjectName v$($ProjectContext.InitialVersion)"
        i18n           = [ordered]@{
            enabled         = $false
            folder          = "src/i18n"
            masterLanguage  = $BootstrapDefaults.Language
            defaultLanguage = $BootstrapDefaults.Language
            languages       = @($BootstrapDefaults.Language)
        }
    }
}

function New-InitialBuildInfoJson
{
    [CmdletBinding()]
    param
    (
        [Parameter(Mandatory = $true)]
        [PSCustomObject]$ProjectContext
    )

    return [ordered]@{
        version  = $ProjectContext.InitialVersion
        tag      = "v$($ProjectContext.InitialVersion)"
        commit   = ""
        builtUtc = ""
        notes    = "Build metadata will be completed by ProjectCreateRelease.ps1."
    }
}



function New-InitialReadmeContent
{
    [CmdletBinding()]
    param
    (
        [Parameter(Mandatory = $true)]
        [PSCustomObject]$ProjectContext
    )

    $ProjectName = Split-Path `
        -Path $ProjectContext.ProjectFolder `
        -Leaf

    $InitialTag = "v$($ProjectContext.InitialVersion)"
    $BeginMarker = "<!-- PROJECTCREATERELEASE:BEGIN -->"
    $EndMarker = "<!-- PROJECTCREATERELEASE:END -->"

    return @(
        "# $ProjectName"
        ""
        "Brief project description."
        ""
        "---"
        ""
        "## Current Release"
        ""
        "Version: **$InitialTag**"
        ""
        "Generated by ProjectCreateRelease.ps1."
        ""
        "---"
        ""
        "## Usage"
        ""
        "(Add project usage documentation here.)"
        ""
        "---"
        ""
        $BeginMarker
        ""
        "## Release History"
        ""
        "| Version | Type | Notes |"
        "|---------|------|-------|"
        ""
        $EndMarker
        ""
    ) -join [Environment]::NewLine
}

function Initialize-ProjectMetadataFiles
{
    [CmdletBinding()]
    param
    (
        [Parameter(Mandatory = $true)]
        [PSCustomObject]$ProjectContext
    )

    $ReleasePath = Join-Path $ProjectContext.ProjectFolder "release.json"
    $BuildInfoPath = Join-Path $ProjectContext.ProjectFolder "build-info.json"
    $ReadmePath = Join-Path $ProjectContext.ProjectFolder "README.md"

    $ProjectContext.IsNewProject = -not (
        Test-Path -LiteralPath $ReleasePath -PathType Leaf
    )

    $ProjectContext.ReadmeWasMissing = -not (
        Test-Path -LiteralPath $ReadmePath -PathType Leaf
    )

    $Missing = @()

    if (-not (Test-Path -LiteralPath $ReleasePath -PathType Leaf))
    {
        $Missing += "release.json"
    }

    if (-not (Test-Path -LiteralPath $BuildInfoPath -PathType Leaf))
    {
        $Missing += "build-info.json"
    }

    if ($ProjectContext.ReadmeWasMissing)
    {
        $Missing += "README.md"
    }

    if ($Missing.Count -eq 0)
    {
        return
    }

    if ($ProjectContext.NoBump -and $ProjectContext.IsNewProject)
    {
        Stop-ProjectRelease `
            "A new project must be initialised with a versioned release. Remove -NoBump."
    }

    if ($ProjectContext.SourceMode -eq "Dummy" -and
        $ProjectContext.IsNewProject)
    {
        Stop-ProjectRelease `
            "A new project must be initialised from Local changes, not -Dummy."
    }

    if ($ProjectContext.IsNewProject)
    {
        Write-Status `
            -Status Success `
            -Message "New project detected"

        Write-Status `
            -Status Progress `
            -Message "Creating project metadata"
    }
    else
    {
        Write-Status `
            -Status Progress `
            -Message "Creating missing project metadata"
    }

    if (-not (Test-Path -LiteralPath $ReleasePath -PathType Leaf))
    {
        if ($ProjectContext.DryRun)
        {
            Write-Host "       Would create: release.json"
        }
        else
        {
            Write-TextFileUtf8NoBom `
                -Path $ReleasePath `
                -Content (
                    ConvertTo-ProjectJson `
                        -InputObject (
                            New-InitialReleaseJson `
                                -ProjectContext $ProjectContext
                        )
                )
        }

        Write-Status `
            -Status Success `
            -Message "Created: release.json"

        if (-not $ProjectContext.DryRun)
        {
            $ProjectContext.CreatedFiles += "release.json"
        }
    }

    if (-not (Test-Path -LiteralPath $BuildInfoPath -PathType Leaf))
    {
        if ($ProjectContext.DryRun)
        {
            Write-Host "       Would create: build-info.json"
        }
        else
        {
            Write-TextFileUtf8NoBom `
                -Path $BuildInfoPath `
                -Content (
                    ConvertTo-ProjectJson `
                        -InputObject (
                            New-InitialBuildInfoJson `
                                -ProjectContext $ProjectContext
                        )
                )
        }

        Write-Status `
            -Status Success `
            -Message "Created: build-info.json"

        if (-not $ProjectContext.DryRun)
        {
            $ProjectContext.CreatedFiles += "build-info.json"
        }
    }

    if ($ProjectContext.ReadmeWasMissing)
    {
        if ($ProjectContext.DryRun)
        {
            Write-Host "       Would create: README.md"
        }
        else
        {
            Write-TextFileUtf8NoBom `
                -Path $ReadmePath `
                -Content (
                    New-InitialReadmeContent `
                        -ProjectContext $ProjectContext
                )
        }

        Write-Status `
            -Status Success `
            -Message "Created: README.md"

        if (-not $ProjectContext.DryRun)
        {
            $ProjectContext.CreatedFiles += "README.md"
        }
    }

    if ($ProjectContext.DryRun -and $ProjectContext.IsNewProject)
    {
        Write-Status `
            -Status Warning `
            -Message "Dry run: initial metadata files were not created."
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

    Initialize-ProjectMetadataFiles `
        -ProjectContext $ProjectContext

    if ($ProjectContext.DryRun -and $ProjectContext.IsNewProject)
    {
        return
    }

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

    $PackagePath = Join-Path $ProjectContext.ProjectFolder "package.json"

    if (Test-Path -LiteralPath $PackagePath -PathType Leaf)
    {
        Write-Status -Status Success -Message "Found optional file: package.json"
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

function Get-ProjectType
{
    [CmdletBinding()]
    param
    (
        [Parameter(Mandatory = $true)]
        [PSCustomObject]$ProjectContext
    )

    $Folder = $ProjectContext.ProjectFolder

    $HasNode =
        (Test-Path -LiteralPath (Join-Path $Folder "package.json") -PathType Leaf)

    $HasDotNet =
        (
            @(Get-ChildItem -LiteralPath $Folder -Filter "*.sln" -File -ErrorAction SilentlyContinue).Count -gt 0
        ) -or (
            @(Get-ChildItem -LiteralPath $Folder -Filter "*.csproj" -File -Recurse -ErrorAction SilentlyContinue).Count -gt 0
        )

    $HasPython =
        (
            Test-Path -LiteralPath (Join-Path $Folder "pyproject.toml") -PathType Leaf
        ) -or (
            Test-Path -LiteralPath (Join-Path $Folder "requirements.txt") -PathType Leaf
        ) -or (
            @(Get-ChildItem -LiteralPath $Folder -Filter "*.py" -File -Recurse -ErrorAction SilentlyContinue).Count -gt 0
        )

    $HasPowerShell =
        (
            @(Get-ChildItem -LiteralPath $Folder -Filter "*.ps1" -File -Recurse -ErrorAction SilentlyContinue).Count -gt 0
        ) -or (
            @(Get-ChildItem -LiteralPath $Folder -Filter "*.psm1" -File -Recurse -ErrorAction SilentlyContinue).Count -gt 0
        )

    if ($HasNode)
    {
        return "Node"
    }

    if ($HasDotNet)
    {
        return ".NET"
    }

    if ($HasPython)
    {
        return "Python"
    }

    if ($HasPowerShell)
    {
        return "PowerShell"
    }

    return "Generic"
}

function Set-ProjectType
{
    [CmdletBinding()]
    param
    (
        [Parameter(Mandatory = $true)]
        [PSCustomObject]$ProjectContext
    )

    $ProjectContext.ProjectType =
        Get-ProjectType -ProjectContext $ProjectContext

    Write-Status `
        -Status Success `
        -Message "Project type: $($ProjectContext.ProjectType)"
}

#region Project Metadata

function Get-ReleaseInfo
{
    [CmdletBinding()]
    param
    (
        [Parameter(Mandatory = $true)]
        [PSCustomObject]$ProjectContext
    )

    if ($ProjectContext.DryRun -and $ProjectContext.IsNewProject)
    {
        $ProjectContext.ProjectName = Split-Path $ProjectContext.ProjectFolder -Leaf
        $ProjectContext.CurrentVersion = $ProjectContext.InitialVersion
        $ProjectContext.Release = [PSCustomObject](New-InitialReleaseJson -ProjectContext $ProjectContext)
        $ProjectContext.BuildInfo = [PSCustomObject](New-InitialBuildInfoJson -ProjectContext $ProjectContext)

        $PackagePath = Join-Path $ProjectContext.ProjectFolder "package.json"
        $ProjectContext.HasPackageJson = Test-Path -LiteralPath $PackagePath -PathType Leaf
        if ($ProjectContext.HasPackageJson)
        {
            $ProjectContext.Package = Read-JsonFile -Path $PackagePath -DisplayName "package.json"
        }

        Write-Status -Status Success -Message "Dry run project metadata prepared"
        return
    }

    Write-Status -Status Progress -Message "Loading project metadata"

    $ReleasePath = Join-Path $ProjectContext.ProjectFolder "release.json"
    $PackagePath = Join-Path $ProjectContext.ProjectFolder "package.json"
    $BuildInfoPath = Join-Path $ProjectContext.ProjectFolder "build-info.json"

    $ProjectContext.Release =
        Read-JsonFile -Path $ReleasePath -DisplayName "release.json"

    $ProjectContext.BuildInfo =
        Read-JsonFile -Path $BuildInfoPath -DisplayName "build-info.json"

    $ProjectContext.HasPackageJson = Test-Path -LiteralPath $PackagePath -PathType Leaf

    if ($ProjectContext.HasPackageJson)
    {
        $ProjectContext.Package =
            Read-JsonFile -Path $PackagePath -DisplayName "package.json"
    }
    else
    {
        $ProjectContext.Package = $null
    }

    $ProjectContext.ProjectName = [string]$ProjectContext.Release.project
    $ProjectContext.CurrentVersion = [string]$ProjectContext.Release.version

    if ([string]::IsNullOrWhiteSpace($ProjectContext.ProjectName))
    {
        Stop-ProjectRelease "Project name was not found in release.json."
    }

    if ([string]::IsNullOrWhiteSpace($ProjectContext.CurrentVersion))
    {
        Stop-ProjectRelease "Current version was not found in release.json."
    }

    [void](Test-SemanticVersion `
        -Value $ProjectContext.CurrentVersion `
        -Description "Current version")

    Write-Status -Status Success -Message "Project metadata loaded"
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

    $PackagePath = Join-Path $ProjectContext.ProjectFolder "package.json"
    $ProjectContext.HasPackageJson = Test-Path -LiteralPath $PackagePath -PathType Leaf

    if ($ProjectContext.HasPackageJson)
    {
        $ProjectContext.Package =
            Read-JsonFile -Path $PackagePath -DisplayName "package.json"
    }

    Write-Status -Status Success -Message "Imported project metadata reloaded"
}

function Get-TargetVersion
{
    [CmdletBinding()]
    param
    (
        [Parameter(Mandatory = $true)]
        [PSCustomObject]$ProjectContext
    )

    if ($ProjectContext.NoBump)
    {
        Write-Status -Status Progress -Message "Preparing development commit"

        $ProjectContext.TargetVersion = $ProjectContext.CurrentVersion
        $ProjectContext.TargetTag = $null
        $ProjectContext.ReleaseType = "NoBump"
        $ProjectContext.ReleaseHistoryNote = $null
        $ProjectContext.CommitMessage =
            if ([string]::IsNullOrWhiteSpace($ProjectContext.Message))
            {
                "Update $($ProjectContext.ProjectName)"
            }
            else
            {
                $ProjectContext.Message.Trim()
            }

        Write-Status -Status Success -Message "Version unchanged: $($ProjectContext.CurrentVersion)"
        return
    }

    Write-Status -Status Progress -Message "Determining target version"

    $Current = Test-SemanticVersion `
        -Value $ProjectContext.CurrentVersion `
        -Description "Current version"

    if ($ProjectContext.IsNewProject)
    {
        $ProjectContext.TargetVersion = $ProjectContext.InitialVersion
        $ProjectContext.ReleaseType = $BootstrapDefaults.ReleaseType
        $ProjectContext.ReleaseHistoryNote = $BootstrapDefaults.ReleaseNotes
    }
    elseif (-not [string]::IsNullOrWhiteSpace($Version))
    {
        $Explicit = Test-SemanticVersion -Value $Version -Description "Version"

        if ($Explicit -le $Current)
        {
            Stop-ProjectRelease "Version must be greater than the current version."
        }

        $ProjectContext.TargetVersion = $Explicit.ToString()
        $ProjectContext.ReleaseType = "Explicit"
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

    $ProjectContext.TargetTag = "v$($ProjectContext.TargetVersion)"
    $ProjectContext.BuiltUtc = (Get-Date).ToUniversalTime().ToString("o")
    $ProjectContext.CommitMessage =
        "Release $($ProjectContext.ProjectName) $($ProjectContext.TargetTag)"

    if ($null -ne $ProjectContext.Release -and
        -not [string]::IsNullOrWhiteSpace([string]$ProjectContext.Release.commit))
    {
                $Template = [string]$ProjectContext.Release.commit
        $Template = $Template.Replace($ProjectContext.CurrentVersion,$ProjectContext.TargetVersion)
        $Template = $Template.Replace("v$($ProjectContext.CurrentVersion)",$ProjectContext.TargetTag)
        $ProjectContext.CommitMessage = $Template
    }

    if (-not $ProjectContext.IsNewProject)
    {
        switch ($ProjectContext.SourceMode)
        {
            "Local" { $ProjectContext.ReleaseHistoryNote = "Released from local project changes." }
            "Zip"   { $ProjectContext.ReleaseHistoryNote = "Released from imported Change Package." }
            "Dummy" { $ProjectContext.ReleaseHistoryNote = "Version-only test release." }
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

    Set-ObjectProperty -InputObject $ProjectContext.Release -Name "version" -Value $ProjectContext.TargetVersion
    Set-ObjectProperty -InputObject $ProjectContext.Release -Name "githubSource" -Value $ProjectContext.TargetTag

    if ($ProjectContext.HasPackageJson -and $null -ne $ProjectContext.Package)
    {
        Set-ObjectProperty -InputObject $ProjectContext.Package -Name "version" -Value $ProjectContext.TargetVersion
    }

    Set-ObjectProperty -InputObject $ProjectContext.BuildInfo -Name "version" -Value $ProjectContext.TargetVersion
    Set-ObjectProperty -InputObject $ProjectContext.BuildInfo -Name "tag" -Value $ProjectContext.TargetTag
    Set-ObjectProperty -InputObject $ProjectContext.BuildInfo -Name "commit" -Value ""

    if ($null -ne $ProjectContext.BuildInfo.PSObject.Properties["builtUtc"])
    {
        Set-ObjectProperty -InputObject $ProjectContext.BuildInfo -Name "builtUtc" -Value ""
    }
    elseif ($null -ne $ProjectContext.BuildInfo.PSObject.Properties["builtAt"])
    {
        Set-ObjectProperty -InputObject $ProjectContext.BuildInfo -Name "builtAt" -Value ""
    }
    else
    {
        Set-ObjectProperty -InputObject $ProjectContext.BuildInfo -Name "builtUtc" -Value ""
    }

    Set-ObjectProperty `
        -InputObject $ProjectContext.BuildInfo `
        -Name "notes" `
        -Value "Build information will be completed after the content commit."

    $UpdatedFiles = @{
        "release.json" = ConvertTo-ProjectJson -InputObject $ProjectContext.Release
        "build-info.json" = ConvertTo-ProjectJson -InputObject $ProjectContext.BuildInfo
    }

    if ($ProjectContext.HasPackageJson -and $null -ne $ProjectContext.Package)
    {
        $UpdatedFiles["package.json"] =
            ConvertTo-ProjectJson -InputObject $ProjectContext.Package
    }

    return $UpdatedFiles
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

function Get-ServiceWorkerReportedVersion
{
    [CmdletBinding()]
    param
    (
        [Parameter(Mandatory = $true)]
        [string]$Path
    )

    if (-not (Test-Path -LiteralPath $Path -PathType Leaf))
    {
        return $null
    }

    foreach ($Line in (Get-Content -LiteralPath $Path))
    {
        if ($Line -match '(?i)(cache|version)' -and
            $Line -match '(?<Version>\d+\.\d+\.\d+)')
        {
            return $Matches.Version
        }
    }

    return $null
}

function Get-MetadataVersionSnapshot
{
    [CmdletBinding()]
    param
    (
        [Parameter(Mandatory = $true)]
        [PSCustomObject]$ProjectContext
    )

    $Items = [System.Collections.Generic.List[object]]::new()

    $Items.Add([PSCustomObject]@{
        Name = "release.json"
        Version = [string]$ProjectContext.Release.version
    })

    if ($ProjectContext.HasPackageJson -and $null -ne $ProjectContext.Package)
    {
        $Items.Add([PSCustomObject]@{
            Name = "package.json"
            Version = [string]$ProjectContext.Package.version
        })
    }

    if ($null -ne $ProjectContext.BuildInfo)
    {
        $Items.Add([PSCustomObject]@{
            Name = "build-info.json"
            Version = [string]$ProjectContext.BuildInfo.version
        })
    }

    $ManifestPath = Join-Path $ProjectContext.ProjectFolder "manifest.json"
    if (Test-Path -LiteralPath $ManifestPath -PathType Leaf)
    {
        $Manifest = Read-JsonFile -Path $ManifestPath -DisplayName "manifest.json"
        if ($null -ne $Manifest.PSObject.Properties["version"])
        {
            $Items.Add([PSCustomObject]@{
                Name = "manifest.json"
                Version = [string]$Manifest.version
            })
        }
    }

    $ServiceWorkerPath =
        Join-Path $ProjectContext.ProjectFolder "service-worker.js"

    $ServiceWorkerVersion =
        Get-ServiceWorkerReportedVersion -Path $ServiceWorkerPath

    if (-not [string]::IsNullOrWhiteSpace($ServiceWorkerVersion))
    {
        $Items.Add([PSCustomObject]@{
            Name = "service-worker.js"
            Version = $ServiceWorkerVersion
        })
    }

    return @($Items)
}

function Show-MetadataConsistency
{
    [CmdletBinding()]
    param
    (
        [Parameter(Mandatory = $true)]
        [PSCustomObject]$ProjectContext
    )

    $ProjectContext.MetadataVersions =
        @(Get-MetadataVersionSnapshot -ProjectContext $ProjectContext)

    if ($ProjectContext.MetadataVersions.Count -le 1)
    {
        return
    }

    $Expected = [string]$ProjectContext.Release.version
    $Mismatches = @(
        $ProjectContext.MetadataVersions |
        Where-Object {
            -not [string]::IsNullOrWhiteSpace($_.Version) -and
            $_.Version -ne $Expected
        }
    )

    if ($Mismatches.Count -eq 0)
    {
        Write-Status `
            -Status Success `
            -Message "Project metadata versions are consistent"

        return
    }

    Write-Status `
        -Status Warning `
        -Message "Project metadata versions differ and will be synchronised."

    foreach ($Item in $ProjectContext.MetadataVersions)
    {
        $VersionText =
            if ([string]::IsNullOrWhiteSpace($Item.Version))
            {
                "(not set)"
            }
            else
            {
                $Item.Version
            }

        Write-Host ("       {0,-20} {1}" -f $Item.Name, $VersionText)
    }
}

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

    $BeginMarker = "<!-- PROJECTCREATERELEASE:BEGIN -->"
    $EndMarker = "<!-- PROJECTCREATERELEASE:END -->"

    $HasBeginMarker = $Readme.IndexOf($BeginMarker) -ge 0
    $HasEndMarker = $Readme.IndexOf($EndMarker) -ge 0

    if ($HasBeginMarker -xor $HasEndMarker)
    {
        Write-Status `
            -Status Warning `
            -Message "README contains only one release history marker."

        Write-Status `
            -Status Warning `
            -Message "README was left unchanged."

        return $Readme.TrimEnd() + [Environment]::NewLine
    }

    $HasMarkers = $HasBeginMarker -and $HasEndMarker
    $ShouldInitialiseHistory =
        $ProjectContext.IsNewProject -or
        $ProjectContext.ReadmeWasMissing

    if (-not $HasMarkers -and -not $ShouldInitialiseHistory)
    {
        Write-Status `
            -Status Warning `
            -Message "README release history markers not found."

        Write-Status `
            -Status Warning `
            -Message "README was left unchanged."

        return $Readme.TrimEnd() + [Environment]::NewLine
    }

    $ExistingRows = @()

    if ($HasMarkers)
    {
        $ExistingBlock = [regex]::Match(
            $Readme,
            "(?s)<!-- PROJECTCREATERELEASE:BEGIN -->.*?<!-- PROJECTCREATERELEASE:END -->"
        ).Value

        $ExistingRows = @(
            $ExistingBlock -split '\r?\n' |
            Where-Object {
                $_ -match '^\|\s*v\d+\.\d+\.\d+\s*\|'
            }
        )
    }

    $Note =
        if ([string]::IsNullOrWhiteSpace(
            $ProjectContext.ReleaseHistoryNote
        ))
        {
            "Release created."
        }
        else
        {
            $ProjectContext.ReleaseHistoryNote
        }

    $NewRow =
        "| $($ProjectContext.TargetTag) | $($ProjectContext.ReleaseType) | $Note |"

    $Rows = @($NewRow)

    foreach ($Row in $ExistingRows)
    {
        if ($Row -notmatch "^\|\s*$([regex]::Escape(
            $ProjectContext.TargetTag
        ))\s*\|")
        {
            $Rows += $Row
        }
    }

    $Rows = @(
        $Rows |
        Select-Object -First $MaximumHistoryEntries
    )

    $Replacement = @(
        $BeginMarker
        ""
        "## Release History"
        ""
        "| Version | Type | Notes |"
        "|---------|------|-------|"
        $Rows
        ""
        $EndMarker
    ) -join [Environment]::NewLine

    if ($HasMarkers)
    {
        $Pattern =
            "(?s)<!-- PROJECTCREATERELEASE:BEGIN -->.*?<!-- PROJECTCREATERELEASE:END -->"

        $Readme = [regex]::Replace(
            $Readme,
            $Pattern,
            [System.Text.RegularExpressions.MatchEvaluator]{
                param($Match)
                $Replacement
            }
        )

        Write-Status `
            -Status Success `
            -Message "README release history updated."
    }
    else
    {
        $Readme =
            $Readme.TrimEnd() +
            [Environment]::NewLine +
            [Environment]::NewLine +
            $Replacement +
            [Environment]::NewLine

        Write-Status `
            -Status Success `
            -Message "README release history initialised."
    }

    $CurrentReleaseBlock = @(
        "## Current Release"
        ""
        "Version: **$($ProjectContext.TargetTag)**"
        ""
        "Generated by ProjectCreateRelease.ps1."
    ) -join [Environment]::NewLine

    $CurrentReleasePattern =
        "(?ms)^## Current Release\s*.*?(?=^---\s*$|^##\s|\z)"

    if ($Readme -match "(?m)^## Current Release\s*$")
    {
        $Readme = [regex]::Replace(
            $Readme,
            $CurrentReleasePattern,
            $CurrentReleaseBlock + [Environment]::NewLine + [Environment]::NewLine
        )
    }

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

function Test-ProjectHasChanges
{
    [CmdletBinding()]
    param
    (
        [Parameter(Mandatory = $true)]
        [PSCustomObject]$ProjectContext
    )

    if ($ProjectContext.SourceMode -eq "Dummy" -or
        $ProjectContext.IsNewProject -or
        $ProjectContext.DryRun)
    {
        return $true
    }

    try
    {
        Push-Location $ProjectContext.ProjectFolder
        $Changes = @(Get-GitStatus)
    }
    finally
    {
        Pop-Location
    }

    return $Changes.Count -gt 0
}

function Write-NothingToDoSummary
{
    [CmdletBinding()]
    param
    (
        [Parameter(Mandatory = $true)]
        [PSCustomObject]$ProjectContext
    )

    $ProjectContext.NoChangesDetected = $true
    $ProjectContext.Stopwatch.Stop()

    Write-Host ""
    Write-Host "=========================================================" -ForegroundColor Yellow
    Write-Host " NOTHING TO COMMIT" -ForegroundColor Yellow
    Write-Host "=========================================================" -ForegroundColor Yellow
    Write-Host ""
    Write-Host "No project changes were detected."
    Write-Host ""

    if (-not $ProjectContext.NoBump)
    {
        Write-Host "Use -Dummy to create a version-only test release."
        Write-Host ""
    }

    Write-Host ("Elapsed Time    : {0:N1} seconds" -f $ProjectContext.Stopwatch.Elapsed.TotalSeconds)
    Write-Host ""
}

function Write-ReleasePlan
{
    [CmdletBinding()]
    param
    (
        [Parameter(Mandatory = $true)]
        [PSCustomObject]$ProjectContext
    )

    if (-not $ProjectContext.DryRun)
    {
        return
    }

    Write-Host ""
    Write-Host "=========================================================" -ForegroundColor Cyan

    if ($ProjectContext.NoBump)
    {
        Write-Host " DEVELOPMENT COMMIT PLAN" -ForegroundColor Cyan
    }
    else
    {
        Write-Host " RELEASE PLAN" -ForegroundColor Cyan
    }

    Write-Host "=========================================================" -ForegroundColor Cyan
    Write-Host ""
    Write-Host "Project         : $($ProjectContext.ProjectName)"
    Write-Host "Project Type    : $($ProjectContext.ProjectType)"
    Write-Host "Source          : $($ProjectContext.SourceMode)"

    if ($null -ne $ProjectContext.SourceZip)
    {
        Write-Host "Change Package  : $($ProjectContext.SourceZip.Name)"
    }

    if ($ProjectContext.IsNewProject)
    {
        Write-Host "Current Version : (new project)"
    }
    else
    {
        Write-Host "Current Version : $($ProjectContext.CurrentVersion)"
    }

    if ($ProjectContext.NoBump)
    {
        Write-Host "Version         : Unchanged"
    }
    else
    {
        Write-Host "Target Version  : $($ProjectContext.TargetVersion)"
        Write-Host "Release Type    : $($ProjectContext.ReleaseType)"
        Write-Host "Tag             : $($ProjectContext.TargetTag)"
    }

    Write-Host ""
    Write-Host "Actions"

    if ($ProjectContext.SourceMode -eq "Zip")
    {
        Write-Host "  - Import newest Change Package"
    }

    if (-not $ProjectContext.NoBump)
    {
        Write-Host "  - Synchronise release metadata"
        Write-Host "  - Update managed README history"
    }

    if ($ProjectContext.HasPackageJson)
    {
        Write-Host "  - Run npm install"
    }

    Write-Host "  - Commit: $($ProjectContext.CommitMessage)"
    Write-Host "  - Push commit(s)"

    if (-not $ProjectContext.NoBump)
    {
        Write-Host "  - Record build metadata"
        Write-Host "  - Create and push tag $($ProjectContext.TargetTag)"
    }

    Write-Host ""
}

#region Release File Updates

function Set-ReleaseFiles
{
    [CmdletBinding()]
    param
    (
        [Parameter(Mandatory = $true)]
        [PSCustomObject]$ProjectContext
    )

    if ($ProjectContext.NoBump)
    {
        Write-Status -Status Success -Message "Release metadata unchanged (-NoBump)"
        return
    }

    if ($ProjectContext.DryRun -and $ProjectContext.IsNewProject)
    {
        Write-Status `
            -Status Warning `
            -Message "Dry run: initial release files were not changed."

        Write-Host "       Would initialise README release history."
        return
    }

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

        if ($ProjectContext.HasPackageJson)
        {
            Write-Host "       Would update: package.json"
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
        "build-info.json"
        "package.json"
    ))
    {
        if (-not $UpdatedFiles.ContainsKey($FileName))
        {
            continue
        }

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

    if (-not $ProjectContext.HasPackageJson) { return }

    if ($ProjectContext.DryRun)
    {
        if (-not $ProjectContext.NoBump)
        {
            Write-Host "       Would validate: release metadata"
        }
        Write-Host "       Would run: npm install"
        return
    }

    Write-Status -Status Progress -Message "Running npm install"
    try
    {
        Push-Location $ProjectContext.ProjectFolder
        Invoke-NativeCommand -Command "npm.cmd" -Arguments @("install")
    }
    catch
    {
        Stop-ProjectRelease "npm install failed: $($_.Exception.Message)"
    }
    finally
    {
        Pop-Location
    }

    if (-not $ProjectContext.NoBump)
    {
        Assert-ReleaseMetadata -ProjectContext $ProjectContext
    }

    Write-Status -Status Success -Message "npm install completed"
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
        if ($ProjectContext.NoBump)
        {
            Write-Status -Status Warning -Message "Dry run: Git commit and push were not performed."
            Write-Host "       Would commit: $($ProjectContext.CommitMessage)"
            Write-Host "       Would push commit"
        }
        else
        {
            Write-Status -Status Warning -Message "Dry run: Git commit, push and tag were not performed."
            Write-Host "       Would commit: $($ProjectContext.CommitMessage)"
            Write-Host "       Would tag: $($ProjectContext.TargetTag)"
            Write-Host "       Would push commits and tag"
        }
        return
    }

    try
    {
        Push-Location $ProjectContext.ProjectFolder

        $PreparationMessage =
            if ($ProjectContext.NoBump) { "Preparing Git development commit" }
            else { "Preparing Git release" }

        Write-Status -Status Progress -Message $PreparationMessage

        $GitIgnorePath = Join-Path -Path $ProjectContext.ProjectFolder -ChildPath ".gitignore"
        Ensure-GitIgnoreEntry -GitIgnorePath $GitIgnorePath -Entry ".vs/"

        Invoke-NativeCommand -Command "git.exe" -Arguments @(
            "rm", "-r", "--cached", "--ignore-unmatch", ".vs"
        )

        if (-not $ProjectContext.NoBump)
        {
            Assert-ReleaseMetadata -ProjectContext $ProjectContext
        }

        Invoke-NativeCommand -Command "git.exe" -Arguments @("add", "--all")
        $PendingChanges = @(Get-GitStatus)
        if ($PendingChanges.Count -eq 0) { throw "No Git changes remain to commit." }

        Invoke-NativeCommand -Command "git.exe" -Arguments @(
            "commit", "-m", $ProjectContext.CommitMessage
        )

        $CommitStatus =
            if ($ProjectContext.NoBump) { "Development changes committed" }
            else { "Project changes committed" }
        Write-Status -Status Success -Message $CommitStatus

        $ProjectContext.ContentCommit = Get-GitHead

        # NoBump deliberately skips build-info.json and the second commit.
        if (-not $ProjectContext.NoBump)
        {
            Set-FinalBuildInfo -ProjectContext $ProjectContext
            Invoke-NativeCommand -Command "git.exe" -Arguments @("add", "--", "build-info.json")

            $BuildInfoChanges = @(git.exe status --porcelain -- build-info.json)
            if ($LASTEXITCODE -ne 0) { throw "Unable to check build-info.json status." }

            if ($BuildInfoChanges.Count -gt 0)
            {
                Invoke-NativeCommand -Command "git.exe" -Arguments @(
                    "commit", "-m", "Record build metadata for $($ProjectContext.TargetTag)"
                )
                Write-Status -Status Success -Message "Build metadata recorded"
            }
        }

        $ProjectContext.FinalCommit = Get-GitHead
        Invoke-NativeCommand -Command "git.exe" -Arguments @("push")
        Write-Status -Status Success -Message "Changes pushed"

        # NoBump deliberately creates no tag.
        if (-not $ProjectContext.NoBump)
        {
            Invoke-NativeCommand -Command "git.exe" -Arguments @("tag", $ProjectContext.TargetTag)
            Invoke-NativeCommand -Command "git.exe" -Arguments @("push", "origin", $ProjectContext.TargetTag)
            Write-Status -Status Success -Message "Tag created and pushed: $($ProjectContext.TargetTag)"
        }

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

    if ($ProjectContext.Stopwatch.IsRunning)
    {
        $ProjectContext.Stopwatch.Stop()
    }

    $DryRunText = if ($ProjectContext.DryRun) { "Yes" } else { "No" }

    Write-Host ""
    Write-Host "=========================================================" -ForegroundColor Green

    if ($ProjectContext.IsNewProject -and -not $ProjectContext.DryRun)
    {
        Write-Host " INITIAL PROJECT CREATED" -ForegroundColor Green
    }
    elseif ($ProjectContext.NoBump)
    {
        if ($ProjectContext.DryRun)
        {
            Write-Host " DEVELOPMENT COMMIT DRY RUN COMPLETE" -ForegroundColor Green
        }
        else
        {
            Write-Host " DEVELOPMENT COMMIT COMPLETE" -ForegroundColor Green
        }
    }
    elseif ($ProjectContext.DryRun)
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
    Write-Host "Project Type    : $($ProjectContext.ProjectType)"
    Write-Host "Source          : $($ProjectContext.SourceMode)"

    if ($null -ne $ProjectContext.SourceZip)
    {
        Write-Host "Change Package  : $($ProjectContext.SourceZip.Name)"
    }

    if ($ProjectContext.IsNewProject)
    {
        Write-Host "Current Version : (new project)"
    }
    else
    {
        Write-Host "Current Version : $($ProjectContext.CurrentVersion)"
    }

    if ($ProjectContext.NoBump)
    {
        Write-Host "Version         : Unchanged"
        Write-Host "Commit Message  : $($ProjectContext.CommitMessage)"
    }
    else
    {
        Write-Host "Target Version  : $($ProjectContext.TargetVersion)"
        Write-Host "Release Type    : $($ProjectContext.ReleaseType)"
        Write-Host "Tag             : $($ProjectContext.TargetTag)"
    }

    Write-Host "Dry Run         : $DryRunText"

    if ($ProjectContext.IsNewProject -and
        $ProjectContext.CreatedFiles.Count -gt 0)
    {
        Write-Host ""
        Write-Host "Created Files"

        foreach ($FileName in $ProjectContext.CreatedFiles)
        {
            Write-Host "  $FileName"
        }
    }

    if (-not [string]::IsNullOrWhiteSpace($ProjectContext.FinalCommit))
    {
        Write-Host "Commit          : $($ProjectContext.FinalCommit.Substring(
            0, [Math]::Min(12, $ProjectContext.FinalCommit.Length)
        ))"
    }

    Write-Host ("Elapsed Time    : {0:N1} seconds" -f $ProjectContext.Stopwatch.Elapsed.TotalSeconds)
    Write-Host ""
}

#endregion Summary

#region Main

try
{
    Show-Banner `
        -ProjectContext $ProjectContext

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

    Set-ProjectType `
        -ProjectContext $ProjectContext

    Show-MetadataConsistency `
        -ProjectContext $ProjectContext

    Initialize-ChangeSource `
        -ProjectContext $ProjectContext

    Refresh-ImportedProjectContent `
        -ProjectContext $ProjectContext

    if (-not (Test-ProjectHasChanges -ProjectContext $ProjectContext))
    {
        Write-NothingToDoSummary `
            -ProjectContext $ProjectContext

        exit 0
    }

    Get-TargetVersion `
        -ProjectContext $ProjectContext

    Write-ReleasePlan `
        -ProjectContext $ProjectContext

    if (-not $ProjectContext.NoBump)
    {
        Test-TargetTagAvailable `
            -ProjectContext $ProjectContext
    }

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
