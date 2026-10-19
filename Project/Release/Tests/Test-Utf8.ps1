# Run with Windows PowerShell 5.1 and/or PowerShell 7.
# Extract only the functions under test: never run release/publication code.
[CmdletBinding()]
param()
$ErrorActionPreference = 'Stop'
$SourcePath = Join-Path $PSScriptRoot '..\ProjectRelease.ps1'
$Tokens = $null
$ParseErrors = $null
$Ast = [System.Management.Automation.Language.Parser]::ParseFile(
    $SourcePath, [ref]$Tokens, [ref]$ParseErrors
)
if ($ParseErrors.Count) { throw ($ParseErrors | Out-String) }
$Names = @(
    'Write-TextFileUtf8NoBom', 'Read-JsonFile',
    'Get-UpdatedReadmeContent', 'Set-ServiceWorkerVersion',
    'Get-ServiceWorkerReportedVersion', 'Ensure-GitIgnoreEntry'
)
foreach ($Name in $Names) {
    $Definitions = @($Ast.FindAll({
        param($Node)
        $Node -is [System.Management.Automation.Language.FunctionDefinitionAst]
    }, $true) | Where-Object Name -eq $Name)
    if ($Definitions.Count -ne 1) { throw "Expected one function: $Name" }
    Invoke-Expression $Definitions[0].Extent.Text
}
function Write-Status { param($Status, $Message) }
function Stop-ProjectRelease { param($Message) throw $Message }
function Assert-True { param([bool]$Condition, [string]$Message)
    if (-not $Condition) { throw $Message }
}
$Reads = @($Ast.FindAll({
    param($Node)
    $Node -is [System.Management.Automation.Language.CommandAst] -and
        $Node.GetCommandName() -eq 'Get-Content'
}, $true))
Assert-True ($Reads.Count -eq 5) 'Review changed text reads in the release tool.'
foreach ($Read in $Reads) {
    Assert-True ($Read.Extent.Text -match '(?i)-Encoding\s+UTF8') 'A release text read has no explicit UTF-8 encoding.'
}
$MaximumHistoryEntries = 25
$TempRoot = Join-Path ([IO.Path]::GetTempPath()) ('pstp-utf8-test-' + [guid]::NewGuid().ToString('N'))
$null = New-Item -ItemType Directory -Path $TempRoot
$Utf8 = [System.Text.UTF8Encoding]::new($false, $true)
$Unicode = "caf$([char]0x00e9) $([char]0x00a3) $([char]0x20ac) 8$([char]0x00d7)8 $([char]0x4e2d)$([char]0x6587) $([char]::ConvertFromUtf32(0x1f3b2))"
try {
    $ReadmePath = Join-Path $TempRoot 'README.md'
    $Seed = @(
        '# Encoding fixture', '', $Unicode, '', '---', '',
        '## Current Release', '', 'Version: **v0.0.0**', '', '---', '',
        '<!-- PROJECTRELEASE:BEGIN -->', '', '## Release History', '',
        '| Version | Type | Notes |', '|---------|------|-------|',
        '| v0.0.0 | Package | Initial fixture. |', '',
        '<!-- PROJECTRELEASE:END -->'
    ) -join [Environment]::NewLine
    $Context = [pscustomobject]@{
        ProjectFolder = $TempRoot; TargetTag = 'v0.0.0'
        ReleaseType = 'Package'; ReleaseHistoryNote = $Unicode
        IsNewProject = $false; ReadmeWasMissing = $false
    }
    foreach ($WithBom in @($false, $true)) {
        [IO.File]::WriteAllText($ReadmePath, $Seed, ([System.Text.UTF8Encoding]::new($WithBom)))
        for ($Round = 1; $Round -le 40; $Round++) {
            $Context.TargetTag = "v0.0.$Round"
            $Updated = Get-UpdatedReadmeContent -ProjectContext $Context
            Assert-True ($Updated.Contains($Unicode)) "Unicode changed in README round $Round (BOM=$WithBom)."
            Write-TextFileUtf8NoBom -Path $ReadmePath -Content $Updated
            $Actual = [IO.File]::ReadAllText($ReadmePath, $Utf8)
            Assert-True ($Actual -ceq ($Updated.TrimEnd() + [Environment]::NewLine)) 'README writer changed text.'
            Assert-True ($Actual.Contains("Version: **$($Context.TargetTag)**")) 'Current Release was not updated.'
            Assert-True ((Get-Item -LiteralPath $ReadmePath).Length -lt 16384) 'README grew unexpectedly.'
            $Rows = @($Actual -split '\r?\n' | Where-Object { $_ -match '^\|\s*v\d+\.\d+\.\d+\s*\|' })
            Assert-True ($Rows.Count -le 25) 'Release history cap was not respected.'
        }
        $Bytes = [IO.File]::ReadAllBytes($ReadmePath)
        Assert-True (-not ($Bytes[0] -eq 239 -and $Bytes[1] -eq 187 -and $Bytes[2] -eq 191)) 'Output unexpectedly has a BOM.'
    }
    $JsonPath = Join-Path $TempRoot 'release.json'
    $Json = '{"version":"1.0.0","description":"' + $Unicode + '"}'
    Write-TextFileUtf8NoBom -Path $JsonPath -Content $Json
    $Parsed = Read-JsonFile -Path $JsonPath -DisplayName 'fixture'
    Assert-True ($Parsed.description -ceq $Unicode) 'JSON text changed.'

    $WorkerPath = Join-Path $TempRoot 'service-worker.js'
    Write-TextFileUtf8NoBom -Path $WorkerPath -Content ("// Notes: $Unicode`nconst VERSION = `"1.0.0`";")
    $null = Set-ServiceWorkerVersion -Path $WorkerPath -Version '2.3.4'
    Assert-True ([IO.File]::ReadAllText($WorkerPath, $Utf8).Contains($Unicode)) 'Worker comment changed.'
    Assert-True ((Get-ServiceWorkerReportedVersion -Path $WorkerPath) -eq '2.3.4') 'Worker version was not updated.'

    $IgnorePath = Join-Path $TempRoot '.gitignore'
    Write-TextFileUtf8NoBom -Path $IgnorePath -Content ("# $Unicode`nassets/caf$([char]0x00e9)/")
    Ensure-GitIgnoreEntry -GitIgnorePath $IgnorePath -Entry 'Old/'
    $After = [IO.File]::ReadAllText($IgnorePath, $Utf8)
    Assert-True ($After.Contains($Unicode)) 'Gitignore text changed.'
    Assert-True ($After.Contains('Old/')) 'Gitignore entry missing.'
    Ensure-GitIgnoreEntry -GitIgnorePath $IgnorePath -Entry 'Old/'
    Assert-True ([IO.File]::ReadAllText($IgnorePath, $Utf8) -ceq $After) 'Repeated gitignore update changed text.'
    Write-Host 'PASS: UTF-8 README (80 updates), JSON, service worker and gitignore checks.' -ForegroundColor Green
}
finally {
    Remove-Item -LiteralPath $TempRoot -Recurse -Force
}
