
#PERMISOS DE ADMINISTRADOR
if (!([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole] "Administrator")) {
    Write-Warning "Este script debe ejecutarse como Administrador."
    Start-Process powershell.exe "-NoProfile -ExecutionPolicy Bypass -File `"$PSCommandPath`"" -Verb RunAs
    exit
}

#UTILIDADES
function Limpiar {
    [Console]::Out.Flush()
    Start-Sleep -Milliseconds 150
    [System.Console]::Clear()
    [Console]::Out.Flush()
}

function Validar-IP {
    param ([string]$IP)
    $ipObj = $null
    if (![System.Net.IPAddress]::TryParse($IP, [ref]$ipObj)) { return $false }
    $oct = $IP.Split('.')
    if ($oct.Count -ne 4)    { return $false }
    if ($IP -eq "0.0.0.0")   { Write-Host "  Error: IP 0.0.0.0 no valida.";             return $false }
    if ($IP.StartsWith("127.")){ Write-Host "  Error: Localhost no permitido.";           return $false }
    if ($oct[3] -eq "0")      { Write-Host "  Error: IP de Red (termina en .0).";        return $false }
    if ($oct[3] -eq "255")    { Write-Host "  Error: IP de Broadcast (termina en .255)."; return $false }
    return $true
}

#SERVICIO DHCP

function DHCP-Estado {
    while ($true) {
        Limpiar
        Write-Host "================================"
        Write-Host "  ESTADO DEL SERVICIO DHCP"
        Write-Host "================================"
        Write-Host ""

        $feat = Get-WindowsFeature -Name DHCP
        if ($feat.InstallState -ne "Installed") {
            Write-Host "  El Rol DHCP Server NO esta instalado."
            Write-Host "  Use la opcion 2 para instalarlo."
            Read-Host "`n  Presione Enter para volver"
            return
        }

        $svc = Get-Service DhcpServer

        if ($svc.Status -eq "Running") {
            Write-Host "  Estado: ACTIVO (Running)"
            Write-Host ""
            Write-Host "  1) Detener el servicio"
            Write-Host "  2) Reiniciar y limpiar concesiones"
            Write-Host "  3) Volver"
        } else {
            Write-Host "  Estado: DETENIDO (Stopped)"
            Write-Host ""
            Write-Host "  1) Iniciar el servicio"
            Write-Host "  3) Volver"
        }

        Write-Host ""
        $op = Read-Host "  Seleccione una opcion"

        switch ($op) {
            "1" {
                if ($svc.Status -eq "Running") {
                    Write-Host "  Deteniendo servicio DHCP..."
                    Stop-Service DhcpServer -Force
                } else {
                    Write-Host "  Iniciando servicio DHCP..."
                    Start-Service DhcpServer
                }
                Start-Sleep 2
            }
            "2" {
                if ($svc.Status -eq "Running") {
                    Write-Host "  Reiniciando y purgando concesiones..."
                    try {
                        foreach ($scope in (Get-DhcpServerv4Scope)) {
                            Get-DhcpServerv4Lease -ScopeId $scope.ScopeId | Remove-DhcpServerv4Lease -Force
                            Write-Host "  > Concesiones eliminadas para $($scope.ScopeId)"
                        }
                    } catch { Write-Host "  No hay ambitos activos o error al limpiar." }
                    Restart-Service DhcpServer -Force
                    Write-Host "  Servicio reiniciado correctamente."
                    Start-Sleep 2
                } else {
                    Write-Host "  El servicio no esta activo."; Start-Sleep 1
                }
            }
            "3" { return }
            Default { Write-Host "  Opcion no valida."; Start-Sleep 1 }
        }
    }
}

