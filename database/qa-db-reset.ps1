param(
    [string] $ServiceRepository = "C:\Users\DavideTonin\IdeaProjects\doc-exchange-service",
    [string] $DatabaseRepository = "C:\Users\DavideTonin\DataGripProjects\doc-exchange-db",
    [string] $FlywayConfig = "flyway.conf"
)

$ErrorActionPreference = "Stop"
$expectedJdbcUrl = "jdbc:postgresql://localhost:5433/de-db"
$databaseRepositoryPath = (Resolve-Path -LiteralPath $DatabaseRepository).Path
$flywayConfigPath = (Resolve-Path -LiteralPath (
    Join-Path $databaseRepositoryPath $FlywayConfig
)).Path

$configuredUrl = Get-Content -LiteralPath $flywayConfigPath |
    Where-Object { $_ -match "^\s*flyway\.url\s*=" } |
    Select-Object -First 1
if ($null -eq $configuredUrl) {
    throw "flyway.url is missing from $flywayConfigPath."
}
$configuredUrl = ($configuredUrl -split "=", 2)[1].Trim()
if ($configuredUrl -ne $expectedJdbcUrl) {
    throw ("Refusing destructive Flyway clean. Expected '$expectedJdbcUrl', " +
        "but $flywayConfigPath targets '$configuredUrl'.")
}

$flyway = Get-Command flyway -ErrorAction SilentlyContinue
if ($null -eq $flyway) {
    throw "Flyway CLI is not available on PATH."
}

Write-Host "Reset target verified: $expectedJdbcUrl" -ForegroundColor Yellow
Write-Host "Starting the local QA Postgres container."
& "$PSScriptRoot\dev-db.ps1" up -ServiceRepository $ServiceRepository
if ($LASTEXITCODE -ne 0) {
    throw "Local QA Postgres failed to start."
}

Push-Location $databaseRepositoryPath
try {
    & $flyway.Source "-configFiles=$flywayConfigPath" clean migrate validate
    if ($LASTEXITCODE -ne 0) {
        throw "Flyway clean/migrate/validate failed with exit code $LASTEXITCODE."
    }
}
finally {
    Pop-Location
}

Write-Host "Local QA database is empty and migrated: $expectedJdbcUrl" -ForegroundColor Green
