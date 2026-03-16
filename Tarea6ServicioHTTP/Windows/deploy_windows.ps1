$ErrorActionPreference = 'SilentlyContinue'
$ProgressPreference    = 'SilentlyContinue'
$WarningPreference     = 'SilentlyContinue'
try { $Host.UI.RawUI.WindowTitle = "Despliegue HTTP - Windows Server 2022" } catch {}

$_esAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()
            ).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
if (-not $_esAdmin) {
    Write-Host "  Reiniciando como Administrador..." -ForegroundColor Yellow
    Start-Process powershell.exe -Verb RunAs `
        -ArgumentList "-NoProfile -ExecutionPolicy Bypass -File `"$PSCommandPath`""
    exit
}

Set-ExecutionPolicy Bypass -Scope Process      -Force -ErrorAction SilentlyContinue
Set-ExecutionPolicy Bypass -Scope LocalMachine -Force -ErrorAction SilentlyContinue

$_rutaFn = Join-Path $PSScriptRoot "http_functions.ps1"
if (-not (Test-Path $_rutaFn)) {
    Write-Host "  [XX] ERROR: http_functions.ps1 no encontrado" -ForegroundColor Red
    Write-Host "  Ambos archivos deben estar en la misma carpeta." -ForegroundColor Yellow
    Read-Host | Out-Null
    exit 1
}
. $_rutaFn

#  PANTALLA Y MENU
function Mostrar-Menu {
    Clear-Host
    Write-Host ""
    Write-Host "  ============================================================" -ForegroundColor Cyan
    Write-Host "     DESPLIEGUE HTTP AUTOMATIZADO - Windows Server 2022       " -ForegroundColor Cyan
    Write-Host "     IIS 10 / Apache HTTP Server / Nginx para Windows         " -ForegroundColor Cyan
    Write-Host "  ============================================================" -ForegroundColor Cyan
    Write-Host ""
    Write-Host "  Fecha    : $(Get-Date -Format 'dd/MM/yyyy HH:mm:ss')" -ForegroundColor DarkGray
    Write-Host "  Servidor : $env:COMPUTERNAME   Usuario: $env:USERNAME" -ForegroundColor DarkGray
    Write-Host ""
    Write-Host "  +-----------------------------------------------------+" -ForegroundColor White
    Write-Host "  |         MENU PRINCIPAL DE OPCIONES                  |" -ForegroundColor White
    Write-Host "  +-----------------------------------------------------+" -ForegroundColor White
    Write-Host "  |  INSTALACION DE SERVIDORES                          |" -ForegroundColor White
    Write-Host "  |  [1]  Instalar IIS                                  |" -ForegroundColor Cyan
    Write-Host "  |  [2]  Instalar Apache HTTP Server                   |" -ForegroundColor Cyan
    Write-Host "  |  [3]  Instalar Nginx                                |" -ForegroundColor Cyan
    Write-Host "  |                                                     |" -ForegroundColor White
    Write-Host "  |  GESTION DE VERSIONES                               |" -ForegroundColor White
    Write-Host "  |  [4]  Ver versiones IIS                             |" -ForegroundColor Yellow
    Write-Host "  |  [5]  Ver versiones Apache                          |" -ForegroundColor Yellow
    Write-Host "  |  [6]  Ver versiones Nginx                           |" -ForegroundColor Yellow
    Write-Host "  |                                                     |" -ForegroundColor White
    Write-Host "  |  SEGURIDAD                                          |" -ForegroundColor White
    Write-Host "  |  [7]  Seguridad en IIS                              |" -ForegroundColor Magenta
    Write-Host "  |  [8]  Seguridad en Apache                           |" -ForegroundColor Magenta
    Write-Host "  |  [9]  Seguridad en Nginx                            |" -ForegroundColor Magenta
    Write-Host "  |                                                     |" -ForegroundColor White
    Write-Host "  |  HERRAMIENTAS                                       |" -ForegroundColor White
    Write-Host "  |  [10] Gestionar Firewall                            |" -ForegroundColor Green
    Write-Host "  |  [11] Estado de servicios                           |" -ForegroundColor Green
    Write-Host "  |  [12] Crear pagina index                            |" -ForegroundColor Green
    Write-Host "  |  [13] Desinstalar servidor                          |" -ForegroundColor DarkYellow
    Write-Host "  |                                                     |" -ForegroundColor White
    Write-Host "  |  [0]  Salir                                         |" -ForegroundColor DarkGray
    Write-Host "  +-----------------------------------------------------+" -ForegroundColor White
    Write-Host ""
}

#  FLUJOS
function Flujo-Instalar {
    param([string]$Srv)
    Clear-Host
    $versiones = switch ($Srv) {
        "IIS"    { Obtener-VersionesIIS    }
        "Apache" { Obtener-VersionesApache }
        "Nginx"  { Obtener-VersionesNginx  }
    }
    $elegida = Mostrar-MenuVersiones -Versiones $versiones -Servicio $Srv
    $puerto  = Leer-Puerto -PuertoPredeterminado 8080
    Write-Host ""
    Escribir-Titulo "Confirmar Instalacion"
    Write-Host "  Servidor : $Srv"               -ForegroundColor White
    Write-Host "  Version  : $($elegida.Version)" -ForegroundColor White
    Write-Host "  Puerto   : $puerto"             -ForegroundColor White
    Write-Host ""
    $ok = Leer-Entrada "Confirmas la instalacion? (s/n)" "s" "^[sSnN]$"
    if ($ok -notmatch "^[sS]$") { Escribir-Aviso "Cancelado."; Pausar; return }
    switch ($Srv) {
        "IIS"    { Instalar-IIS    -VersionInfo $elegida -Puerto $puerto }
        "Apache" { Instalar-Apache -VersionInfo $elegida -Puerto $puerto }
        "Nginx"  { Instalar-Nginx  -VersionInfo $elegida -Puerto $puerto }
    }
    Configurar-Firewall -Puerto $puerto -Servicio $Srv
    Write-Host ""
    $seg = Leer-Entrada "Aplicar seguridad ahora? (s/n)" "s" "^[sSnN]$"
    if ($seg -match "^[sS]$") { Aplicar-TodasSeguridades -Servicio $Srv -Puerto $puerto }
    $ip = (Get-NetIPAddress -AddressFamily IPv4 -ErrorAction SilentlyContinue |
           Where-Object { $_.InterfaceAlias -notlike "*Loopback*" } |
           Select-Object -First 1).IPAddress
    Write-Host ""
    Escribir-Exito "====== INSTALACION COMPLETADA ======"
    Escribir-Info  "Acceso local  : http://localhost:$puerto"
    if ($ip) { Escribir-Info "Acceso en red : http://${ip}:$puerto" }
    Pausar
}

