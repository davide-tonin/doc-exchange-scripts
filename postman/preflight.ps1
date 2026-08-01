param(
    [string] $ServiceRepository = "C:\\Users\\DavideTonin\\IdeaProjects\\doc-exchange-service",
    [string] $BaseUrl = "http://localhost:8080/api",
    [string] $Environment = "postman\environments\local-qa.postman_environment.json"
)

$ErrorActionPreference = "Stop"
$repoRoot = (Resolve-Path -LiteralPath $ServiceRepository).Path
$failures = [Collections.Generic.List[string]]::new()

function Add-Failure([string] $Message) {
    $script:failures.Add($Message)
    Write-Host "[FAIL] $Message" -ForegroundColor Red
}

function Add-Pass([string] $Message) {
    Write-Host "[ OK ] $Message" -ForegroundColor Green
}

function Resolve-EnvironmentValue([object] $Document, [string] $Key) {
    return ($Document.values | Where-Object { $_.key -eq $Key } | Select-Object -First 1).value
}

function Invoke-NativeQuiet([string] $Command, [string[]] $Arguments) {
    $previousPreference = $ErrorActionPreference
    try {
        $ErrorActionPreference = "Continue"
        & $Command @Arguments 1>$null 2>$null
        return $LASTEXITCODE
    } finally {
        $ErrorActionPreference = $previousPreference
    }
}

function Test-SesIdentityVerified([string] $EmailAddress) {
    $identities = @($EmailAddress, ($EmailAddress -split "@", 2)[1])
    foreach ($identity in $identities) {
        $previousPreference = $ErrorActionPreference
        try {
            $ErrorActionPreference = "Continue"
            $verified = & aws sesv2 get-email-identity `
                --email-identity $identity `
                --region eu-south-1 `
                --query VerifiedForSendingStatus `
                --output text 2>$null
            $identityExitCode = $LASTEXITCODE
        } finally {
            $ErrorActionPreference = $previousPreference
        }
        if ($identityExitCode -eq 0 -and $verified.Trim() -eq "True") {
            return $true
        }
    }
    return $false
}

if (Get-Command node -ErrorAction SilentlyContinue) {
    Add-Pass "Node.js is available."
} else {
    Add-Failure "Node.js is unavailable."
}

if (Get-Command aws -ErrorAction SilentlyContinue) {
    $identityExitCode = Invoke-NativeQuiet "aws" @(
        "sts", "get-caller-identity", "--output", "json"
    )
    if ($identityExitCode -eq 0) {
        Add-Pass "AWS credentials resolve."
    } else {
        Add-Failure "AWS credentials do not resolve."
    }

    $stageObjectExitCode = Invoke-NativeQuiet "aws" @(
        "s3api", "head-object",
        "--bucket", "de-stage-configuration-7f3c91a6e4b82d50",
        "--key", "stages/qa/application.yaml",
        "--region", "eu-south-1"
    )
    if ($stageObjectExitCode -eq 0) {
        Add-Pass "QA stage-configuration object is readable."
    } else {
        Add-Failure ("QA stage object is missing or unreadable. Populate the protected object described " +
            "in docs\CONFIGURATION.md before starting the QA profile.")
    }
} else {
    Add-Failure "AWS CLI is unavailable."
}

try {
    $healthResponse = Invoke-WebRequest `
        -Uri "$BaseUrl/actuator/health" `
        -UseBasicParsing `
        -TimeoutSec 5
    $healthJson = if ($healthResponse.Content -is [byte[]]) {
        [Text.Encoding]::UTF8.GetString($healthResponse.Content)
    } else {
        [string] $healthResponse.Content
    }
    $health = $healthJson | ConvertFrom-Json
    if ($healthResponse.StatusCode -eq 200 -and
        $health.status -eq "UP" -and
        $health.components.db.status -eq "UP") {
        Add-Pass "actuator/health is UP and the configured QA database is reachable."
    } else {
        Add-Failure "actuator/health did not report the application and configured QA database as UP."
    }
} catch {
    Add-Failure "actuator/health is unreachable at $BaseUrl."
}

foreach ($relativeUri in @("v3/api-docs/public", "v3/api-docs/internal")) {
    try {
        $response = Invoke-WebRequest `
            -Uri "$BaseUrl/$relativeUri" `
            -UseBasicParsing `
            -TimeoutSec 30
        if ($response.StatusCode -eq 200) {
            Add-Pass "$relativeUri is reachable."
        } else {
            Add-Failure "$relativeUri returned HTTP $($response.StatusCode)."
        }
    } catch {
        Add-Failure "$relativeUri is unreachable at $BaseUrl."
    }
}

$environmentPath = Join-Path $repoRoot $Environment
if (-not (Test-Path -LiteralPath $environmentPath)) {
    Add-Failure ("Working Postman environment is missing. Copy the example to $Environment and fill its " +
        "secret values.")
} else {
    $environmentDocument = Get-Content -LiteralPath $environmentPath -Raw -Encoding UTF8 |
        ConvertFrom-Json
    foreach ($requiredSecret in @(
        "primary_password",
        "peer_password",
        "secondary_password",
        "next_primary_password"
    )) {
        if ([string]::IsNullOrWhiteSpace((Resolve-EnvironmentValue $environmentDocument $requiredSecret))) {
            Add-Failure "Postman secret '$requiredSecret' is empty."
        } else {
            Add-Pass "Postman secret '$requiredSecret' is present."
        }
    }

    if (Get-Command aws -ErrorAction SilentlyContinue) {
        $productionAccess = & aws sesv2 get-account `
            --region eu-south-1 `
            --query ProductionAccessEnabled `
            --output text 2>$null
        if ($LASTEXITCODE -eq 0 -and $productionAccess.Trim() -eq "False") {
            foreach ($emailKey in @("primary_email", "peer_email")) {
                $emailAddress = Resolve-EnvironmentValue $environmentDocument $emailKey
                if ([string]::IsNullOrWhiteSpace($emailAddress)) {
                    Add-Failure "Postman environment value '$emailKey' is empty."
                } elseif (Test-SesIdentityVerified $emailAddress) {
                    Add-Pass "SES sandbox recipient '$emailAddress' is verified."
                } else {
                    Add-Failure ("SES sandbox recipient '$emailAddress' is not verified in eu-south-1. " +
                        "Open the AWS verification email for that exact address before Provision.")
                }
            }
        } elseif ($LASTEXITCODE -eq 0) {
            Add-Pass "SES production access is enabled; recipient verification is not required."
        } else {
            Add-Failure "SES account status is unreadable in eu-south-1."
        }
    }
}

if ($failures.Count -gt 0) {
    Write-Host ""
    Write-Host "Postman preflight failed with $($failures.Count) issue(s)." -ForegroundColor Red
    exit 1
}

Write-Host ""
Write-Host "Postman preflight passed. SES is ready for both fixture recipients." `
    -ForegroundColor Green
