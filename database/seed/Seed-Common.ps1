# Shared runtime for the UI volume seed: HTTP, retries, rate-limit backoff, psql, logging.
# Dot-sourced by Seed-Phases.ps1 and database\seed-ui.ps1. Windows PowerShell 5.1 compatible.

Set-StrictMode -Version 2.0

$script:SeedStats = [ordered]@{
    Requests     = 0
    Retries      = 0
    RateLimited  = 0
    Failures     = 0
}

function Write-SeedPhase
{
    param([string] $Message)
    Write-Host ""
    Write-Host ("[{0}] {1}" -f (Get-Date -Format "HH:mm:ss"), $Message) -ForegroundColor Cyan
}

function Write-SeedStep
{
    param([string] $Message)
    Write-Host ("    {0}" -f $Message) -ForegroundColor DarkGray
}

function Write-SeedWarn
{
    param([string] $Message)
    Write-Host ("    ! {0}" -f $Message) -ForegroundColor Yellow
}

function ConvertTo-SeedJson
{
    param([Parameter(Mandatory = $true)] $Value)
    # Depth 30: shape schemas and DSL filters nest deeply; ConvertTo-Json truncates silently at 2.
    # -InputObject rather than the pipeline: piping unrolls a top-level array and would turn a
    # one-element array body into a bare scalar.
    return (ConvertTo-Json -InputObject $Value -Depth 30 -Compress)
}

function Read-SeedErrorBody
{
    param($Exception)
    try
    {
        $response = $Exception.Response
        if ($null -eq $response) { return "" }
        $stream = $response.GetResponseStream()
        $reader = New-Object System.IO.StreamReader($stream)
        $text = $reader.ReadToEnd()
        $reader.Close()
        return $text
    }
    catch
    {
        return ""
    }
}

<#
.SYNOPSIS
One API call with rate-limit and transient-failure handling.

.DESCRIPTION
Returns a result object carrying Status, Json (parsed body or $null), ETag and Location.
Non-success statuses listed in -AllowStatus are returned rather than thrown, which is how
the deliberate cap-exceeded and conflict fixtures are recorded instead of aborting the run.

429 is always retried after Retry-After (or a 2s floor); the seeder deliberately never
falls back to the /internal plane, whose ADMIN bucket is an order of magnitude tighter.
#>
function Invoke-SeedApi
{
    param(
        [Parameter(Mandatory = $true)] [string] $Context,
        [Parameter(Mandatory = $true)] [ValidateSet("GET", "POST", "PUT", "PATCH", "DELETE")] [string] $Method,
        [Parameter(Mandatory = $true)] [string] $Path,
        $Body,
        [string] $Token,
        [string] $BasicCredential,
        [hashtable] $Header,
        [int[]] $AllowStatus = @(),
        [int] $MaxAttempts = 4
    )

    $uri = "{0}{1}" -f $script:SeedBaseUrl, $Path
    $attempt = 0

    while ($true)
    {
        $attempt++
        $headers = @{ "Accept" = "application/json" }
        if ($Header) { foreach ($key in $Header.Keys) { $headers[$key] = $Header[$key] } }
        if ($Token) { $headers["Authorization"] = "Bearer $Token" }
        if ($BasicCredential) { $headers["Authorization"] = "Basic $BasicCredential" }

        $arguments = @{
            Uri             = $uri
            Method          = $Method
            Headers         = $headers
            UseBasicParsing = $true
            TimeoutSec      = 60
            ErrorAction     = "Stop"
        }
        if ($null -ne $Body)
        {
            # Explicit UTF-8 bytes: PS 5.1 would otherwise send the body as Latin-1 and
            # mangle every accented display name in the dataset.
            $json = ConvertTo-SeedJson $Body
            $arguments["Body"] = [Text.Encoding]::UTF8.GetBytes($json)
            $arguments["ContentType"] = "application/json; charset=utf-8"
        }

        try
        {
            $script:SeedStats.Requests++
            $response = Invoke-WebRequest @arguments
            $parsed = $null
            if ($response.Content -and $response.Content.Trim().Length -gt 0)
            {
                try { $parsed = $response.Content | ConvertFrom-Json } catch { $parsed = $null }
            }
            return [pscustomobject]@{
                Status   = [int] $response.StatusCode
                Json     = $parsed
                ETag     = $response.Headers["ETag"]
                Location = $response.Headers["Location"]
                Ok       = $true
            }
        }
        catch
        {
            $exception = $_.Exception
            $status = 0
            if ($exception.PSObject.Properties["Response"] -and $null -ne $exception.Response)
            {
                $status = [int] $exception.Response.StatusCode
            }
            $bodyText = Read-SeedErrorBody $exception

            if ($status -eq 429)
            {
                $script:SeedStats.RateLimited++
                $wait = 2
                try
                {
                    $retryAfter = $exception.Response.Headers["Retry-After"]
                    if ($retryAfter) { $wait = [Math]::Max(1, [int] $retryAfter) }
                }
                catch { $wait = 2 }
                Write-SeedWarn "rate limited on $Context; waiting ${wait}s"
                Start-Sleep -Seconds $wait
                continue
            }

            if ($AllowStatus -contains $status)
            {
                $parsed = $null
                if ($bodyText) { try { $parsed = $bodyText | ConvertFrom-Json } catch { $parsed = $null } }
                return [pscustomobject]@{
                    Status   = $status
                    Json     = $parsed
                    ETag     = $null
                    Location = $null
                    Ok       = $false
                }
            }

            $transient = ($status -ge 500) -or ($status -eq 0)
            if ($transient -and $attempt -lt $MaxAttempts)
            {
                $script:SeedStats.Retries++
                $backoff = [Math]::Pow(2, $attempt)
                Write-SeedWarn "$Context failed with status $status; retry $attempt in ${backoff}s"
                Start-Sleep -Seconds $backoff
                continue
            }

            $script:SeedStats.Failures++
            throw ("{0} -> {1} {2} failed with status {3}: {4}" -f $Context, $Method, $Path, $status, $bodyText)
        }
    }
}

