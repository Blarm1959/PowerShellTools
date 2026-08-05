# =====================================================================
# Blarm Generic Project Updater
# Version 1.2.1
#
# Called from each project's Update.ps1:
#
#   & "$PSScriptRoot\..\UpdateProject.ps1" -ProjectRoot $PSScriptRoot
#   exit $LASTEXITCODE
#
# release.json is the preferred single source of truth for release metadata.
# Legacy projects without release.json remain supported.
#
# The updater:
#   1. Finds the newest matching ZIP in Windows Downloads.
#   2. Extracts and validates it before changing the project.
#   3. Replaces project files while preserving .git and local tooling.
#   4. Runs npm install when package.json exists.
#   5. Starts the application if its configured port is not responding.
#   6. Verifies the application server when a port is known.
#   7. Synchronises and validates version metadata from release.json.
#   8. Commits, pushes and tags the update automatically.
#
# Any error stops the process immediately.
# =====================================================================

param(
    [Parameter(Mandatory = $true)]
    [string]$ProjectRoot
)

$ErrorActionPreference = "Stop"
$UpdaterVersion = "1.2.1"

function Write-Step {
    param([string]$Message)
    Write-Host "[....] $Message" -ForegroundColor Cyan
}

function Write-Success {
    param([string]$Message)
    Write-Host "[ OK ] $Message" -ForegroundColor Green
}

function Write-Warning {
    param([string]$Message)
    Write-Host "[WARN] $Message" -ForegroundColor Yellow
}

function Stop-WithError {
    param([string]$Message)

    Write-Host ""
    Write-Host "=========================================================" -ForegroundColor Red
    Write-Host " UPDATE FAILED" -ForegroundColor Red
    Write-Host "=========================================================" -ForegroundColor Red
    Write-Host ""
    Write-Host $Message -ForegroundColor Red
    Write-Host ""

    exit 1
}

function Invoke-NativeCommand {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Command,

        [string[]]$Arguments = @()
    )

    & $Command @Arguments

    if ($LASTEXITCODE -ne 0) {
        throw "'$Command $($Arguments -join ' ')' failed with exit code $LASTEXITCODE."
    }
}

