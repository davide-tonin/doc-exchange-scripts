param(
    [string] $ServiceRepository = "C:\\Users\\DavideTonin\\IdeaProjects\\doc-exchange-service",
    [Parameter(Mandatory = $true)]
    [ValidateSet("Provision", "ResumeProvision", "Smoke", "ResumeSmoke", "Full", "SeedPlayground")]
    [string] $Mode,
    [string] $StartFolder,
    [string] $Environment = "postman\environments\local-qa.postman_environment.json",
    [switch] $SkipPreflight,
    [switch] $DebugReport
)

$ErrorActionPreference = "Stop"
$repoRoot = (Resolve-Path -LiteralPath $ServiceRepository).Path
$postmanRoot = Join-Path $repoRoot "postman"
$environmentPath = Join-Path $repoRoot $Environment
$runtimeDirectory = Join-Path $repoRoot "build\postman\runtime"
$e2eCollection = Join-Path $postmanRoot "generated\doc-exchange-e2e.postman_collection.json"
$playgroundCollection = Join-Path $postmanRoot "generated\doc-exchange-playground.postman_collection.json"
$newman = Join-Path $postmanRoot "node_modules\.bin\newman.cmd"

function Get-EnvironmentDocument {
    return Get-Content -LiteralPath $environmentPath -Raw -Encoding UTF8 | ConvertFrom-Json
}

function Get-EnvironmentValue([string] $Key) {
    $document = Get-EnvironmentDocument
    return ($document.values | Where-Object { $_.key -eq $Key } | Select-Object -First 1).value
}

function Set-EnvironmentValue([string] $Key, [string] $Value, [string] $Type = "default") {
    $document = Get-EnvironmentDocument
    $entry = $document.values | Where-Object { $_.key -eq $Key } | Select-Object -First 1
    if ($null -eq $entry) {
        $document.values += [PSCustomObject]@{
            key = $Key
            value = $Value
            type = $Type
            enabled = $true
        }
    } else {
        $entry.value = $Value
        $entry.type = $Type
        if ($null -eq $entry.PSObject.Properties["enabled"]) {
            $entry | Add-Member -NotePropertyName "enabled" -NotePropertyValue $true
        } else {
            $entry.enabled = $true
        }
    }
    $environmentJson = $document | ConvertTo-Json -Depth 100
    [IO.File]::WriteAllText(
        $environmentPath,
        $environmentJson,
        [Text.UTF8Encoding]::new($false)
    )
}

