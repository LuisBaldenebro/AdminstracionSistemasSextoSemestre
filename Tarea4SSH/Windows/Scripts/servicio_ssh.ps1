function Reparar-SSH-Windows {
    # Habilitar/crear regla de firewall para puerto 22
    $regla = Get-NetFirewallRule -Name "OpenSSH-Server-In-TCP" -ErrorAction SilentlyContinue
    if (-not $regla) {
        New-NetFirewallRule -Name "OpenSSH-Server-In-TCP" -DisplayName "OpenSSH Server (sshd)" `
            -Enabled True -Direction Inbound -Protocol TCP -Action Allow -LocalPort 22 | Out-Null
        Write-Host " > Regla de firewall creada." -ForegroundColor Green
    } else {
        Enable-NetFirewallRule -Name "OpenSSH-Server-In-TCP" -ErrorAction SilentlyContinue
    }

    # Inicio automatico
    Set-Service -Name sshd -StartupType Automatic -ErrorAction SilentlyContinue

    # Iniciar si no esta corriendo
    $svc = Get-Service sshd -ErrorAction SilentlyContinue
    if ($svc -and $svc.Status -ne "Running") {
        Start-Service sshd
        Start-Sleep 1
    }
}

function Estado-SSH {
    while ($true) {
        Clear-Host
        Write-Host "----------------------------------------"
        Write-Host "        ESTADO DEL SERVICIO SSH"
        Write-Host "----------------------------------------"
        $cap = Get-WindowsCapability -Online -Name OpenSSH.Server~~~~0.0.1.0
        if ($cap.State -ne "Installed") {
            Write-Host "[!] OpenSSH Server no instalado." -ForegroundColor Red
            Read-Host "Enter..."; return
        }
        $svc = Get-Service sshd -ErrorAction SilentlyContinue
        if ($svc -and $svc.Status -eq "Running") {
            Write-Host "Estado: ACTIVO" -ForegroundColor Green
            Write-Host " [1] Detener  [2] Reiniciar  [3] Volver"
        } else {
            Write-Host "Estado: DETENIDO" -ForegroundColor Red
            Write-Host " [1] Iniciar  [3] Volver"
        }
        $op = Read-Host "Opcion"
        switch ($op) {
            "1" {
                if ($svc.Status -eq "Running") { Stop-Service sshd -Force }
                else { Start-Service sshd }
                Start-Sleep 2
            }
            "2" { if ($svc.Status -eq "Running") { Restart-Service sshd -Force; Start-Sleep 2 } }
            "3" { return }
            default { Write-Host "Invalido"; Start-Sleep 1 }
        }
    }
}

function Instalar-SSH {
    Clear-Host
    Write-Host "========================================"
    Write-Host "   INSTALACION Y CONFIG. SSH (Windows)"
    Write-Host "========================================"

    $cap = Get-WindowsCapability -Online -Name OpenSSH.Server~~~~0.0.1.0
    if ($cap.State -ne "Installed") {
        Write-Host "Instalando OpenSSH Server..."
        Add-WindowsCapability -Online -Name OpenSSH.Server~~~~0.0.1.0 | Out-Null
        $cap = Get-WindowsCapability -Online -Name OpenSSH.Server~~~~0.0.1.0
        if ($cap.State -ne "Installed") {
            Write-Host "[ERROR] No se pudo instalar." -ForegroundColor Red
            Pause; return
        }
        Write-Host "Instalado correctamente." -ForegroundColor Green
    } else {
        Write-Host "OpenSSH Server ya estaba instalado." -ForegroundColor Yellow
    }

    # Aplicar todas las correcciones
    Reparar-SSH-Windows

    Write-Host ""
    Write-Host "========================================"
    Write-Host "  SSH LISTO - Conectate con:"
    Write-Host "========================================"
    $ips = Get-NetIPAddress -AddressFamily IPv4 | Where-Object { $_.IPAddress -ne "127.0.0.1" }
    foreach ($ip in $ips) {
        Write-Host "  ssh Administrator@$($ip.IPAddress)" -ForegroundColor Cyan
    }
    Write-Host "========================================"
    Pause
}

function Menu-SSH {
    while ($true) {
        Clear-Host
        Write-Host "======================================="
        Write-Host "          SERVICIO SSH (WINDOWS)"
        Write-Host "======================================="
        Write-Host "1) Estado    2) Instalar y configurar    3) Volver"
        Write-Host "======================================="
        $op = Read-Host "Opcion"
        switch ($op) {
            "1" { Estado-SSH }
            "2" { Instalar-SSH }
            "3" { return }
            default { Write-Host "Invalido" -ForegroundColor Yellow; Start-Sleep 1 }
        }
    }
}
