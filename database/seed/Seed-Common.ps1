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
        [int] $MaxAttempts = 4,
        [int] $TimeoutSec = 60
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
            TimeoutSec      = $TimeoutSec
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
            $transportDetail = ""
            if ($status -eq 0)
            {
                $transportDetail = $exception.Message
                if ($exception.InnerException -and $exception.InnerException.Message)
                {
                    $transportDetail = "$transportDetail | $($exception.InnerException.Message)"
                }
            }
            throw ("{0} -> {1} {2} failed with status {3}: {4}{5}" -f `
                $Context, $Method, $Path, $status, $bodyText, $transportDetail)
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
        [int[]] $AllowStatus = @(),
        [int] $MaxAttempts = 4,
        [int] $TimeoutSec = 60
    )
    $path = "/v1/tenants/{0}{1}" -f $Tenant.CanonicalAlias, $Route
    return Invoke-SeedApi -Context ("{0} [{1}]" -f $Context, $Tenant.Key) -Method $Method -Path $path `
        -Body $Body -Token $Tenant.AccessToken -Header $Header -AllowStatus $AllowStatus `
        -MaxAttempts $MaxAttempts -TimeoutSec $TimeoutSec
}

<#
.SYNOPSIS
Low-overhead document POST for bounded parallel seed workers.

.DESCRIPTION
Windows PowerShell 5.1 Invoke-WebRequest can strand responses when several runspaces share its
legacy ServicePoint transport. Document chunks use one proxy-free HttpClient each instead. The
same idempotency key is retained across the two bounded attempts, so an ambiguous committed
response is safe to retry.
#>
function Invoke-SeedDocumentHttp
{
    param(
        [Parameter(Mandatory = $true)] $Client,
        [Parameter(Mandatory = $true)] $Tenant,
        [Parameter(Mandatory = $true)] $Body,
        [Parameter(Mandatory = $true)] [string] $IdempotencyKey,
        [int] $TimeoutSec = 15,
        [int] $MaxAttempts = 2
    )

    $uri = "{0}/v1/tenants/{1}/documents/" -f $script:SeedBaseUrl, $Tenant.CanonicalAlias
    $jsonBytes = [Text.Encoding]::UTF8.GetBytes((ConvertTo-SeedJson $Body))
    for ($attempt = 1; $attempt -le $MaxAttempts; $attempt++)
    {
        $request = New-Object System.Net.Http.HttpRequestMessage(
            [System.Net.Http.HttpMethod]::Post, $uri)
        $content = New-Object System.Net.Http.ByteArrayContent -ArgumentList (, $jsonBytes)
        $content.Headers.ContentType = [System.Net.Http.Headers.MediaTypeHeaderValue]::Parse(
            "application/json; charset=utf-8")
        $request.Content = $content
        [void] $request.Headers.TryAddWithoutValidation("Accept", "application/json")
        [void] $request.Headers.TryAddWithoutValidation("Authorization", "Bearer $($Tenant.AccessToken)")
        [void] $request.Headers.TryAddWithoutValidation("Idempotency-Key", $IdempotencyKey)
        $cancellation = New-Object System.Threading.CancellationTokenSource
        $cancellation.CancelAfter([TimeSpan]::FromSeconds($TimeoutSec))
        try
        {
            $script:SeedStats.Requests++
            $response = $Client.SendAsync($request, $cancellation.Token).GetAwaiter().GetResult()
            try
            {
                $status = [int] $response.StatusCode
                $text = $response.Content.ReadAsStringAsync().GetAwaiter().GetResult()
                if ($response.IsSuccessStatusCode)
                {
                    return [pscustomobject]@{ Ok = $true; Status = $status }
                }
                if ($status -in @(400, 403, 409, 422))
                {
                    return [pscustomobject]@{ Ok = $false; Status = $status }
                }
                if (($status -eq 429 -or $status -ge 500) -and $attempt -lt $MaxAttempts)
                {
                    $script:SeedStats.Retries++
                    if ($status -eq 429) { $script:SeedStats.RateLimited++ }
                    Start-Sleep -Seconds $attempt
                    continue
                }
                $script:SeedStats.Failures++
                throw "document send [$($Tenant.Key)] failed with status ${status}: $text"
            }
            finally
            {
                if ($null -ne $response) { $response.Dispose() }
            }
        }
        catch
        {
            if ($attempt -lt $MaxAttempts)
            {
                $script:SeedStats.Retries++
                Start-Sleep -Seconds $attempt
                continue
            }
            $script:SeedStats.Failures++
            throw "document send [$($Tenant.Key)] transport failure: $($_.Exception.Message)"
        }
        finally
        {
            $cancellation.Dispose()
            $request.Dispose()
        }
    }
}

<#
.SYNOPSIS
Runs one SQL statement against the local QA database as the container superuser.

.DESCRIPTION
Used only for the two things the API cannot express: promoting verifiable aliases through
fn_alias_transition, and backdating document/trace timestamps. Refuses to run against
anything but the local compose container.
#>
function Initialize-SeedSql
{
    param(
        [Parameter(Mandatory = $true)] [string] $DatabaseRepository,
        [string] $Container = "doc-exchange-postgres"
    )

    $configPath = Join-Path (Resolve-Path -LiteralPath $DatabaseRepository).Path "flyway.conf"
    if (-not (Test-Path -LiteralPath $configPath))
    {
        throw "Flyway configuration not found: $configPath"
    }

    $properties = @{}
    Get-Content -LiteralPath $configPath | ForEach-Object {
        if ($_ -match '^\s*([^#][^=]*)=(.*)$')
        {
            $properties[$matches[1].Trim()] = $matches[2].Trim()
        }
    }

    $jdbcUrl = $properties['flyway.url']
    if ($jdbcUrl -notmatch '^jdbc:postgresql://(?<host>localhost|127\.0\.0\.1):(?<port>\d+)/(?<database>[A-Za-z0-9_-]+)$')
    {
        throw "Refusing seed SQL against non-loopback or unsupported Flyway URL: $jdbcUrl"
    }
    if ([string]::IsNullOrWhiteSpace($properties['flyway.user']) -or
        [string]::IsNullOrWhiteSpace($properties['flyway.password']))
    {
        throw "flyway.user and flyway.password are required in $configPath for seed SQL."
    }

    # The container is only a disposable psql client. Connecting through host.docker.internal
    # guarantees that direct seed SQL reaches the same localhost TCP endpoint as Flyway and the
    # application, even when a native PostgreSQL service and Docker are both present.
    $script:SeedSqlConnection = [PSCustomObject]@{
        Container = $Container
        Host = 'host.docker.internal'
        Port = [int] $matches['port']
        Database = $matches['database']
        User = $properties['flyway.user']
        Password = $properties['flyway.password']
    }
}

function Invoke-SeedSql
{
    param(
        [Parameter(Mandatory = $true)] [string] $Sql,
        [switch] $Quiet
    )
    if ($null -eq $script:SeedSqlConnection)
    {
        throw "Seed SQL is not initialized. Call Initialize-SeedSql first."
    }
    $connection = $script:SeedSqlConnection
    $arguments = @(
        "exec", "-e", ("PGPASSWORD={0}" -f $connection.Password), $connection.Container,
        "psql", "-h", $connection.Host, "-p", $connection.Port,
        "-U", $connection.User, "-d", $connection.Database,
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
    try
    {
        Invoke-SeedSql -Sql "SELECT 1 FROM de_schema.flyway_schema_history LIMIT 1;" -Quiet | Out-Null
        return $true
    }
    catch
    {
        return $false
    }
}
