# Phase implementations for the UI volume seed.
#
# Ordering is not cosmetic. Within a tenant: aliases -> roles -> POVs -> shapes -> identities ->
# credentials -> grants -> groups. Across tenants: every tenant finishes its own graph before any
# cross-tenant phase runs, because shares and party groups consume foreign ids.
#
# Every write goes through the PUBLIC /v1 plane. EndpointCategoryResolver classifies only
# /api/v1/tenants/ as CORE (300 req/10s per credential); /internal is ADMIN at 30 req/10s and
# would turn this run into a crawl.

Set-StrictMode -Version 2.0

. "$PSScriptRoot\Seed-Common.ps1"
. "$PSScriptRoot\Seed-Dataset.ps1"

function New-SeedRandom
{
    param([int] $Seed)
    return New-Object System.Random($Seed)
}

function Get-SeedIsoNow
{
    param([int] $AddDays = 0, [int] $AddMonths = 0)
    $value = (Get-Date).ToUniversalTime().AddDays($AddDays).AddMonths($AddMonths)
    return $value.ToString("yyyy-MM-ddTHH:mm:ss") + "Z"
}

function Get-SeedSlug
{
    param([string] $Text)
    $lower = $Text.ToLowerInvariant()
    $clean = ($lower -replace "[^a-z0-9]+", ".").Trim(".")
    return $clean
}

<#
.SYNOPSIS
Deterministic pool of distinct, realistic human names.

.DESCRIPTION
Given/family cross-product shuffled by the run seed, with a department suffix on roughly one in
four so the UI meets long punctuated names too. One name per tenant is padded to the 64-char
NAME_MAX boundary to catch truncation bugs.
#>
function Get-SeedHumanNames
{
    param(
        [Parameter(Mandatory = $true)] $Dataset,
        [Parameter(Mandatory = $true)] [int] $Count,
        [Parameter(Mandatory = $true)] $Random
    )

    $combinations = New-Object System.Collections.ArrayList
    foreach ($given in $Dataset.GivenNames)
    {
        foreach ($family in $Dataset.FamilyNames)
        {
            [void] $combinations.Add(@{ Given = $given; Family = $family })
        }
    }

    # Fisher-Yates over the cross-product, seeded, so a rerun with the same -Seed is identical.
    for ($i = $combinations.Count - 1; $i -gt 0; $i--)
    {
        $j = $Random.Next(0, $i + 1)
        $swap = $combinations[$i]; $combinations[$i] = $combinations[$j]; $combinations[$j] = $swap
    }

    $names = New-Object System.Collections.ArrayList
    for ($i = 0; $i -lt $Count; $i++)
    {
        $entry = $combinations[$i % $combinations.Count]
        $display = "{0} {1}" -f $entry.Given, $entry.Family
        if ($i % 4 -eq 1)
        {
            $department = $Dataset.Departments[$Random.Next(0, $Dataset.Departments.Count)]
            $display = "{0} - {1}" -f $display, $department
        }
        $local = ("{0}.{1}{2}" -f (Get-SeedSlug $entry.Given), (Get-SeedSlug $entry.Family), $i)
        [void] $names.Add([pscustomobject]@{
            Display = $display
            Local   = $local
        })
    }

    if ($names.Count -gt 0)
    {
        # NAME_MAX is 64; park one entry exactly on it.
        $long = "Maria Vittoria Della Rovere Pallavicini - Controllo Qualita"
        while ($long.Length -lt 64) { $long = $long + "." }
        $names[0].Display = $long.Substring(0, 64)
    }
    return $names
}

# ---------------------------------------------------------------------------------------------
# Phase 1 - tenants
# ---------------------------------------------------------------------------------------------

<#
.SYNOPSIS
Creates every tenant through the real init -> bootstrap path, with no email in the loop.

.DESCRIPTION
When the local QA seed mode is enabled, TenantInitService returns the init token in the 202 body
instead of mailing it (and sends nothing to SES). Bootstrap then runs the production
fn_tenant_bootstrap, so each tenant lands with its canonical alias, admin identity, Admin + Docs
Contributor roles, default POV, and tenant settings exactly as a real customer's would.
#>
function Invoke-SeedPhaseTenants
{
    param(
        [Parameter(Mandatory = $true)] $Dataset,
        [Parameter(Mandatory = $true)] [string] $Password
    )

    Write-SeedPhase "Phase 1/8 - bootstrapping $($Dataset.Tenants.Count) tenants (no email)"
    $created = [ordered]@{}

    foreach ($definition in $Dataset.Tenants)
    {
        $initBody = @{
            email        = $definition.Email
            password     = $Password
            user_type    = $definition.Type
            display_name = $definition.DisplayName
        }

        $init = Invoke-SeedApi -Context "init $($definition.Key)" -Method POST `
            -Path "/internal/tenants/init" -Body $initBody

        if ($null -eq $init.Json -or -not $init.Json.PSObject.Properties["init_token"] -or
            [string]::IsNullOrWhiteSpace($init.Json.init_token))
        {
            throw ("Tenant init returned no init_token. Verify the local QA process uses " +
                "app.deployment.stage = QA, app.tenant-init.seed-echo = true, loopback API/database " +
                "addresses, and a direct loopback connection; then restart and rerun.")
        }

        $token = [Uri]::EscapeDataString($init.Json.init_token)
        $bootstrap = Invoke-SeedApi -Context "bootstrap $($definition.Key)" -Method POST `
            -Path "/internal/tenants/bootstrap?init_token=$token"

        $body = $bootstrap.Json
        $tenant = [ordered]@{
            Key             = $definition.Key
            DisplayName     = $definition.DisplayName
            Type            = $definition.Type
            Email           = $definition.Email
            Domain          = $definition.Domain
            Definition      = $definition
            TenantId        = $body.tenant_id
            CanonicalAlias  = $body.canonical_alias
            CanonicalAliasId = $body.alias_id
            AdminIdentityId = $body.identity_id
            AdminRoleId     = $body.admin_role_id
            DocsRoleId      = $body.docs_role_id
            DefaultPovId    = $body.pov_id
            AccessToken     = $null
            Aliases         = New-Object System.Collections.ArrayList
            PublishedAddresses = New-Object System.Collections.ArrayList
            Roles           = New-Object System.Collections.ArrayList
            Povs            = New-Object System.Collections.ArrayList
            Shapes          = New-Object System.Collections.ArrayList
            Identities      = New-Object System.Collections.ArrayList
            Groups          = New-Object System.Collections.ArrayList
            Credentialed    = New-Object System.Collections.ArrayList
            CapHits         = New-Object System.Collections.ArrayList
        }
        $created[$definition.Key] = $tenant
        Write-SeedStep ("{0,-10} {1,-38} alias {2}" -f $definition.Key, $definition.DisplayName, $tenant.CanonicalAlias)
    }

    return $created
}

