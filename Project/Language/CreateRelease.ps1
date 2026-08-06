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

$SearchFolder = Get-Item -LiteralPath $PSScriptRoot
$ToolPath = $null

while ($SearchFolder -ne $null)
{
    $Candidate = Join-Path `
        -Path $SearchFolder.FullName `
        -ChildPath "PowerShellTools\Project\Release\ProjectCreateRelease.ps1"

    if (Test-Path -LiteralPath $Candidate -PathType Leaf)
    {
        $ToolPath = $Candidate
        break
    }

    $SearchFolder = $SearchFolder.Parent
}

if (-not $ToolPath)
{
    Write-Host ""
    Write-Host "[FAIL] ProjectCreateRelease.ps1 not found." -ForegroundColor Red
    Write-Host "       Searched upwards from:"
    Write-Host "       $PSScriptRoot"
    exit 1
}

& $ToolPath `
    -ProjectFolder $PSScriptRoot `
    @args

exit $LASTEXITCODE