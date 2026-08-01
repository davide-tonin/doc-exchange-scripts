param(
    [int]$Port = 8080
)

Get-NetTCPConnection -LocalPort $Port -State Listen -ErrorAction SilentlyContinue |
        Select-Object -ExpandProperty OwningProcess -Unique |
        ForEach-Object {
            Write-Host "Killing PID $_"
            Stop-Process -Id $_ -Force
        }