# ---------------------------------------------------------------------------------------------
# Phase 2 - login
# ---------------------------------------------------------------------------------------------

function Invoke-SeedPhaseLogin
{
    param(
        [Parameter(Mandatory = $true)] $Tenants,
        [Parameter(Mandatory = $true)] [string] $Password
    )

    Write-SeedPhase "Phase 2/8 - logging in every tenant admin"
    foreach ($key in $Tenants.Keys)
    {
        $tenant = $Tenants[$key]
        $tenant.AccessToken = Get-SeedAccessToken -Email $tenant.Email -Password $Password
        Write-SeedStep ("{0,-10} authenticated" -f $key)
    }
}

# ---------------------------------------------------------------------------------------------
# Phase 3 - per-tenant graph
# ---------------------------------------------------------------------------------------------

function Add-SeedAliases
{
    param($Tenant, $Random)

    $definition = $Tenant.Definition
    $target = $definition.Aliases
    # The canonical alias from bootstrap already counts against the cap of 25.
    $remaining = $target - 1
    if ($remaining -le 0) { return }

    foreach ($address in $definition.EmailAliases)
    {
        if ($remaining -le 0) { break }
        $result = Invoke-SeedTenantApi -Tenant $Tenant -Context "alias EMAIL" -Method POST `
            -Route "/aliases/" -Body @{ type = "EMAIL"; value = $address } -AllowStatus @(409, 422)
        if ($result.Ok)
        {
            [void] $Tenant.Aliases.Add([pscustomobject]@{ Id = $result.Json.id; Type = "EMAIL"; Value = $address })
            $remaining--
        }
        else { [void] $Tenant.CapHits.Add("alias:$address=$($result.Status)") }
    }

    if ($definition.VatId -and $remaining -gt 0)
    {
        $result = Invoke-SeedTenantApi -Tenant $Tenant -Context "alias VAT_ID" -Method POST `
            -Route "/aliases/" -Body @{ type = "VAT_ID"; value = $definition.VatId } -AllowStatus @(409, 422)
        if ($result.Ok)
        {
            [void] $Tenant.Aliases.Add([pscustomobject]@{ Id = $result.Json.id; Type = "VAT_ID"; Value = $definition.VatId })
            $remaining--
        }
        else { [void] $Tenant.CapHits.Add("alias:vat=$($result.Status)") }
    }

    # RANDOM aliases are minted server-side and are PUBLISHED immediately (non-verifiable),
    # so they are the addressing workhorse until the SQL promotion pass runs.
    for ($i = 0; $i -lt $remaining; $i++)
    {
        $result = Invoke-SeedTenantApi -Tenant $Tenant -Context "alias RANDOM" -Method POST `
            -Route "/aliases/" -Body @{ type = "RANDOM" } -AllowStatus @(409, 422)
        if (-not $result.Ok)
        {
            [void] $Tenant.CapHits.Add("alias:random=$($result.Status)")
            break
        }
        [void] $Tenant.Aliases.Add([pscustomobject]@{ Id = $result.Json.id; Type = "RANDOM"; Value = $result.Json.value })
        [void] $Tenant.PublishedAddresses.Add(("random:{0}" -f $result.Json.value))
    }
}

function Add-SeedRoles
{
    param($Tenant, $Random)

    $definition = $Tenant.Definition
    $catalog = $script:SeedRoleCatalog
    # Bootstrap already made Admin + Docs Contributor.
    $target = $definition.Roles - 2
    for ($i = 0; $i -lt $target; $i++)
    {
        $template = $catalog[$i % $catalog.Count]
        $name = $template.Name
        if ($i -ge $catalog.Count) { $name = "{0} {1}" -f $template.Name, ([Math]::Floor($i / $catalog.Count) + 1) }
        # A few roles ship DISABLED so the "granted but dead" badge has data.
        $status = "ENABLED"
        if ($i % 13 -eq 5) { $status = "DISABLED" }

        $body = @{
            allow        = $template.Allow
            status       = $status
            display_name = $name
            description  = $template.Description
        }
        $result = Invoke-SeedTenantApi -Tenant $Tenant -Context "role" -Method POST `
            -Route "/roles/" -Body $body -AllowStatus @(409, 422)
        if (-not $result.Ok) { [void] $Tenant.CapHits.Add("role=$($result.Status)"); break }
        [void] $Tenant.Roles.Add([pscustomobject]@{
            Id = $result.Json.id; Name = $name; Status = $status; Allow = $template.Allow
        })
    }
}

function New-SeedPovFilter
{
    param($Template)

    $conditions = New-Object System.Collections.ArrayList
    if ($Template.Contains("ShapePrefix"))
    {
        [void] $conditions.Add(@{ field = "doc_shape"; op = "startswith"; value = $Template.ShapePrefix })
    }
    if ($Template.Contains("SubjectPresent") -and $Template.SubjectPresent)
    {
        [void] $conditions.Add(@{ not = @{ field = "doc_subject"; op = "is_null" } })
    }
    return @{ and = $conditions.ToArray() }
}

