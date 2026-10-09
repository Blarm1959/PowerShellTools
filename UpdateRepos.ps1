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

    A saved Windows-encrypted token lists public and private repository names.
    Save it under LOCALAPPDATA\Blarm1959\UpdateRepos\github-token.txt using
    Read-Host -AsSecureString | ConvertFrom-SecureString | Set-Content.
    Use a fine-grained token for All repositories with Metadata read permission.
    If no token works, an authenticated GitHub CLI (gh) is tried, then public API.
    Clones and pulls use existing Git credentials, never the metadata-only token.
    Failed clones remain listed for manual action.
    Also reports duplicate clones, unmatched origins, different folder names
    and folders without Git metadata. Excluded copies are audited too.
    No folders are deleted or renamed. An incomplete inventory exits with 1.

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

$ScriptVersion = '1.2.1'   # Adds GitHub Desktop instructions for newly cloned repositories.

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

$rootFolders = @(Get-ChildItem -LiteralPath $Root -Directory | Sort-Object Name)
$allFolders = @($rootFolders |
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
$inventoryWarning = ''
$tokenPath = if ($env:LOCALAPPDATA) { Join-Path $env:LOCALAPPDATA 'Blarm1959\UpdateRepos\github-token.txt' } else { '' }
if ($tokenPath -and (Test-Path -LiteralPath $tokenPath -PathType Leaf)) {
    $tokenHeaders = $null
    $plainToken = $null
    $secureToken = $null
    try {
        $secureToken = (Get-Content -LiteralPath $tokenPath -Raw -ErrorAction Stop).Trim() | ConvertTo-SecureString -ErrorAction Stop
        $credential = [System.Management.Automation.PSCredential]::new('UpdateRepos', $secureToken)
        $plainToken = $credential.GetNetworkCredential().Password
        $tokenHeaders = @{ Authorization = "Bearer $plainToken"; Accept = 'application/vnd.github+json'; 'User-Agent' = 'UpdateRepos' }
        $identity = Invoke-RestMethod -Uri 'https://api.github.com/user' -Headers $tokenHeaders -ErrorAction Stop
        if ($identity.login -ine $Owner) { throw 'Token owner does not match the requested owner.' }
        $tokenNames = @()
        $page = 1
        do {
            $api = @(Invoke-RestMethod -Uri "https://api.github.com/user/repos?affiliation=owner&visibility=all&per_page=100&page=$page" -Headers $tokenHeaders -ErrorAction Stop)
            $tokenNames += @($api | Where-Object { $_.owner.login -ieq $Owner } | ForEach-Object { $_.name })
            $page++
        } while ($api.Count -eq 100)
        $remoteNames = $tokenNames
        $scope = 'all'
    }
    catch {
        # Never print API request details or credential-bearing exceptions.
        $inventoryWarning = 'Saved token could not list repositories. Check its expiry, owner and All repositories access; private coverage is incomplete.'
    }
    finally {
        if ($tokenHeaders) { $tokenHeaders.Clear() }
        $plainToken = $null
        $credential = $null
        if ($secureToken) { $secureToken.Dispose() }
    }
}
if ($null -eq $remoteNames -and (Get-Command gh -ErrorAction SilentlyContinue)) {
    $login = @(gh api user --jq .login 2>$null)
    if ($LASTEXITCODE -eq 0) {
        $repoJson = @(gh repo list $Owner --limit 10000 --json name 2>$null)
        if ($LASTEXITCODE -eq 0) {
            try {
                $listed = @((($repoJson -join "`n") | ConvertFrom-Json -ErrorAction Stop))
                if ($listed.Count -ge 10000) { throw 'Inventory limit reached.' }
                $remoteNames = @($listed | ForEach-Object { $_.name })
                if (($login -join '').Trim() -ieq $Owner) { $scope = 'all' }
                else {
                    $scope = 'accessible'
                    $inventoryWarning = "gh is signed in as $($login -join ''), not $Owner; private coverage may be incomplete."
                }
            }
            catch { $inventoryWarning = 'Authenticated repository inventory could not be read.' }
        }
        else { $inventoryWarning = 'Authenticated repository inventory failed.' }
    }
    else { $inventoryWarning = 'gh is not signed in. Run gh auth login to check private repos.' }
}
elseif ($null -eq $remoteNames -and -not $inventoryWarning) {
    $inventoryWarning = 'No saved token or GitHub CLI login available; private coverage is incomplete.'
}

if ($null -eq $remoteNames) {
    try {
        $publicNames = @()
        $page = 1
        do {
            $api = @(Invoke-RestMethod -Uri "https://api.github.com/users/$Owner/repos?per_page=100&page=$page" -ErrorAction Stop)
            $publicNames += @($api | ForEach-Object { $_.name })
            $page++
        } while ($api.Count -eq 100)
        $remoteNames = $publicNames
        $scope = 'public'
    }
    catch {
        $remoteNames = $null
        $inventoryWarning = 'Could not retrieve a complete GitHub repository inventory.'
    }
}

# Check excluded copies too. Match by origin, not folder name.
$inventory = @()
foreach ($f in $allFolders) {
    $url = git -C $f.FullName remote get-url origin 2>$null
    $g = Get-GitHubName $url
    $inventory += [pscustomobject]@{
        Folder = $f.Name
        Origin = "$url"
        Owner = if ($g) { $g.Owner } else { '' }
        Remote = if ($g) { $g.Name } else { '' }
    }
}
$inventoryIssues = @()
foreach ($item in $inventory) {
    $reason = ''
    if (-not $item.Origin) { $reason = 'No origin remote' }
    elseif (-not $item.Remote) { $reason = 'Origin is not a recognised GitHub URL' }
    elseif ($item.Owner -ine $Owner) { $reason = "Origin belongs to $($item.Owner), not $Owner" }
    elseif ($null -ne $remoteNames -and $remoteNames -notcontains $item.Remote) {
        if ($scope -eq 'all') {
            $reason = "Origin not listed in authenticated $Owner inventory; check rename or access"
        }
        else { $reason = 'Origin not listed; private repository existence is unverified' }
    }
    if ($reason) { $inventoryIssues += [pscustomobject]@{ Folder = $item.Folder; Detail = $reason } }
    if ($item.Remote -and $item.Owner -ieq $Owner -and $item.Folder -ine $item.Remote) {
        $inventoryIssues += [pscustomobject]@{ Folder = $item.Folder; Detail = "Folder name differs from origin: $($item.Remote)" }
    }
}
$duplicates = @($inventory | Where-Object { $_.Remote -and $_.Owner -ieq $Owner } |
    Group-Object { "$($_.Owner)/$($_.Remote)".ToLowerInvariant() } | Where-Object { $_.Count -gt 1 })
foreach ($group in $duplicates) {
    $inventoryIssues += [pscustomobject]@{
        Folder = ($group.Group.Folder -join ', ')
        Detail = "Duplicate clones of $($group.Name)"
    }
}
$nonGitFolders = @($rootFolders | Where-Object {
    -not (Test-Path -LiteralPath (Join-Path $_.FullName '.git'))
})

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
        Write-Host "(Only public $Owner repos checked; private inventory is incomplete.)" -ForegroundColor Yellow
    }
    if ($missing.Count) {
        $mWidth = ($missing | ForEach-Object { $_.Length } | Measure-Object -Maximum).Maximum
        Write-Host "Not cloned on this laptop ($($missing.Count)):" -ForegroundColor Yellow
        foreach ($m in $missing) {
            $cloneTarget = Join-Path $Root $m
            Write-Host ("  {0}  git clone https://github.com/{1}/{2}.git {3}" -f $m.PadRight($mWidth), $Owner, $m, ('"' + $cloneTarget + '"'))
        }
        if (-not $U) { Write-Host '  (run without -L to clone them all)' -ForegroundColor DarkGray }
    }
    else {
        $label = $Owner
        if ($scope -eq 'public') { $label = "public $Owner" }
        elseif ($scope -eq 'accessible') { $label = "accessible $Owner" }
        Write-Host "All $label repos are cloned here." -ForegroundColor Green
    }
}

