<#
.SYNOPSIS
    Project Release Creator shortcut.

.DESCRIPTION
    Transparently forwards every supplied argument to the generic
    ProjectCreateRelease.ps1 tool and supplies only the current project folder.

    The wrapper deliberately has no param() block. This means new parameters
    added to ProjectCreateRelease.ps1 are automatically supported without
    requiring this file to be changed.
#>

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
    @args

exit $LASTEXITCODE