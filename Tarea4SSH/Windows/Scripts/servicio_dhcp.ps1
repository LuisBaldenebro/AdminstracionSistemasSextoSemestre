function Validar-IP {
    param([string]$IP)
    $ipObj = $null
    if (![System.Net.IPAddress]::TryParse($IP, [ref]$ipObj)) { return $false }
    $oct = $IP.Split('.')
    if ($IP -eq "0.0.0.0")       { Write-Host "Error: 0.0.0.0 invalida" -ForegroundColor Red; return $false }
    if ($IP.StartsWith("127."))  { Write-Host "Error: Localhost no permitido" -ForegroundColor Red; return $false }
    if ($oct[3] -eq "0")         { Write-Host "Error: IP de red (.0)" -ForegroundColor Red; return $false }
    if ($oct[3] -eq "255")       { Write-Host "Error: IP de broadcast (.255)" -ForegroundColor Red; return $false }
    return $true
}

function Configurar-FirewallDHCP {
    param([string]$Iface)
    try {
        Set-NetConnectionProfile -InterfaceAlias $Iface -NetworkCategory Private -ErrorAction SilentlyContinue
        Get-NetFirewallRule -DisplayGroup "DHCP Server" -ErrorAction SilentlyContinue | Set-NetFirewallRule -Enabled True
        if (-not (Get-NetFirewallRule -DisplayName "DHCP-UDP67" -ErrorAction SilentlyContinue)) {
            New-NetFirewallRule -DisplayName "DHCP-UDP67" -Direction Inbound -Protocol UDP -LocalPort 67 -Action Allow -Profile Any | Out-Null
        }
    } catch {}
}

function Estado-Servicio {
    while ($true) {
        Clear-Host
        Write-Host "----------------------------------------"
        Write-Host "        ESTADO DEL SERVICIO DHCP"
        Write-Host "----------------------------------------"
        $rol = Get-WindowsFeature -Name DHCP
        if ($rol.InstallState -ne "Installed") {
            Write-Host "[!] DHCP no instalado." -ForegroundColor Red
            Read-Host "Enter..."; return
        }
        $svc = Get-Service DhcpServer
        if ($svc.Status -eq "Running") {
            Write-Host "Estado: ACTIVO" -ForegroundColor Green
            Write-Host " [1] Detener  [2] Reiniciar/Limpiar  [3] Volver"
        } else {
            Write-Host "Estado: DETENIDO" -ForegroundColor Red
            Write-Host " [1] Iniciar  [3] Volver"
        }
        $op = Read-Host "Opcion"
        switch ($op) {
            "1" {
                if ($svc.Status -eq "Running") { Stop-Service DhcpServer -Force }
                else { Start-Service DhcpServer }
                Start-Sleep 2
            }
            "2" {
                if ($svc.Status -eq "Running") {
                    try { Get-DhcpServerv4Scope | ForEach-Object { Get-DhcpServerv4Lease -ScopeId $_.ScopeId | Remove-DhcpServerv4Lease -Force } } catch {}
                    Restart-Service DhcpServer -Force
                    Write-Host "Reiniciado y leases limpiados." -ForegroundColor Green
                    Start-Sleep 2
                }
            }
            "3" { return }
        }
    }
}

function Instalar-Servicio {
    $check = Get-WindowsFeature -Name DHCP
    if ($check.InstallState -eq "Installed") {
        Write-Host "DHCP ya instalado."; Read-Host "Enter..."; return
    }
    Write-Host "Instalando Rol DHCP..."
    try {
        Install-WindowsFeature -Name DHCP -IncludeManagementTools
        Add-DhcpServerInDC -DnsName $env:COMPUTERNAME -ErrorAction SilentlyContinue
        Write-Host "[EXITO] DHCP instalado." -ForegroundColor Green
    } catch {
        Write-Host "[ERROR] $($_.Exception.Message)" -ForegroundColor Red
    }
    Read-Host "Enter..."
}