function Initialize-RunState {
    Set-EnvironmentValue "run_id" (
        "{0}-{1}" -f [DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds(), ([Guid]::NewGuid().ToString("N").Substring(0, 8))
    )
    foreach ($key in @(
        "cursor",
        "public_document_visibility_attempt",
        "internal_document_visibility_attempt",
        "public_document_idempotency_key",
        "internal_document_idempotency_key",
        "public_invalid_document_idempotency_key",
        "internal_invalid_document_idempotency_key",
        "public_undeliverable_document_idempotency_key",
        "internal_undeliverable_document_idempotency_key"
    )) {
        Set-EnvironmentValue $key ""
    }
}

function Select-PrimaryPlaygroundTenant {
    Set-EnvironmentValue "tenant_alias" (Get-EnvironmentValue "primary_alias")
    Set-EnvironmentValue "tenant_email" (Get-EnvironmentValue "primary_email")
    Set-EnvironmentValue "tenant_password" (Get-EnvironmentValue "primary_password") "secret"
    Set-EnvironmentValue "tenant_access_token" (Get-EnvironmentValue "primary_access_token") "secret"
    Set-EnvironmentValue "tenant_default_pov_id" (Get-EnvironmentValue "primary_default_pov_id")
    Set-EnvironmentValue "tenant_admin_role_id" (Get-EnvironmentValue "primary_admin_role_id")
}

function Normalize-Token([string] $InputValue, [string] $Parameter) {
    $trimmed = $InputValue.Trim()
    $match = [regex]::Match($trimmed, "(?:\?|&)$([regex]::Escape($Parameter))=([^&\s]+)")
    if ($match.Success) {
        return [Uri]::UnescapeDataString($match.Groups[1].Value)
    }
    return $trimmed
}

function Invoke-Newman(
    [string] $Collection,
    [string[]] $Folders,
    [string] $RunName
) {
    New-Item -ItemType Directory -Force -Path $runtimeDirectory | Out-Null
    $exportedEnvironment = Join-Path $runtimeDirectory "$RunName.environment.json"
    $junitReport = Join-Path $runtimeDirectory "$RunName.junit.xml"
    $arguments = @(
        "run", $Collection,
        "--environment", $environmentPath,
        "--export-environment", $exportedEnvironment,
        "--delay-request", (Get-EnvironmentValue "request_delay_ms"),
        "--bail", "failure",
        "--reporters", "cli,junit",
        "--reporter-junit-export", $junitReport
    )
    foreach ($folder in $Folders) {
        $arguments += @("--folder", $folder)
    }
    if ($DebugReport) {
        $arguments[($arguments.IndexOf("cli,junit"))] = "cli,junit,json"
        $arguments += @(
            "--reporter-json-export",
            (Join-Path $runtimeDirectory "$RunName.debug.json")
        )
    }

    & $newman @arguments
    $exitCode = $LASTEXITCODE
    if (Test-Path -LiteralPath $exportedEnvironment) {
        $exportedEnvironmentBytes = (Get-Item -LiteralPath $exportedEnvironment).Length
        if ($exportedEnvironmentBytes -gt 1MB) {
            throw ("Newman produced an abnormally large environment export " +
                "($exportedEnvironmentBytes bytes): $exportedEnvironment. " +
                "The working environment was not replaced.")
        }
        Copy-Item -LiteralPath $exportedEnvironment -Destination $environmentPath -Force
    }
    if ($exitCode -ne 0) {
        throw "Newman phase '$RunName' failed with exit code $exitCode."
    }
}

function Invoke-Provision {
    Invoke-Newman $e2eCollection @("000 Internal Tenant Init") "provision-init"

    $primaryToken = Read-Host "Paste the primary tenant init token or complete link"
    $peerToken = Read-Host "Paste the peer tenant init token or complete link"
    Set-EnvironmentValue "primary_init_token" (Normalize-Token $primaryToken "init_token") "secret"
    Set-EnvironmentValue "peer_init_token" (Normalize-Token $peerToken "init_token") "secret"

    Invoke-ProvisionBootstrapAndAuth
}

function Invoke-ProvisionBootstrapAndAuth {
    foreach ($key in @("primary_init_token", "peer_init_token")) {
        if ([string]::IsNullOrWhiteSpace((Get-EnvironmentValue $key))) {
            throw "Postman secret '$key' is empty. Run Provision first and paste both emailed tokens."
        }
    }
    Invoke-Newman $e2eCollection @("001 Internal Tenant Bootstrap") "provision-bootstrap"
    Invoke-Newman $e2eCollection @("002 Internal Auth") "provision-auth"
    Select-PrimaryPlaygroundTenant
}

function Invoke-Smoke {
    Initialize-RunState
    Invoke-SmokeFolders
}

function Invoke-SmokeFolders([string] $FromFolder) {
    $collection = Get-Content -LiteralPath $e2eCollection -Raw -Encoding UTF8 | ConvertFrom-Json
    $folders = @($collection.item.name | Where-Object {
        $_ -notmatch "^000 " -and
        $_ -notmatch "^001 " -and
        $_ -notmatch "^119 " -and
        $_ -notmatch "^120 "
    })
    if (-not [string]::IsNullOrWhiteSpace($FromFolder)) {
        $startIndex = [Array]::IndexOf($folders, $FromFolder)
        if ($startIndex -lt 0) {
            throw "Smoke start folder '$FromFolder' was not found in the generated collection."
        }
        $folders = @($folders[$startIndex..($folders.Count - 1)])
    }
    Invoke-Newman $e2eCollection $folders "smoke"
}

if (-not (Test-Path -LiteralPath $environmentPath)) {
    throw "Working environment not found: $environmentPath. Copy the committed example and fill secrets."
}
& "$PSScriptRoot\init-local.ps1" -ServiceRepository $repoRoot -Environment $Environment
if (-not (Test-Path -LiteralPath $newman)) {
    & npm ci --prefix $postmanRoot --no-audit --no-fund
    if ($LASTEXITCODE -ne 0) {
        throw "npm ci failed."
    }
}
if (-not $SkipPreflight) {
    $baseUrl = Get-EnvironmentValue "base_url"
    & "$PSScriptRoot\preflight.ps1" -ServiceRepository $repoRoot -BaseUrl $baseUrl -Environment $Environment
    if ($LASTEXITCODE -ne 0) {
        throw "Postman preflight failed."
    }
}

switch ($Mode) {
    "Provision" {
        Invoke-Provision
    }
    "ResumeProvision" {
        Invoke-ProvisionBootstrapAndAuth
    }
    "Smoke" {
        Invoke-Smoke
    }
    "ResumeSmoke" {
        if ([string]::IsNullOrWhiteSpace($StartFolder)) {
            throw "ResumeSmoke requires -StartFolder with an exact generated collection folder name."
        }
        Invoke-SmokeFolders $StartFolder
    }
    "Full" {
        if ([string]::IsNullOrWhiteSpace((Get-EnvironmentValue "primary_alias")) -or
            [string]::IsNullOrWhiteSpace((Get-EnvironmentValue "peer_alias"))) {
            Invoke-Provision
        }
        Invoke-Smoke

        Invoke-Newman $e2eCollection @("119 Interactive Password Reset") "password-reset-request"
        $resetToken = Read-Host "Paste the newest password reset token or complete link"
        Set-EnvironmentValue "reset_token" (Normalize-Token $resetToken "token") "secret"
        Invoke-Newman $e2eCollection @("120 Interactive Password Reset Completion") "password-reset-complete"
        Invoke-Newman $e2eCollection @("002 Internal Auth") "password-reset-reauth"
    }
    "SeedPlayground" {
        Initialize-RunState
        Select-PrimaryPlaygroundTenant
        Invoke-Newman $playgroundCollection @("00 Seed Playground") "playground-seed"
    }
}

Write-Host "Postman $Mode completed. Runtime reports: $runtimeDirectory"
