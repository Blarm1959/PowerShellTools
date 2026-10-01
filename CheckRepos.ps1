<#
.SYNOPSIS
    Checks that every Git repo on this laptop is up to date with GitHub.

.DESCRIPTION
    Scans the folder that holds all the repos (by default the parent of the
    PowerShellTools folder this script lives in), fetches each repo and
    reports whether the current branch is up to date, behind, ahead or
    diverged, and whether there are uncommitted changes or stashes.

    It then lists any GitHub repos for the owner that are not cloned on this
    laptop. With the GitHub CLI (gh) logged in this covers private repos too;
    without it only public repos can be checked.

    Nothing is changed in any repo apart from the fetch.

    Exit code: 0 when everything is up to date, 1 when anything needs action.

.PARAMETER Root
    Folder containing the repos. Default: parent of the PowerShellTools repo.

.PARAMETER Owner
    GitHub owner for the missing-repo check. Default: taken from this repo's
    origin URL.

.PARAMETER NoFetch
    Skip 'git fetch' and report against the last fetched state.

.EXAMPLE
    .\CheckRepos.ps1

.EXAMPLE
    .\CheckRepos.ps1 -NoFetch
#>

[CmdletBinding()]
param(
    [string]$Root,
    [string]$Owner,
    [switch]$NoFetch
)

$ScriptVersion = '1.0.0'   # 1.0.0 - first version

# Never let git stop and wait for a password prompt.
$env:GIT_TERMINAL_PROMPT = '0'

if (-not (Get-Command git -ErrorAction SilentlyContinue)) {
    Write-Host '[FAIL] git is not on the PATH.' -ForegroundColor Red
    exit 1
}

# ------------------------------------------------------------
# Locate the repos folder and the GitHub owner
# ------------------------------------------------------------

$toolsRepo = git -C $PSScriptRoot rev-parse --show-toplevel 2>$null
if (-not $toolsRepo) { $toolsRepo = $PSScriptRoot }

if (-not $Root) {
    $Root = Split-Path -Path $toolsRepo -Parent
}

if (-not (Test-Path -LiteralPath $Root -PathType Container)) {
    Write-Host "[FAIL] Repos folder not found: $Root" -ForegroundColor Red
    exit 1
}

function Get-GitHubName {
    param([string]$Url)
    if ($Url -match 'github\.com[:/]+([^/]+)/(.+?)(\.git)?/?$') {
        return [pscustomobject]@{ Owner = $Matches[1]; Name = $Matches[2] }
    }
    return $null
}

if (-not $Owner) {
    $own = Get-GitHubName (git -C $toolsRepo remote get-url origin 2>$null)
    if ($own) { $Owner = $own.Owner } else { $Owner = 'Blarm1959' }
}

Write-Host ''
Write-Host "CheckRepos v$ScriptVersion  -  $env:COMPUTERNAME  -  $Root" -ForegroundColor Cyan
Write-Host ''

# ------------------------------------------------------------
# Check each repo
# ------------------------------------------------------------

$folders = @(Get-ChildItem -LiteralPath $Root -Directory |
    Where-Object { Test-Path -LiteralPath (Join-Path $_.FullName '.git') } |
    Sort-Object Name)

$results = @()
$i = 0

foreach ($folder in $folders) {
    $i++
    $path = $folder.FullName
    Write-Progress -Activity 'Checking repos' -Status $folder.Name -PercentComplete (100 * $i / [math]::Max($folders.Count, 1))

    $problems = @()
    $ok = $true

    $originUrl = git -C $path remote get-url origin 2>$null
    $gh = Get-GitHubName $originUrl

    if (-not $NoFetch -and $originUrl) {
        $null = git -C $path fetch --all --prune --quiet 2>&1
        if ($LASTEXITCODE -ne 0) { $problems += 'FETCH FAILED'; $ok = $false }
    }

    $branch = git -C $path symbolic-ref --quiet --short HEAD 2>$null

    if (-not $branch) {
        $problems += 'Detached HEAD'
        $ok = $false
    }
    elseif (-not $originUrl) {
        $problems += 'No remote'
        $ok = $false
    }
    else {
        $info = git -C $path for-each-ref --format='%(upstream:short)|%(upstream:track)' "refs/heads/$branch"
        $upstream, $track = "$info" -split '\|', 2

        if (-not $upstream) {
            $problems += 'No upstream'
            $ok = $false
        }
        elseif ($track -match 'gone') {
            $problems += 'Upstream gone'
            $ok = $false
        }
        else {
            $ahead = 0; $behind = 0
            if ($track -match 'ahead (\d+)')  { $ahead  = [int]$Matches[1] }
            if ($track -match 'behind (\d+)') { $behind = [int]$Matches[1] }

            if ($ahead -and $behind) { $problems += "DIVERGED +$ahead/-$behind"; $ok = $false }
            elseif ($behind)         { $problems += "BEHIND $behind - pull";     $ok = $false }
            elseif ($ahead)          { $problems += "AHEAD $ahead - push";       $ok = $false }
        }
    }

    $dirty = @(git -C $path status --porcelain 2>$null).Count
    if ($dirty) { $problems += "$dirty uncommitted"; $ok = $false }

    $stashes = @(git -C $path stash list 2>$null).Count
    if ($stashes) { $problems += "$stashes stash(es)"; $ok = $false }

    $status = 'Up to date'
    if ($problems.Count) { $status = $problems -join ' | ' }

    $remoteName = ''
    if ($gh) { $remoteName = $gh.Name }

    $results += [pscustomobject]@{
        Repo   = $folder.Name
        Branch = $branch
        Status = $status
        OK     = $ok
        Remote = $remoteName
        Owner  = if ($gh) { $gh.Owner } else { '' }
    }
}

