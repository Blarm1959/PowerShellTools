<#
.SYNOPSIS
    Brings every Git repo on this laptop up to date with GitHub.

.DESCRIPTION
    Works on the folder that holds all the repos (by default the parent of
    the PowerShellTools folder this script lives in). For each repo it
    fetches and then:
      - fast-forwards repos that are behind and have no uncommitted changes
        ('git pull --ff-only');
      - leaves alone, and reports, repos that are behind but dirty, diverged,
        detached or without an upstream;
      - leaves alone repos that are only ahead (push them yourself);
      - clones every GitHub repo for the owner that is missing locally,
        including <Repo>-App repos.

    It then shows the status of every repo: up to date, behind, ahead,
    diverged, uncommitted changes or stashes.

    With the GitHub CLI (gh) logged in, missing private repos are found too;
    without it only public repos can be checked.

    With -L nothing is changed apart from the fetch: it only lists the repos
    and their status, and the missing repos with their clone commands.

    Exit code: 0 when everything is up to date, 1 when anything needs action.

.PARAMETER L
    List only: report status without pulling or cloning. Also -List.

.PARAMETER Root
    Folder containing the repos. Default: parent of the PowerShellTools repo.

.PARAMETER Owner
    GitHub owner for the missing-repo check. Default: taken from this repo's
    origin URL.

.PARAMETER Exclude
    Folder name patterns to skip. Default: '* - Copy'.

.PARAMETER NoFetch
    Skip 'git fetch' (only sensible with -L).

.EXAMPLE
    .\UpdateRepos.ps1

.EXAMPLE
    .\UpdateRepos.ps1 -L
#>

[CmdletBinding()]
param(
    [Alias('List')]
    [switch]$L,
    [string]$Root,
    [string]$Owner,
    [string[]]$Exclude = @('* - Copy'),
    [switch]$NoFetch
)

$ScriptVersion = '1.0.0'   # 1.0.0 - replaces CheckRepos.ps1: updates by default, -L lists only

$U = -not $L

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

$mode = 'update'
if ($L) { $mode = 'list only' }

Write-Host ''
Write-Host "UpdateRepos v$ScriptVersion  -  $env:COMPUTERNAME  -  $Root  ($mode)" -ForegroundColor Cyan
Write-Host ''

# ------------------------------------------------------------
# Helpers
# ------------------------------------------------------------

function Test-Excluded {
    param([string]$Name)
    foreach ($pattern in $Exclude) {
        if ($Name -like $pattern) { return $true }
    }
    return $false
}

function Get-RepoState {
    param([string]$Path)

    $state = [pscustomobject]@{
        Origin   = (git -C $Path remote get-url origin 2>$null)
        Branch   = (git -C $Path symbolic-ref --quiet --short HEAD 2>$null)
        Upstream = ''
        Gone     = $false
        Ahead    = 0
        Behind   = 0
        Dirty    = @(git -C $Path status --porcelain 2>$null).Count
        Stashes  = @(git -C $Path stash list 2>$null).Count
    }

    if ($state.Branch) {
        $info = git -C $Path for-each-ref --format='%(upstream:short)|%(upstream:track)' "refs/heads/$($state.Branch)"
        $upstream, $track = "$info" -split '\|', 2
        $state.Upstream = $upstream
        if ($track -match 'gone')         { $state.Gone   = $true }
        if ($track -match 'ahead (\d+)')  { $state.Ahead  = [int]$Matches[1] }
        if ($track -match 'behind (\d+)') { $state.Behind = [int]$Matches[1] }
    }

    return $state
}

# ------------------------------------------------------------
# Check (and optionally update) each repo
# ------------------------------------------------------------

$allFolders = @(Get-ChildItem -LiteralPath $Root -Directory |
    Where-Object { Test-Path -LiteralPath (Join-Path $_.FullName '.git') } |
    Sort-Object Name)

$folders  = @($allFolders | Where-Object { -not (Test-Excluded $_.Name) })
$skipped  = @($allFolders | Where-Object { Test-Excluded $_.Name })

