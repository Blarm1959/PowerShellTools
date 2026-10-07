# ============================================================
# Blarm Generic Project Creator
#
# Bootstraps a newly created/cloned project with the standard
# files defined in ProjectCreate.json, then commits and pushes
# the bootstrap changes to GitHub.
#
# Usage:
#   .\ProjectCreate.ps1 <ProjectName>
#
# Example:
#   .\ProjectCreate.ps1 BXTest
#
# Expected structure:
#
#   GitHub\
#     PowerShellTools\
#       ProjectCreate.ps1
#       ProjectCreate.json
#       .gitattributes
#       PSTP.ps1
#
#     BXTest\
#
# ProjectCreate.json contains the list of files to copy from
# the PowerShellTools root into the new project.
#
# ProjectCreate commits its bootstrap changes as "ProjectCreate"
# and pushes them to the project's origin remote.
#
# ProjectRelease is responsible for all subsequent project
# metadata, versioning, commits, releases and Git operations.
# ============================================================

param(
    [Parameter(Mandatory = $true, Position = 0)]
    [string]$ProjectName
)

$ErrorActionPreference = "Stop"

# ------------------------------------------------------------
# Resolve folders and configuration
# ------------------------------------------------------------

# ProjectCreate.ps1 lives in the PowerShellTools root.
$powerShellToolsRoot = $PSScriptRoot

# Projects are direct children of the folder containing
# PowerShellTools.
$githubRoot    = Split-Path $powerShellToolsRoot -Parent
$projectFolder = Join-Path $githubRoot $ProjectName

# ProjectCreate.json also lives in the PowerShellTools root.
$configFile = Join-Path $powerShellToolsRoot "ProjectCreate.json"

# ------------------------------------------------------------
# Header
# ------------------------------------------------------------

Write-Host ""
Write-Host "========================================================="
Write-Host " Blarm Generic Project Creator"
Write-Host "========================================================="
Write-Host ""

# ------------------------------------------------------------
# Validate project name
# ------------------------------------------------------------

if ([string]::IsNullOrWhiteSpace($ProjectName)) {
    Write-Host "[ERROR] Project name cannot be empty." -ForegroundColor Red
    exit 1
}

