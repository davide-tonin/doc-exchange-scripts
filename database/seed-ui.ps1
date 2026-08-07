<#
.SYNOPSIS
Fills the local QA database with a realistic, fully interlinked UI dataset.

.DESCRIPTION
Resets and migrates the local QA database, waits for a fresh QA process, then drives the real
public API to build ten tenants with aliases, roles, POVs, shapes, identities, grants, groups,
cross-tenant shares, party groups and several hundred documents — sized against the service's
own caps and page sizes so the UI meets pagination, limit alerts, lifecycle badges and
cross-tenant screens with actual data behind them.

No email is involved. The local QA document enables tenant-init seed echo, so every tenant
receives the real init token in the 202 response and bootstraps through the production
fn_tenant_bootstrap path without a human opening an inbox.

Everything created is described in doc-exchange-service\docs\UI_SEED_DATASET.md, and everything
created is written to the run manifest at the end.

.PARAMETER Scale
Full is the real dataset (~3,500 writes, a few minutes). Fast keeps the same shape — same
tenants, same relationships, same edge states — with roughly a sixth of the rows.

.PARAMETER Seed
Drives every name-pool shuffle and payload choice. The same seed against the same database
revision produces the same graph.

.PARAMETER SkipReset
Seeds on top of whatever is already there. Only useful when a previous run died mid-way; the
seeder does not reconcile existing rows, so a clean reset is the supported path. The existing
database must already expose the OAuth2 schema contract at migration V052 or the seed aborts.

.EXAMPLE
.\seed-ui.ps1

.EXAMPLE
.\seed-ui.ps1 -Scale Fast -Seed 7
#>
param(
    [string] $ServiceRepository = "C:\Users\DavideTonin\IdeaProjects\doc-exchange-service",
    [string] $DatabaseRepository = "C:\Users\DavideTonin\DataGripProjects\doc-exchange-db",
    [string] $BaseUrl = "http://localhost:8080/api",
    [string] $BrowserOrigin = "http://localhost:4200",
    [string] $LoginPassword = "UiPlayground!2026",
    [ValidateSet("Full", "Fast")] [string] $Scale = "Full",
    [int] $Seed = 20260802,
    [int] $HealthTimeoutSeconds = 120,
    [int] $BackdateDays = 90,
    [string] $ManifestPath,
    [string] $PostgresContainer = "doc-exchange-postgres",
    [switch] $SkipReset,
    [switch] $SkipPostmanEnvironment
)

$ErrorActionPreference = "Stop"
$totalStopwatch = [Diagnostics.Stopwatch]::StartNew()

. "$PSScriptRoot\seed\Seed-Phases.ps1"

# --- Guard rails -------------------------------------------------------------------------------

if ([string]::IsNullOrWhiteSpace($LoginPassword)) { throw "LoginPassword cannot be empty." }

$serviceRepositoryPath = (Resolve-Path -LiteralPath $ServiceRepository).Path
$baseUri = [Uri] $BaseUrl
if ($baseUri.Host -notin @("localhost", "127.0.0.1", "::1"))
{
    throw "Refusing to seed a non-loopback target: $BaseUrl"
}
if ([string]::IsNullOrWhiteSpace($ManifestPath))
{
    $ManifestPath = Join-Path $serviceRepositoryPath "build\seed\seed-manifest.json"
}

Initialize-SeedHttp -BaseUrl $BaseUrl -BrowserOrigin $BrowserOrigin
Initialize-SeedSql -DatabaseRepository $DatabaseRepository -Container $PostgresContainer

# --- Phase 0: reset and health ------------------------------------------------------------------

$applicationPort = $baseUri.Port
$previousListener = Get-NetTCPConnection -LocalPort $applicationPort -State Listen -ErrorAction SilentlyContinue |
    Select-Object -First 1
$previousApplicationPid = $null
if ($null -ne $previousListener) { $previousApplicationPid = $previousListener.OwningProcess }