$results = @()
$i = 0

foreach ($folder in $folders) {
    $i++
    $path = $folder.FullName
    Write-Progress -Activity 'Checking repos' -Status $folder.Name -PercentComplete (100 * $i / [math]::Max($folders.Count, 1))

    $notes = @()
    $fetchFailed = $false

    $originUrl = git -C $path remote get-url origin 2>$null

    if (((-not $NoFetch) -or $U) -and $originUrl) {
        $null = git -C $path fetch --all --prune --quiet 2>&1
        if ($LASTEXITCODE -ne 0) { $fetchFailed = $true }
    }

    $s = Get-RepoState $path

    # ---- Full update: fast-forward when it is safe ----
    $updated = $false
    if ($U -and -not $fetchFailed -and $s.Branch -and $s.Upstream -and -not $s.Gone -and $s.Behind) {
        if ($s.Ahead) {
            $notes += 'not updated (diverged)'
        }
        elseif ($s.Dirty) {
            $notes += 'not updated (uncommitted changes)'
        }
        else {
            $pullOut = git -C $path pull --ff-only --quiet 2>&1
            if ($LASTEXITCODE -eq 0) {
                $notes += "UPDATED +$($s.Behind)"
                $updated = $true
                $s = Get-RepoState $path
            }
            else {
                $notes += 'PULL FAILED'
                Write-Verbose ("{0}: {1}" -f $folder.Name, ($pullOut -join ' '))
            }
        }
    }

    # ---- Status ----
    $problems = @()
    if ($fetchFailed) { $problems += 'FETCH FAILED' }

    if (-not $s.Branch)        { $problems += 'Detached HEAD' }
    elseif (-not $s.Origin)    { $problems += 'No remote' }
    elseif (-not $s.Upstream)  { $problems += 'No upstream' }
    elseif ($s.Gone)           { $problems += 'Upstream gone' }
    elseif ($s.Ahead -and $s.Behind) { $problems += "DIVERGED +$($s.Ahead)/-$($s.Behind)" }
    elseif ($s.Behind)         { $problems += "BEHIND $($s.Behind) - pull" }
    elseif ($s.Ahead)          { $problems += "AHEAD $($s.Ahead) - push" }

    if ($s.Dirty)   { $problems += "$($s.Dirty) uncommitted" }
    if ($s.Stashes) { $problems += "$($s.Stashes) stash(es)" }

    $parts = @($notes | Where-Object { $_ -like 'UPDATED*' })
    if ($problems.Count) { $parts += $problems } else { $parts += 'Up to date' }
    $parts += @($notes | Where-Object { $_ -notlike 'UPDATED*' })

    $gh = Get-GitHubName $s.Origin

    $results += [pscustomobject]@{
        Repo    = $folder.Name
        Branch  = $s.Branch
        Status  = ($parts -join ' | ')
        OK      = ($problems.Count -eq 0 -and -not ($notes -match 'FAILED'))
        Updated = $updated
        Remote  = if ($gh) { $gh.Name } else { '' }
        Owner   = if ($gh) { $gh.Owner } else { '' }
    }
}

Write-Progress -Activity 'Checking repos' -Completed

# ------------------------------------------------------------
# GitHub repos not cloned on this laptop
# ------------------------------------------------------------

# Excluded folders still count as "cloned" so they are not offered again.
$localNames = @()
foreach ($f in $allFolders) {
    $g = Get-GitHubName (git -C $f.FullName remote get-url origin 2>$null)
    if ($g -and $g.Owner -eq $Owner) { $localNames += $g.Name.ToLower() }
}

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
        $remoteNames = $null
    }
}

$missing = @()
$cloned  = @()