function DHCP-Instalar {
    Limpiar
    Write-Host "================================"
    Write-Host "  INSTALACION DEL SERVICIO DHCP"
    Write-Host "================================"
    Write-Host ""

    if ((Get-WindowsFeature -Name DHCP).InstallState -eq "Installed") {
        Write-Host "  El servicio ya esta instalado."
        Write-Host ""
    Read-Host "  Presione Enter"; return
    }

    Write-Host "  Iniciando instalacion... Por favor espere."
    try {
        Install-WindowsFeature -Name DHCP -IncludeManagementTools | Out-Null

        $enDominio = (Get-WmiObject Win32_ComputerSystem).PartOfDomain
        if ($enDominio) {
            Add-DhcpServerInDC -DnsName $env:COMPUTERNAME -ErrorAction SilentlyContinue
            Write-Host "  > Servidor autorizado en el dominio AD."
        } else {
            Write-Host "  > Servidor en Workgroup, omitiendo autorizacion AD."
        }

        Set-ItemProperty `
            -Path "HKLM:\SOFTWARE\Microsoft\ServerManager\Roles\12" `
            -Name "ConfigurationState" `
            -Value 2 `
            -ErrorAction SilentlyContinue

        Write-Host "  [EXITO] Instalacion completada."
    } catch {
        Write-Host "  [ERROR] $($_.Exception.Message)"
    }
    Write-Host ""
    Read-Host "  Presione Enter"
}