function Test-ApplicationServer {
    param(
        [Parameter(Mandatory = $true)]
        [int]$Port,

        [int]$TimeoutSeconds = 2
    )

    try {
        $response = Invoke-WebRequest `
            -Uri "http://127.0.0.1:$Port/" `
            -UseBasicParsing `
            -TimeoutSec $TimeoutSeconds

        return ($response.StatusCode -ge 200 -and $response.StatusCode -lt 500)
    }
    catch {
        return $false
    }
}

function Get-OptionalJson {
    param([string]$Path)

    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
        return $null
    }

    try {
        return Get-Content `
            -LiteralPath $Path `
            -Raw |
            ConvertFrom-Json
    }
    catch {
        throw "Invalid JSON file: $Path"
    }
}

function Get-VersionFromZipName {
    param([string]$ZipName)

    $match = [regex]::Match(
        $ZipName,
        '(?i)(v\d+\.\d+\.\d+(?:-\d+)?)'
    )

    if ($match.Success) {
        return $match.Groups[1].Value
    }

    return $null
}

function Get-VersionFromPackageJson {
    param([string]$PackageJsonPath)

    $package = Get-OptionalJson -Path $PackageJsonPath

    if ($null -eq $package) {
        return $null
    }

    if ([string]::IsNullOrWhiteSpace([string]$package.version)) {
        return $null
    }

    $version = [string]$package.version

    if ($version.StartsWith("v")) {
        return $version
    }

    return "v$version"
}

function Get-PortFromPackageJson {
    param([string]$PackageJsonPath)

    $package = Get-OptionalJson -Path $PackageJsonPath

    if ($null -eq $package -or $null -eq $package.scripts) {
        return $null
    }

    $startCommand = [string]$package.scripts.start

    if ([string]::IsNullOrWhiteSpace($startCommand)) {
        return $null
    }

    $match = [regex]::Match(
        $startCommand,
        '(?i)(?:-p|--port)(?:=|\s+)(\d{1,5})'
    )

    if (-not $match.Success) {
        return $null
    }

    $port = [int]$match.Groups[1].Value

    if ($port -lt 1 -or $port -gt 65535) {
        throw "Invalid port in package.json start command: $port"
    }

    return $port
}


function Normalize-VersionInfo {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Version
    )

    $trimmed = $Version.Trim()

    if ($trimmed -notmatch '^(?i)v?(\d+\.\d+\.\d+(?:-\d+)?)$') {
        throw "Invalid release version '$Version'. Expected a value such as 0.3.2 or v0.3.2."
    }

    $plainVersion = $Matches[1]

    return [pscustomobject]@{
        Version = $plainVersion
        Tag     = "v$plainVersion"
    }
}

function Write-JsonFile {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Path,

        [Parameter(Mandatory = $true)]
        [object]$Value
    )

    $json = $Value | ConvertTo-Json -Depth 100
    [System.IO.File]::WriteAllText(
        $Path,
        ($json + [Environment]::NewLine),
        [System.Text.UTF8Encoding]::new($false)
    )
}

function Set-JsonVersion {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Path,

        [Parameter(Mandatory = $true)]
        [string]$Version
    )

    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
        return $false
    }

    $json = Get-OptionalJson -Path $Path
    $json.version = $Version
    Write-JsonFile -Path $Path -Value $json
    return $true
}

function Set-BuildInfo {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Path,

        [Parameter(Mandatory = $true)]
        [string]$Project,

        [Parameter(Mandatory = $true)]
        [string]$Version,

        [Parameter(Mandatory = $true)]
        [string]$Tag,

        [Parameter(Mandatory = $true)]
        [string]$BuiltAt,

        [string]$Commit = ""
    )

    $buildInfo = Get-OptionalJson -Path $Path

    if ($null -eq $buildInfo) {
        $buildInfo = [pscustomobject]@{}
    }

    $buildInfo | Add-Member -NotePropertyName project -NotePropertyValue $Project -Force
    $buildInfo | Add-Member -NotePropertyName version -NotePropertyValue $Version -Force
    $buildInfo | Add-Member -NotePropertyName tag -NotePropertyValue $Tag -Force
    $buildInfo | Add-Member -NotePropertyName commit -NotePropertyValue $Commit -Force
    $buildInfo | Add-Member -NotePropertyName builtAt -NotePropertyValue $BuiltAt -Force

    Write-JsonFile -Path $Path -Value $buildInfo
}

function Set-ServiceWorkerVersion {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Path,

        [Parameter(Mandatory = $true)]
        [string]$Version
    )

    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
        return $false
    }

    $content = Get-Content -LiteralPath $Path -Raw
    $original = $content

    # Update semantic versions only on cache/version declaration lines.
    $lines = $content -split "`r?`n"
    for ($index = 0; $index -lt $lines.Count; $index++) {
        if ($lines[$index] -match '(?i)(cache|version)') {
            $lines[$index] = [regex]::Replace(
                $lines[$index],
                '(?i)v?\d+\.\d+\.\d+(?:-\d+)?',
                $Version
            )
        }
    }

    $content = $lines -join [Environment]::NewLine

    if ($content -ne $original) {
        [System.IO.File]::WriteAllText(
            $Path,
            $content,
            [System.Text.UTF8Encoding]::new($false)
        )
        return $true
    }

    return $false
}

function Ensure-GitIgnoreEntry {
    param(
        [Parameter(Mandatory = $true)]
        [string]$GitIgnorePath,

        [Parameter(Mandatory = $true)]
        [string]$Entry
    )

    $lines = @()
    if (Test-Path -LiteralPath $GitIgnorePath -PathType Leaf) {
        $lines = @(Get-Content -LiteralPath $GitIgnorePath)
    }

    if ($lines -contains $Entry) {
        return
    }

    if ($lines.Count -gt 0 -and -not [string]::IsNullOrWhiteSpace($lines[-1])) {
        $lines += ""
    }

    $lines += $Entry
    [System.IO.File]::WriteAllLines(
        $GitIgnorePath,
        $lines,
        [System.Text.UTF8Encoding]::new($false)
    )
}

function Sync-ReleaseMetadata {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Root,

        [Parameter(Mandatory = $true)]
        [string]$Project,

        [Parameter(Mandatory = $true)]
        [string]$Version,

        [Parameter(Mandatory = $true)]
        [string]$Tag,

        [Parameter(Mandatory = $true)]
        [string]$BuiltAt
    )

    $releaseJsonPath = Join-Path $Root 'release.json'
    $packageJsonPath = Join-Path $Root 'package.json'
    $packageLockPath = Join-Path $Root 'package-lock.json'
    $buildInfoPath = Join-Path $Root 'build-info.json'
    $serviceWorkerPath = Join-Path $Root 'service-worker.js'

    [void](Set-JsonVersion -Path $releaseJsonPath -Version $Version)
    [void](Set-JsonVersion -Path $packageJsonPath -Version $Version)

    if (Test-Path -LiteralPath $packageLockPath -PathType Leaf) {
        Write-Host "[ OK ] package-lock.json skipped (managed by npm)" -ForegroundColor Green
    }

    Set-BuildInfo `
        -Path $buildInfoPath `
        -Project $Project `
        -Version $Version `
        -Tag $Tag `
        -BuiltAt $BuiltAt `
        -Commit ''

    [void](Set-ServiceWorkerVersion -Path $serviceWorkerPath -Version $Version)
}

function Assert-ReleaseMetadata {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Root,

        [Parameter(Mandatory = $true)]
        [string]$Version,

        [Parameter(Mandatory = $true)]
        [string]$Tag
    )

    $problems = [System.Collections.Generic.List[string]]::new()

    foreach ($name in @('release.json', 'package.json', 'build-info.json')) {
        $path = Join-Path $Root $name
        if (-not (Test-Path -LiteralPath $path -PathType Leaf)) {
            continue
        }

        $json = Get-OptionalJson -Path $path
        if ($null -ne $json.version -and [string]$json.version -ne $Version) {
            $problems.Add("$name version is '$($json.version)' instead of '$Version'.")
        }
        if ($name -eq 'build-info.json' -and $null -ne $json.tag -and [string]$json.tag -ne $Tag) {
            $problems.Add("build-info.json tag is '$($json.tag)' instead of '$Tag'.")
        }
    }

    $serviceWorkerPath = Join-Path $Root 'service-worker.js'
    if (Test-Path -LiteralPath $serviceWorkerPath -PathType Leaf) {
        $versionLines = @(
            Get-Content -LiteralPath $serviceWorkerPath |
            Where-Object { $_ -match '(?i)(cache|version)' }
        )

        $staleVersions = @(
            foreach ($line in $versionLines) {
                foreach ($match in [regex]::Matches($line, '(?i)v?(\d+\.\d+\.\d+(?:-\d+)?)')) {
                    if ($match.Groups[1].Value -ne $Version) {
                        $match.Value
                    }
                }
            }
        ) | Select-Object -Unique

        if ($staleVersions.Count -gt 0) {
            $problems.Add("service-worker.js still contains release version(s): $($staleVersions -join ', ').")
        }
    }

    if ($problems.Count -gt 0) {
        throw "Release metadata validation failed:`n - $($problems -join "`n - ")"
    }
}

