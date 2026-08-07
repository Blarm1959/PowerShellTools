# ============================================================
# Blarm Generic Project Creator
#
# Bootstraps a newly created/cloned project with the standard
# files defined in ProjectCreate.json.
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