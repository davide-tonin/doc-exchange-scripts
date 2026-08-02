# OpenAPI internal-spec smoke generation (ledger task OAS-004).
#
# Fetches the generated INTERNAL OpenAPI document from a running instance, saves it under build/,
# and runs an OpenAPI Generator `typescript-angular` smoke generation into build/openapi-smoke to
# prove the internal spec produces Angular client models (every *ExpandedResponse / *Refs / RefInfo /
# TenantRefInfo / TenantRefAddress and the typed Industry enum + tenant profiles). Nothing generated
# is committed: build/ is gitignored.
#
# Prerequisites:
#   1. The app is running and reachable at -BaseUrl (start it with .\run-app.ps1).
#   2. Node/npx on PATH (the OpenAPI Generator CLI is fetched via npx; no global install needed).
#
# The generator + CLI-wrapper versions are PINNED below so the smoke is reproducible. Record the
# printed versions in the ledger evidence for OAS-004.
#
# Usage:
#   .\openapi-smoke.ps1
#   .\openapi-smoke.ps1 -BasicUser user -BasicPassword $env:OPENAPI_SMOKE_PASSWORD
#   .\openapi-smoke.ps1 -BaseUrl http://localhost:8080/api -GeneratorVersion 7.13.0

param(
    [string] $ServiceRepository = "C:\\Users\\DavideTonin\\IdeaProjects\\doc-exchange-service",
    [string] $BaseUrl = "http://localhost:8080/api",
    [string] $BasicUser,
    [string] $BasicPassword,
    # Pinned OpenAPI Generator (the JAR that actually generates). Bump deliberately, not silently.
    [string] $GeneratorVersion = "7.13.0",
    # Pinned @openapitools/openapi-generator-cli npm wrapper version.
    [string] $CliVersion = "2.20.0"
)

$ErrorActionPreference = "Stop"

$repoRoot = (Resolve-Path -LiteralPath $ServiceRepository).Path
$buildDir = Join-Path $repoRoot "build"
$specFile = Join-Path $buildDir "internal-openapi.json"
$outDir   = Join-Path $buildDir "openapi-smoke"

New-Item -ItemType Directory -Force -Path $buildDir | Out-Null

$requestHeaders = @{
    # QA/test runs may deliberately disable the TID secret snapshot. Supplying
    # caller-owned request metadata keeps the normal request-context filter deterministic.
    "X-Correlation-Id" = [Guid]::NewGuid().ToString()
    "X-Idempotency-Key" = [Guid]::NewGuid().ToString()
}
if ([string]::IsNullOrWhiteSpace($BasicUser) -ne [string]::IsNullOrWhiteSpace($BasicPassword)) {
    throw "BasicUser and BasicPassword must be supplied together"
}
if (-not [string]::IsNullOrWhiteSpace($BasicUser)) {
    $basicBytes = [Text.Encoding]::UTF8.GetBytes("${BasicUser}:${BasicPassword}")
    $requestHeaders["Authorization"] = "Basic $([Convert]::ToBase64String($basicBytes))"
}

$specUrl = "$BaseUrl/v3/api-docs/internal"
Write-Host "Fetching internal OpenAPI spec from $specUrl"
Invoke-WebRequest -Uri $specUrl -Headers $requestHeaders -OutFile $specFile -UseBasicParsing
Write-Host "Saved internal spec to $specFile"
$specInput = "build/internal-openapi.json"
$cliConfig = "build/openapitools.json"

$cli = "@openapitools/openapi-generator-cli@$CliVersion"

Push-Location $repoRoot
try {
    Write-Host "Pinning OpenAPI Generator to $GeneratorVersion (CLI wrapper $CliVersion)"
    & npx --yes $cli --openapitools $cliConfig version-manager set $GeneratorVersion
    if ($LASTEXITCODE -ne 0) { throw "openapi-generator-cli version-manager set failed" }

    Write-Host "Validating $specFile"
    & npx --yes $cli --openapitools $cliConfig validate -i $specInput
    if ($LASTEXITCODE -ne 0) { throw "internal spec failed OpenAPI validation" }

    if (Test-Path $outDir) { Remove-Item -Recurse -Force $outDir }
    Write-Host "Generating typescript-angular models into $outDir"
    & npx --yes $cli --openapitools $cliConfig generate -g typescript-angular -i $specInput -o $outDir
    if ($LASTEXITCODE -ne 0) { throw "typescript-angular smoke generation failed" }
}
finally {
    Pop-Location
}

Write-Host "OpenAPI smoke generation OK."
Write-Host "  spec : $specFile"
Write-Host "  models: $outDir"
Write-Host "Record the generator version ($GeneratorVersion) and CLI wrapper ($CliVersion) in the ledger (OAS-004)."