function Configurar-Servicio {
    Clear-Host
    Write-Host "========================================"
    Write-Host "   CONFIGURACION DHCP (WINDOWS)"
    Write-Host "========================================"
    if ((Get-WindowsFeature DHCP).InstallState -ne "Installed") {
        Write-Host "Instale el servicio primero."; Read-Host "Enter..."; return
    }
    Write-Host "Interfaces disponibles:"
    Get-NetAdapter | Where-Object Status -eq "Up" | Select-Object Name, MacAddress | Format-Table -AutoSize

    while ($true) {
        $iface = Read-Host "1. Nombre exacto del adaptador (ej: Ethernet 2)"
        if (Get-NetAdapter -Name $iface -ErrorAction SilentlyContinue) { break }
        Write-Host " [!] Interfaz no encontrada." -ForegroundColor Red
    }
    $scopeName = Read-Host "2. Nombre del Ambito"
    while ($true) {
        $ipInicio = Read-Host "3. IP del Servidor"
        if (Validar-IP $ipInicio) { break }
        Write-Host " [!] IP invalida" -ForegroundColor Red
    }
    $bytes = [System.Net.IPAddress]::Parse($ipInicio).GetAddressBytes()
    $poolOct = [int]$bytes[3] + 1
    $prefix   = "{0}.{1}.{2}" -f $bytes[0],$bytes[1],$bytes[2]
    $poolStart = "$prefix.$poolOct"
    $subnetID  = "$prefix.0"

    while ($true) {
        $ipFin = Read-Host "4. Rango final ($prefix.X)"
        if (-not (Validar-IP $ipFin)) { continue }
        if (-not $ipFin.StartsWith($prefix)) { Write-Host " [!] Debe estar en $prefix.x" -ForegroundColor Red; continue }
        if ($poolOct -le [int]$ipFin.Split('.')[3]) { break }
        Write-Host " [!] Debe ser mayor a $poolStart" -ForegroundColor Red
    }
    while ($true) {
        $gateway = Read-Host "5. Gateway (Enter omitir)"
        if ([string]::IsNullOrWhiteSpace($gateway)) { break }
        if ((Validar-IP $gateway) -and $gateway.StartsWith($prefix)) { break }
        Write-Host " [!] IP invalida o fuera del segmento" -ForegroundColor Red
    }
    $dns = Read-Host "6. DNS (Enter omitir)"
    if (-not [string]::IsNullOrWhiteSpace($dns) -and -not (Validar-IP $dns)) { $dns = $null }
    while ($true) {
        $leaseStr = Read-Host "7. Tiempo de concesion (segundos)"
        if ($leaseStr -match "^\d+$") { break }
        Write-Host " [!] Solo numeros." -ForegroundColor Red
    }
    $leaseSpan = New-TimeSpan -Seconds $leaseStr

    Clear-Host
    Write-Host "========================================"
    Write-Host "        RESUMEN"
    Write-Host "========================================"
    Write-Host "Adaptador:   $iface"
    Write-Host "Ambito:      $scopeName"
    Write-Host "IP Servidor: $ipInicio"
    Write-Host "Pool:        $poolStart - $ipFin"
    Write-Host "Gateway:     $(if($gateway){$gateway}else{'(ninguno)'})"
    Write-Host "DNS:         $(if($dns){$dns}else{'(ninguno)'})"
    Write-Host "Concesion:   $leaseStr seg"
    Write-Host "========================================"
    $ok = Read-Host "Confirmar (S/N)"
    if ($ok -ne "s") { Write-Host "Cancelado."; return }

    # Asignar IP estatica
    try {
        Remove-NetIPAddress -InterfaceAlias $iface -AddressFamily IPv4 -Confirm:$false -ErrorAction SilentlyContinue
        if ([string]::IsNullOrWhiteSpace($gateway)) {
            New-NetIPAddress -InterfaceAlias $iface -IPAddress $ipInicio -PrefixLength 24 -Confirm:$false
        } else {
            New-NetIPAddress -InterfaceAlias $iface -IPAddress $ipInicio -PrefixLength 24 -DefaultGateway $gateway -Confirm:$false
        }
        if ($dns) { Set-DnsClientServerAddress -InterfaceAlias $iface -ServerAddresses $dns }
    } catch { Write-Host "Aviso IP: $($_.Exception.Message)" -ForegroundColor Yellow }

    Start-Sleep 2

    # Crear ambito DHCP
    try {
        Get-DhcpServerv4Scope | Remove-DhcpServerv4Scope -Force -ErrorAction SilentlyContinue
        Add-DhcpServerv4Scope -Name $scopeName -StartRange $poolStart -EndRange $ipFin -SubnetMask 255.255.255.0 -State Active -LeaseDuration $leaseSpan
        if (-not [string]::IsNullOrWhiteSpace($gateway)) { Set-DhcpServerv4OptionValue -ScopeId $subnetID -OptionId 3 -Value $gateway }
        if ($dns) { Set-DhcpServerv4OptionValue -ScopeId $subnetID -OptionId 6 -Value $dns -Force }
        Set-DhcpServerv4Binding -InterfaceAlias $iface -BindingState $true -ErrorAction SilentlyContinue
        Restart-Service DhcpServer -Force
        Configurar-FirewallDHCP -Iface $iface
        Write-Host "[EXITO] DHCP configurado y activo." -ForegroundColor Green
    } catch {
        Write-Host "[ERROR] $($_.Exception.Message)" -ForegroundColor Red
    }
    Read-Host "Enter..."
}