function DHCP-Configurar {
    Limpiar
    Write-Host "================================"
    Write-Host "  CONFIGURACION DE DHCP"
    Write-Host "================================"
    Write-Host ""

    if ((Get-WindowsFeature DHCP).InstallState -ne "Installed") {
        Write-Host "  Error: Instale el servicio primero."
        Read-Host "  Enter"; return
    }

    Write-Host "  Interfaces disponibles:"
    Get-NetAdapter | Where-Object Status -eq "Up" | Select-Object Name, InterfaceDescription | Format-Table -AutoSize
    Write-Host ""

    while ($true) {
        $iface = Read-Host "  1. Nombre del Adaptador de red"
        if (Get-NetAdapter -Name $iface -ErrorAction SilentlyContinue) { break }
        Write-Host "  La interfaz no existe."
    }

    $scopeName = Read-Host "  2. Nombre del Ambito"

    while ($true) {
        $ipInicio = Read-Host "  3. Rango inicial (IP del Servidor)"
        if (Validar-IP $ipInicio) { break }
        Write-Host "  IP invalida."
    }

    $bytes         = ([System.Net.IPAddress]::Parse($ipInicio)).GetAddressBytes()
    $poolStartLast = [int]$bytes[3] + 1
    $prefix        = "{0}.{1}.{2}" -f $bytes[0], $bytes[1], $bytes[2]
    $poolStart     = "$prefix.$poolStartLast"
    $subnetID      = "$prefix.0"

    while ($true) {
        $ipFin = Read-Host "  4. Rango final ($prefix.X)"
        if (-not (Validar-IP $ipFin)) { continue }
        if (-not $ipFin.StartsWith($prefix)) { Write-Host "  Debe estar en el segmento $prefix.x"; continue }
        if ($poolStartLast -le [int]$ipFin.Split('.')[3]) { break }
        Write-Host "  El rango final debe ser mayor a $poolStart"
    }

    while ($true) {
        $gateway = Read-Host "  5. Gateway (Enter para omitir)"
        if ([string]::IsNullOrWhiteSpace($gateway)) { break }
        if ((Validar-IP $gateway) -and $gateway.StartsWith($prefix)) { break }
        elseif (-not $gateway.StartsWith($prefix)) { Write-Host "  El Gateway debe pertenecer a la red $prefix.x" }
    }

    while ($true) {
        $dns = Read-Host "  6. DNS (IP del servidor, Enter para omitir)"
        if ([string]::IsNullOrWhiteSpace($dns)) { break }
        if (-not (Validar-IP $dns)) { Write-Host "  IP invalida."; continue }

        $dnsLast = [int]$dns.Split('.')[3]
        $poolSLast = [int]$poolStart.Split('.')[3]
        $ipFinLast = [int]$ipFin.Split('.')[3]
        if ($dns.StartsWith($prefix) -and $dnsLast -ge $poolSLast -and $dnsLast -le $ipFinLast) {
            Write-Host ""
            Write-Host "  [!] ATENCION: La IP $dns esta dentro del pool DHCP ($poolStart - $ipFin)."
            Write-Host "      Esto causara conflicto. Use la IP del servidor: $ipInicio"
            Write-Host ""
            continue
        }
        break
    }

    while ($true) {
        $leaseStr = Read-Host "  7. Tiempo de concesion (segundos)"
        if ($leaseStr -match "^\d+$") { break }
        Write-Host "  Debe ser un numero entero."
    }
    $leaseSpan = New-TimeSpan -Seconds $leaseStr

    Limpiar
    Write-Host "================================"
    Write-Host "  RESUMEN DE CONFIGURACION"
    Write-Host "================================"
    Write-Host ""
    Write-Host "  1- Adaptador:       $iface"
    Write-Host "  2- Ambito:          $scopeName"
    Write-Host "  3- IP Servidor:     $ipInicio"
    Write-Host "  4- Pool DHCP:       $poolStart - $ipFin"
    Write-Host "  5- Gateway:         $(if ([string]::IsNullOrWhiteSpace($gateway)) { '(sin gateway)' } else { $gateway })"
    Write-Host "  6- DNS:             $(if ([string]::IsNullOrWhiteSpace($dns)) { '(sin DNS)' } else { $dns })"
    Write-Host "  7- Concesion:       $leaseStr segundos"
    Write-Host ""
    $confirm = Read-Host "  Confirmar configuracion (S/N)"
    if ($confirm -ne "s" -and $confirm -ne "S") { Write-Host "  Cancelado."; Start-Sleep 1; return }

    Write-Host ""
    Write-Host "  Configurando IP estatica en $iface..."
    try {
        Remove-NetIPAddress -InterfaceAlias $iface -AddressFamily IPv4 -Confirm:$false -ErrorAction SilentlyContinue
        if ([string]::IsNullOrWhiteSpace($gateway)) {
            New-NetIPAddress -InterfaceAlias $iface -IPAddress $ipInicio -PrefixLength 24 -Confirm:$false | Out-Null
        } else {
            New-NetIPAddress -InterfaceAlias $iface -IPAddress $ipInicio -PrefixLength 24 -DefaultGateway $gateway -Confirm:$false | Out-Null
        }

        if ($dns) {
            try {
                $ifIndex = (Get-NetAdapter -Name $iface).InterfaceIndex
                Set-ItemProperty `
                    -Path "HKLM:\SYSTEM\CurrentControlSet\Services\Tcpip\Parameters\Interfaces\$(
                        (Get-NetAdapter -Name $iface).InterfaceGuid)" `
                    -Name "NameServer" -Value $dns -ErrorAction SilentlyContinue
                Write-Host "  > DNS $dns asignado correctamente."
            } catch {
                Set-DnsClientServerAddress -InterfaceAlias $iface -ServerAddresses $dns -Validate:$false -ErrorAction SilentlyContinue
            }
        }
    } catch { Write-Host "  Nota: $($_.Exception.Message)" }
    Start-Sleep 2

    Write-Host "  Configurando Servicio DHCP..."
    try {
        Get-DhcpServerv4Scope -ErrorAction SilentlyContinue | Remove-DhcpServerv4Scope -Force -ErrorAction SilentlyContinue
        Add-DhcpServerv4Scope -Name $scopeName -StartRange $poolStart -EndRange $ipFin -SubnetMask 255.255.255.0 -State Active -LeaseDuration $leaseSpan
        if (-not [string]::IsNullOrWhiteSpace($gateway)) { Set-DhcpServerv4OptionValue -ScopeId $subnetID -OptionId 3 -Value $gateway -ErrorAction SilentlyContinue }
        if ($dns) {
            try {
                $dnsObj = [System.Net.IPAddress]::Parse($dns)
                Set-DhcpServerv4OptionValue -ScopeId $subnetID -OptionId 6 -Value $dnsObj.ToString() -ErrorAction Stop
            } catch {
                try {
                    $opt = New-Object Microsoft.Management.Infrastructure.CimInstance("MSFT_DHCPServerv4OptionValue","root/Microsoft/Windows/DHCP")
                    Add-DhcpServerv4OptionValue -ScopeId $subnetID -OptionId 6 -Value $dns -ErrorAction SilentlyContinue
                } catch {}
            }
        }
        Restart-Service DhcpServer -Force
        Write-Host "  [EXITO] Servicio configurado y activo."
    } catch { Write-Host "  [ERROR] $($_.Exception.Message)" }

    Write-Host ""
    Read-Host "  Presione Enter"
}