Write-Host ''

if ($inventoryWarning) { Write-Host "[WARN] $inventoryWarning" -ForegroundColor Yellow }
Write-Host ''
Write-Host "Local/GitHub inventory: $($allFolders.Count) Git folders checked (including excluded folders)." -ForegroundColor Cyan
if ($inventoryIssues.Count) {
    Write-Host 'Local folders needing review (no folders deleted):' -ForegroundColor Yellow
    foreach ($issue in $inventoryIssues) {
        Write-Host ("  {0}: {1}" -f $issue.Folder, $issue.Detail) -ForegroundColor Yellow
    }
}
elseif ($scope -eq 'all') {
    Write-Host 'Every local Git folder has a matching origin; no duplicate clones or different folder names found.' -ForegroundColor Green
}
else {
    Write-Host 'No additional local folder issues detected; private repository coverage is unverified.' -ForegroundColor Yellow
}
if ($nonGitFolders.Count) {
    Write-Host 'Folders without Git metadata (may be ordinary folders):' -ForegroundColor Yellow
    foreach ($folder in $nonGitFolders) { Write-Host "  $($folder.Name)" -ForegroundColor Yellow }
}
Write-Host ''
if ($cloned.Count) {
    Write-Host 'Add these newly cloned repositories to GitHub Desktop:' -ForegroundColor Cyan
    foreach ($name in ($cloned | Sort-Object)) {
        Write-Host ("  {0}  ({1})" -f $name, (Join-Path $Root $name))
    }
    Write-Host ''
    Write-Host 'For each repository:'
    Write-Host '  1. Choose File -> Add local repository (Ctrl+O).'
    Write-Host "  2. Select the repository's folder shown above."
    Write-Host '  3. Click Add repository.'
    Write-Host ''
}
if ($needAction.Count -or $missing.Count -or $inventoryIssues.Count -or $nonGitFolders.Count -or $scope -ne 'all') { exit 1 }
exit 0

