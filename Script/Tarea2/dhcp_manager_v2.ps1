$ErrorActionPreference = "SilentlyContinue"

function ValidarIP {
    param([string]$IP)
    
    if ([string]::IsNullOrWhiteSpace($IP)) {
        return $true
    }
    
    try {
        $ipObj = [System.Net.IPAddress]::Parse($IP)
        
        $octetos = $IP.Split('.')
        $primero = [int]$octetos[0]
        $segundo = [int]$octetos[1]
        
        if ($primero -eq 0 -or $primero -eq 127) {
            Write-Host "Error: IP reservada (rango $primero.x.x.x no permitido)"
            return $false
        }
        
        if ($primero -eq 169 -and $segundo -eq 254) {
            Write-Host "Error: IP reservada (rango 169.254.x.x no permitido)"
            return $false
        }
        
        if ($primero -ge 224 -and $primero -le 239) {
            Write-Host "Error: IP reservada (rango multicast 224-239.x.x.x no permitido)"
            return $false
        }
        
        if ($primero -eq 255) {
            Write-Host "Error: IP reservada (255.x.x.x no permitido)"
            return $false
        }
        
        return $true
    }
    catch {
        return $false
    }
}

function VerificarInstalacion {
    Clear-Host
    Write-Host "=========================================="
    Write-Host "  VERIFICACION DE INSTALACION"
    Write-Host "=========================================="
    Write-Host ""
    
    $dhcpRole = Get-WindowsFeature -Name DHCP
    if ($dhcpRole.Installed) {
        Write-Host "[OK] Rol DHCP detectado"
        Write-Host ""
        $reinstalar = Read-Host "Desea reinstalar? (s/n)"
        if ($reinstalar -eq "s" -or $reinstalar -eq "S") {
            return $false
        }
        else {
            return $true
        }
    }
    else {
        Write-Host "[INFO] Rol DHCP no instalado"
        return $false
    }
}

function InstalarDHCP {
    Write-Host ""
    Write-Host "=========================================="
    Write-Host "  INSTALACION DE ROL DHCP"
    Write-Host "=========================================="
    Write-Host ""
    Write-Host "Instalando rol DHCP..."
    Write-Host "Este proceso puede tardar varios minutos..."
    Write-Host ""
    
    Install-WindowsFeature -Name DHCP -IncludeManagementTools | Out-Null
    
    if ($?) {
        Write-Host "[OK] Instalacion completada"
        
        Add-DhcpServerSecurityGroup | Out-Null
        Restart-Service dhcpserver -ErrorAction SilentlyContinue
        
        Set-ItemProperty -Path registry::HKEY_LOCAL_MACHINE\SOFTWARE\Microsoft\ServerManager\Roles\12 -Name ConfigurationState -Value 2 -ErrorAction SilentlyContinue
        
        Write-Host "[OK] Configuracion post-instalacion completada"
    }
    else {
        Write-Host "[ERROR] Fallo en la instalacion"
    }
}

function ConfigurarDHCP {
    Clear-Host
    Write-Host "=========================================="
    Write-Host "  CONFIGURACION DEL SERVIDOR DHCP"
    Write-Host "=========================================="
    Write-Host ""
    
    $scopeName = Read-Host "Nombre del ambito"
    
    do {
        $ipInicio = Read-Host "IP inicial del rango"
        $validIP = ValidarIP -IP $ipInicio
        if (-not $validIP) {
            Write-Host "IP invalida. Intente nuevamente."
        }
    } while (-not $validIP)
    
    do {
        $ipFinal = Read-Host "IP final del rango"
        $validIP = ValidarIP -IP $ipFinal
        if (-not $validIP) {
            Write-Host "IP invalida. Intente nuevamente."
        }
    } while (-not $validIP)
    
    $octetos = $ipInicio.Split('.')
    $subnet = "$($octetos[0]).$($octetos[1]).$($octetos[2]).0"
    
    $gateway = Read-Host "Puerta de enlace (Enter para omitir)"
    if (-not [string]::IsNullOrWhiteSpace($gateway)) {
        while (-not (ValidarIP -IP $gateway)) {
            Write-Host "IP invalida."
            $gateway = Read-Host "Puerta de enlace (Enter para omitir)"
            if ([string]::IsNullOrWhiteSpace($gateway)) { break }
        }
    }
    
    $dns = Read-Host "DNS (Enter para omitir)"
    if (-not [string]::IsNullOrWhiteSpace($dns)) {
        while (-not (ValidarIP -IP $dns)) {
            Write-Host "IP invalida."
            $dns = Read-Host "DNS (Enter para omitir)"
            if ([string]::IsNullOrWhiteSpace($dns)) { break }
        }
    }
    
    $leaseTimeSeconds = Read-Host "Tiempo de concesion en segundos"
    $leaseTimeDays = [math]::Round($leaseTimeSeconds / 86400, 2)
    
    Write-Host ""
    Write-Host "Generando configuracion..."
    
    try {
        $existingScope = Get-DhcpServerv4Scope -ScopeId $subnet -ErrorAction SilentlyContinue
        if ($existingScope) {
            Remove-DhcpServerv4Scope -ScopeId $subnet -Force
        }
        
        Add-DhcpServerv4Scope -Name $scopeName -StartRange $ipInicio -EndRange $ipFinal -SubnetMask 255.255.255.0 -LeaseDuration (New-TimeSpan -Days $leaseTimeDays) -State Active
        
        if (-not [string]::IsNullOrWhiteSpace($gateway)) {
            Set-DhcpServerv4OptionValue -ScopeId $subnet -Router $gateway
        }
        
        if (-not [string]::IsNullOrWhiteSpace($dns)) {
            Set-DhcpServerv4OptionValue -ScopeId $subnet -DnsServer $dns
        }
        
        Write-Host "[OK] Configuracion completada"
    }
    catch {
        Write-Host "[ERROR] Error en la configuracion: $_"
    }
}