function DHCP-Monitorear {
    while ($true) {
        Limpiar
        Write-Host "================================"
        Write-Host "  MONITOREAR SERVICIO DHCP"
        Write-Host "================================"
        Write-Host ""
        $svc = Get-Service DhcpServer
        Write-Host "  Estado: $(if ($svc.Status -eq 'Running') { 'ACTIVO' } else { 'INACTIVO' })"
        Write-Host ""
        Write-Host "  Clientes Conectados:"
        Write-Host ("  {0,-18} | {1,-18} | {2,-25}" -f 'DIRECCION IP', 'MAC ADDRESS', 'HOSTNAME')
        Write-Host "  ------------------|------------------|------------------------"
        try {
            $scopes = Get-DhcpServerv4Scope -ErrorAction SilentlyContinue
            $hayLeases = $false
            foreach ($scope in $scopes) {
                $leases = Get-DhcpServerv4Lease -ScopeId $scope.ScopeId -ErrorAction SilentlyContinue
                foreach ($lease in $leases) {
                    Write-Host ("  {0,-18} | {1,-18} | {2,-25}" -f $lease.IPAddress.IPAddressToString, $lease.ClientId, $lease.HostName)
                    $hayLeases = $true
                }
            }
            if (-not $hayLeases) { Write-Host "  Sin concesiones activas..." }
        } catch { Write-Host "  Error leyendo concesiones." }

        Write-Host ""
        Write-Host "  (Presione CTRL+C para salir del monitoreo)"
        Start-Sleep 2
    }
}

function Menu-DHCP {
    while ($true) {
        Limpiar
        Write-Host "================================"
        Write-Host "  GESTIONAR SERVICIO DHCP"
        Write-Host "================================"
        Write-Host ""
        Write-Host "  1) Verificar Estado del Servicio"
        Write-Host "  2) Instalar Servicio (Rol DHCP)"
        Write-Host "  4) Configurar Servicio"
        Write-Host "  5) Monitorear Servicio"
        Write-Host "  6) Volver al menu principal"
        Write-Host ""
        $op = Read-Host "  Opcion"
        switch ($op) {
            "1" { DHCP-Estado;     Start-Sleep -Milliseconds 200; Limpiar }
            "2" { DHCP-Instalar;   Start-Sleep -Milliseconds 200; Limpiar }
            "4" { DHCP-Configurar; Start-Sleep -Milliseconds 200; Limpiar }
            "5" { DHCP-Monitorear; Start-Sleep -Milliseconds 200; Limpiar }
            "6" { return }
            Default { Write-Host "  Opcion no valida."; Start-Sleep 1 }
        }
    }
}

#SERVICIO DNS

function DNS-Estado {
    while ($true) {
        Limpiar
        Write-Host "================================"
        Write-Host "  ESTADO DEL SERVICIO DNS"
        Write-Host "================================"
        Write-Host ""

        $svc = Get-Service -Name DNS -ErrorAction SilentlyContinue
        if ($null -eq $svc) {
            Write-Host "  Servicio DNS no instalado."
            Write-Host ""
    Read-Host "  Presione Enter"; return
        }

        Write-Host "  Estado: $($svc.Status)"
        Write-Host ""

        if ($svc.Status -eq "Running") {
            Write-Host "  1) Detener servicio"
            Write-Host "  2) Reiniciar servicio"
            Write-Host "  3) Volver"
        } else {
            Write-Host "  1) Iniciar servicio"
            Write-Host "  3) Volver"
        }

        Write-Host ""
        $op = Read-Host "  Seleccione una opcion"

        switch ($op) {
            "1" {
                if ($svc.Status -eq "Running") {
                    Write-Host "  Deteniendo servicio..."; Stop-Service DNS -Force
                } else {
                    Write-Host "  Iniciando servicio..."; Start-Service DNS
                }
                Start-Sleep 2
            }
            "2" {
                if ($svc.Status -eq "Running") {
                    Write-Host "  Reiniciando servicio..."; Restart-Service DNS -Force; Start-Sleep 2
                } else {
                    Write-Host "  El servicio esta detenido."; Start-Sleep 2
                }
            }
            "3" { return }
            Default { Write-Host "  Opcion no valida."; Start-Sleep 1 }
        }
    }
}

