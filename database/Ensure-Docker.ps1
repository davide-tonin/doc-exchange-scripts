param(
    [int] $TimeoutSeconds = 300,
    [switch] $NoStart
)

$ErrorActionPreference = "Stop"

function Test-DockerReady {
    try {
        & docker version --format "{{.Server.Version}}" 1>$null 2>$null
        return $LASTEXITCODE -eq 0
    }
    catch {
        return $false
    }
}

if (Test-DockerReady) {
    Write-Host "Docker is ready."
    exit 0
}

$dockerDesktop = Join-Path $env:ProgramFiles "Docker\Docker\Docker Desktop.exe"

if (-not $NoStart) {
    if (-not (Test-Path -LiteralPath $dockerDesktop)) {
        throw "Docker Desktop was not found at '$dockerDesktop'."
    }

    Write-Host "Docker is not ready. Starting Docker Desktop..."
    Start-Process -FilePath $dockerDesktop -WindowStyle Hidden | Out-Null
}
else {
    Write-Host "Docker is not ready. Waiting without starting it..."
}

$deadline = (Get-Date).AddSeconds($TimeoutSeconds)
while ((Get-Date) -lt $deadline) {
    Start-Sleep -Seconds 3
    if (Test-DockerReady) {
        Write-Host "Docker is ready."
        exit 0
    }
}

throw "Docker did not become ready within $TimeoutSeconds seconds. Open Docker Desktop once, or run .\database\Install-DockerAutostart.ps1 to start it at login."
