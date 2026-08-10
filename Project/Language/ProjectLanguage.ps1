param(
    [Parameter(Mandatory = $true)]
    [string]$ProjectFolder,

    [Parameter(Position = 0, ValueFromRemainingArguments = $true)]
    [string[]]$Languages,

    [string]$Model = $(if ($env:OPENAI_MODEL) { $env:OPENAI_MODEL } else { "gpt-5" })
)

$ErrorActionPreference = "Stop"

function Write-Ok([string]$Message) {
    Write-Host "[ OK ] $Message" -ForegroundColor Green
}

function Write-Step([string]$Message) {
    Write-Host "[....] $Message" -ForegroundColor Cyan
}

function Stop-Tool([string]$Message) {
    Write-Host "[FAIL] $Message" -ForegroundColor Red
    exit 1
}

function Get-Placeholders([string]$Text) {
    if ($null -eq $Text) { return @() }

    return @(
        [regex]::Matches($Text, '\{[A-Za-z0-9_.-]+\}') |
            ForEach-Object { $_.Value } |
            Sort-Object
    )
}

function Test-SamePlaceholders([string]$Source, [string]$Translated) {
    $a = @(Get-Placeholders $Source)
    $b = @(Get-Placeholders $Translated)

    if ($a.Count -ne $b.Count) { return $false }

    for ($i = 0; $i -lt $a.Count; $i++) {
        if ($a[$i] -cne $b[$i]) { return $false }
    }

    return $true
}

function ConvertTo-JsonString([string]$Value) {
    return ($Value | ConvertTo-Json -Compress)
}

function Get-ResponseText($Response) {
    foreach ($item in @($Response.output)) {
        foreach ($content in @($item.content)) {
            if ($content.type -eq "output_text" -and $content.text) {
                return [string]$content.text
            }
        }
    }

    return $null
}

function Invoke-Translation(
    [string]$Language,
    [System.Collections.Specialized.OrderedDictionary]$Master,
    [string]$ApiKey,
    [string]$ModelName
) {
    $sourceJson = $Master | ConvertTo-Json -Depth 20

    $instructions = @"
You are a professional software localisation translator.

Translate localisation values from British English (en-GB) into BCP 47 language '$Language'.

Rules:
- en-GB is the authoritative source.
- Return one JSON object only.
- Preserve every JSON key exactly and in the same order.
- Translate values only.
- Preserve placeholders such as {version}, {date}, {player}, {count}, {name}, and {difficulty} exactly.
- Preserve symbols and punctuation where appropriate.
- Keep product names and proper names unchanged unless normal localisation convention requires otherwise.
- Use natural, idiomatic language suitable for a polished software user interface.
- Translate accessibility/ARIA text naturally.
- Do not add, remove, rename, or reorder keys.
- Do not include markdown or commentary.
"@

    $body = [ordered]@{
        model = $ModelName
        store = $false
        instructions = $instructions
        input = $sourceJson
        text = @{
            format = @{
                type = "json_object"
            }
        }
    } | ConvertTo-Json -Depth 20

    $headers = @{
        Authorization = "Bearer $ApiKey"
        "Content-Type" = "application/json"
    }

    $response = Invoke-RestMethod `
        -Method Post `
        -Uri "https://api.openai.com/v1/responses" `
        -Headers $headers `
        -Body $body

    $text = Get-ResponseText $response

    if ([string]::IsNullOrWhiteSpace($text)) {
        throw "The translation provider returned no text."
    }

    return $text
}

Write-Host ""
Write-Host "========================================================="
Write-Host " PowerShellTools Project Language"
Write-Host "========================================================="
Write-Host ""

if (-not (Test-Path -LiteralPath $ProjectFolder -PathType Container)) {
    Stop-Tool "Project folder not found: $ProjectFolder"
}

$ProjectFolder = (Resolve-Path -LiteralPath $ProjectFolder).Path
Write-Ok "Project folder: $ProjectFolder"

if (-not $Languages -or $Languages.Count -eq 0) {
    Stop-Tool "No target language specified. Example: .\PSTP.ps1 Language de-DE fr-FR"
}

$Languages = @(
    $Languages |
        ForEach-Object { $_.Trim() } |
        Where-Object { $_ } |
        Select-Object -Unique
)

foreach ($language in $Languages) {
    if ($language -notmatch '^[A-Za-z]{2,3}(?:-[A-Za-z0-9]{2,8})+$') {
        Stop-Tool "Invalid BCP 47 language code: $language"
    }

    if ($language -ieq "en-GB") {
        Stop-Tool "en-GB is the master language and can never be generated or overwritten."
    }
}

$releasePath = Join-Path $ProjectFolder "release.json"

if (-not (Test-Path -LiteralPath $releasePath -PathType Leaf)) {
    Stop-Tool "release.json not found: $releasePath"
}

Write-Step "Reading localisation configuration"

try {
    $release = Get-Content -LiteralPath $releasePath -Raw -Encoding UTF8 | ConvertFrom-Json
}
catch {
    Stop-Tool "release.json is not valid JSON: $($_.Exception.Message)"
}

if (-not $release.i18n) {
    Stop-Tool "release.json does not contain an i18n configuration."
}

if ($release.i18n.enabled -ne $true) {
    Stop-Tool "Localisation is not enabled in release.json."
}

if ([string]::IsNullOrWhiteSpace([string]$release.i18n.folder)) {
    Stop-Tool "release.json i18n.folder is missing."
}