function EstadoServicio {
    Clear-Host
    Write-Host "=========================================="
    Write-Host "  ESTADO DEL SERVICIO DHCP"
    Write-Host "=========================================="
    Write-Host ""
    
    $servicio = Get-Service -Name dhcpserver -ErrorAction SilentlyContinue
    
    if ($servicio) {
        Write-Host "Estado: $($servicio.Status)"
        Write-Host "Tipo de inicio: $($servicio.StartType)"
        Write-Host ""
    }
    else {
        Write-Host "Servicio DHCP no encontrado"
        Write-Host ""
    }
    
    $scopes = Get-DhcpServerv4Scope -ErrorAction SilentlyContinue
    if ($scopes) {
        Write-Host "Ambitos configurados:"
        $scopes | Format-Table ScopeId, Name, State, StartRange, EndRange -AutoSize
    }
    else {
        Write-Host "No hay ambitos configurados"
    }
}

function ListarConcesiones {
    Clear-Host
    Write-Host "=========================================="
    Write-Host "  CONCESIONES ACTIVAS"
    Write-Host "=========================================="
    Write-Host ""
    
    $scopes = Get-DhcpServerv4Scope -ErrorAction SilentlyContinue
    if (-not $scopes) {
        Write-Host "No hay ambitos configurados"
        return
    }
    
    $hayLeases = $false
    foreach ($scope in $scopes) {
        $leases = Get-DhcpServerv4Lease -ScopeId $scope.ScopeId -ErrorAction SilentlyContinue
        if ($leases) {
            $hayLeases = $true
            $leases | Format-Table IPAddress, HostName, ClientId, AddressState, LeaseExpiryTime -AutoSize
        }
    }
    
    if (-not $hayLeases) {
        Write-Host "No hay concesiones activas"
    }
}

function MenuPrincipal {
    while ($true) {
        Clear-Host
        Write-Host "=========================================="
        Write-Host "  GESTOR DE SERVIDOR DHCP"
        Write-Host "=========================================="
        Write-Host ""
        Write-Host "1. Verificar e Instalar DHCP"
        Write-Host "2. Configurar Servidor DHCP"
        Write-Host "3. Ver Estado del Servicio"
        Write-Host "4. Listar Concesiones Activas"
        Write-Host "5. Salir"
        Write-Host ""
        
        $opcion = Read-Host "Seleccione opcion"
        
        if ($opcion -eq "1") {
            $instalado = VerificarInstalacion
            if (-not $instalado) {
                InstalarDHCP
            }
            Read-Host "`nPresione Enter para continuar"
        }
        elseif ($opcion -eq "2") {
            ConfigurarDHCP
            Read-Host "`nPresione Enter para continuar"
        }
        elseif ($opcion -eq "3") {
            EstadoServicio
            Read-Host "`nPresione Enter para continuar"
        }
        elseif ($opcion -eq "4") {
            ListarConcesiones
            Read-Host "`nPresione Enter para continuar"
        }
        elseif ($opcion -eq "5") {
            Write-Host "`nSaliendo..."
            exit
        }
        else {
            Write-Host "`nOpcion invalida"
            Start-Sleep -Seconds 2
        }
    }
}

$isAdmin = ([Security.Principal.WindowsPrincipal] [Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)

if (-not $isAdmin) {
    Write-Host "Este script debe ejecutarse como Administrador"
    Read-Host "Presione Enter para salir"
    exit
}

MenuPrincipal