if (-not $SkipReset)
{
    Write-SeedPhase "Phase 0/8 - resetting and migrating the local QA database"
    & "$PSScriptRoot\qa-db-reset.ps1" -ServiceRepository $serviceRepositoryPath -DatabaseRepository $DatabaseRepository
    if ($LASTEXITCODE -ne 0) { throw "Database reset failed." }

    if ($null -eq $previousApplicationPid)
    {
        Read-Host "Start IntelliJ 'Main - QA', then press Enter"
    }
    else
    {
        Read-Host "Restart IntelliJ 'Main - QA' to clear pre-reset JVM caches, then press Enter"
    }
}

Write-SeedPhase "Waiting for a healthy QA application at $BaseUrl"
$deadline = [DateTimeOffset]::UtcNow.AddSeconds($HealthTimeoutSeconds)
$healthy = $false
do
{
    try
    {
        $health = Invoke-RestMethod -Uri "$BaseUrl/actuator/health" -TimeoutSec 3
        $freshProcess = $true
        if (-not $SkipReset -and $null -ne $previousApplicationPid)
        {
            $currentListener = Get-NetTCPConnection -LocalPort $applicationPort -State Listen -ErrorAction SilentlyContinue |
                Select-Object -First 1
            $freshProcess = ($null -ne $currentListener) -and ($currentListener.OwningProcess -ne $previousApplicationPid)
        }
        $healthy = $freshProcess -and $health.status -eq "UP" -and $health.components.db.status -eq "UP"
    }
    catch { $healthy = $false }
    if (-not $healthy) { Start-Sleep -Seconds 2 }
}
while (-not $healthy -and [DateTimeOffset]::UtcNow -lt $deadline)

if (-not $healthy) { throw "QA did not become healthy within $HealthTimeoutSeconds seconds." }
Write-SeedStep "QA is UP with database health UP"

if (-not (Test-SeedDatabaseReachable))
{
    throw ("Cannot reach the migrated local QA database through the '$PostgresContainer' psql client. " +
        "The alias-promotion and backdating passes need the same database used by the application.")
}

