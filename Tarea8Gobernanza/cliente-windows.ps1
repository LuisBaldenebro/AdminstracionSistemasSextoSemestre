[CmdletBinding()]
param([switch]$Menu)

Set-ExecutionPolicy Bypass -Scope Process -Force
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

# CONFIGURACION
$DomainName = 'lab.local'
$DCIp       = '192.168.100.1'
$AdminUser  = 'Administrator'
$AdminPass  = 'Admin123'

$SEP = '=' * 50
$script:Exitosos = 0
$script:Fallidos = 0

# Helpers visuales
function Write-Banner {
    param([string]$Texto)
    Write-Host ''; Write-Host $SEP -ForegroundColor Cyan
    Write-Host "  $Texto" -ForegroundColor Cyan
    Write-Host $SEP -ForegroundColor Cyan; Write-Host ''
}
function Write-Fase {
    param([string]$Texto)
    Write-Host ''; Write-Host $SEP -ForegroundColor Yellow
    Write-Host "  $Texto" -ForegroundColor Yellow
    Write-Host $SEP -ForegroundColor Yellow; Write-Host ''
}
function Write-OK   { param([string]$m) Write-Host "  [OK] $m" -ForegroundColor Green  }
function Write-Info { param([string]$m) Write-Host "  [i]  $m" -ForegroundColor Cyan   }
function Write-Warn { param([string]$m) Write-Host "  [!]  $m" -ForegroundColor Yellow }
function Write-Err  { param([string]$m) Write-Host "  [X]  $m" -ForegroundColor Red    }
function Pause-Menu { $null = Read-Host '  Presiona ENTER para continuar' }

# FASE 0 - Inicializacion
function Invoke-Fase0 {
    Write-Fase 'FASE 0: Inicializacion'
    $fecha = Get-Date -Format 'dd/MM/yyyy HH:mm'
    Write-Banner "Practica: Gobernanza AD - Cliente Windows`n  Equipo  : $env:COMPUTERNAME`n  IP DC   : $DCIp`n  Dominio : $DomainName`n  Fecha   : $fecha"
    $script:Exitosos++
}