if ([string]$release.i18n.masterLanguage -cne "en-GB") {
    Stop-Tool "The master language must be en-GB."
}

$i18nFolder = Join-Path $ProjectFolder ([string]$release.i18n.folder)
$fullI18nFolder = [System.IO.Path]::GetFullPath($i18nFolder)
$fullProjectFolder = [System.IO.Path]::GetFullPath($ProjectFolder).TrimEnd('\') + '\'

if (-not $fullI18nFolder.StartsWith($fullProjectFolder, [System.StringComparison]::OrdinalIgnoreCase)) {
    Stop-Tool "i18n.folder must be inside the project folder."
}

if (-not (Test-Path -LiteralPath $fullI18nFolder -PathType Container)) {
    Stop-Tool "Localisation folder not found: $fullI18nFolder"
}

Write-Ok "Localisation folder: $fullI18nFolder"

$masterPath = Join-Path $fullI18nFolder "en-GB.json"

if (-not (Test-Path -LiteralPath $masterPath -PathType Leaf)) {
    Stop-Tool "Master language file not found: $masterPath"
}

Write-Step "Loading master language: en-GB"

try {
    $masterRaw = Get-Content -LiteralPath $masterPath -Raw -Encoding UTF8
    $masterObject = $masterRaw | ConvertFrom-Json
}
catch {
    Stop-Tool "Master language file is not valid JSON: $($_.Exception.Message)"
}

$master = [ordered]@{}

foreach ($property in $masterObject.PSObject.Properties) {
    if ($property.Value -isnot [string]) {
        Stop-Tool "Phase 1 supports flat JSON language files with string values. Key '$($property.Name)' is not a string."
    }

    $master[$property.Name] = [string]$property.Value
}

if ($master.Count -eq 0) {
    Stop-Tool "Master language file contains no strings."
}

Write-Ok "Master language loaded: $($master.Count) strings"

if ([string]::IsNullOrWhiteSpace($env:OPENAI_API_KEY)) {
    Stop-Tool "OPENAI_API_KEY is not set. Set it before generating translations."
}

Write-Ok "Translation provider: OpenAI ($Model)"

foreach ($language in $Languages) {
    Write-Host ""
    Write-Step "Generating $language from en-GB"

    try {
        $translatedText = Invoke-Translation `
            -Language $language `
            -Master $master `
            -ApiKey $env:OPENAI_API_KEY `
            -ModelName $Model
    }
    catch {
        Stop-Tool "Translation failed for ${language}: $($_.Exception.Message)"
    }

    try {
        $translatedObject = $translatedText | ConvertFrom-Json
    }
    catch {
        Stop-Tool "Translation for $language is not valid JSON: $($_.Exception.Message)"
    }

    $translatedProperties = @($translatedObject.PSObject.Properties)
    $masterKeys = @($master.Keys)
    $translatedKeys = @($translatedProperties.Name)

    if ($translatedKeys.Count -ne $masterKeys.Count) {
        Stop-Tool "$language has $($translatedKeys.Count) keys; en-GB has $($masterKeys.Count)."
    }

    for ($i = 0; $i -lt $masterKeys.Count; $i++) {
        if ($translatedKeys[$i] -cne $masterKeys[$i]) {
            Stop-Tool "$language key mismatch at position $($i + 1): expected '$($masterKeys[$i])', received '$($translatedKeys[$i])'."
        }
    }

    $translated = [ordered]@{}

    foreach ($key in $masterKeys) {
        $value = $translatedObject.PSObject.Properties[$key].Value

        if ($value -isnot [string]) {
            Stop-Tool "$language value for '$key' is not a string."
        }

        $value = [string]$value

        if (-not (Test-SamePlaceholders -Source $master[$key] -Translated $value)) {
            Stop-Tool "$language placeholder mismatch for '$key'."
        }

        $translated[$key] = $value
    }

    $targetPath = Join-Path $fullI18nFolder "$language.json"
    $tempPath = "$targetPath.tmp"

    $lines = New-Object System.Collections.Generic.List[string]
    $lines.Add("{")

    for ($i = 0; $i -lt $masterKeys.Count; $i++) {
        $key = $masterKeys[$i]
        $keyJson = ConvertTo-JsonString $key
        $valueJson = ConvertTo-JsonString $translated[$key]
        $comma = if ($i -lt ($masterKeys.Count - 1)) { "," } else { "" }
        $lines.Add("  ${keyJson}: ${valueJson}${comma}")
    }

    $lines.Add("}")
    $outputText = ($lines -join "`n") + "`n"

    try {
        [System.IO.File]::WriteAllText(
            $tempPath,
            $outputText,
            [System.Text.UTF8Encoding]::new($false)
        )

        # Validate the exact file that will be installed.
        $null = Get-Content -LiteralPath $tempPath -Raw -Encoding UTF8 | ConvertFrom-Json

        Move-Item -LiteralPath $tempPath -Destination $targetPath -Force
    }
    catch {
        Remove-Item -LiteralPath $tempPath -Force -ErrorAction SilentlyContinue
        Stop-Tool "Could not write ${language}: $($_.Exception.Message)"
    }

    Write-Ok "Created: $targetPath"
}

Write-Host ""
Write-Host "========================================================="
Write-Host " LANGUAGE GENERATION COMPLETE"
Write-Host "========================================================="
Write-Host ""
Write-Host "Master    : en-GB"
Write-Host "Generated : $($Languages -join ', ')"
Write-Host "Folder    : $fullI18nFolder"
Write-Host ""

exit 0