function Add-SeedPovs
{
    param($Tenant, $Random)

    $definition = $Tenant.Definition
    $catalog = $script:SeedPovCatalog
    # Bootstrap already made the "Sent documents" default POV.
    $target = $definition.Povs - 1
    for ($i = 0; $i -lt $target; $i++)
    {
        $template = $catalog[$i % $catalog.Count]
        $name = $template.Name
        if ($i -ge $catalog.Count) { $name = "{0} {1}" -f $template.Name, ([Math]::Floor($i / $catalog.Count) + 1) }

        $body = @{
            display_name  = $name
            description   = $template.Description
            from_datetime = (Get-SeedIsoNow -AddMonths (-1 * $template.Months))
            to_datetime   = (Get-SeedIsoNow -AddMonths 12)
            tenant_role   = $template.TenantRole
            filter        = (New-SeedPovFilter $template)
        }
        $result = Invoke-SeedTenantApi -Tenant $Tenant -Context "pov" -Method POST `
            -Route "/povs/" -Body $body -AllowStatus @(409, 422)
        if (-not $result.Ok) { [void] $Tenant.CapHits.Add("pov=$($result.Status)"); break }
        [void] $Tenant.Povs.Add([pscustomobject]@{
            Id = $result.Json.id; Name = $name; TenantRole = $template.TenantRole
        })
    }
}

function Add-SeedShapes
{
    param($Tenant, $Random)

    $definition = $Tenant.Definition
    $catalog = $script:SeedShapeCatalog
    for ($i = 0; $i -lt $definition.Shapes; $i++)
    {
        $template = $catalog[$i % $catalog.Count]
        $name = $template.Name
        if ($i -ge $catalog.Count) { $name = "{0} {1}" -f $template.Name, ([Math]::Floor($i / $catalog.Count) + 1) }

        $body = @{ name = $name; description = $template.Description; schema = $template.Schema }
        $result = Invoke-SeedTenantApi -Tenant $Tenant -Context "shape" -Method POST `
            -Route "/shapes/" -Body $body -AllowStatus @(409, 422)
        if (-not $result.Ok) { [void] $Tenant.CapHits.Add("shape=$($result.Status)"); break }

        $shape = [pscustomobject]@{
            # Shape item endpoints take the ROW/version id. `id` is the stable lineage id and
            # deliberately fails the ROW checksum used by @ValidObfuscatedId.
            Id             = $result.Json.version_id
            StableId       = $result.Json.id
            Name           = $name
            NormalizedName = $result.Json.normalized_name
            Version        = $result.Json.version
            TemplateName   = $template.Name
            ETag           = $result.ETag
        }
        [void] $Tenant.Shapes.Add($shape)

        # Revise the first three lineages so the version picker has something to pick.
        if ($i -lt 3)
        {
            $revisions = 3 - $i
            for ($r = 0; $r -lt $revisions; $r++)
            {
                $revised = Invoke-SeedTenantApi -Tenant $Tenant -Context "shape revise" -Method PUT `
                    -Route ("/shapes/{0}" -f $shape.Id) -Body $body -AllowStatus @(409)
                if (-not $revised.Ok) { break }
                $shape.Id = $revised.Json.version_id
                $shape.Version = $revised.Json.version
            }
        }
    }
}

function Add-SeedIdentities
{
    param($Tenant, $Dataset, $Random, [string] $Password)

    $definition = $Tenant.Definition
    # Bootstrap already made the admin identity.
    $target = $definition.Identities - 1
    if ($target -le 0) { return }

    $humanCount = [Math]::Max(0, $target - [Math]::Min(6, [int][Math]::Floor($target / 4)))
    $serviceCount = $target - $humanCount
    $names = Get-SeedHumanNames -Dataset $Dataset -Count $humanCount -Random $Random

    for ($i = 0; $i -lt $humanCount; $i++)
    {
        $name = $names[$i]
        $status = "ENABLED"
        if ($i % 23 -eq 7) { $status = "DISABLED" }

        $body = @{
            email        = ("{0}@{1}" -f $name.Local, $Tenant.Domain)
            auth_type    = "USERNAME_PASSWORD"
            display_name = $name.Display
            status       = $status
            type         = "HUMAN"
        }
        # A handful expire soon so the expiry badge and the 24h warning have data.
        if ($i % 29 -eq 3) { $body["expires_at"] = (Get-SeedIsoNow -AddDays 45) }
        elseif ($i -eq 2) { $body["expires_at"] = (Get-SeedIsoNow -AddDays 1) }

        $result = Invoke-SeedTenantApi -Tenant $Tenant -Context "identity HUMAN" -Method POST `
            -Route "/identities/" -Body $body -AllowStatus @(409, 422)
        if (-not $result.Ok) { [void] $Tenant.CapHits.Add("identity=$($result.Status)"); return }

        [void] $Tenant.Identities.Add([pscustomobject]@{
            Id = $result.Json.id; DisplayName = $name.Display; Email = $body.email
            Type = "HUMAN"; Status = $status; ETag = $result.ETag
        })
    }

    for ($i = 0; $i -lt $serviceCount; $i++)
    {
        $base = $Dataset.ServiceNames[$i % $Dataset.ServiceNames.Count]
        $name = $base
        if ($i -ge $Dataset.ServiceNames.Count) { $name = "{0} {1}" -f $base, ([Math]::Floor($i / $Dataset.ServiceNames.Count) + 1) }

        $body = @{
            auth_type    = "API_KEY"
            display_name = $name
            status       = "ENABLED"
            type         = "SERVICE"
        }
        $result = Invoke-SeedTenantApi -Tenant $Tenant -Context "identity SERVICE" -Method POST `
            -Route "/identities/" -Body $body -AllowStatus @(409, 422)
        if (-not $result.Ok) { [void] $Tenant.CapHits.Add("identity=$($result.Status)"); return }

        [void] $Tenant.Identities.Add([pscustomobject]@{
            Id = $result.Json.id; DisplayName = $name; Email = $null
            Type = "SERVICE"; Status = "ENABLED"; ETag = $result.ETag
        })
    }
}

<#
.SYNOPSIS
Gives a few humans a real password and a few services a real API key.

.DESCRIPTION
Without this the only account anyone can sign into is the tenant admin, and every
permission-limited screen goes unverified.
#>
function Add-SeedCredentials
{
    param($Tenant, [string] $Password)

    $definition = $Tenant.Definition
    $humans = @($Tenant.Identities | Where-Object { $_.Type -eq "HUMAN" -and $_.Status -eq "ENABLED" })
    $wanted = [Math]::Min($definition.Credentialed, $humans.Count)

    for ($i = 0; $i -lt $wanted; $i++)
    {
        $identity = $humans[$i]
        $result = Invoke-SeedTenantApi -Tenant $Tenant -Context "setCredentials" -Method POST `
            -Route ("/identities/{0}:setCredentials" -f $identity.Id) `
            -Body @{ new_password = $Password } -AllowStatus @(409, 422)
        if (-not $result.Ok) { continue }
        [void] $Tenant.Credentialed.Add([pscustomobject]@{
            IdentityId = $identity.Id; DisplayName = $identity.DisplayName
            Email = $identity.Email; Password = $Password
        })
    }

    $services = @($Tenant.Identities | Where-Object { $_.Type -eq "SERVICE" })
    $rotations = [Math]::Min(2, $services.Count)
    for ($i = 0; $i -lt $rotations; $i++)
    {
        Invoke-SeedTenantApi -Tenant $Tenant -Context "rotateApiKey" -Method POST `
            -Route ("/identities/{0}:rotateApiKey" -f $services[$i].Id) -AllowStatus @(409, 422) | Out-Null
    }
}

function Add-SeedLocalGrants
{
    param($Tenant, $Random)

    # Disabled roles remain in the dataset for lifecycle/empty-state UI, but the real grant
    # validator deliberately does not resolve them as assignable permissions.
    $roles = @($Tenant.Roles | Where-Object { $_.Status -eq "ENABLED" })
    $povs = @($Tenant.Povs)
    if ($roles.Count -eq 0 -and $povs.Count -eq 0) { return }

    $index = 0
    foreach ($identity in $Tenant.Identities)
    {
        if ($roles.Count -gt 0)
        {
            $role = $roles[$index % $roles.Count]
            Invoke-SeedTenantApi -Tenant $Tenant -Context "identity role" -Method PUT `
                -Route ("/identities/{0}/role" -f $identity.Id) `
                -Body @{ role_id = $role.Id } `
                -Header @{ "If-None-Match" = "*" } -AllowStatus @(409, 412, 422, 428) | Out-Null
        }

        if ($povs.Count -gt 0)
        {
            $pov = $povs[$index % $povs.Count]
            Invoke-SeedTenantApi -Tenant $Tenant -Context "identity pov" -Method PUT `
                -Route ("/identities/{0}/povs/{1}" -f $identity.Id, $pov.Id) `
                -Body @{} `
                -Header @{ "If-None-Match" = "*" } -AllowStatus @(409, 412, 422, 428) | Out-Null
        }
        $index++
    }
}

function Add-SeedGroups
{
    param($Tenant, $Random, $AllTenants)

    $definition = $Tenant.Definition
    if ($definition.Groups -le 0) { return }

    # TENANT groups are only interesting when they name other parties, and every tenant already
    # exists by the time any tenant graph is built (bootstrap is phase 1).
    $tenantPool = New-Object System.Collections.ArrayList
    foreach ($key in $AllTenants.Keys) { [void] $tenantPool.Add($AllTenants[$key].TenantId) }

    $catalog = $script:SeedGroupCatalog
    $pools = @{
        ALIAS    = @($Tenant.Aliases | ForEach-Object { $_.Id })
        IDENTITY = @($Tenant.Identities | ForEach-Object { $_.Id })
        ROLE     = @($Tenant.Roles | Where-Object { $_.Status -eq "ENABLED" } | ForEach-Object { $_.Id })
        TENANT   = @($tenantPool.ToArray())
    }

    for ($i = 0; $i -lt $definition.Groups; $i++)
    {
        $template = $catalog[$i % $catalog.Count]
        $name = $template.Name
        if ($i -ge $catalog.Count) { $name = "{0} {1}" -f $template.Name, ([Math]::Floor($i / $catalog.Count) + 1) }

        $pool = @($pools[$template.Entity])
        if ($pool.Count -eq 0) { continue }
        $size = [Math]::Min($pool.Count, $Random.Next(1, [Math]::Min(12, $pool.Count + 1)))
        $members = @($pool | Get-Random -Count $size -SetSeed $Random.Next())

        $route = "/groups/"
        $storedEntity = $template.Entity
        if ($template.Entity -eq "TENANT")
        {
            # TENANT has no stable-id representation on any public response. Homogeneous groups
            # require stable-flagged member ids, so a client cannot lawfully construct one from
            # bootstrap/auth/directory data. PARTY is the public, round-trippable tenant grouping
            # surface and accepts the canonical row tenant ids returned by bootstrap.
            $partyMembers = @($members | ForEach-Object { @{ type = "TENANT"; value = $_ } })
            $body = @{ name = $name; description = $template.Description; members = $partyMembers }
            $route = "/groups/party"
            $storedEntity = "PARTY"
        }
        else
        {
            $body = @{
                entity_type = $template.Entity
                name        = $name
                description = $template.Description
                ids         = $members
            }
        }
        $result = Invoke-SeedTenantApi -Tenant $Tenant -Context "group" -Method POST `
            -Route $route -Body $body -AllowStatus @(409, 422)
        if (-not $result.Ok) { [void] $Tenant.CapHits.Add("group=$($result.Status)"); break }
        [void] $Tenant.Groups.Add([pscustomobject]@{
            Id = $result.Json.id; Name = $name; Entity = $storedEntity
        })
    }
}

function Invoke-SeedPhaseTenantGraph
{
    param(
        [Parameter(Mandatory = $true)] $Tenants,
        [Parameter(Mandatory = $true)] $Dataset,
        [Parameter(Mandatory = $true)] [string] $Password,
        [Parameter(Mandatory = $true)] [int] $Seed
    )

    Write-SeedPhase "Phase 3/8 - per-tenant graph (aliases, roles, POVs, shapes, identities, grants, groups)"
    foreach ($key in $Tenants.Keys)
    {
        $tenant = $Tenants[$key]
        $random = New-SeedRandom ($Seed + $key.GetHashCode())

        Add-SeedAliases     -Tenant $tenant -Random $random
        Add-SeedRoles       -Tenant $tenant -Random $random
        Add-SeedPovs        -Tenant $tenant -Random $random
        Add-SeedShapes      -Tenant $tenant -Random $random
        Add-SeedIdentities  -Tenant $tenant -Dataset $Dataset -Random $random -Password $Password
        Add-SeedCredentials -Tenant $tenant -Password $Password
        Add-SeedLocalGrants -Tenant $tenant -Random $random
        Add-SeedGroups      -Tenant $tenant -Random $random -AllTenants $Tenants

        Write-SeedStep ("{0,-10} aliases {1,-3} roles {2,-4} povs {3,-4} shapes {4,-3} identities {5,-4} groups {6,-4} caps-hit {7}" -f `
            $key, $tenant.Aliases.Count, $tenant.Roles.Count, $tenant.Povs.Count, `
            $tenant.Shapes.Count, $tenant.Identities.Count, $tenant.Groups.Count, $tenant.CapHits.Count)
    }
}

# ---------------------------------------------------------------------------------------------
# Phase 4 - alias promotion (SQL)
# ---------------------------------------------------------------------------------------------

<#
.SYNOPSIS
Walks verifiable aliases to PUBLISHED, leaving a deliberate spread of lifecycle states behind.

.DESCRIPTION
AliasCommandMapper lands EMAIL and VAT_ID aliases in REQUESTED; nothing in the public API
promotes them. fn_alias_transition is the production writer, so the seed drives it directly.
This must happen before documents are sent, because email:/vat_id: addressing only resolves
against published aliases.
#>
function Invoke-SeedPhaseAliasPromotion
{
    param([Parameter(Mandatory = $true)] $Tenants)

    Write-SeedPhase "Phase 4/8 - promoting verifiable aliases through fn_alias_transition"

    $promoted = 0
    $index = 0
    foreach ($key in $Tenants.Keys)
    {
        $tenant = $Tenants[$key]
        $verifiable = @($tenant.Aliases | Where-Object { $_.Type -eq "EMAIL" -or $_.Type -eq "VAT_ID" })
        foreach ($alias in $verifiable)
        {
            $index++
            $normalized = $alias.Value.ToLowerInvariant()
            $typeCode = "EM"
            if ($alias.Type -eq "VAT_ID") { $typeCode = "VA" }

            # Leave a spread of non-published states so every lifecycle badge has data.
            $terminal = "PB"
            $reject = "NULL"
            if ($index % 11 -eq 4) { $terminal = "RQ" }
            elseif ($index % 11 -eq 7) { $terminal = "IP" }
            elseif ($index % 17 -eq 9) { $terminal = "RJ"; $reject = "'NR'" }

            if ($terminal -eq "RQ") { continue }

            $steps = @("IP")
            if ($terminal -eq "PB") { $steps = @("IP", "VR", "PB") }
            elseif ($terminal -eq "RJ") { $steps = @("IP", "RJ") }

            foreach ($step in $steps)
            {
                $stepReject = "NULL"
                if ($step -eq "RJ") { $stepReject = $reject }
                $canonicalAlias = $tenant.CanonicalAlias.ToString().Replace("'", "''")
                $sql = @"
SELECT set_config(
    'app.tenant_context',
    (SELECT tenant_id::TEXT
       FROM de_schema.fn_alias_registry_resolve(
           ARRAY['CA'::CHAR(2)], ARRAY['$canonicalAlias'])
      LIMIT 1),
    FALSE);
SELECT 1 FROM de_schema.fn_alias_transition(
    CURRENT_SETTING('app.tenant_context')::INT,
    '$typeCode', '$normalized', '$step',
    (SELECT version_id FROM de_schema.identity
      WHERE tenant_id = CURRENT_SETTING('app.tenant_context')::INT
      ORDER BY version_id LIMIT 1),
    NULL, NULL, NULL, 'OT', NULL, $stepReject, NULL);
"@
                Invoke-SeedSql -Sql $sql -Quiet | Out-Null
            }

            if ($terminal -eq "PB")
            {
                $prefix = "email"
                if ($alias.Type -eq "VAT_ID") { $prefix = "vat_id" }
                [void] $tenant.PublishedAddresses.Add(("{0}:{1}" -f $prefix, $alias.Value))
                $promoted++
            }
        }
    }
    Write-SeedStep "published $promoted verifiable aliases; the rest are parked in REQUESTED / IN_PROGRESS / REJECTED"
}

# ---------------------------------------------------------------------------------------------
# Phase 5 - cross-tenant
# ---------------------------------------------------------------------------------------------

function Invoke-SeedPhaseCrossTenant
{
    param(
        [Parameter(Mandatory = $true)] $Tenants,
        [Parameter(Mandatory = $true)] $Dataset,
        [Parameter(Mandatory = $true)] [int] $Seed
    )

    Write-SeedPhase "Phase 5/8 - cross-tenant shares, foreign grants and party groups"
    $random = New-SeedRandom ($Seed + 977)
    $records = New-Object System.Collections.ArrayList

    foreach ($share in $Dataset.Shares)
    {
        if (-not $Tenants.Contains($share.Owner) -or -not $Tenants.Contains($share.Grantee)) { continue }
        $owner = $Tenants[$share.Owner]
        $grantee = $Tenants[$share.Grantee]

        $subjectId = $owner.AdminIdentityId
        $subjectName = "admin"
        if ($share.Subject -eq "human")
        {
            $candidate = @($owner.Identities | Where-Object { $_.Type -eq "HUMAN" -and $_.Status -eq "ENABLED" })
            if ($candidate.Count -gt 0) { $subjectId = $candidate[0].Id; $subjectName = $candidate[0].DisplayName }
        }
        elseif ($share.Subject -eq "service")
        {
            $candidate = @($owner.Identities | Where-Object { $_.Type -eq "SERVICE" })
            if ($candidate.Count -gt 0) { $subjectId = $candidate[0].Id; $subjectName = $candidate[0].DisplayName }
        }

        # Owner side: publish the identity to the other tenant.
        $created = Invoke-SeedTenantApi -Tenant $owner -Context "identity share" -Method PUT `
            -Route ("/identities/{0}/shares/{1}" -f $subjectId, $grantee.TenantId) `
            -Body @{ allow_roles = $true; allow_povs = $true; single_use = $false } `
            -Header @{ "If-None-Match" = "*" } -AllowStatus @(409, 412, 422, 428)
        if (-not $created.Ok)
        {
            Write-SeedWarn ("share {0} -> {1} refused with {2}" -f $share.Owner, $share.Grantee, $created.Status)
            continue
        }

        $grantedRole = $null
        $grantedPov = $null
        if ($share.Grant)
        {
            # Grantee side: its own role and POV, granted back to the shared identity.
            $roles = @($grantee.Roles | Where-Object { $_.Status -eq "ENABLED" })
            if ($roles.Count -gt 0)
            {
                $role = $roles[$random.Next(0, $roles.Count)]
                $result = Invoke-SeedTenantApi -Tenant $grantee -Context "foreign role grant" -Method PUT `
                    -Route ("/identities/{0}/role" -f $subjectId) -Body @{ role_id = $role.Id } `
                    -Header @{ "If-None-Match" = "*" } -AllowStatus @(403, 409, 412, 422, 428)
                if ($result.Ok) { $grantedRole = $role.Name }
            }

            $povs = @($grantee.Povs)
            if ($povs.Count -gt 0)
            {
                $pov = $povs[$random.Next(0, $povs.Count)]
                $result = Invoke-SeedTenantApi -Tenant $grantee -Context "foreign pov grant" -Method PUT `
                    -Route ("/identities/{0}/povs/{1}" -f $subjectId, $pov.Id) -Body @{} `
                    -Header @{ "If-None-Match" = "*" } -AllowStatus @(403, 409, 412, 422, 428)
                if ($result.Ok) { $grantedPov = $pov.Name }
            }
        }

        # Status patches need the current ETag; re-read the share to get it.
        if ($share.OwnerStatus -eq "DISABLED")
        {
            $current = Invoke-SeedTenantApi -Tenant $owner -Context "share read" -Method GET `
                -Route ("/identities/{0}/shares/{1}" -f $subjectId, $grantee.TenantId) -AllowStatus @(404)
            if ($current.Ok)
            {
                Invoke-SeedTenantApi -Tenant $owner -Context "share disable" -Method PATCH `
                    -Route ("/identities/{0}/shares/{1}/status" -f $subjectId, $grantee.TenantId) `
                    -Body @{ status = "DISABLED" } -Header @{ "If-Match" = $current.ETag } `
                    -AllowStatus @(409, 412, 422, 428) | Out-Null
            }
        }

        # Discovery read from the grantee side, so the discovery list is exercised too.
        Invoke-SeedTenantApi -Tenant $grantee -Context "share discovery" -Method GET `
            -Route "/identity-share-discovery" -AllowStatus @(403, 404) | Out-Null

        [void] $records.Add([pscustomobject]@{
            Owner = $owner.DisplayName; Grantee = $grantee.DisplayName
            Identity = $subjectName; Role = $grantedRole; Pov = $grantedPov
            OwnerStatus = $share.OwnerStatus
        })
        Write-SeedStep ("{0} -> {1} ({2})" -f $share.Owner, $share.Grantee, $subjectName)
    }

    # Party groups mix foreign tenant ids with foreign published alias addresses.
    $partyHosts = @("aurora", "bellini", "dogane")
    $catalog = $Dataset.PartyGroupCatalog
    $catalogIndex = 0
    foreach ($hostKey in $partyHosts)
    {
        if (-not $Tenants.Contains($hostKey)) { continue }
        $tenant = $Tenants[$hostKey]

        $members = New-Object System.Collections.ArrayList
        foreach ($otherKey in $Tenants.Keys)
        {
            if ($otherKey -eq $hostKey) { continue }
            $other = $Tenants[$otherKey]
            [void] $members.Add(@{ type = "TENANT"; value = $other.TenantId })
            if ($other.PublishedAddresses.Count -gt 0)
            {
                [void] $members.Add(@{ type = "ALIAS"; value = $other.PublishedAddresses[0] })
            }
        }
        if ($members.Count -eq 0) { continue }

        $template = $catalog[$catalogIndex % $catalog.Count]
        $catalogIndex++
        $result = Invoke-SeedTenantApi -Tenant $tenant -Context "party group" -Method POST `
            -Route "/groups/party" `
            -Body @{ name = $template.Name; description = $template.Description; members = $members.ToArray() } `
            -AllowStatus @(409, 422)
        if ($result.Ok)
        {
            [void] $tenant.Groups.Add([pscustomobject]@{
                Id = $result.Json.id; Name = $template.Name; Entity = "PARTY"
            })
            Write-SeedStep ("party group '{0}' on {1} with {2} members" -f $template.Name, $hostKey, $members.Count)
        }
    }

    return $records
}

# ---------------------------------------------------------------------------------------------
# Phase 6 - documents
# ---------------------------------------------------------------------------------------------

function New-SeedDocumentPayload
{
    param([string] $TemplateName, $Random, [int] $Ordinal)

    switch ($TemplateName)
    {
        "Fattura Elettronica PA" {
            $imponibile = [Math]::Round($Random.NextDouble() * 9000 + 100, 2)
            $iva = [Math]::Round($imponibile * 0.22, 2)
            return @{
                numero = ("FT/{0}/{1:0000}" -f (Get-Date).Year, $Ordinal)
                data = (Get-Date).ToString("yyyy-MM-dd")
                imponibile = $imponibile
                iva = $iva
                totale = [Math]::Round($imponibile + $iva, 2)
                cig = ("Z{0:X7}" -f $Random.Next(1048576, 16777215))
            }
        }
        "Ordine di Acquisto" {
            $lines = New-Object System.Collections.ArrayList
            $count = $Random.Next(1, 6)
            for ($i = 0; $i -lt $count; $i++)
            {
                [void] $lines.Add(@{
                    codice = ("ART-{0:0000}" -f $Random.Next(1, 9999))
                    descrizione = "Materiale di consumo"
                    quantita = $Random.Next(1, 250)
                    prezzo = [Math]::Round($Random.NextDouble() * 400 + 5, 2)
                })
            }
            return @{
                numero_ordine = ("ODA/{0:00000}" -f $Ordinal)
                data = (Get-Date).ToString("yyyy-MM-dd")
                consegna = (Get-Date).AddDays($Random.Next(3, 45)).ToString("yyyy-MM-dd")
                righe = $lines.ToArray()
            }
        }
        "Documento di Trasporto" {
            return @{
                numero_ddt = ("DDT/{0:00000}" -f $Ordinal)
                data = (Get-Date).ToString("yyyy-MM-dd")
                vettore = "Cormorano Trasporti S.r.l."
                colli = $Random.Next(1, 40)
                peso_kg = [Math]::Round($Random.NextDouble() * 1800 + 10, 1)
                destinazione = "Verona"
            }
        }
        "Lettera di Vettura CMR" {
            return @{
                cmr = ("CMR-{0:000000}" -f $Ordinal)
                mittente = "Aurora Logistics S.r.l."
                destinatario = "Nordwind Spedition GmbH"
                luogo_carico = "Verona"
                luogo_scarico = "Hamburg"
                targa = ("{0}{1} {2:000} {3}{4}" -f "F", "G", $Random.Next(1, 999), "P", "T")
            }
        }
        "Dichiarazione Doganale Export" {
            return @{
                mrn = ("{0}IT{1:00000000}" -f (Get-Date).ToString("yy"), $Random.Next(1, 99999999))
                regime = "1000"
                valore_statistico = [Math]::Round($Random.NextDouble() * 50000 + 500, 2)
                paese_destinazione = "CH"
                voce_doganale = "84713000"
            }
        }
        "Rilascio Lotto Farmaceutico" {
            $esito = "CONFORME"
            if ($Random.Next(0, 12) -eq 0) { $esito = "NON_CONFORME" }
            return @{
                lotto = ("L{0:000000}" -f $Random.Next(1, 999999))
                aic = ("{0:000000000}" -f $Random.Next(1, 999999999))
                data_rilascio = (Get-Date).ToString("yyyy-MM-dd")
                esito = $esito
                qp = "Dott.ssa Elena Costa"
            }
        }
        "Notifica Legale" {
            return @{
                protocollo = ("PROT/{0}/{1:00000}" -f (Get-Date).Year, $Ordinal)
                oggetto = "Diffida ad adempiere"
                corpo = ("Con la presente si comunica quanto segue. " * $Random.Next(1, 12))
            }
        }
        default {
            $stato = @("ACCETTATO", "PARZIALE", "RIFIUTATO")[$Random.Next(0, 3)]
            return @{
                ordine_riferimento = ("ODA/{0:00000}" -f $Ordinal)
                stato = $stato
                data_consegna = (Get-Date).AddDays($Random.Next(1, 30)).ToString("yyyy-MM-dd")
            }
        }
    }
}

function Invoke-SeedDocumentChunk
{
    param(
        [Parameter(Mandatory = $true)] $Tenant,
        [Parameter(Mandatory = $true)] $Tenants,
        [Parameter(Mandatory = $true)] $Dataset,
        [Parameter(Mandatory = $true)] [int] $Seed,
        [Parameter(Mandatory = $true)] [int] $StartOrdinal,
        [Parameter(Mandatory = $true)] [int] $Count
    )

    Add-Type -AssemblyName System.Net.Http
    $random = New-SeedRandom ($Seed + 4231 + $Tenant.Key.GetHashCode() + ($StartOrdinal * 7919))
    $subjects = @(
        "Fattura mese corrente", "Ordine urgente", "Spedizione confermata",
        "Documenti doganali allegati", "Sollecito pagamento", "Conferma consegna",
        "Rilascio lotto", "Comunicazione di servizio", $null
    )
    $recipientPool = New-Object System.Collections.ArrayList
    $weights = $Dataset.TrafficWeights[$Tenant.Key]
    foreach ($otherKey in $weights.Keys)
    {
        if (-not $Tenants.Contains($otherKey)) { continue }
        $other = $Tenants[$otherKey]
        # Canonical aliases are immediately registry-backed by bootstrap. Newly promoted
        # verifiable aliases can still be waiting on claim-backfill; using them in the volume
        # loop makes a fixture send depend on an asynchronous worker and can strand the request.
        # Published aliases remain exercised by party groups and alias screens.
        $addresses = @($other.CanonicalAlias)
        for ($w = 0; $w -lt $weights[$otherKey]; $w++)
        {
            [void] $recipientPool.Add($addresses[$random.Next(0, $addresses.Count)])
        }
    }
    if ($recipientPool.Count -eq 0) { return [pscustomobject]@{ Key = $Tenant.Key; Sent = 0; Requests = 0; Retries = 0; RateLimited = 0; Failures = 0 } }
    $uniqueRecipientCount = @($recipientPool | Select-Object -Unique).Count

    $handler = New-Object System.Net.Http.HttpClientHandler
    $handler.UseProxy = $false
    $client = New-Object System.Net.Http.HttpClient -ArgumentList $handler
    $client.Timeout = [System.Threading.Timeout]::InfiniteTimeSpan
    $sent = 0
    try
    {
        for ($i = 0; $i -lt $Count; $i++)
        {
            $ordinal = $StartOrdinal + $i + 1
            $shape = $Tenant.Shapes[$random.Next(0, $Tenant.Shapes.Count)]
            $shapeRef = "{0}:{1}" -f $shape.NormalizedName, $shape.Version

        $recipientCount = 1
        $roll = $random.Next(0, 100)
        if ($roll -gt 92) { $recipientCount = $random.Next(4, 9) }
        elseif ($roll -gt 70) { $recipientCount = $random.Next(2, 4) }
        $recipientCount = [Math]::Min($recipientCount, $uniqueRecipientCount)

        $recipients = New-Object System.Collections.ArrayList
        while ($recipients.Count -lt $recipientCount)
        {
            $candidate = $recipientPool[$random.Next(0, $recipientPool.Count)]
            if (-not $recipients.Contains($candidate)) { [void] $recipients.Add($candidate) }
            if ($recipients.Count -ge $uniqueRecipientCount) { break }
        }

        $cc = New-Object System.Collections.ArrayList
        if ($random.Next(0, 100) -gt 72)
        {
            $ccCount = [Math]::Min(
                $random.Next(1, 4),
                [Math]::Max(0, $uniqueRecipientCount - $recipients.Count))
            while ($cc.Count -lt $ccCount)
            {
                $candidate = $recipientPool[$random.Next(0, $recipientPool.Count)]
                if (-not $recipients.Contains($candidate) -and -not $cc.Contains($candidate))
                {
                    [void] $cc.Add($candidate)
                }
                if (($cc.Count + $recipients.Count) -ge $uniqueRecipientCount) { break }
            }
        }

        $body = @{
            recipients         = $recipients.ToArray()
            cc                 = $cc.ToArray()
            shape              = $shapeRef
            data               = (New-SeedDocumentPayload -TemplateName $shape.TemplateName -Random $random -Ordinal $ordinal)
            # Volume fixtures must persist. Strict guarantees intentionally reject unresolved
            # party lines and create no UI-visible row; those failure contracts belong in API
            # tests, while BEST_EFFORT preserves the resolved/unresolved line detail on a document.
            delivery_guarantee = "BEST_EFFORT"
        }
        $subject = $subjects[$random.Next(0, $subjects.Count)]
        if ($subject) { $body["subject"] = $subject }

            $md5 = [Security.Cryptography.MD5]::Create()
            try
            {
                $keyBytes = $md5.ComputeHash([Text.Encoding]::UTF8.GetBytes(
                    ("ui-seed|{0}|{1}|{2}" -f $Seed, $Tenant.Key, $ordinal)))
                $idempotencyKey = (New-Object Guid -ArgumentList (, $keyBytes)).ToString()
            }
            finally { $md5.Dispose() }
            $result = Invoke-SeedDocumentHttp -Client $client -Tenant $Tenant -Body $body `
                -IdempotencyKey $idempotencyKey
            if ($result.Ok) { $sent++ }
        }
    }
    finally
    {
        $client.Dispose()
        $handler.Dispose()
    }

    return [pscustomobject]@{
        Key = $Tenant.Key; Sent = $sent
        Requests = $script:SeedStats.Requests; Retries = $script:SeedStats.Retries
        RateLimited = $script:SeedStats.RateLimited; Failures = $script:SeedStats.Failures
    }
}

function Invoke-SeedPhaseDocuments
{
    param(
        [Parameter(Mandatory = $true)] $Tenants,
        [Parameter(Mandatory = $true)] $Dataset,
        [Parameter(Mandatory = $true)] [int] $Seed,
        [Parameter(Mandatory = $true)] [string] $Password
    )

    Write-SeedPhase "Phase 6/8 - sending documents (persistent HTTP client)"
    $chunkSize = 15
    $specs = New-Object System.Collections.ArrayList
    $sentByTenant = [ordered]@{}
    foreach ($key in $Tenants.Keys)
    {
        $tenant = $Tenants[$key]
        $target = $tenant.Definition.Sends
        $sentByTenant[$key] = 0
        if ($target -le 0) { continue }
        if ($tenant.Shapes.Count -eq 0)
        {
            Write-SeedWarn "$key has no shape of its own; skipping its sends"
            continue
        }
        for ($start = 0; $start -lt $target; $start += $chunkSize)
        {
            [void] $specs.Add([pscustomobject]@{
                Tenant = $tenant; Start = $start; Count = [Math]::Min($chunkSize, $target - $start)
            })
        }
    }

    $activeTenantKey = $null
    foreach ($spec in $specs)
    {
        if ($activeTenantKey -ne $spec.Tenant.Key)
        {
            $spec.Tenant.AccessToken = Get-SeedAccessToken -Email $spec.Tenant.Email -Password $Password
            $activeTenantKey = $spec.Tenant.Key
        }
        $result = Invoke-SeedDocumentChunk -Tenant $spec.Tenant -Tenants $Tenants -Dataset $Dataset `
            -Seed $Seed -StartOrdinal $spec.Start -Count $spec.Count
        $sentByTenant[$result.Key] += $result.Sent
    }

    $sentTotal = 0
    foreach ($key in $Tenants.Keys)
    {
        $target = $Tenants[$key].Definition.Sends
        if ($target -le 0) { continue }
        $sent = $sentByTenant[$key]
        $sentTotal += $sent
        Write-SeedStep ("{0,-10} sent {1}/{2}" -f $key, $sent, $target)
    }
    Write-SeedStep "total documents sent: $sentTotal"
    return $sentTotal
}

# ---------------------------------------------------------------------------------------------
# Phase 7 - backdating (SQL) and reads
# ---------------------------------------------------------------------------------------------

<#
.SYNOPSIS
Spreads document and trace timestamps across the trailing 90 days.

.DESCRIPTION
Without this every row lands inside the same minute, every date-ranged POV returns an identical
set, and the whole filter UI looks broken while being perfectly correct.

Timestamps are assigned monotonically in id order. Queue reads page on (created_at, id), so a
random spread would put the cursor out of step with the ordering and silently skip rows. This
also has to run BEFORE the read phase, or the cursors it advances would point into the old
timeline.
#>
function Invoke-SeedPhaseBackdate
{
    param([int] $Days = 90)

    Write-SeedPhase "Phase 7/8 - backdating documents across the last $Days days"

    # These are local fixture-maintenance updates, not product writes. The migration owner is
    # normally subject to FORCE RLS; relax FORCE only inside one transaction, restore it before
    # commit, and let any error roll the entire operation (including the ALTERs) back.
    $sql = @"
BEGIN;
ALTER TABLE de_schema.document NO FORCE ROW LEVEL SECURITY;
ALTER TABLE de_schema.trace NO FORCE ROW LEVEL SECURITY;
WITH ordered AS (
    SELECT id, ROW_NUMBER() OVER (ORDER BY id) AS rn, COUNT(*) OVER () AS total
    FROM de_schema.document
)
UPDATE de_schema.document d
SET created_at = NOW()
    - INTERVAL '$Days days'
    + ((o.rn::FLOAT8 / GREATEST(o.total, 1)::FLOAT8) * INTERVAL '$Days days')
FROM ordered o
WHERE o.id = d.id;
UPDATE de_schema.trace t
SET created_at = d.created_at
FROM de_schema.document d
WHERE d.id = t.doc_id;
SELECT COUNT(*) FROM de_schema.document;
ALTER TABLE de_schema.trace FORCE ROW LEVEL SECURITY;
ALTER TABLE de_schema.document FORCE ROW LEVEL SECURITY;
COMMIT;
"@
    $count = (Invoke-SeedSql -Sql $sql) -join ""
    Write-SeedStep "backdated $($count.Trim()) documents and their traces"
}

<#
.SYNOPSIS
Reads inboxes so queue_cursor rows end up genuinely mixed.

.DESCRIPTION
Some identities are left fully caught up, some with a backlog, some having never read at all —
otherwise every unread badge in the UI shows the same number.
#>
function Invoke-SeedPhaseReads
{
    param(
        [Parameter(Mandatory = $true)] $Tenants,
        [Parameter(Mandatory = $true)] [string] $Password,
        [int] $MaxPagesPerPov = 6
    )

    Write-SeedPhase "Phase 8/8 - advancing read cursors"
    $index = 0
    foreach ($key in $Tenants.Keys)
    {
        $tenant = $Tenants[$key]
        $index++
        # Leave every third admin entirely untouched for the "never read" state. Tenant admins
        # are assigned the bootstrap default POV, not every custom POV created later.
        if ($index % 3 -eq 0)
        {
            Write-SeedStep ("{0,-10} left unread" -f $key)
            continue
        }

        $tenant.AccessToken = Get-SeedAccessToken -Email $tenant.Email -Password $Password
        # The high-volume tenants exercise different amounts of genuine cursor movement. Other
        # readable tenants only peek, while the every-third set above remains completely untouched.
        # There is no client cursor query parameter on this endpoint.
        $advanceCursor = $key -in @("aurora", "lumen", "nordwind")
        $advance = $advanceCursor.ToString().ToLowerInvariant()
        $pageLimit = if ($advanceCursor)
        {
            [Math]::Min($MaxPagesPerPov, (@{ aurora = 1; lumen = 2; nordwind = 5 }[$key]))
        }
        else { 1 }
        $pages = 0
        for ($page = 0; $page -lt $pageLimit; $page++)
        {
            $result = Invoke-SeedTenantApi -Tenant $tenant -Context "document read" -Method GET `
                -Route ("/documents/?advance_cursor={0}" -f $advance)
            $pages++

            $payload = $result.Json
            if ($null -eq $payload) { break }
            $hasMore = $false
            if ($payload.PSObject.Properties["has_more"]) { $hasMore = [bool] $payload.has_more }
            if (-not $hasMore) { break }
        }
        Write-SeedStep ("{0,-10} read {1} pages (advance={2})" -f $key, $pages, $advance)
    }
}

# ---------------------------------------------------------------------------------------------
# Manifest
# ---------------------------------------------------------------------------------------------

function Export-SeedManifest
{
    param(
        [Parameter(Mandatory = $true)] $Tenants,
        [Parameter(Mandatory = $true)] $ShareRecords,
        [Parameter(Mandatory = $true)] [string] $Password,
        [Parameter(Mandatory = $true)] [string] $Path,
        [Parameter(Mandatory = $true)] [string] $BaseUrl,
        [int] $DocumentsSent = 0
    )

    $entries = New-Object System.Collections.ArrayList
    foreach ($key in $Tenants.Keys)
    {
        $tenant = $Tenants[$key]
        [void] $entries.Add([ordered]@{
            key             = $tenant.Key
            display_name    = $tenant.DisplayName
            type            = $tenant.Type
            note            = $tenant.Definition.Note
            tenant_id       = $tenant.TenantId
            canonical_alias = $tenant.CanonicalAlias
            admin_login     = @{ email = $tenant.Email; password = $Password }
            default_pov_id  = $tenant.DefaultPovId
            admin_role_id   = $tenant.AdminRoleId
            counts          = [ordered]@{
                aliases = $tenant.Aliases.Count + 1
                roles = $tenant.Roles.Count + 2
                povs = $tenant.Povs.Count + 1
                shapes = $tenant.Shapes.Count
                identities = $tenant.Identities.Count + 1
                groups = $tenant.Groups.Count
            }
            cap_refusals    = @($tenant.CapHits)
            published_addresses = @($tenant.PublishedAddresses)
            credentialed_identities = @($tenant.Credentialed | ForEach-Object {
                [ordered]@{
                    display_name = $_.DisplayName
                    email = $_.Email
                    password = $_.Password
                    identity_id = $_.IdentityId
                }
            })
        })
    }

    $manifest = [ordered]@{
        generated_at   = (Get-Date).ToUniversalTime().ToString("yyyy-MM-ddTHH:mm:ssZ")
        base_url       = $BaseUrl
        shared_password = $Password
        documents_sent = $DocumentsSent
        tenants        = $entries.ToArray()
        shares         = @($ShareRecords)
        stats          = (Get-SeedStats)
    }

    $directory = Split-Path -Parent $Path
    if (-not (Test-Path -LiteralPath $directory)) { New-Item -ItemType Directory -Force -Path $directory | Out-Null }
    [IO.File]::WriteAllText($Path, (ConvertTo-Json $manifest -Depth 20), [Text.UTF8Encoding]::new($false))
    return $Path
}
