param(
    [string] $ServiceRepository = "C:\Users\DavideTonin\IdeaProjects\doc-exchange-service",
    [switch] $IncludeBodies
)

$ErrorActionPreference = "Stop"
$serviceRepositoryPath = (Resolve-Path -LiteralPath $ServiceRepository).Path
$collectionPath = Join-Path $serviceRepositoryPath (
    "postman\generated\doc-exchange-e2e.postman_collection.json"
)
$collection = Get-Content -LiteralPath $collectionPath -Raw -Encoding UTF8 | ConvertFrom-Json
$foldersByName = @{}
foreach ($folder in $collection.item) {
    $foldersByName[$folder.name] = $folder
}

$provisionFolders = @(
    "000 Internal Tenant Init",
    "001 Internal Tenant Bootstrap",
    "002 Internal Auth"
)
$smokeFolders = @($collection.item |
    Where-Object {
        $_.name -notmatch "^000 " -and
        $_.name -notmatch "^001 " -and
        $_.name -notmatch "^119 " -and
        $_.name -notmatch "^120 "
    } |
    ForEach-Object { $_.name })
$resetFolders = @(
    "119 Interactive Password Reset",
    "120 Interactive Password Reset Completion",
    "002 Internal Auth"
)
$stages = @(
    [PSCustomObject]@{ name = "Provision and initial authentication"; folders = $provisionFolders },
    [PSCustomObject]@{ name = "Repeatable Smoke"; folders = $smokeFolders },
    [PSCustomObject]@{ name = "Interactive password reset and reauthentication"; folders = $resetFolders }
)

function Get-ExpectedStatus([object] $Item) {
    $scriptText = ($Item.event |
        Where-Object { $_.listen -eq "test" } |
        ForEach-Object { $_.script.exec }) -join "`n"
    $match = [regex]::Match($scriptText, 'status is (\d+)')
    if ($match.Success) {
        return $match.Groups[1].Value
    }
    return "?"
}

function Get-Captures([object] $Item) {
    $scriptText = ($Item.event |
        ForEach-Object { $_.script.exec }) -join "`n"
    $matches = [regex]::Matches(
        $scriptText,
        'pm\.environment\.(?:set|unset)\(["'']([^"'']+)'
    )
    return @($matches |
        ForEach-Object { $_.Groups[1].Value } |
        Where-Object {
            $_ -notin @(
                "correlation_id",
                "request_idempotency_key",
                "future_time"
            )
        } |
        Sort-Object -Unique)
}

function Format-Query([object] $Request) {
    $query = @($Request.url.query)
    if ($query.Count -eq 0) {
        return "-"
    }
    return ($query | ForEach-Object {
        $state = if ($_.disabled) { "disabled" } else { "enabled" }
        "$($_.key)=$($_.value) [$state]"
    }) -join "; "
}

function Format-Headers([object] $Request) {
    $commonHeaders = @(
        "Accept",
        "Content-Type",
        "X-Correlation-Id",
        "X-Idempotency-Key"
    )
    $headers = @($Request.header |
        Where-Object { $_.key -notin $commonHeaders })
    if ($headers.Count -eq 0) {
        return "-"
    }
    return ($headers | ForEach-Object {
        $state = if ($_.disabled) { "disabled" } else { "enabled" }
        "$($_.key)=$($_.value) [$state]"
    }) -join "; "
}

function Format-BodyFields([object] $Request) {
    if ($null -eq $Request.body -or [string]::IsNullOrWhiteSpace($Request.body.raw)) {
        return "-"
    }
    try {
        $body = $Request.body.raw | ConvertFrom-Json
        return (@($body.PSObject.Properties.Name) -join ", ")
    }
    catch {
        return "<non-JSON body>"
    }
}

$sequence = 0
$total = ($stages | ForEach-Object {
    foreach ($folderName in $_.folders) {
        $foldersByName[$folderName].item.Count
    }
} | Measure-Object -Sum).Sum

Write-Host "Generated collection: $collectionPath"
Write-Host "Clean-room Full execution: $total HTTP calls"
Write-Host (
    "Common request headers: Accept, Content-Type when applicable, " +
    "X-Correlation-Id, and X-Idempotency-Key."
)

foreach ($stage in $stages) {
    Write-Host ""
    Write-Host "=== $($stage.name) ===" -ForegroundColor Cyan
    foreach ($folderName in $stage.folders) {
        $folder = $foldersByName[$folderName]
        Write-Host ""
        Write-Host "-- $folderName ($($folder.item.Count) calls) --" -ForegroundColor Yellow
        foreach ($item in $folder.item) {
            $sequence++
            $request = $item.request
            $auth = if ($null -eq $request.auth.type) { "inherit" } else { $request.auth.type }
            $captures = Get-Captures $item
            $captureText = if ($captures.Count) { $captures -join ", " } else { "-" }

            Write-Host (
                "{0,3}/{1}  {2}  {3}  -> {4}" -f
                $sequence,
                $total,
                $request.method,
                $request.url.raw,
                (Get-ExpectedStatus $item)
            )
            Write-Host "         name: $($item.name)"
            Write-Host "         auth: $auth"
            Write-Host "        query: $(Format-Query $request)"
            Write-Host "      headers: $(Format-Headers $request)"
            Write-Host "  body fields: $(Format-BodyFields $request)"
            Write-Host "     captures: $captureText"
            if ($IncludeBodies -and $null -ne $request.body) {
                Write-Host "          body:"
                Write-Host $request.body.raw
            }
        }
    }
}