# ProjectName must be a direct child folder name, not a path.
if ($ProjectName.Contains("\") -or $ProjectName.Contains("/")) {
    Write-Host "[ERROR] Project name must be a repository name, not a path." -ForegroundColor Red
    Write-Host "        Example: BXTest"
    exit 1
}

# ------------------------------------------------------------
# Validate configuration
# ------------------------------------------------------------

if (-not (Test-Path -LiteralPath $configFile -PathType Leaf)) {
    Write-Host "[ERROR] ProjectCreate.json not found:" -ForegroundColor Red
    Write-Host "        $configFile"
    exit 1
}

try {
    $config = Get-Content -LiteralPath $configFile -Raw |
        ConvertFrom-Json
}
catch {
    Write-Host "[ERROR] ProjectCreate.json is not valid JSON." -ForegroundColor Red
    Write-Host "        $($_.Exception.Message)"
    exit 1
}

if (-not $config.files -or $config.files.Count -eq 0) {
    Write-Host "[ERROR] ProjectCreate.json contains no files to copy." -ForegroundColor Red
    exit 1
}

# ------------------------------------------------------------
# Validate target project
# ------------------------------------------------------------

if (-not (Test-Path -LiteralPath $projectFolder -PathType Container)) {
    Write-Host "[ERROR] Project folder not found:" -ForegroundColor Red
    Write-Host "        $projectFolder"
    Write-Host ""
    Write-Host "Create/clone the GitHub repository first, then run ProjectCreate."
    exit 1
}

Write-Host "[ OK ] Project folder: $projectFolder"

# ------------------------------------------------------------
# Validate Git repository and clean working tree
# ------------------------------------------------------------

Write-Host "[....] Validating Git repository"

$insideWorkTree = & git -C $projectFolder rev-parse --is-inside-work-tree 2>&1

if ($LASTEXITCODE -ne 0 -or "$insideWorkTree".Trim() -ne "true") {
    Write-Host "[ERROR] Project folder is not a Git repository:" -ForegroundColor Red
    Write-Host "        $projectFolder"
    Write-Host ""
    Write-Host "Create/clone the GitHub repository first, then run ProjectCreate."
    exit 1
}

Write-Host "[ OK ] Git repository found"

$existingChanges = @(& git -C $projectFolder status --porcelain 2>&1)

if ($LASTEXITCODE -ne 0) {
    Write-Host "[ERROR] Unable to read Git working-tree status." -ForegroundColor Red
    $existingChanges | ForEach-Object { Write-Host "        $_" }
    exit 1
}

if ($existingChanges.Count -gt 0) {
    Write-Host "[ERROR] The target repository already contains uncommitted changes." -ForegroundColor Red
    Write-Host ""
    $existingChanges | ForEach-Object { Write-Host "        $_" }
    Write-Host ""
    Write-Host "Commit, discard or otherwise resolve these changes before running ProjectCreate."
    Write-Host "This prevents ProjectCreate from accidentally including unrelated work."
    exit 1
}

Write-Host "[ OK ] Working tree clean"

$originUrl = & git -C $projectFolder remote get-url origin 2>&1

if ($LASTEXITCODE -ne 0 -or [string]::IsNullOrWhiteSpace("$originUrl")) {
    Write-Host "[ERROR] Git remote 'origin' is not configured." -ForegroundColor Red
    Write-Host ""
    Write-Host "ProjectCreate requires the repository to have been cloned from GitHub."
    exit 1
}

Write-Host "[ OK ] Git remote: origin"

# ------------------------------------------------------------
# Validate all source files before copying anything
# ------------------------------------------------------------

Write-Host "[....] Validating standard project files"

$filesToCopy = @()

foreach ($relativeFile in $config.files) {

    if ([string]::IsNullOrWhiteSpace([string]$relativeFile)) {
        Write-Host "[ERROR] ProjectCreate.json contains an empty file name." -ForegroundColor Red
        exit 1
    }

    $relativeFile = [string]$relativeFile

    # Files must be relative to the PowerShellTools root.
    if ([System.IO.Path]::IsPathRooted($relativeFile) -or
        $relativeFile -match '(^|[\\/])\.\.([\\/]|$)') {

        Write-Host "[ERROR] Invalid file path in ProjectCreate.json:" -ForegroundColor Red
        Write-Host "        $relativeFile"
        Write-Host ""
        Write-Host "File paths must be relative to the PowerShellTools root."
        exit 1
    }

    $sourceFile = Join-Path $powerShellToolsRoot $relativeFile
    $targetFile = Join-Path $projectFolder $relativeFile

    if (-not (Test-Path -LiteralPath $sourceFile -PathType Leaf)) {
        Write-Host "[ERROR] Standard project file not found:" -ForegroundColor Red
        Write-Host "        $sourceFile"
        exit 1
    }

    $filesToCopy += [PSCustomObject]@{
        RelativeFile = $relativeFile
        SourceFile   = $sourceFile
        TargetFile   = $targetFile
    }

    Write-Host "[ OK ] Found: $relativeFile"
}

# ------------------------------------------------------------
# Copy standard project files
# ------------------------------------------------------------

Write-Host "[....] Copying standard project files"

foreach ($file in $filesToCopy) {

    $targetDirectory = Split-Path $file.TargetFile -Parent

    if (-not (Test-Path -LiteralPath $targetDirectory -PathType Container)) {
        New-Item `
            -ItemType Directory `
            -Path $targetDirectory `
            -Force |
            Out-Null
    }

    Copy-Item `
        -LiteralPath $file.SourceFile `
        -Destination $file.TargetFile `
        -Force

    Write-Host "[ OK ] Created: $($file.RelativeFile)"
}

# ------------------------------------------------------------
# Stage ProjectCreate files only
# ------------------------------------------------------------

Write-Host "[....] Staging ProjectCreate files"

foreach ($file in $filesToCopy) {
    & git -C $projectFolder add -- $file.RelativeFile

    if ($LASTEXITCODE -ne 0) {
        Write-Host "[ERROR] Failed to stage:" -ForegroundColor Red
        Write-Host "        $($file.RelativeFile)"
        exit 1
    }
}

$stagedChanges = @(& git -C $projectFolder diff --cached --name-only 2>&1)

if ($LASTEXITCODE -ne 0) {
    Write-Host "[ERROR] Unable to inspect staged ProjectCreate changes." -ForegroundColor Red
    $stagedChanges | ForEach-Object { Write-Host "        $_" }
    exit 1
}

if ($stagedChanges.Count -eq 0) {
    Write-Host "[ OK ] Repository already contains the current ProjectCreate files"
    Write-Host ""
    Write-Host "Project bootstrap complete." -ForegroundColor Green
    Write-Host ""
    Write-Host "Next:"
    Write-Host "  cd `"$projectFolder`""
    Write-Host "  .\PSTP.ps1 Release"
    Write-Host ""
    exit 0
}

$unexpectedStaged = @(
    $stagedChanges | Where-Object {
        $_ -notin $filesToCopy.RelativeFile
    }
)

if ($unexpectedStaged.Count -gt 0) {
    Write-Host "[ERROR] Unexpected staged files were detected:" -ForegroundColor Red
    $unexpectedStaged | ForEach-Object { Write-Host "        $_" }
    Write-Host ""
    Write-Host "ProjectCreate will not create a commit containing unrelated files."
    exit 1
}

$stagedChanges | ForEach-Object {
    Write-Host "[ OK ] Staged: $_"
}

# ------------------------------------------------------------
# Commit bootstrap
# ------------------------------------------------------------

Write-Host "[....] Committing ProjectCreate changes"

$commitOutput = @(& git -C $projectFolder commit -m "ProjectCreate" 2>&1)

if ($LASTEXITCODE -ne 0) {
    Write-Host "[ERROR] Git commit failed." -ForegroundColor Red
    $commitOutput | ForEach-Object { Write-Host "        $_" }
    exit 1
}

Write-Host "[ OK ] Commit created: ProjectCreate"

# ------------------------------------------------------------
# Push bootstrap to GitHub
# ------------------------------------------------------------

Write-Host "[....] Pushing ProjectCreate changes to GitHub"

$branch = (& git -C $projectFolder branch --show-current 2>&1).Trim()

if ($LASTEXITCODE -ne 0 -or [string]::IsNullOrWhiteSpace($branch)) {
    Write-Host "[ERROR] Unable to determine the current Git branch." -ForegroundColor Red
    Write-Host ""
    Write-Host "The ProjectCreate commit has been created locally but was not pushed."
    exit 1
}

$upstream = & git -C $projectFolder rev-parse --abbrev-ref --symbolic-full-name '@{u}' 2>$null

if ($LASTEXITCODE -eq 0 -and -not [string]::IsNullOrWhiteSpace("$upstream")) {
    $pushOutput = @(& git -C $projectFolder push 2>&1)
}
else {
    $pushOutput = @(& git -C $projectFolder push -u origin $branch 2>&1)
}

if ($LASTEXITCODE -ne 0) {
    Write-Host "[ERROR] Git push failed." -ForegroundColor Red
    $pushOutput | ForEach-Object { Write-Host "        $_" }
    Write-Host ""
    Write-Host "The ProjectCreate commit exists locally and can be pushed manually."
    exit 1
}

Write-Host "[ OK ] ProjectCreate changes published to GitHub"

# ------------------------------------------------------------
# Complete
# ------------------------------------------------------------

Write-Host ""
Write-Host "Project bootstrap complete." -ForegroundColor Green
Write-Host ""
Write-Host "Next:"
Write-Host "  cd `"$projectFolder`""
Write-Host "  .\PSTP.ps1 Release"
Write-Host ""

exit 0