function DNS-Instalar {
    Limpiar
    Write-Host "================================"
    Write-Host "  INSTALACION DEL SERVICIO DNS"
    Write-Host "================================"
    Write-Host ""

    if ((Get-WindowsFeature -Name DNS).Installed) {
        Write-Host "  DNS ya esta instalado."
        Write-Host ""
    Read-Host "  Presione Enter"; return
    }

    Write-Host "  Instalando servicio DNS... Por favor espere."
    Install-WindowsFeature -Name DNS -IncludeManagementTools | Out-Null

    if ((Get-WindowsFeature -Name DNS).Installed) {
        Start-Service DNS
        Set-NetConnectionProfile -InterfaceAlias "Ethernet 2" -NetworkCategory Private -ErrorAction SilentlyContinue
        Enable-NetFirewallRule -DisplayGroup "DNS Server" -ErrorAction SilentlyContinue
        Enable-NetFirewallRule -Name FPS-ICMP4-ERQ-In -ErrorAction SilentlyContinue
        Write-Host "  [EXITO] Instalacion completada y firewall configurado."
    } else {
        Write-Host "  [ERROR] Fallo la instalacion."
    }
    Write-Host ""
    Read-Host "  Presione Enter"
}

function DNS-NuevoDominio {
    Limpiar
    Write-Host "================================"
    Write-Host "  NUEVO DOMINIO DNS"
    Write-Host "================================"
    Write-Host ""

    $dominio = Read-Host "  Nombre del dominio (ej: reprobados.com)"
    if ([string]::IsNullOrWhiteSpace($dominio)) { Write-Host "  Dominio invalido."; Start-Sleep 2; return }

    $ipSrv = (Get-NetIPAddress -AddressFamily IPv4 |
        Where-Object { $_.IPAddress -notlike "169.*" -and $_.IPAddress -ne "127.0.0.1" } |
        Select-Object -First 1).IPAddress

    if (-not $ipSrv) { Write-Host "  No se pudo detectar la IP del servidor."; Read-Host "  Enter"; return }

    if (Get-DnsServerZone -Name $dominio -ErrorAction SilentlyContinue) {
        Write-Host "  El dominio ya existe."; Start-Sleep 2; return
    }

    Write-Host "  Creando zona DNS..."
    Add-DnsServerPrimaryZone -Name $dominio -ZoneFile "$dominio.dns"
    Add-DnsServerResourceRecordA -ZoneName $dominio -Name "@"   -IPv4Address $ipSrv
    Add-DnsServerResourceRecordA -ZoneName $dominio -Name "www" -IPv4Address $ipSrv

    #Limpiar cache para que los clientes puedan hacer ping al nuevo dominio
    try { Clear-DnsServerCache -Force; Write-Host "  > Cache del servidor DNS limpiada." }
    catch { Write-Host "  > No se pudo limpiar la cache: $($_.Exception.Message)" }

    Write-Host "  [EXITO] Dominio '$dominio' creado. IP: $ipSrv"
    Write-Host ""
    Read-Host "  Presione Enter"
}

function DNS-BorrarDominio {
    Limpiar
    Write-Host "================================"
    Write-Host "  BORRAR DOMINIO DNS"
    Write-Host "================================"
    Write-Host ""

    $dominio = Read-Host "  Dominio a eliminar"

    if (Get-DnsServerZone -Name $dominio -ErrorAction SilentlyContinue) {
        Remove-DnsServerZone -Name $dominio -Force

        #Limpiar cache para que los clientes dejen de resolver el dominio eliminado
        try { Clear-DnsServerCache -Force; Write-Host "  > Cache del servidor DNS limpiada." }
        catch { Write-Host "  > No se pudo limpiar la cache: $($_.Exception.Message)" }

        Write-Host "  [EXITO] Dominio '$dominio' eliminado."
    } else {
        Write-Host "  El dominio no existe."
    }
    Write-Host ""
    Read-Host "  Presione Enter"
}