if ($null -ne $remoteNames) {
    $missing = @($remoteNames | Where-Object { $_ -and ($localNames -notcontains $_.ToLower()) } | Sort-Object)

    if ($U -and $missing.Count) {
        $stillMissing = @()
        foreach ($m in $missing) {
            $target = Join-Path $Root $m
            if (Test-Path -LiteralPath $target) {
                Write-Host "[WARN] $m not cloned: folder already exists ($target)." -ForegroundColor Yellow
                $stillMissing += $m
                continue
            }
            Write-Host "Cloning $m ..." -ForegroundColor Cyan
            $null = git clone --quiet "https://github.com/$Owner/$m.git" $target 2>&1
            if ($LASTEXITCODE -eq 0) {
                $cloned += $m
                $results += [pscustomobject]@{
                    Repo = $m; Branch = (git -C $target symbolic-ref --quiet --short HEAD 2>$null)
                    Status = 'CLONED'; OK = $true; Updated = $true; Remote = $m; Owner = $Owner
                }
            }
            else {
                Write-Host "[WARN] Clone of $m failed." -ForegroundColor Yellow
                $stillMissing += $m
            }
        }
        $missing = $stillMissing
        if ($cloned.Count) { Write-Host '' }
    }
}

# ------------------------------------------------------------
# Report
# ------------------------------------------------------------

$results = @($results | Sort-Object Repo)

$nameWidth   = [math]::Max(4, ($results | ForEach-Object { $_.Repo.Length } | Measure-Object -Maximum).Maximum)
$branchWidth = [math]::Max(6, ($results | ForEach-Object { "$($_.Branch)".Length } | Measure-Object -Maximum).Maximum)

Write-Host ('{0}  {1}  {2}' -f 'Repo'.PadRight($nameWidth), 'Branch'.PadRight($branchWidth), 'Status')
Write-Host ('{0}  {1}  {2}' -f ('-' * $nameWidth), ('-' * $branchWidth), ('-' * 6))

foreach ($r in $results) {
    $colour = 'Green'
    if (-not $r.OK) { $colour = 'Yellow' }
    if ($r.Status -match 'BEHIND|DIVERGED|FAILED|gone') { $colour = 'Red' }
    elseif ($r.OK -and $r.Updated) { $colour = 'Cyan' }
    Write-Host ('{0}  {1}  {2}' -f $r.Repo.PadRight($nameWidth), "$($r.Branch)".PadRight($branchWidth), $r.Status) -ForegroundColor $colour
}

$needAction = @($results | Where-Object { -not $_.OK })
$nUpdated   = @($results | Where-Object { $_.Updated -and $_.Status -notlike 'CLONED*' }).Count

Write-Host ''
if ($U) {
    Write-Host "Updated $nUpdated, cloned $($cloned.Count)." -ForegroundColor Cyan
}
if ($needAction.Count) {
    Write-Host "$($needAction.Count) of $($results.Count) repos need attention." -ForegroundColor Yellow
}
else {
    Write-Host "All $($results.Count) repos are up to date." -ForegroundColor Green
}
if ($skipped.Count) {
    Write-Host ("Skipped: " + (($skipped | ForEach-Object { $_.Name }) -join ', ')) -ForegroundColor DarkGray
}

Write-Host ''
if ($null -eq $remoteNames) {
    Write-Host "[WARN] Could not list GitHub repos for $Owner, missing-repo check skipped." -ForegroundColor Yellow
}
else {
    if ($scope -eq 'public') {
        Write-Host "(gh not available: only public $Owner repos checked.)" -ForegroundColor DarkGray
    }
    if ($missing.Count) {
        $mWidth = ($missing | ForEach-Object { $_.Length } | Measure-Object -Maximum).Maximum
        Write-Host "Not cloned on this laptop ($($missing.Count)):" -ForegroundColor Yellow
        foreach ($m in $missing) {
            Write-Host ("  {0}  git clone https://github.com/{1}/{2}.git" -f $m.PadRight($mWidth), $Owner, $m)
        }
        if (-not $U) { Write-Host '  (run without -L to clone them all)' -ForegroundColor DarkGray }
    }
    else {
        $label = $Owner
        if ($scope -eq 'public') { $label = "public $Owner" }
        Write-Host "All $label repos are cloned here." -ForegroundColor Green
    }
}

Write-Host ''

if ($needAction.Count -or $missing.Count) { exit 1 }
exit 0
