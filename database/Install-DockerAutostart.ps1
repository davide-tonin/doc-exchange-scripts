$ErrorActionPreference = "Stop"

$dockerDesktop = Join-Path $env:ProgramFiles "Docker\Docker\Docker Desktop.exe"
if (-not (Test-Path -LiteralPath $dockerDesktop)) {
    throw "Docker Desktop was not found at '$dockerDesktop'."
}

$startupDir = [Environment]::GetFolderPath("Startup")
$shortcutPath = Join-Path $startupDir "Docker Desktop.lnk"

$shell = New-Object -ComObject WScript.Shell
$shortcut = $shell.CreateShortcut($shortcutPath)
$shortcut.TargetPath = $dockerDesktop
$shortcut.WorkingDirectory = Split-Path -Parent $dockerDesktop
$shortcut.Description = "Start Docker Desktop at Windows login for doc-exchange-service development"
$shortcut.Save()

Write-Host "Docker Desktop will start at Windows login:"
Write-Host $shortcutPath
