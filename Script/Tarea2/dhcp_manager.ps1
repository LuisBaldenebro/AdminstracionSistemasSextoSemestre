$ErrorActionPreference = "SilentlyContinue"
$INTERFAZ_RED_INTERNA = "Ethernet 2"

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

function CalcularSubnetMascaraIPServidor {
    param([string]$IPInicio, [string]$IPFinal)
    
    $inicio = $IPInicio.Split('.')
    $final = $IPFinal.Split('.')
    
    $subnet = ""
    $mascara = ""
    $ipServidor = ""
    $prefijo = 0
    
    if ($inicio[0] -ne $final[0]) {
        $subnet = "$($inicio[0]).0.0.0"
        $mascara = "255.0.0.0"
        $ipServidor = "$($inicio[0]).0.0.1"
        $prefijo = 8
    }
    elseif ($inicio[1] -ne $final[1]) {
        $subnet = "$($inicio[0]).$($inicio[1]).0.0"
        $mascara = "255.255.0.0"
        $ipServidor = "$($inicio[0]).$($inicio[1]).0.1"
        $prefijo = 16
    }
    elseif ($inicio[2] -ne $final[2]) {
        $subnet = "$($inicio[0]).$($inicio[1]).$($inicio[2]).0"
        $mascara = "255.255.255.0"
        $ipServidor = "$($inicio[0]).$($inicio[1]).$($inicio[2]).1"
        $prefijo = 24
    }
    else {
        $subnet = "$($inicio[0]).$($inicio[1]).$($inicio[2]).0"
        $mascara = "255.255.255.0"
        $ipServidor = "$($inicio[0]).$($inicio[1]).$($inicio[2]).1"
        $prefijo = 24
    }
    
    return @{
        Subnet = $subnet
        Mascara = $mascara
        IPServidor = $ipServidor
        Prefijo = $prefijo
    }
}

function VerificarYConfigurarInterfaz {
    param([string]$IPServidor, [int]$Prefijo)
    
    Write-Host ""
    Write-Host "=========================================="
    Write-Host "  CONFIGURACION DE INTERFAZ DE RED"
    Write-Host "=========================================="
    Write-Host ""
    
    $adapter = Get-NetAdapter -Name $INTERFAZ_RED_INTERNA -ErrorAction SilentlyContinue
    if (-not $adapter) {
        Write-Host "[ERROR] Interfaz $INTERFAZ_RED_INTERNA no encontrada"
        Write-Host ""
        Write-Host "Interfaces disponibles:"
        Get-NetAdapter | Format-Table Name, Status, InterfaceDescription -AutoSize
        return $false
    }
    
    Write-Host "Interfaz detectada: $INTERFAZ_RED_INTERNA"
    Write-Host "Estado: $($adapter.Status)"
    Write-Host ""
    
    $ipActual = Get-NetIPAddress -InterfaceAlias $INTERFAZ_RED_INTERNA -AddressFamily IPv4 -ErrorAction SilentlyContinue
    
    if ($ipActual) {
        Write-Host "IP actual: $($ipActual.IPAddress)/$($ipActual.PrefixLength)"
        
        if ($ipActual.IPAddress -eq $IPServidor) {
            Write-Host "[OK] La interfaz ya tiene la IP correcta"
            return $true
        }
        else {
            Write-Host "[INFO] La IP actual es diferente a la requerida"
            Write-Host "IP requerida: $IPServidor/$Prefijo"
            Write-Host ""
        }
    }
    else {
        Write-Host "[INFO] La interfaz no tiene IP asignada"
        Write-Host ""
    }
    
    Write-Host "Configurando IP del servidor: $IPServidor/$Prefijo"
    Write-Host ""
    
    Write-Host "Paso 1: Eliminando configuracion IP anterior..."
    Remove-NetIPAddress -InterfaceAlias $INTERFAZ_RED_INTERNA -Confirm:$false -ErrorAction SilentlyContinue
    Remove-NetRoute -InterfaceAlias $INTERFAZ_RED_INTERNA -Confirm:$false -ErrorAction SilentlyContinue
    
    Start-Sleep -Seconds 2
    
    Write-Host "Paso 2: Asignando nueva IP..."
    try {
        New-NetIPAddress -InterfaceAlias $INTERFAZ_RED_INTERNA -IPAddress $IPServidor -PrefixLength $Prefijo -ErrorAction Stop | Out-Null
        Write-Host "[OK] IP asignada correctamente"
    }
    catch {
        Write-Host "[ERROR] Fallo al asignar IP: $_"
        return $false
    }
    
    Start-Sleep -Seconds 3
    
    Write-Host ""
    Write-Host "Paso 3: Verificando configuracion..."
    $ipVerificada = Get-NetIPAddress -InterfaceAlias $INTERFAZ_RED_INTERNA -AddressFamily IPv4 -ErrorAction SilentlyContinue
    
    if ($ipVerificada -and $ipVerificada.IPAddress -eq $IPServidor) {
        Write-Host "[OK] Configuracion verificada"
        Write-Host ""
        Write-Host "Resumen:"
        Write-Host "  Interfaz: $INTERFAZ_RED_INTERNA"
        Write-Host "  IP: $($ipVerificada.IPAddress)"
        Write-Host "  Prefijo: $($ipVerificada.PrefixLength)"
        Write-Host "  Estado: Configurada correctamente"
        return $true
    }
    else {
        Write-Host "[ERROR] La verificacion fallo"
        Write-Host "No se pudo asignar la IP correctamente"
        return $false
    }
}

