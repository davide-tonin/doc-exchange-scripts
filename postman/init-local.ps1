param(
    [string] $ServiceRepository = "C:\\Users\\DavideTonin\\IdeaProjects\\doc-exchange-service",
    [string] $Environment = "postman\environments\local-qa.postman_environment.json",
    [switch] $ResetRuntime,
    [int] $RequestDelayMs = -1
)

$ErrorActionPreference = "Stop"
$repoRoot = (Resolve-Path -LiteralPath $ServiceRepository).Path
$examplePath = Join-Path $repoRoot "postman\environments\local-qa.example.postman_environment.json"
$environmentPath = Join-Path $repoRoot $Environment

if (-not (Test-Path -LiteralPath $environmentPath)) {
    Copy-Item -LiteralPath $examplePath -Destination $environmentPath
}

$document = Get-Content -LiteralPath $environmentPath -Raw -Encoding UTF8 | ConvertFrom-Json
$example = Get-Content -LiteralPath $examplePath -Raw -Encoding UTF8 | ConvertFrom-Json
$document.name = $example.name

foreach ($exampleEntry in $example.values) {
    $entry = $document.values |
        Where-Object { $_.key -eq $exampleEntry.key } |
        Select-Object -First 1
    if ($null -eq $entry) {
        $document.values += [PSCustomObject]@{
            key = $exampleEntry.key
            value = $exampleEntry.value
            type = $exampleEntry.type
            enabled = $true
        }
    } else {
        $entry.type = $exampleEntry.type
        if ($null -eq $entry.PSObject.Properties["enabled"]) {
            $entry | Add-Member -NotePropertyName "enabled" -NotePropertyValue $true
        } else {
            $entry.enabled = $true
        }
    }
}

if ($RequestDelayMs -ge 0) {
    $requestDelay = $document.values |
        Where-Object { $_.key -eq "request_delay_ms" } |
        Select-Object -First 1
    $requestDelay.value = [string] $RequestDelayMs
}

if ($ResetRuntime) {
    $preservedKeys = @(
        "base_url",
        "browser_origin",
        "request_delay_ms",
        "primary_email",
        "primary_display_name",
        "primary_password",
        "peer_email",
        "peer_display_name",
        "peer_password",
        "secondary_password",
        "provision_email",
        "provision_display_name",
        "provision_password"
    )
    foreach ($entry in $document.values) {
        if ($entry.key -notin $preservedKeys) {
            $entry.value = ""
        }
    }

    $nextPassword = $document.values |
        Where-Object { $_.key -eq "next_primary_password" } |
        Select-Object -First 1
    $nextPassword.value = "Qa1!$([Guid]::NewGuid().ToString('N'))"
    $nextPassword.type = "secret"
}

function Set-GeneratedPasswordIfEmpty([string] $Key) {
    $entry = $document.values | Where-Object { $_.key -eq $Key } | Select-Object -First 1
    if ($null -eq $entry) {
        throw "Postman environment is missing required key '$Key'."
    }
    if ([string]::IsNullOrWhiteSpace($entry.value)) {
        $entry.value = "Qa1!$([Guid]::NewGuid().ToString('N'))"
        $entry.type = "secret"
        if ($null -eq $entry.PSObject.Properties["enabled"]) {
            $entry | Add-Member -NotePropertyName "enabled" -NotePropertyValue $true
        } else {
            $entry.enabled = $true
        }
    }
}

foreach ($key in @(
    "primary_password",
    "peer_password",
    "secondary_password",
    "next_primary_password"
)) {
    Set-GeneratedPasswordIfEmpty $key
}

$environmentJson = $document | ConvertTo-Json -Depth 100
[IO.File]::WriteAllText(
    $environmentPath,
    $environmentJson,
    [Text.UTF8Encoding]::new($false)
)
Write-Host "Local Postman environment is ready. Required passwords are populated and remain local."