Write-Progress -Activity 'Checking repos' -Completed

# ------------------------------------------------------------
# Report
# ------------------------------------------------------------

$nameWidth   = [math]::Max(4, ($results | ForEach-Object { $_.Repo.Length }   | Measure-Object -Maximum).Maximum)
$branchWidth = [math]::Max(6, ($results | ForEach-Object { "$($_.Branch)".Length } | Measure-Object -Maximum).Maximum)

Write-Host ('{0}  {1}  {2}' -f 'Repo'.PadRight($nameWidth), 'Branch'.PadRight($branchWidth), 'Status')
Write-Host ('{0}  {1}  {2}' -f ('-' * $nameWidth), ('-' * $branchWidth), ('-' * 6))

foreach ($r in $results) {
    $colour = 'Green'
    if (-not $r.OK) { $colour = 'Yellow' }
    if ($r.Status -match 'BEHIND|DIVERGED|FAILED|gone') { $colour = 'Red' }
    Write-Host ('{0}  {1}  {2}' -f $r.Repo.PadRight($nameWidth), "$($r.Branch)".PadRight($branchWidth), $r.Status) -ForegroundColor $colour
}

$needAction = @($results | Where-Object { -not $_.OK })

Write-Host ''
if ($needAction.Count) {
    Write-Host "$($needAction.Count) of $($results.Count) repos need attention." -ForegroundColor Yellow
}
else {
    Write-Host "All $($results.Count) repos are up to date." -ForegroundColor Green
}

# ------------------------------------------------------------
# GitHub repos not cloned on this laptop
# ------------------------------------------------------------

$localNames = @($results | Where-Object { $_.Owner -eq $Owner } | ForEach-Object { $_.Remote.ToLower() })
$remoteNames = $null
$scope = ''

if (Get-Command gh -ErrorAction SilentlyContinue) {
    $remoteNames = @(gh repo list $Owner --limit 500 --json name -q '.[].name' 2>$null)
    if ($LASTEXITCODE -ne 0) { $remoteNames = $null } else { $scope = 'all' }
}

if ($null -eq $remoteNames) {
    try {
        $api = Invoke-RestMethod -Uri "https://api.github.com/users/$Owner/repos?per_page=100" -UseBasicParsing -ErrorAction Stop
        $remoteNames = @($api | ForEach-Object { $_.name })
        $scope = 'public'
    }
    catch {
        Write-Host ''
        Write-Host "[WARN] Could not list GitHub repos for $Owner, missing-repo check skipped." -ForegroundColor Yellow
    }
}

$missing = @()
if ($null -ne $remoteNames) {
    $missing = @($remoteNames | Where-Object { $_ -and ($localNames -notcontains $_.ToLower()) } | Sort-Object)

    Write-Host ''
    if ($scope -eq 'public') {
        Write-Host "(gh not available: only public $Owner repos checked.)" -ForegroundColor DarkGray
    }
    if ($missing.Count) {
        Write-Host "Not cloned on this laptop ($($missing.Count)):" -ForegroundColor Yellow
        foreach ($m in $missing) { Write-Host "  $m   git clone https://github.com/$Owner/$m.git" }
    }
    else {
        Write-Host "All $scope $Owner repos are cloned here." -ForegroundColor Green
    }
}

Write-Host ''

if ($needAction.Count -or $missing.Count) { exit 1 }
exit 0