function Find-ExtractedProjectRoot {
    param(
        [Parameter(Mandatory = $true)]
        [string]$ExtractedFolder
    )

    # Prefer release.json when one is present.
    $releaseFiles = @(
        Get-ChildItem `
            -LiteralPath $ExtractedFolder `
            -Filter "release.json" `
            -File `
            -Recurse
    )

    if ($releaseFiles.Count -eq 1) {
        return $releaseFiles[0].Directory.FullName
    }

    if ($releaseFiles.Count -gt 1) {
        throw "The ZIP contains more than one release.json file."
    }

    # Otherwise use a unique package.json.
    $packageFiles = @(
        Get-ChildItem `
            -LiteralPath $ExtractedFolder `
            -Filter "package.json" `
            -File `
            -Recurse |
        Where-Object {
            $_.FullName -notmatch '[\\/](node_modules)[\\/]'
        }
    )

    if ($packageFiles.Count -eq 1) {
        return $packageFiles[0].Directory.FullName
    }

    if ($packageFiles.Count -gt 1) {
        throw "The ZIP contains more than one possible project package.json."
    }

    # Otherwise accept a ZIP containing one top-level project folder.
    $topLevelItems = @(
        Get-ChildItem `
            -LiteralPath $ExtractedFolder `
            -Force
    )

    $topLevelDirectories = @(
        $topLevelItems |
        Where-Object { $_.PSIsContainer }
    )

    $topLevelFiles = @(
        $topLevelItems |
        Where-Object { -not $_.PSIsContainer }
    )

    if (
        $topLevelDirectories.Count -eq 1 -and
        $topLevelFiles.Count -eq 0
    ) {
        return $topLevelDirectories[0].FullName
    }

    # A ZIP may also contain the project directly at its root.
    if ($topLevelItems.Count -gt 0) {
        return $ExtractedFolder
    }

    throw "The ZIP is empty or its project root could not be identified."
}

