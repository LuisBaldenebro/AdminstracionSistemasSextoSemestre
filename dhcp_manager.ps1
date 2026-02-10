$isAdmin = ([Security.Principal.WindowsPrincipal] `
    [Security.Principal.WindowsIdentity]::GetCurrent()
).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)

if (-not $isAdmin) {
    Write-Host "Este script debe ejecutarse como Administrador"
    Read-Host "Presione Enter para salir"
    exit
}

function ValidarIP {
    param([string]$IP)
    try {
        [System.Net.IPAddress]::Parse($IP) | Out-Null
        return $true
    }
    catch {
        return $false
    }
}

function VerificarInstalacion {
    Clear-Host
    Write-Host "VERIFICANDO INSTALACION DEL ROL DHCP"
    Write-Host ""

    $dhcpRole = Get-WindowsFeature -Name DHCP
    if ($dhcpRole.Installed) {
        Write-Host "[OK] Rol DHCP ya esta instalado"
        return $true
    } else {
        Write-Host "[!] Rol DHCP no detectado"
        return $false
    }
}

function InstalarDHCP {
    Write-Host ""
    Write-Host "[*] Instalando Rol DHCP Server..."
    Write-Host "    Esto puede tardar varios minutos..."
    Write-Host ""

    Install-WindowsFeature -Name DHCP -IncludeManagementTools | Out-Null

    if ($?) {
        Write-Host "[OK] Rol DHCP instalado correctamente"
        Add-DhcpServerSecurityGroup | Out-Null
        Restart-Service dhcpserver -ErrorAction SilentlyContinue
        Write-Host "[OK] Configuracion post-instalacion completada"
    } else {
        Write-Host "[ERROR] Error en la instalacion"
    }
}

function ConfigurarDHCP {
    Clear-Host
    Write-Host "CONFIGURACION INTERACTIVA DEL SERVIDOR DHCP"
    Write-Host ""

    $scopeName = Read-Host "Nombre del Ambito"

    do {
        $ipInicio = Read-Host "IP Inicial"
    } until (ValidarIP $ipInicio)

    do {
        $ipFinal = Read-Host "IP Final"
    } until (ValidarIP $ipFinal)

    do {
        $gateway = Read-Host "Gateway"
    } until (ValidarIP $gateway)

    do {
        $dns = Read-Host "DNS"
    } until (ValidarIP $dns)

    $leaseTime = Read-Host "Tiempo de concesion en dias"

    Write-Host ""
    Write-Host "[*] Aplicando configuracion..."

    Add-DhcpServerv4Scope `
        -Name $scopeName `
        -StartRange $ipInicio `
        -EndRange $ipFinal `
        -SubnetMask 255.255.255.0 `
        -LeaseDuration (New-TimeSpan -Days $leaseTime) `
        -State Active

    Write-Host "[OK] Ambito configurado correctamente"
}

function MenuPrincipal {
    while ($true) {
        Clear-Host
        Write-Host "GESTOR DE SERVIDOR DHCP"
        Write-Host ""
        Write-Host "1. Verificar / Instalar DHCP"
        Write-Host "2. Configurar DHCP"
        Write-Host "3. Salir"
        Write-Host ""

        $opcion = Read-Host "Seleccione una opcion"

        switch ($opcion) {
            "1" {
                if (-not (VerificarInstalacion)) {
                    InstalarDHCP
                }
                Read-Host "Presione Enter para continuar"
            }
            "2" {
                ConfigurarDHCP
                Read-Host "Presione Enter para continuar"
            }
            "3" {
                exit
            }
            default {
                Write-Host "Opcion invalida"
                Start-Sleep 2
            }
        }
    }
}

MenuPrincipal
