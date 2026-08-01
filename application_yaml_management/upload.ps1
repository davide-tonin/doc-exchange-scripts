param(
    [Parameter(Mandatory = $true)]
    [ValidateSet("qa", "sandbox", "prod")]
    [string]$Stage
)

$ErrorActionPreference = "Stop"
$env:AWS_PROFILE = "infra-admin"

$region = "eu-south-1"
$bucket = "de-stage-configuration-7f3c91a6e4b82d50"
$source = Join-Path $PSScriptRoot "application-$Stage.yaml"
$destination = "s3://$bucket/stages/$Stage/application.yaml"

if (-not (Test-Path $source)) {
    throw "Configuration file not found: $source"
}

aws sts get-caller-identity

if ($LASTEXITCODE -ne 0) {
    throw "AWS authentication failed."
}

aws s3 cp `
    $source `
    $destination `
    --region $region `
    --sse AES256 `
    --content-type "application/yaml"

if ($LASTEXITCODE -ne 0) {
    throw "Upload failed."
}

Write-Host "Uploaded $Stage configuration successfully."