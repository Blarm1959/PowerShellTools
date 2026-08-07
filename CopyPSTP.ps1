# ============================================================
# Copy PSTP launchers
#
# The folder containing this script is the master folder.
#
# Master:
#   <MasterFolder>\PSTP.ps1
#
# Searches recursively beneath the parent of the master folder.
#
# For every folder containing PSTP.ps1 or Release.ps1:
#   - Copy the master PSTP.ps1 into that folder
#   - Overwrite an existing PSTP.ps1
#   - Delete Release.ps1 if present
# ============================================================

$masterFolder = $PSScriptRoot
$masterPSTP   = Join-Path $masterFolder "PSTP.ps1"
$searchRoot   = Split-Path $masterFolder -Parent

if (-not (Test-Path -LiteralPath $masterPSTP -PathType Leaf)) {
    Write-Host ""
    Write-Host "[ERROR] Master PSTP.ps1 not found:" -ForegroundColor Red
    Write-Host "        $masterPSTP"
    Write-Host ""
    exit 1
}

Write-Host ""
Write-Host "Master PSTP:"
Write-Host "  $masterPSTP"
Write-Host ""
Write-Host "Search root:"
Write-Host "  $searchRoot"
Write-Host ""

# Find all folders containing either PSTP.ps1 or Release.ps1.
$folders = Get-ChildItem -Path $searchRoot -Recurse -File |
    Where-Object {
        $_.Name -ieq "PSTP.ps1" -or
        $_.Name -ieq "Release.ps1"
    } |
    Where-Object {
        $_.DirectoryName -ne $masterFolder
    } |
    Select-Object -ExpandProperty DirectoryName -Unique

foreach ($folder in $folders) {

    $targetPSTP = Join-Path $folder "PSTP.ps1"
    $oldRelease = Join-Path $folder "Release.ps1"

    Write-Host "Updating: $folder"

    Copy-Item `
        -LiteralPath $masterPSTP `
        -Destination $targetPSTP `
        -Force

    Write-Host "  [OK] PSTP.ps1 copied"

    if (Test-Path -LiteralPath $oldRelease -PathType Leaf) {
        Remove-Item -LiteralPath $oldRelease -Force
        Write-Host "  [OK] Release.ps1 removed"
    }

    Write-Host ""
}

Write-Host "Complete."
Write-Host "Updated $($folders.Count) folder(s)."