function DNS-ConsultarDominio {
    Limpiar
    Write-Host "================================"
    Write-Host "  CONSULTAR DOMINIO DNS"
    Write-Host "================================"
    Write-Host ""

    $zonas = Get-DnsServerZone | Where-Object { $_.ZoneType -eq "Primary" }

    if ($zonas.Count -eq 0) {
        Write-Host "  No existen dominios configurados."
        Write-Host ""
    Read-Host "  Presione Enter"; return
    }

    Write-Host "  Dominios disponibles:"
    Write-Host ""
    $i = 1
    foreach ($z in $zonas) { Write-Host "  $i) $($z.ZoneName)"; $i++ }

    Write-Host ""
    $sel = Read-Host "  Seleccione un numero"

    if (-not ($sel -match "^\d+$") -or [int]$sel -lt 1 -or [int]$sel -gt $zonas.Count) {
        Write-Host "  Seleccion invalida."; Start-Sleep 2; return
    }

    $dominio = $zonas[[int]$sel - 1].ZoneName

    Limpiar
    Write-Host "================================"
    Write-Host "  DOMINIO: $dominio"
    Write-Host "================================"
    Write-Host ""

    $reg = Get-DnsServerResourceRecord -ZoneName $dominio -RRType A | Where-Object { $_.HostName -eq "@" }
    if ($reg) { Write-Host "  IP Asociada: $($reg.RecordData.IPv4Address)" }
    else       { Write-Host "  No se encontro registro A." }

    Write-Host ""
    Write-Host ""
    Read-Host "  Presione Enter"
}

function Menu-DNS {
    while ($true) {
        Limpiar
        Write-Host "================================"
        Write-Host "  GESTIONAR SERVICIO DNS"
        Write-Host "================================"
        Write-Host ""
        Write-Host "  1) Estado del servicio DNS"
        Write-Host "  2) Instalar el servicio DNS"
        Write-Host "  3) Nuevo Dominio"
        Write-Host "  4) Borrar Dominio"
        Write-Host "  5) Consultar Dominio"
        Write-Host "  6) Volver al menu principal"
        Write-Host ""
        $op = Read-Host "  Selecciona una opcion"
        switch ($op) {
            "1" { DNS-Estado;           Start-Sleep -Milliseconds 200; Limpiar }
            "2" { DNS-Instalar;         Start-Sleep -Milliseconds 200; Limpiar }
            "3" { DNS-NuevoDominio;     Start-Sleep -Milliseconds 200; Limpiar }
            "4" { DNS-BorrarDominio;    Start-Sleep -Milliseconds 200; Limpiar }
            "5" { DNS-ConsultarDominio; Start-Sleep -Milliseconds 200; Limpiar }
            "6" { return }
            Default { Write-Host "  Opcion invalida."; Start-Sleep 1 }
        }
    }
}

#MENU PRINCIPAL

$salir = $false
while (-not $salir) {
    Limpiar
    Write-Host "================================"
    Write-Host "  MENU DE SERVICIOS DEL SERVIDOR"
    Write-Host "================================"
    Write-Host ""
    Write-Host "  1. Servicio DHCP"
    Write-Host "  2. Servicio DNS"
    Write-Host "  3. Salir"
    Write-Host ""
    $op = Read-Host "  Seleccione una opcion"
    switch ($op) {
        "1" { Menu-DHCP; Start-Sleep -Milliseconds 200; Limpiar }
        "2" { Menu-DNS;  Start-Sleep -Milliseconds 200; Limpiar }
        "3" { $salir = $true }
        Default { Write-Host "  Opcion invalida."; Start-Sleep 1 }
    }
}
