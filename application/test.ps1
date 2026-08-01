param(
    [string] $ServiceRepository = "C:\\Users\\DavideTonin\\IdeaProjects\\doc-exchange-service",
    [Parameter(ValueFromRemainingArguments = $true)]
    [string[]] $GradleArgs
)

$ErrorActionPreference = "Stop"

$repoRoot = (Resolve-Path -LiteralPath $ServiceRepository).Path

if ($GradleArgs.Count -eq 0) {
    $GradleArgs = @("test")
}

& "$PSScriptRoot\..\database\Ensure-Docker.ps1"
& "$repoRoot\gradlew.bat" @GradleArgs
exit $LASTEXITCODE
