param(
    [string] $ServiceRepository = "C:\\Users\\DavideTonin\\IdeaProjects\\doc-exchange-service",
    [string] $Container = "doc-exchange-postgres",
    [string] $Database = "de-db",
    [string] $DatabaseUser = "postgres",
    [string] $FlywayConfig
)

$ErrorActionPreference = "Stop"

$repoRoot = (Resolve-Path -LiteralPath $ServiceRepository).Path
$seedFile = Join-Path $PSScriptRoot "seed-ui.sql"

if (-not (Test-Path -LiteralPath $seedFile -PathType Leaf)) {
    throw "UI seed SQL was not found at $seedFile"
}

function Get-ConfigValue {
    param(
        [string[]] $Lines,
        [string] $Key
    )

    $prefix = "$Key="
    $line = $Lines | Where-Object { $_.StartsWith($prefix) } | Select-Object -Last 1
    if (-not $line) {
        throw "Required '$Key' entry is missing from the Flyway config."
    }
    return $line.Substring($prefix.Length)
}

function Find-Psql {
    $command = Get-Command psql -ErrorAction SilentlyContinue
    if ($command) {
        return $command.Source
    }

    $candidates = Get-ChildItem "C:\Program Files\PostgreSQL" `
        -Recurse `
        -Filter "psql.exe" `
        -ErrorAction SilentlyContinue |
        Where-Object { $_.FullName -match "\\bin\\psql\.exe$" } |
        Sort-Object FullName -Descending

    if (-not $candidates) {
        throw "psql was not found. Install PostgreSQL client tools or use Docker mode."
    }
    return $candidates[0].FullName
}

if ($FlywayConfig) {
    $resolvedConfig = Resolve-Path -LiteralPath $FlywayConfig -ErrorAction Stop
    $configLines = Get-Content -LiteralPath $resolvedConfig
    $jdbcUrl = Get-ConfigValue $configLines "flyway.url"
    $DatabaseUser = Get-ConfigValue $configLines "flyway.user"
    $databasePassword = Get-ConfigValue $configLines "flyway.password"

    if ($jdbcUrl -notmatch "^jdbc:postgresql://([^/:]+)(?::(\d+))?/([^?]+)") {
        throw "Unsupported Flyway PostgreSQL URL: $jdbcUrl"
    }

    $databaseHost = $Matches[1]
    $databasePort = if ($Matches[2]) { $Matches[2] } else { "5432" }
    $Database = $Matches[3]
    $psql = Find-Psql

    $env:PGPASSWORD = $databasePassword
    try {
        $tenantTable = & $psql -X -h $databaseHost -p $databasePort `
            -U $DatabaseUser -d $Database -Atc `
            "SELECT to_regclass('de_schema.tenant') IS NOT NULL;"
        if ($LASTEXITCODE -ne 0 -or $tenantTable.Trim() -ne "t") {
            throw "The Flyway-configured database has not been migrated."
        }

        Write-Host "Seeding deterministic UI fixtures through the Flyway database login..."
        & $psql -X -v ON_ERROR_STOP=1 -P pager=off `
            -h $databaseHost -p $databasePort `
            -U $DatabaseUser -d $Database `
            -f $seedFile
    }
    finally {
        Remove-Item Env:PGPASSWORD -ErrorAction SilentlyContinue
    }
}
else {
    & "$PSScriptRoot\dev-db.ps1" up -ServiceRepository $repoRoot

    $containerState = docker inspect --format `
        "{{.State.Status}} {{if .State.Health}}{{.State.Health.Status}}{{end}}" `
        $Container 2>$null
    if ($LASTEXITCODE -ne 0 -or $containerState -notmatch "^running healthy$") {
        throw "PostgreSQL container '$Container' is not running and healthy."
    }

    $tenantTable = docker exec $Container psql -U $DatabaseUser -d $Database -Atc `
        "SELECT to_regclass('de_schema.tenant') IS NOT NULL;"
    if ($LASTEXITCODE -ne 0 -or $tenantTable.Trim() -ne "t") {
        throw (
            "The database inside '$Container' has not been migrated. Apply the " +
            "doc-exchange-db migrations, then rerun .\scripts\seed-ui.ps1."
        )
    }

    Write-Host "Seeding deterministic UI fixtures inside $Container..."
    $seedSql = Get-Content -LiteralPath $seedFile -Raw
    $seedSql | docker exec -i $Container psql `
        -X `
        -v ON_ERROR_STOP=1 `
        -P pager=off `
        -U $DatabaseUser `
        -d $Database
}

if ($LASTEXITCODE -ne 0) {
    throw "UI seed failed. PostgreSQL rolled back the fixture transaction."
}

Write-Host ""
Write-Host "UI seed complete: 80 application tenants plus the migration-owned system tenant."
Write-Host "Rerunning this command is safe; deterministic fixture rows are not duplicated."