# FASE 1 - Configurar DNS y unirse al dominio
function Invoke-Fase1 {
    Write-Fase 'FASE 1: Configuracion de DNS y union al dominio'

    # Configurar DNS primario en el adaptador activo
    Write-Info "Configurando DNS primario: $DCIp ..."
    try {
        $adapter = Get-NetAdapter | Where-Object { $_.Status -eq 'Up' -and $_.InterfaceDescription -notmatch 'Loopback' } |
            Select-Object -First 1
        if ($adapter) {
            Set-DnsClientServerAddress -InterfaceIndex $adapter.InterfaceIndex `
                -ServerAddresses @($DCIp) -Confirm:$false
            Write-OK "DNS configurado en '$($adapter.Name)' --> $DCIp"
            $script:Exitosos++
        } else {
            Write-Warn 'No se encontro adaptador de red activo.'
        }
    } catch {
        Write-Err "Error al configurar DNS: $_"
        $script:Fallidos++
    }

    # Verificar conectividad con el DC
    Write-Info "Verificando conectividad con el DC ($DCIp)..."
    if (Test-Connection -ComputerName $DCIp -Count 2 -Quiet) {
        Write-OK 'Conectividad con el DC confirmada.'
    } else {
        Write-Err 'Sin conectividad con el DC. Verifica la red antes de continuar.'
        $script:Fallidos++
        return
    }

    # Verificar si ya esta en el dominio
    $dominioActual = (Get-WmiObject Win32_ComputerSystem).Domain
    if ($dominioActual -ieq $DomainName) {
        Write-Warn "El equipo '$env:COMPUTERNAME' ya pertenece a '$DomainName'. No se requiere accion."
        $script:Exitosos++
        return
    }
    Write-Info "Dominio actual: '$dominioActual'. Uniendo a '$DomainName'..."

    # Unirse al dominio
    try {
        $secPwd = ConvertTo-SecureString $AdminPass -AsPlainText -Force
        $cred   = New-Object System.Management.Automation.PSCredential("$DomainName\$AdminUser", $secPwd)
        Add-Computer -DomainName $DomainName -Credential $cred -Force -Confirm:$false -ErrorAction Stop
        Write-OK "Equipo unido al dominio '$DomainName' correctamente."
        Write-Warn 'Reiniciando en 10 segundos para aplicar los cambios...'
        $script:Exitosos++
        Start-Sleep -Seconds 10
        Restart-Computer -Force -Confirm:$false
    } catch {
        Write-Err "Error al unirse al dominio: $_"
        $script:Fallidos++
    }
}

# Funciones del menu
function Menu-VerEstado {
    Write-Banner 'Estado de union al dominio'
    $cs = Get-WmiObject Win32_ComputerSystem
    Write-Info "Equipo        : $($cs.Name)"
    Write-Info "Dominio       : $($cs.Domain)"
    Write-Info "En dominio    : $(if ($cs.PartOfDomain) {'SI'} else {'NO'})"
    Write-Info "Usuario actual: $env:USERNAME"
    Write-Info "IP DC config  : $DCIp"
    if ($cs.PartOfDomain) {
        Write-OK 'El equipo esta correctamente unido al dominio.'
    } else {
        Write-Warn 'El equipo NO esta en un dominio.'
    }
}

function Menu-CambiarDns {
    Write-Banner 'Cambiar servidor DNS'
    $nuevoDns = Read-Host '  IP del nuevo servidor DNS'
    if (-not $nuevoDns) { return }
    try {
        $adapter = Get-NetAdapter | Where-Object { $_.Status -eq 'Up' } | Select-Object -First 1
        Set-DnsClientServerAddress -InterfaceIndex $adapter.InterfaceIndex `
            -ServerAddresses @($nuevoDns) -Confirm:$false
        Write-OK "DNS actualizado a $nuevoDns en '$($adapter.Name)'."
    } catch { Write-Err "Error: $_" }
}

function Menu-InfoEquipo {
    Write-Banner 'Informacion del equipo'
    $cs  = Get-WmiObject Win32_ComputerSystem
    $os  = Get-WmiObject Win32_OperatingSystem
    $net = Get-NetAdapter | Where-Object { $_.Status -eq 'Up' } | Select-Object -First 1
    $ip  = (Get-NetIPAddress -InterfaceIndex $net.InterfaceIndex -AddressFamily IPv4 -ErrorAction SilentlyContinue).IPAddress
    $dns = (Get-DnsClientServerAddress -InterfaceIndex $net.InterfaceIndex -AddressFamily IPv4).ServerAddresses -join ', '
    Write-Info "Hostname     : $($cs.Name)"
    Write-Info "Dominio      : $($cs.Domain)"
    Write-Info "SO           : $($os.Caption)"
    Write-Info "RAM (GB)     : $([math]::Round($cs.TotalPhysicalMemory/1GB,2))"
    Write-Info "Adaptador    : $($net.Name)"
    Write-Info "IP           : $ip"
    Write-Info "DNS          : $dns"
    Write-Info "Usuario      : $env:USERNAME"
}

# MENU INTERACTIVO
function Show-Menu {
    do {
        Clear-Host
        Write-Host ''
        Write-Host '  ╔══════════════════════════════════════════╗' -ForegroundColor Cyan
        Write-Host '  ║     GESTION - CLIENTE WINDOWS            ║' -ForegroundColor Cyan
        Write-Host '  ╠══════════════════════════════════════════╣' -ForegroundColor Cyan
        Write-Host '  ║  [1]  Unirse al dominio                  ║' -ForegroundColor Cyan
        Write-Host '  ║  [2]  Verificar estado de union          ║' -ForegroundColor Cyan
        Write-Host '  ║  [3]  Cambiar servidor DNS               ║' -ForegroundColor Cyan
        Write-Host '  ║  [4]  Ver informacion del equipo         ║' -ForegroundColor Cyan
        Write-Host '  ║  [0]  Salir                              ║' -ForegroundColor Cyan
        Write-Host '  ╚══════════════════════════════════════════╝' -ForegroundColor Cyan
        Write-Host ''
        $opcion = Read-Host '  Selecciona una opcion'
        switch ($opcion) {
            '1' { Invoke-Fase1 }
            '2' { Menu-VerEstado }
            '3' { Menu-CambiarDns }
            '4' { Menu-InfoEquipo }
            '0' { Write-OK 'Saliendo. Hasta pronto!'; return }
            default { Write-Warn 'Opcion no valida.' }
        }
        if ($opcion -ne '0') { Pause-Menu }
    } while ($true)
}

# PUNTO DE ENTRADA
if ($Menu) {
    Invoke-Fase0
    Show-Menu
} else {
    Invoke-Fase0
    Invoke-Fase1
    Write-Host ''
    Write-Host "  Exitosos : $script:Exitosos" -ForegroundColor Green
    Write-Host "  Fallidos : $script:Fallidos" -ForegroundColor $(if ($script:Fallidos -eq 0) {'Green'} else {'Red'})
}