function Initialize-SeedHttp
{
    param(
        [Parameter(Mandatory = $true)] [string] $BaseUrl,
        [Parameter(Mandatory = $true)] [string] $BrowserOrigin
    )
    $script:SeedBaseUrl = $BaseUrl.TrimEnd("/")
    $script:SeedBrowserOrigin = $BrowserOrigin
    [Net.ServicePointManager]::DefaultConnectionLimit = 32
}

function Get-SeedStats
{
    return $script:SeedStats
}

<#
.SYNOPSIS
Basic login for one seeded tenant admin, returning the bearer token.
#>
function Get-SeedAccessToken
{
    param(
        [Parameter(Mandatory = $true)] [string] $Email,
        [Parameter(Mandatory = $true)] [string] $Password
    )
    $pair = "{0}:{1}" -f $Email, $Password
    $encoded = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($pair))

    # Origin is mandatory on session-mutating routes (OriginValidator) and must equal the
    # origin of app.web.public-api-base-url.
    $result = Invoke-SeedApi -Context "login $Email" -Method POST -Path "/internal/auth/basic" `
        -BasicCredential $encoded -Header @{ "Origin" = $script:SeedBrowserOrigin }

    return $result.Json.access_token
}

<#
.SYNOPSIS
Tenant-scoped public-plane call. The wildcard segment of /v1/tenants/*/... is the tenant's
canonical alias.
#>
function Invoke-SeedTenantApi
{
    param(
        [Parameter(Mandatory = $true)] $Tenant,
        [Parameter(Mandatory = $true)] [string] $Context,
        [Parameter(Mandatory = $true)] [string] $Method,
        [Parameter(Mandatory = $true)] [string] $Route,
        $Body,
        [hashtable] $Header,
        [int[]] $AllowStatus = @()
    )
    $path = "/v1/tenants/{0}{1}" -f $Tenant.CanonicalAlias, $Route
    return Invoke-SeedApi -Context ("{0} [{1}]" -f $Context, $Tenant.Key) -Method $Method -Path $path `
        -Body $Body -Token $Tenant.AccessToken -Header $Header -AllowStatus $AllowStatus
}

<#
.SYNOPSIS
Runs one SQL statement against the local QA database as the container superuser.

.DESCRIPTION
Used only for the two things the API cannot express: promoting verifiable aliases through
fn_alias_transition, and backdating document/trace timestamps. Refuses to run against
anything but the local compose container.
#>
function Invoke-SeedSql
{
    param(
        [Parameter(Mandatory = $true)] [string] $Sql,
        [string] $Container = "doc-exchange-postgres",
        [switch] $Quiet
    )
    $arguments = @(
        "exec", "-e", "PGPASSWORD=postgres", $Container,
        "psql", "-U", "postgres", "-d", "de-db",
        "-v", "ON_ERROR_STOP=1", "-X", "-q", "-t", "-A",
        "-c", $Sql
    )
    $output = & docker @arguments 2>&1
    if ($LASTEXITCODE -ne 0)
    {
        throw ("psql failed ({0}): {1}" -f $LASTEXITCODE, ($output -join "`n"))
    }
    if (-not $Quiet) { return $output }
    return $null
}

function Test-SeedDatabaseReachable
{
    param([string] $Container = "doc-exchange-postgres")
    try
    {
        Invoke-SeedSql -Sql "SELECT 1;" -Container $Container -Quiet | Out-Null
        return $true
    }
    catch
    {
        return $false
    }
}