$oauth2SchemaState = (Invoke-SeedSql -Sql @"
SELECT CONCAT_WS('|',
    COALESCE((
        SELECT MAX(version)::TEXT
        FROM de_schema.flyway_schema_history
        WHERE success = TRUE
    ), ''),
    EXISTS (
        SELECT 1 FROM information_schema.columns
        WHERE table_schema = 'de_schema'
          AND table_name = 'identity'
          AND column_name = 'oauth2_provider'
    ),
    EXISTS (
        SELECT 1 FROM information_schema.columns
        WHERE table_schema = 'de_schema'
          AND table_name = 'tenant'
          AND column_name = 'google_hosted_domain'
    ),
    EXISTS (
        SELECT 1 FROM information_schema.columns
        WHERE table_schema = 'de_schema'
          AND table_name = 'tenant'
          AND column_name = 'microsoft_entra_tenant_id'
    )
);
"@ | Out-String).Trim()

if ($oauth2SchemaState -ne '052|t|t|t')
{
    throw ("The local QA database is stale (schema contract '$oauth2SchemaState'; expected " +
        "'052|t|t|t'). Run seed-ui.ps1 without -SkipReset so Flyway clean/migrate rebuilds " +
        "the database from the OAuth2 schema before the service or UI reads identities.")
}
Write-SeedStep "OAuth2 database schema contract V052 is present"

# --- Phases 1-8 ---------------------------------------------------------------------------------

$dataset = Get-SeedDataset -Scale $Scale
Write-SeedStep ("dataset '{0}': {1} tenants, seed {2}" -f $Scale, $dataset.Tenants.Count, $Seed)

$tenants = Invoke-SeedPhaseTenants -Dataset $dataset -Password $LoginPassword
Invoke-SeedPhaseLogin -Tenants $tenants -Password $LoginPassword
Invoke-SeedPhaseTenantGraph -Tenants $tenants -Dataset $dataset -Password $LoginPassword -Seed $Seed
Invoke-SeedPhaseAliasPromotion -Tenants $tenants
$shareRecords = Invoke-SeedPhaseCrossTenant -Tenants $tenants -Dataset $dataset -Seed $Seed
$documentsSent = Invoke-SeedPhaseDocuments -Tenants $tenants -Dataset $dataset -Seed $Seed -Password $LoginPassword
Invoke-SeedPhaseBackdate -Days $BackdateDays
Invoke-SeedPhaseReads -Tenants $tenants -Password $LoginPassword

# --- Manifest and Postman handoff ----------------------------------------------------------------

$manifest = Export-SeedManifest -Tenants $tenants -ShareRecords $shareRecords -Password $LoginPassword `
    -Path $ManifestPath -BaseUrl $BaseUrl -DocumentsSent $documentsSent

if (-not $SkipPostmanEnvironment)
{
    # Keep the existing Postman collections usable against the seeded database by pointing their
    # primary/peer fixtures at the two anchor tenants.
    $environmentPath = Join-Path $serviceRepositoryPath "postman\environments\local-qa.postman_environment.json"
    if (Test-Path -LiteralPath $environmentPath)
    {
        $document = Get-Content -LiteralPath $environmentPath -Raw -Encoding UTF8 | ConvertFrom-Json
        function Set-Value([string] $Key, [string] $Value, [string] $Type = "default")
        {
            $entry = $document.values | Where-Object { $_.key -eq $Key } | Select-Object -First 1
            if ($null -eq $entry)
            {
                $document.values += [PSCustomObject]@{ key = $Key; value = $Value; type = $Type; enabled = $true }
            }
            else { $entry.value = $Value; $entry.type = $Type }
        }

        $primary = $tenants["aurora"]
        $peer = $tenants["lumen"]
        Set-Value "primary_email" $primary.Email
        Set-Value "primary_password" $LoginPassword "secret"
        Set-Value "primary_alias" $primary.CanonicalAlias
        Set-Value "primary_canonical_alias" $primary.CanonicalAlias
        Set-Value "primary_tenant_id" $primary.TenantId
        Set-Value "primary_admin_identity_id" $primary.AdminIdentityId
        Set-Value "primary_admin_role_id" $primary.AdminRoleId
        Set-Value "primary_default_pov_id" $primary.DefaultPovId
        Set-Value "primary_access_token" $primary.AccessToken "secret"
        Set-Value "peer_email" $peer.Email
        Set-Value "peer_password" $LoginPassword "secret"
        Set-Value "peer_alias" $peer.CanonicalAlias
        Set-Value "peer_canonical_alias" $peer.CanonicalAlias
        Set-Value "peer_tenant_id" $peer.TenantId
        Set-Value "peer_admin_identity_id" $peer.AdminIdentityId
        Set-Value "peer_admin_role_id" $peer.AdminRoleId
        Set-Value "peer_default_pov_id" $peer.DefaultPovId
        Set-Value "peer_access_token" $peer.AccessToken "secret"

        [IO.File]::WriteAllText($environmentPath, ($document | ConvertTo-Json -Depth 100), [Text.UTF8Encoding]::new($false))
        Write-SeedStep "Postman environment repointed at the seeded anchor tenants"
    }
}

# --- Summary --------------------------------------------------------------------------------------

$stats = Get-SeedStats
Write-Host ""
Write-Host ("UI seed complete in {0:mm\:ss}." -f $totalStopwatch.Elapsed) -ForegroundColor Green
Write-Host ("Requests {0} | retries {1} | rate-limit waits {2} | failures {3}" -f `
    $stats.Requests, $stats.Retries, $stats.RateLimited, $stats.Failures)
Write-Host ("Documents sent: {0}" -f $documentsSent)
Write-Host ("Manifest: {0}" -f $manifest)
Write-Host ""
Write-Host "Logins (all tenants share the same password):" -ForegroundColor Cyan
foreach ($key in $tenants.Keys)
{
    $tenant = $tenants[$key]
    Write-Host ("  {0,-38} {1,-32} {2}" -f $tenant.DisplayName, $tenant.Email, $tenant.CanonicalAlias)
}
Write-Host ("  password: {0}" -f $LoginPassword)