function Monitorear-Servicio {
    while ($true) {
        Clear-Host
        Write-Host "========================================================="
        Write-Host "              MONITOREAR DHCP (Windows)"
        Write-Host "========================================================="
        $svc = Get-Service DhcpServer
        if ($svc.Status -eq "Running") { Write-Host "Estado: ACTIVO" -ForegroundColor Green }
        else { Write-Host "Estado: INACTIVO" -ForegroundColor Red }
        Write-Host ("{0,-20} | {1,-20} | {2,-25}" -f 'IP','MAC','HOSTNAME')
        Write-Host "-------------------|--------------------|------------------------"
        try {
            $scope = Get-DhcpServerv4Scope -ErrorAction SilentlyContinue
            if ($scope) {
                $leases = Get-DhcpServerv4Lease -ScopeId $scope.ScopeId -ErrorAction SilentlyContinue
                if ($leases) {
                    foreach ($l in $leases) {
                        Write-Host ("{0,-20} | {1,-20} | {2,-25}" -f $l.IPAddress.IPAddressToString, $l.ClientId, $l.HostName)
                    }
                } else { Write-Host "  Sin concesiones activas." -ForegroundColor DarkGray }
            } else { Write-Host "  No hay ambitos configurados." -ForegroundColor DarkGray }
        } catch { Write-Host "Error leyendo leases." -ForegroundColor Red }
        Write-Host "`n(Ctrl+C para salir)"
        Start-Sleep 2
    }
}

function Menu-DHCP {
    while ($true) {
        Clear-Host
        Write-Host "========================================"
        Write-Host "        GESTIONAR SERVICIO DHCP"
        Write-Host "========================================"
        Write-Host "1. Estado    2. Instalar    3. Configurar"
        Write-Host "4. Monitorear              5. Volver"
        Write-Host "========================================"
        $op = Read-Host "Opcion"
        switch ($op) {
            "1" { Estado-Servicio }
            "2" { Instalar-Servicio }
            "3" { Configurar-Servicio }
            "4" { Monitorear-Servicio }
            "5" { return }
            default { Write-Host "Opcion no valida."; Start-Sleep 1 }
        }
    }
}
