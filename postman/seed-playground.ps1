param(
    [string] $ServiceRepository = "C:\Users\DavideTonin\IdeaProjects\doc-exchange-service",
    [string] $Environment = "postman\environments\local-qa.postman_environment.json"
)

$ErrorActionPreference = "Stop"
$serviceRepositoryPath = (Resolve-Path -LiteralPath $ServiceRepository).Path
$runner = Join-Path $PSScriptRoot "run.ps1"

& $runner -ServiceRepository $serviceRepositoryPath -Mode SeedPlayground -Environment $Environment

Write-Host "Playground fixtures were retained and exported to $Environment." -ForegroundColor Green
