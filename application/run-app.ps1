param(
    [string] $ServiceRepository = "C:\\Users\\DavideTonin\\IdeaProjects\\doc-exchange-service",
    [Parameter(ValueFromRemainingArguments = $true)]
    [string[]] $BootRunArgs
)

$ErrorActionPreference = "Stop"

$repoRoot = (Resolve-Path -LiteralPath $ServiceRepository).Path

& "$PSScriptRoot\..\database\dev-db.ps1" up -ServiceRepository $repoRoot

Push-Location $repoRoot
try {
    if ($BootRunArgs.Count -eq 0) {
        $BootRunArgs = @("--args=--spring.profiles.active=qa")
    }

    & "$repoRoot\gradlew.bat" bootRun @BootRunArgs
    exit $LASTEXITCODE
}
finally {
    Pop-Location
}