try {
    $ProjectRoot = [System.IO.Path]::GetFullPath($ProjectRoot)
    $projectName = Split-Path $ProjectRoot -Leaf

    Write-Host ""
    Write-Host "========================================================="
    Write-Host " Blarm Generic Project Updater"
    Write-Host " Version $UpdaterVersion"
    Write-Host "========================================================="
    Write-Host ""

    # -----------------------------------------------------------------
    # Validate local project
    # -----------------------------------------------------------------

    if (-not (Test-Path -LiteralPath $ProjectRoot -PathType Container)) {
        throw "Project folder not found: $ProjectRoot"
    }

    $gitFolder = Join-Path $ProjectRoot ".git"

    if (-not (Test-Path -LiteralPath $gitFolder -PathType Container)) {
        throw "The project does not contain a .git folder."
    }

    $currentReleaseFile = Join-Path $ProjectRoot "release.json"
    $currentRelease = Get-OptionalJson -Path $currentReleaseFile

    if (
        $null -ne $currentRelease -and
        -not [string]::IsNullOrWhiteSpace([string]$currentRelease.project)
    ) {
        $projectName = [string]$currentRelease.project
    }

    $zipPrefix = "$projectName-"

    if (
        $null -ne $currentRelease -and
        -not [string]::IsNullOrWhiteSpace([string]$currentRelease.zipPrefix)
    ) {
        $zipPrefix = [string]$currentRelease.zipPrefix
    }

    Write-Success "Project found: $projectName"
    Write-Success "Project folder: $ProjectRoot"

    # -----------------------------------------------------------------
    # Require clean Git state
    # -----------------------------------------------------------------

    Push-Location $ProjectRoot

    try {
        $gitStatus = @(git status --porcelain)

        if ($LASTEXITCODE -ne 0) {
            throw "Unable to read Git status."
        }

        if ($gitStatus.Count -gt 0) {
            throw "The Git working tree contains uncommitted changes. Commit or discard them before running the updater."
        }
    }
    finally {
        Pop-Location
    }

    Write-Success "Git working tree is clean"

    # -----------------------------------------------------------------
    # Find newest matching ZIP
    # -----------------------------------------------------------------

    $downloadsFolder = Join-Path $env:USERPROFILE "Downloads"

    if (-not (Test-Path -LiteralPath $downloadsFolder -PathType Container)) {
        throw "Windows Downloads folder not found: $downloadsFolder"
    }

    $zip = Get-ChildItem `
        -LiteralPath $downloadsFolder `
        -Filter "$zipPrefix*.zip" `
        -File |
        Sort-Object LastWriteTime -Descending |
        Select-Object -First 1

    if ($null -eq $zip) {
        throw "No '$zipPrefix*.zip' file was found in $downloadsFolder"
    }

    Write-Success "ZIP found: $($zip.Name)"

    # -----------------------------------------------------------------
    # Extract and validate before modifying project
    # -----------------------------------------------------------------

    $temporaryFolder = Join-Path `
        $env:TEMP `
        ("BlarmProjectUpdate-" + [guid]::NewGuid().ToString("N"))

    New-Item `
        -ItemType Directory `
        -Path $temporaryFolder |
        Out-Null

    try {
        Write-Step "Extracting and validating ZIP"

        Expand-Archive `
            -LiteralPath $zip.FullName `
            -DestinationPath $temporaryFolder `
            -Force

        $extractedProjectRoot = Find-ExtractedProjectRoot `
            -ExtractedFolder $temporaryFolder

        $newReleaseFile = Join-Path $extractedProjectRoot "release.json"
        $newRelease = Get-OptionalJson -Path $newReleaseFile

        $newPackageFile = Join-Path $extractedProjectRoot "package.json"
        $hasPackageJson = Test-Path `
            -LiteralPath $newPackageFile `
            -PathType Leaf

        $newProjectName = $projectName

        if (
            $null -ne $newRelease -and
            -not [string]::IsNullOrWhiteSpace([string]$newRelease.project)
        ) {
            $newProjectName = [string]$newRelease.project
        }

        if ($newProjectName -ne $projectName) {
            throw "The ZIP is for '$newProjectName', not '$projectName'."
        }

        # Version priority:
        # 1. release.json
        # 2. ZIP filename
        # 3. package.json
        $version = $null

        if (
            $null -ne $newRelease -and
            -not [string]::IsNullOrWhiteSpace([string]$newRelease.version)
        ) {
            $version = [string]$newRelease.version
        }

        if ([string]::IsNullOrWhiteSpace($version)) {
            $version = Get-VersionFromZipName -ZipName $zip.Name
        }

        if (
            [string]::IsNullOrWhiteSpace($version) -and
            $hasPackageJson
        ) {
            $version = Get-VersionFromPackageJson `
                -PackageJsonPath $newPackageFile
        }

        if ([string]::IsNullOrWhiteSpace($version)) {
            throw "Unable to determine the new version. Put a version such as 1.2.3 in release.json, the ZIP filename, or package.json."
        }

        $versionInfo = Normalize-VersionInfo -Version $version
        $version = $versionInfo.Version
        $tag = $versionInfo.Tag
        $builtAt = (Get-Date).ToUniversalTime().ToString('o')

        if ($null -ne $newRelease) {
            Write-Step "Synchronising release metadata from release.json"

            Sync-ReleaseMetadata `
                -Root $extractedProjectRoot `
                -Project $projectName `
                -Version $version `
                -Tag $tag `
                -BuiltAt $builtAt

            Assert-ReleaseMetadata `
                -Root $extractedProjectRoot `
                -Version $version `
                -Tag $tag

            Write-Success "Release metadata synchronised and validated"
        }
        else {
            Write-Warning "No release.json found; using legacy version detection without metadata propagation"
        }

        # Commit message is optional in release.json.
        $commitMessage = "Update $projectName to $version"

        if (
            $null -ne $newRelease -and
            -not [string]::IsNullOrWhiteSpace([string]$newRelease.commit)
        ) {
            $commitMessage = [string]$newRelease.commit
        }

        # Port is optional. Try release.json, then package.json.
        $port = $null

        if (
            $null -ne $newRelease -and
            $null -ne $newRelease.port
        ) {
            $port = [int]$newRelease.port
        }
        elseif ($hasPackageJson) {
            $port = Get-PortFromPackageJson `
                -PackageJsonPath $newPackageFile
        }

        if (
            $null -ne $port -and
            ($port -lt 1 -or $port -gt 65535)
        ) {
            throw "Invalid development port: $port"
        }

        $githubSource = ""

        if (
            $null -ne $newRelease -and
            -not [string]::IsNullOrWhiteSpace([string]$newRelease.githubSource)
        ) {
            $githubSource = [string]$newRelease.githubSource
        }

        Write-Success "ZIP validated"
        Write-Host ""
        Write-Host "Project : $projectName"
        Write-Host "Version : $version"
        Write-Host "Tag     : $tag"

        if (-not [string]::IsNullOrWhiteSpace($githubSource)) {
            Write-Host "Source  : $githubSource"
        }

        if ($null -ne $port) {
            Write-Host "Port    : $port"
        }

        Write-Host ""

        # -------------------------------------------------------------
        # Replace project contents
        # -------------------------------------------------------------

        Write-Step "Replacing project files"

        $preserveNames = @(
            ".git",
            "node_modules",
            ".vs",
            "Update.ps1"
        )

        Get-ChildItem `
            -LiteralPath $ProjectRoot `
            -Force |
        Where-Object {
            $preserveNames -notcontains $_.Name
        } |
        Remove-Item `
            -Recurse `
            -Force

        Get-ChildItem `
            -LiteralPath $extractedProjectRoot `
            -Force |
        ForEach-Object {
            Copy-Item `
                -LiteralPath $_.FullName `
                -Destination $ProjectRoot `
                -Recurse `
                -Force
        }

        Write-Success "Project files replaced"
    }
    finally {
        if (Test-Path -LiteralPath $temporaryFolder) {
            Remove-Item `
                -LiteralPath $temporaryFolder `
                -Recurse `
                -Force
        }
    }

    # -----------------------------------------------------------------
    # Install/start/test and publish
    # -----------------------------------------------------------------

    Push-Location $ProjectRoot

    try {
        $localPackageFile = Join-Path $ProjectRoot "package.json"
        $hasPackageJson = Test-Path `
            -LiteralPath $localPackageFile `
            -PathType Leaf

        if ($hasPackageJson) {
            Write-Step "Running npm install"

            Invoke-NativeCommand `
                -Command "npm.cmd" `
                -Arguments @("install")

            Write-Success "npm install completed"

            if (Test-Path -LiteralPath (Join-Path $ProjectRoot 'release.json') -PathType Leaf) {
                Assert-ReleaseMetadata `
                    -Root $ProjectRoot `
                    -Version $version `
                    -Tag $tag

                Write-Success "Release metadata remains consistent after npm install"
            }

            $package = Get-OptionalJson -Path $localPackageFile
            $hasStartCommand = (
                $null -ne $package -and
                $null -ne $package.scripts -and
                -not [string]::IsNullOrWhiteSpace(
                    [string]$package.scripts.start
                )
            )

            if ($hasStartCommand) {
                if (
                    $null -ne $port -and
                    (Test-ApplicationServer -Port $port)
                ) {
                    Write-Success "Application server is already running on port $port"
                }
                else {
                    Write-Step "Starting application"

                    $escapedProjectRoot = $ProjectRoot.Replace("'", "''")

                    Start-Process `
                        -FilePath "powershell.exe" `
                        -ArgumentList @(
                            "-NoExit",
                            "-Command",
                            "Set-Location -LiteralPath '$escapedProjectRoot'; npm start"
                        ) |
                        Out-Null

                    if ($null -ne $port) {
                        $serverStarted = $false

                        for ($attempt = 1; $attempt -le 20; $attempt++) {
                            Start-Sleep -Seconds 1

                            if (Test-ApplicationServer -Port $port) {
                                $serverStarted = $true
                                break
                            }
                        }

                        if (-not $serverStarted) {
                            throw "The application did not respond on port $port."
                        }

                        Write-Success "Application server started on port $port"
                    }
                    else {
                        Start-Sleep -Seconds 4
                        Write-Warning "Application started, but no port was available for automatic verification"
                    }
                }
            }
            else {
                Write-Warning "package.json has no npm start command; application start skipped"
            }
        }
        else {
            Write-Warning "No package.json found; npm install and application start skipped"
        }

        # -------------------------------------------------------------
        # Git housekeeping, validation, commit and push
        # -------------------------------------------------------------

        Write-Step "Preparing Git update"

        $gitIgnorePath = Join-Path $ProjectRoot '.gitignore'
        Ensure-GitIgnoreEntry -GitIgnorePath $gitIgnorePath -Entry '.vs/'

        # Preserve the local .vs folder, but stop tracking it if an older
        # version of the repository committed it before .gitignore existed.
        Invoke-NativeCommand `
            -Command "git.exe" `
            -Arguments @(
                "rm",
                "-r",
                "--cached",
                "--ignore-unmatch",
                ".vs"
            )

        if (Test-Path -LiteralPath (Join-Path $ProjectRoot 'release.json') -PathType Leaf) {
            Assert-ReleaseMetadata `
                -Root $ProjectRoot `
                -Version $version `
                -Tag $tag

            Write-Success "Pre-commit release metadata validation passed"
        }

        Invoke-NativeCommand `
            -Command "git.exe" `
            -Arguments @("add", "--all")

        $pendingChanges = @(git status --porcelain)

        if ($LASTEXITCODE -ne 0) {
            throw "Unable to read Git status after updating files."
        }

        if ($pendingChanges.Count -gt 0) {
            Invoke-NativeCommand `
                -Command "git.exe" `
                -Arguments @(
                    "commit",
                    "-m",
                    $commitMessage
                )

            Write-Success "Project changes committed"
        }
        else {
            Write-Warning "No Git file changes were detected"
        }

        $contentCommit = (git rev-parse HEAD).Trim()
        if ($LASTEXITCODE -ne 0) {
            throw "Unable to determine the project commit."
        }

        # A commit cannot contain its own hash. Record the content commit in
        # a small follow-up metadata commit, then tag that final metadata state.
        $buildInfoPath = Join-Path $ProjectRoot 'build-info.json'
        if (Test-Path -LiteralPath $buildInfoPath -PathType Leaf) {
            Set-BuildInfo `
                -Path $buildInfoPath `
                -Project $projectName `
                -Version $version `
                -Tag $tag `
                -BuiltAt $builtAt `
                -Commit $contentCommit

            Invoke-NativeCommand `
                -Command "git.exe" `
                -Arguments @("add", "--", "build-info.json")

            $buildInfoChanges = @(git status --porcelain -- build-info.json)
            if ($LASTEXITCODE -ne 0) {
                throw "Unable to check build-info.json status."
            }

            if ($buildInfoChanges.Count -gt 0) {
                Invoke-NativeCommand `
                    -Command "git.exe" `
                    -Arguments @(
                        "commit",
                        "-m",
                        "Record build information for $tag"
                    )

                Write-Success "Build information recorded"
            }
        }

        $headCommit = (git rev-parse HEAD).Trim()
        if ($LASTEXITCODE -ne 0) {
            throw "Unable to determine the final Git commit."
        }

        Invoke-NativeCommand `
            -Command "git.exe" `
            -Arguments @("push")

        Write-Success "Changes pushed"

        # -------------------------------------------------------------
        # Create or verify version tag
        # -------------------------------------------------------------

        Invoke-NativeCommand `
            -Command "git.exe" `
            -Arguments @("fetch", "--tags", "--quiet")

        $existingTag = git tag --list $tag

        if ($LASTEXITCODE -ne 0) {
            throw "Unable to check Git tags."
        }

        if ([string]::IsNullOrWhiteSpace($existingTag)) {
            Invoke-NativeCommand `
                -Command "git.exe" `
                -Arguments @("tag", $tag)

            Invoke-NativeCommand `
                -Command "git.exe" `
                -Arguments @("push", "origin", $tag)

            Write-Success "Tag created and pushed: $tag"
        }
        else {
            $tagCommit = (
                git rev-list -n 1 $tag
            ).Trim()

            if ($tagCommit -ne $headCommit) {
                throw "Tag '$tag' already exists on a different commit."
            }

            Write-Success "Tag already exists on current commit: $tag"
        }
    }
    finally {
        Pop-Location
    }

    Write-Host ""
    Write-Host "=========================================================" -ForegroundColor Green
    Write-Host " UPDATE COMPLETE" -ForegroundColor Green
    Write-Host "=========================================================" -ForegroundColor Green
    Write-Host ""
    Write-Host "Project : $projectName"
    Write-Host "Version : $version"
    Write-Host "Tag     : $tag"

    if (-not [string]::IsNullOrWhiteSpace($githubSource)) {
        Write-Host "Source  : $githubSource"
    }

    if (-not [string]::IsNullOrWhiteSpace($headCommit)) {
        Write-Host "Commit  : $($headCommit.Substring(0, [Math]::Min(12, $headCommit.Length)))"
    }

    if ($null -ne $port) {
        Write-Host "Address : http://127.0.0.1:$port"
        Write-Host ""
        Write-Host "Press CTRL+F5 in the existing browser window."
    }

    Write-Host ""

    exit 0
}
catch {
    Stop-WithError -Message $_.Exception.Message
}