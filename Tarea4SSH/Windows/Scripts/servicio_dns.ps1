function Estado-DNS {
    while ($true) {
        Clear-Host
        Write-Host "----------------------------------------"
        Write-Host "        ESTADO DEL SERVICIO DNS"
        Write-Host "----------------------------------------"
        if ((Get-WindowsFeature -Name DNS).InstallState -ne "Installed") {
            Write-Host "[!] DNS no instalado." -ForegroundColor Red
            Read-Host "Enter..."; return
        }
        $svc = Get-Service DNS
        if ($svc.Status -eq "Running") {
            Write-Host "Estado: ACTIVO" -ForegroundColor Green
            Write-Host " [1] Detener  [2] Reiniciar  [3] Volver"
        } else {
            Write-Host "Estado: DETENIDO" -ForegroundColor Red
            Write-Host " [1] Iniciar  [3] Volver"
        }
        $op = Read-Host "Opcion"
        switch ($op) {
            "1" { if ($svc.Status -eq "Running") { Stop-Service DNS -Force } else { Start-Service DNS }; Start-Sleep 2 }
            "2" { if ($svc.Status -eq "Running") { Restart-Service DNS -Force; Start-Sleep 2 } }
            "3" { return }
            default { Write-Host "Opcion no valida."; Start-Sleep 1 }
        }
    }
}

function Instalar-DNS {
    Clear-Host
    if ((Get-WindowsFeature -Name DNS).Installed) {
        Write-Host "DNS ya instalado." -ForegroundColor Yellow; Pause; return
    }
    Write-Host "Instalando DNS..."
    Install-WindowsFeature -Name DNS -IncludeManagementTools
    if ((Get-WindowsFeature -Name DNS).Installed) {
        Start-Service DNS
        Set-NetConnectionProfile -InterfaceAlias "Ethernet 2" -NetworkCategory Private -ErrorAction SilentlyContinue
        Enable-NetFirewallRule -DisplayGroup "DNS Server" -ErrorAction SilentlyContinue
        Enable-NetFirewallRule -Name FPS-ICMP4-ERQ-In -ErrorAction SilentlyContinue
        Write-Host "DNS instalado y firewall configurado." -ForegroundColor Green
    } else {
        Write-Host "Error en instalacion." -ForegroundColor Red
    }
    Pause
}

function Nuevo-Dominio {
    Clear-Host
    $dominio = Read-Host "Nombre del dominio (ej: empresa.local)"
    if ([string]::IsNullOrWhiteSpace($dominio)) { Write-Host "Invalido." -ForegroundColor Red; Pause; return }
    if (Get-DnsServerZone -Name $dominio -ErrorAction SilentlyContinue) {
        Write-Host "El dominio ya existe." -ForegroundColor Yellow; Pause; return
    }
    do {
        $ip = Read-Host "IP para el dominio"
        $ok = -not [string]::IsNullOrWhiteSpace($ip) -and (Validar-IP $ip)
        if (-not $ok) { Write-Host "IP invalida." -ForegroundColor Red }
    } until ($ok)

    try {
        Add-DnsServerPrimaryZone -Name $dominio -ZoneFile "$dominio.dns" -ErrorAction Stop
        Add-DnsServerResourceRecordA -ZoneName $dominio -Name "@"   -IPv4Address $ip -ErrorAction Stop
        Add-DnsServerResourceRecordA -ZoneName $dominio -Name "www" -IPv4Address $ip -ErrorAction Stop
        Write-Host "Dominio '$dominio' creado -> $ip" -ForegroundColor Green
    } catch {
        Write-Host "Error: $($_.Exception.Message)" -ForegroundColor Red
    }
    Pause
}

function Borrar-Dominio {
    $dominio = Read-Host "Dominio a eliminar"
    if (Get-DnsServerZone -Name $dominio -ErrorAction SilentlyContinue) {
        Remove-DnsServerZone -Name $dominio -Force
        Write-Host "Dominio eliminado." -ForegroundColor Green
    } else {
        Write-Host "No existe." -ForegroundColor Red
    }
    Pause
}

function Consultar-Dominio {
    Clear-Host
    $zonas = Get-DnsServerZone | Where-Object { $_.ZoneType -eq "Primary" }
    if ($zonas.Count -eq 0) { Write-Host "Sin dominios."; Pause; return }
    $i = 1
    foreach ($z in $zonas) { Write-Host "$i) $($z.ZoneName)"; $i++ }
    $sel = Read-Host "Numero"
    if (-not ($sel -match "^\d+$") -or [int]$sel -lt 1 -or [int]$sel -gt $zonas.Count) {
        Write-Host "Seleccion invalida." -ForegroundColor Red; Pause; return
    }
    $dom = $zonas[[int]$sel - 1].ZoneName
    $rec = Get-DnsServerResourceRecord -ZoneName $dom -RRType A | Where-Object { $_.HostName -eq "@" }
    Write-Host "Dominio: $dom"
    Write-Host "IP:      $(if($rec){$rec.RecordData.IPv4Address}else{'No encontrado'})"
    Pause
}

function Menu-DNS {
    while ($true) {
        Clear-Host
        Write-Host "======================================="
        Write-Host "            SERVICIO DNS"
        Write-Host "======================================="
        Write-Host "1) Estado    2) Instalar    3) Nuevo Dominio"
        Write-Host "4) Borrar    5) Consultar   6) Volver"
        Write-Host "======================================="
        $op = Read-Host "Opcion"
        switch ($op) {
            "1" { Estado-DNS }
            "2" { Instalar-DNS }
            "3" { Nuevo-Dominio }
            "4" { Borrar-Dominio }
            "5" { Consultar-Dominio }
            "6" { return }
            default { Write-Host "Invalido"; Start-Sleep 1 }
        }
    }
}