function Flujo-Versiones {
    param([string]$Srv)
    Clear-Host
    $v = switch ($Srv) {
        "IIS"    { Obtener-VersionesIIS    }
        "Apache" { Obtener-VersionesApache }
        "Nginx"  { Obtener-VersionesNginx  }
    }
    Write-Host ""
    Write-Host "  Versiones disponibles - $Srv" -ForegroundColor Cyan
    Write-Host ("-" * 60) -ForegroundColor DarkGray
    $v | ForEach-Object { Write-Host "  > $($_.Etiqueta)" -ForegroundColor White }
    Write-Host ""
    Pausar
}

function Flujo-Seguridad {
    param([string]$Srv)
    Clear-Host
    $puerto = Leer-Puerto -PuertoPredeterminado 8080
    Aplicar-TodasSeguridades -Servicio $Srv -Puerto $puerto
    Pausar
}

function Flujo-Firewall {
    Clear-Host
    Escribir-Titulo "Gestion de Firewall"
    Write-Host "  [1] Abrir puerto   [2] Bloquear puerto   [3] Ver reglas   [4] Volver" -ForegroundColor White
    Write-Host ""
    $op = Leer-Entrada "Opcion" "4" "^[1-4]$"
    switch ($op) {
        "1" { $p = Leer-Puerto; Configurar-Firewall -Puerto $p -Servicio "Manual" }
        "2" {
            $p = Leer-Puerto
            New-NetFirewallRule -DisplayName "HTTP-BLOQUEAR-$p" -Direction Inbound `
                -Protocol TCP -LocalPort $p -Action Block -Profile Any -Enabled True | Out-Null
            Escribir-Exito "Puerto $p bloqueado."
        }
        "3" {
            Get-NetFirewallRule -DisplayName "HTTP-*" -ErrorAction SilentlyContinue |
                Format-Table DisplayName, Enabled, Action -AutoSize
        }
    }
    Pausar
}

function Flujo-PaginaIndex {
    Clear-Host
    Escribir-Titulo "Crear Pagina Index"
    Write-Host "  [1] IIS  [2] Apache  [3] Nginx  [4] Ruta personalizada  [5] Volver" -ForegroundColor White
    Write-Host ""
    $op = Leer-Entrada "Opcion" "5" "^[1-5]$"
    if ($op -eq "5") { return }
    $p = Leer-Puerto
    switch ($op) {
        "1" { Crear-PaginaIndex "IIS"    "10.0"  $p "C:\inetpub\wwwroot" }
        "2" { Crear-PaginaIndex "Apache" "2.4.x" $p "C:\Apache24\htdocs" }
        "3" { Crear-PaginaIndex "Nginx"  "1.x"   $p "C:\nginx\html"      }
        "4" {
            $r = Leer-Entrada "Ruta web" "C:\inetpub\wwwroot"
            $s = Leer-Entrada "Servicio" "HTTP"
            $v = Leer-Entrada "Version"  "1.0"
            Crear-PaginaIndex $s $v $p $r
        }
    }
    Pausar
}

Write-Host "  [OK] Administrador verificado." -ForegroundColor Green
Write-Host "  [OK] Politica de ejecucion configurada." -ForegroundColor Green
Start-Sleep -Milliseconds 800

while ($true) {
    Mostrar-Menu

    $opcion = (Read-Host "  Selecciona una opcion [0-13]").Trim()
    if ($null -eq $opcion -or $opcion -eq "") { continue }
    $opcion = $opcion -replace '[^0-9]', ''
    if ($opcion -eq "") { continue }

    switch ($opcion) {
        "1"  { Flujo-Instalar  "IIS"    }
        "2"  { Flujo-Instalar  "Apache" }
        "3"  { Flujo-Instalar  "Nginx"  }
        "4"  { Flujo-Versiones "IIS"    }
        "5"  { Flujo-Versiones "Apache" }
        "6"  { Flujo-Versiones "Nginx"  }
        "7"  { Flujo-Seguridad "IIS"    }
        "8"  { Flujo-Seguridad "Apache" }
        "9"  { Flujo-Seguridad "Nginx"  }
        "10" { Flujo-Firewall           }
        "11" { Clear-Host; Ver-EstadoServicios; Pausar }
        "12" { Flujo-PaginaIndex        }
        "13" { Desinstalar-Servicio     }
        "0"  {
            Clear-Host
            Write-Host ""
            Write-Host "  Hasta pronto." -ForegroundColor Cyan
            Write-Host ""
            [System.Environment]::Exit(0)
        }
        default {
            Write-Host "  Opcion no valida. Elige entre 0 y 13." -ForegroundColor Yellow
            Start-Sleep -Seconds 1
        }
    }
}
