param(
    [ValidateSet("up", "down", "restart", "logs")]
    [string] $Command = "up",
    [string] $ServiceRepository = "C:\Users\DavideTonin\IdeaProjects\doc-exchange-service"
)

$ErrorActionPreference = "Stop"

$serviceRepositoryPath = (Resolve-Path -LiteralPath $ServiceRepository).Path
$composeFile = Join-Path $serviceRepositoryPath "docker-compose.yml"
if (-not (Test-Path -LiteralPath $composeFile)) {
    throw "Service Docker Compose file not found: $composeFile"
}
& "$PSScriptRoot\Ensure-Docker.ps1"

Push-Location $serviceRepositoryPath
try {
    switch ($Command) {
        "up" {
            docker compose up -d postgres
            docker compose ps postgres
        }
        "down" {
            docker compose down
        }
        "restart" {
            docker compose restart postgres
            docker compose ps postgres
        }
        "logs" {
            docker compose logs -f postgres
        }
    }
}
finally {
    Pop-Location
}
