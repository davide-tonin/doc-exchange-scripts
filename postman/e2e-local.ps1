param(
    [string] $ServiceRepository = "C:\Users\DavideTonin\IdeaProjects\doc-exchange-service",
    [string] $DatabaseRepository = "C:\Users\DavideTonin\DataGripProjects\doc-exchange-db",
    [string] $Environment = "postman\environments\local-qa.postman_environment.json",
    [int] $HealthTimeoutSeconds = 90,
    [int] $RequestDelayMs = 350,
    [ValidateSet("Full", "Provision")]
    [string] $Mode = "Full"
)

$ErrorActionPreference = "Stop"
$totalStopwatch = [Diagnostics.Stopwatch]::StartNew()

function Write-Phase([int] $Number, [string] $Message) {
    $timestamp = Get-Date -Format "HH:mm:ss"
    Write-Host ""
    Write-Host "[$timestamp] [$Number/6] $Message" -ForegroundColor Cyan
}

Write-Phase 1 "Resolving and validating local repositories."
$serviceRepositoryPath = (Resolve-Path -LiteralPath $ServiceRepository).Path
$environmentPath = Join-Path $serviceRepositoryPath $Environment
$baseUrl = "http://localhost:8080/api"

if (Test-Path -LiteralPath $environmentPath) {
    $existingEnvironment = Get-Content -LiteralPath $environmentPath -Raw -Encoding UTF8 |
        ConvertFrom-Json
    $configuredBaseUrl = ($existingEnvironment.values |
        Where-Object { $_.key -eq "base_url" } |
        Select-Object -First 1).value
    if (-not [string]::IsNullOrWhiteSpace($configuredBaseUrl)) {
        $baseUrl = $configuredBaseUrl
    }
}

$baseUri = [Uri] $baseUrl
if ($baseUri.Host -notin @("localhost", "127.0.0.1", "::1")) {
    throw "Refusing local E2E reset because base_url is not loopback: $baseUrl"
}
$applicationPort = $baseUri.Port
$previousListener = Get-NetTCPConnection `
    -LocalPort $applicationPort `
    -State Listen `
    -ErrorAction SilentlyContinue |
    Select-Object -First 1
$previousApplicationPid = if ($null -eq $previousListener) {
    $null
} else {
    $previousListener.OwningProcess
}

Write-Phase 2 "Resetting and migrating the local QA database."
& "$PSScriptRoot\..\database\qa-db-reset.ps1" `
    -ServiceRepository $serviceRepositoryPath `
    -DatabaseRepository $DatabaseRepository

Write-Phase 3 "Clearing stale Postman runtime state while preserving local fixture credentials."
& "$PSScriptRoot\init-local.ps1" `
    -ServiceRepository $serviceRepositoryPath `
    -Environment $Environment `
    -ResetRuntime `
    -RequestDelayMs $RequestDelayMs

$environmentDocument = Get-Content -LiteralPath $environmentPath -Raw -Encoding UTF8 |
    ConvertFrom-Json
$baseUrl = ($environmentDocument.values |
    Where-Object { $_.key -eq "base_url" } |
    Select-Object -First 1).value
$healthUrl = "$baseUrl/actuator/health"
$deadline = [DateTimeOffset]::UtcNow.AddSeconds($HealthTimeoutSeconds)
$healthy = $false

Write-Phase 4 "Restarting QA and waiting for a fresh healthy JVM."
if ($null -eq $previousApplicationPid) {
    Read-Host "Start IntelliJ 'Main - QA', then press Enter"
} else {
    Read-Host ("Restart IntelliJ 'Main - QA' to clear pre-reset JVM caches, " +
        "then press Enter")
}

Write-Host "Waiting for a fresh QA application at $healthUrl."
$healthStopwatch = [Diagnostics.Stopwatch]::StartNew()
$nextHealthUpdateSeconds = 10
do {
    $currentListener = Get-NetTCPConnection `
        -LocalPort $applicationPort `
        -State Listen `
        -ErrorAction SilentlyContinue |
        Select-Object -First 1
    $freshProcess = $null -ne $currentListener -and (
        $null -eq $previousApplicationPid -or
        $currentListener.OwningProcess -ne $previousApplicationPid
    )
    try {
        $healthResponse = Invoke-RestMethod -Uri $healthUrl -TimeoutSec 3
        $healthy = $freshProcess -and
            $healthResponse.status -eq "UP" -and
            $healthResponse.components.db.status -eq "UP"
    }
    catch {
        $healthy = $false
    }
    if (-not $healthy) {
        if ($healthStopwatch.Elapsed.TotalSeconds -ge $nextHealthUpdateSeconds) {
            $elapsedSeconds = [Math]::Floor($healthStopwatch.Elapsed.TotalSeconds)
            Write-Host "  Still waiting for fresh JVM + database health ($elapsedSeconds s elapsed)..."
            $nextHealthUpdateSeconds += 10
        }
        Start-Sleep -Seconds 2
    }
} while (-not $healthy -and [DateTimeOffset]::UtcNow -lt $deadline)

if (-not $healthy) {
    throw ("A fresh QA application process did not become healthy within " +
        "$HealthTimeoutSeconds seconds. Restart IntelliJ 'Main - QA', then rerun this script.")
}
Write-Host "Fresh QA application is UP with database health UP." -ForegroundColor Green

Write-Phase 5 "Refreshing generated collections from live public/internal OpenAPI."
& "$PSScriptRoot\refresh.ps1" -ServiceRepository $serviceRepositoryPath -BaseUrl $baseUrl

if ($Mode -eq "Full") {
    Write-Phase 6 "Running provisioning, Smoke, and interactive password-reset E2E."
} else {
    Write-Phase 6 "Provisioning the fixture tenants through tenant init, bootstrap, and Basic login."
}
& "$PSScriptRoot\run.ps1" -ServiceRepository $serviceRepositoryPath -Mode $Mode -Environment $Environment

$elapsed = $totalStopwatch.Elapsed
Write-Host ""
Write-Host (
    "Clean-room Postman $Mode workflow completed in {0:mm\:ss}." -f $elapsed
) -ForegroundColor Green