function DesactivarFirewall {
    Write-Host ""
    Write-Host "=========================================="
    Write-Host "  VERIFICANDO FIREWALL"
    Write-Host "=========================================="
    Write-Host ""
    
    $perfiles = Get-NetFirewallProfile
    $algunoActivo = $false
    
    foreach ($perfil in $perfiles) {
        if ($perfil.Enabled -eq $true) {
            Write-Host "[INFO] Firewall $($perfil.Name): Activo"
            $algunoActivo = $true
        }
    }
    
    if ($algunoActivo) {
        Write-Host ""
        Write-Host "IMPORTANTE: El firewall puede bloquear DHCP"
        $desactivar = Read-Host "Desea desactivar el firewall? (s/n)"
        
        if ($desactivar -eq "s" -or $desactivar -eq "S") {
            Set-NetFirewallProfile -Profile Domain,Public,Private -Enabled False
            Write-Host "[OK] Firewall desactivado"
        }
        else {
            Write-Host "[INFO] Firewall permanece activo"
            Write-Host "Si el cliente no obtiene IP, desactive el firewall manualmente"
        }
    }
    else {
        Write-Host "[OK] Firewall ya esta desactivado"
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
    
    Write-Host ""
    Write-Host "Calculando subnet, mascara e IP del servidor..."
    
    $resultado = CalcularSubnetMascaraIPServidor -IPInicio $ipInicio -IPFinal $ipFinal
    
    Write-Host "Subnet detectada: $($resultado.Subnet)"
    Write-Host "Mascara calculada: $($resultado.Mascara)"
    Write-Host "IP del servidor: $($resultado.IPServidor)"
    
    if (-not (VerificarYConfigurarInterfaz -IPServidor $resultado.IPServidor -Prefijo $resultado.Prefijo)) {
        Write-Host ""
        Write-Host "[ERROR] No se pudo configurar la interfaz de red"
        Write-Host "El servicio DHCP necesita que la interfaz tenga una IP en la misma red"
        Read-Host "`nPresione Enter para continuar"
        return
    }
    
    DesactivarFirewall
    
    Write-Host ""
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
    $leaseTimeDays = [math]::Round([int]$leaseTimeSeconds / 86400, 3)
    if ($leaseTimeDays -lt 0.001) { $leaseTimeDays = 0.001 }
    
    Write-Host ""
    Write-Host "Generando configuracion DHCP..."
    
    try {
        $existingScope = Get-DhcpServerv4Scope -ScopeId $resultado.Subnet -ErrorAction SilentlyContinue
        if ($existingScope) {
            Write-Host "Eliminando ambito anterior..."
            Remove-DhcpServerv4Scope -ScopeId $resultado.Subnet -Force
        }
        
        Write-Host "Creando nuevo ambito..."
        Add-DhcpServerv4Scope -Name $scopeName -StartRange $ipInicio -EndRange $ipFinal -SubnetMask $resultado.Mascara -LeaseDuration (New-TimeSpan -Days $leaseTimeDays) -State Active
        
        if (-not [string]::IsNullOrWhiteSpace($gateway)) {
            Write-Host "Configurando gateway..."
            Set-DhcpServerv4OptionValue -ScopeId $resultado.Subnet -Router $gateway
        }
        
        if (-not [string]::IsNullOrWhiteSpace($dns)) {
            Write-Host "Configurando DNS..."
            Set-DhcpServerv4OptionValue -ScopeId $resultado.Subnet -DnsServer $dns
        }
        
        Write-Host "[OK] Configuracion completada"
        Write-Host ""
        Write-Host "=========================================="
        Write-Host "  RESUMEN DE CONFIGURACION"
        Write-Host "=========================================="
        Write-Host ""
        Write-Host "Servidor:"
        Write-Host "  Interfaz: $INTERFAZ_RED_INTERNA"
        Write-Host "  IP: $($resultado.IPServidor)"
        Write-Host ""
        Write-Host "Ambito DHCP:"
        Write-Host "  Nombre: $scopeName"
        Write-Host "  Red: $($resultado.Subnet)/$($resultado.Prefijo)"
        Write-Host "  Rango: $ipInicio - $ipFinal"
        if (-not [string]::IsNullOrWhiteSpace($gateway)) {
            Write-Host "  Gateway: $gateway"
        }
        if (-not [string]::IsNullOrWhiteSpace($dns)) {
            Write-Host "  DNS: $dns"
        }
        Write-Host "  Tiempo: $leaseTimeSeconds segundos"
        Write-Host ""
        Write-Host "[OK] El servidor DHCP esta listo"
        Write-Host ""
        Write-Host "Desde el cliente, ejecutar:"
        Write-Host "  ipconfig /release `"Ethernet 2`""
        Write-Host "  ipconfig /renew `"Ethernet 2`""
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
    
    Write-Host "=========================================="
    Write-Host "  CONFIGURACION DE RED"
    Write-Host "=========================================="
    Write-Host ""
    Write-Host "Interfaz: $INTERFAZ_RED_INTERNA"
    $ipConfig = Get-NetIPAddress -InterfaceAlias $INTERFAZ_RED_INTERNA -AddressFamily IPv4 -ErrorAction SilentlyContinue
    if ($ipConfig) {
        Write-Host "IP asignada: $($ipConfig.IPAddress)/$($ipConfig.PrefixLength)"
    }
    else {
        Write-Host "Sin IP asignada"
    }
    Write-Host ""
    
    Write-Host "=========================================="
    Write-Host "  AMBITOS CONFIGURADOS"
    Write-Host "=========================================="
    Write-Host ""
    
    $scopes = Get-DhcpServerv4Scope -ErrorAction SilentlyContinue
    if ($scopes) {
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
        Write-Host ""
        return
    }
    
    $hayLeases = $false
    
    foreach ($scope in $scopes) {
        Write-Host "Ambito: $($scope.Name) ($($scope.ScopeId))"
        Write-Host "Rango: $($scope.StartRange) - $($scope.EndRange)"
        Write-Host ""
        
        $leases = Get-DhcpServerv4Lease -ScopeId $scope.ScopeId -ErrorAction SilentlyContinue
        
        if ($leases) {
            $hayLeases = $true
            
            foreach ($lease in $leases) {
                Write-Host "  IP: $($lease.IPAddress)"
                Write-Host "  Hostname: $($lease.HostName)"
                Write-Host "  MAC: $($lease.ClientId)"
                Write-Host "  Estado: $($lease.AddressState)"
                Write-Host "  Expira: $($lease.LeaseExpiryTime)"
                Write-Host ""
            }
        }
        else {
            Write-Host "  Sin concesiones en este ambito"
            Write-Host ""
        }
    }
    
    if (-not $hayLeases) {
        Write-Host "=========================================="
        Write-Host "DIAGNOSTICO:"
        Write-Host ""
        Write-Host "No hay concesiones activas."
        Write-Host "Posibles causas:"
        Write-Host "  1. El cliente no esta configurado para DHCP"
        Write-Host "  2. El cliente no esta en la misma red"
        Write-Host "  3. Hay un firewall bloqueando"
        Write-Host ""
        Write-Host "Verificar:"
        Write-Host "  - Interfaz del servidor tiene IP correcta (Opcion 3)"
        Write-Host "  - Firewall desactivado"
        Write-Host "  - Cliente y servidor en red interna 'red_sistemas'"
        Write-Host ""
        Write-Host "Desde el cliente, ejecutar:"
        Write-Host "  ipconfig /release `"Ethernet 2`""
        Write-Host "  ipconfig /renew `"Ethernet 2`""
        Write-Host "=========================================="
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
