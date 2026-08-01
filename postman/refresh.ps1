param(
    [string] $ServiceRepository = "C:\\Users\\DavideTonin\\IdeaProjects\\doc-exchange-service",
    [string] $BaseUrl = "http://localhost:8080/api",
    [string] $PublicSpec,
    [string] $InternalSpec,
    [switch] $UseTestExport,
    [switch] $Check
)

$ErrorActionPreference = "Stop"
$repoRoot = (Resolve-Path -LiteralPath $ServiceRepository).Path
$postmanRoot = Join-Path $repoRoot "postman"
$openApiDirectory = Join-Path $repoRoot "build\postman\openapi"
$generatedDirectory = Join-Path $postmanRoot "generated"

if ([string]::IsNullOrWhiteSpace($PublicSpec) -ne [string]::IsNullOrWhiteSpace($InternalSpec)) {
    throw "PublicSpec and InternalSpec must be supplied together."
}

if ($UseTestExport -and -not [string]::IsNullOrWhiteSpace($PublicSpec)) {
    throw "UseTestExport cannot be combined with explicit spec paths."
}

if ($UseTestExport) {
    & "$PSScriptRoot\..\application\test.ps1" -ServiceRepository $repoRoot test --tests "eu.davide.support.integration.PostmanOpenApiExportIT"
    if ($LASTEXITCODE -ne 0) {
        throw "Test-profile OpenAPI export failed."
    }
    $PublicSpec = Join-Path $openApiDirectory "public.json"
    $InternalSpec = Join-Path $openApiDirectory "internal.json"
} elseif ([string]::IsNullOrWhiteSpace($PublicSpec)) {
    New-Item -ItemType Directory -Force -Path $openApiDirectory | Out-Null
    $PublicSpec = Join-Path $openApiDirectory "public.json"
    $InternalSpec = Join-Path $openApiDirectory "internal.json"
    $headers = @{
        "X-Correlation-Id" = [Guid]::NewGuid().ToString()
        "X-Idempotency-Key" = [Guid]::NewGuid().ToString()
    }

    Write-Host "Fetching public OpenAPI from $BaseUrl/v3/api-docs/public"
    Invoke-WebRequest `
        -Uri "$BaseUrl/v3/api-docs/public" `
        -Headers $headers `
        -OutFile $PublicSpec `
        -UseBasicParsing
    Write-Host "Fetching internal OpenAPI from $BaseUrl/v3/api-docs/internal"
    Invoke-WebRequest `
        -Uri "$BaseUrl/v3/api-docs/internal" `
        -Headers $headers `
        -OutFile $InternalSpec `
        -UseBasicParsing
}

if (-not (Test-Path -LiteralPath $PublicSpec) -or -not (Test-Path -LiteralPath $InternalSpec)) {
    throw "Both OpenAPI files must exist. Public=$PublicSpec Internal=$InternalSpec"
}

if (-not (Test-Path -LiteralPath (Join-Path $postmanRoot "node_modules\.bin\newman.cmd"))) {
    Write-Host "Installing pinned Postman tooling with npm ci"
    & npm ci --prefix $postmanRoot --no-audit --no-fund
    if ($LASTEXITCODE -ne 0) {
        throw "npm ci failed."
    }
}

$arguments = @(
    (Join-Path $postmanRoot "generator.mjs"),
    "--public", (Resolve-Path -LiteralPath $PublicSpec).Path,
    "--internal", (Resolve-Path -LiteralPath $InternalSpec).Path,
    "--manifest", (Join-Path $postmanRoot "scenarios.json"),
    "--out-dir", $generatedDirectory
)
if ($Check) {
    $arguments += "--check"
}

& node @arguments
if ($LASTEXITCODE -ne 0) {
    throw "Postman generation failed."
}

Write-Host "Postman artifacts are current:"
Write-Host "  $generatedDirectory"
