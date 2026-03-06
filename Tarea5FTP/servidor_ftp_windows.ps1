# ============================================================
#   AUTOMATIZACION SERVIDOR FTP - WINDOWS SERVER 2022 (IIS)
#   Version 1.0 | Requiere: Administrador
# ============================================================

#Requires -RunAsAdministrator
Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$FTP_RAIZ     = "C:\FTP"
$FTP_DATA     = "$FTP_RAIZ\Data"
$FTP_HOMES    = "$FTP_RAIZ\LocalUser"
$FTP_PUBLICA  = "$FTP_DATA\general"
$FTP_GRUPO1   = "$FTP_DATA\reprobados"
$FTP_GRUPO2   = "$FTP_DATA\recursadores"
$FTP_USUARIOS = "$FTP_DATA\Usuarios"
$NOMBRE_SITIO = "ServidorFTP"
$PUERTO_FTP   = 21
$LOG_FILE     = "C:\FTP\ftp_admin.log"
$GRUPO_1      = "reprobados"
$GRUPO_2      = "recursadores"
$GRUPO_FTP    = "ftplocales"

function Escribir-Ok    { param($m) Write-Host "  [OK]  $m" -ForegroundColor Green;  Registrar-Log "OK: $m" }
function Escribir-Error { param($m) Write-Host "  [X]   $m" -ForegroundColor Red;    Registrar-Log "ERROR: $m" }
function Escribir-Info  { param($m) Write-Host "  [i]   $m" -ForegroundColor Cyan }
function Escribir-Advert{ param($m) Write-Host "  [!]   $m" -ForegroundColor Yellow; Registrar-Log "AVISO: $m" }
function Separador      { Write-Host "  ------------------------------------------------------------" -ForegroundColor DarkBlue }

function Registrar-Log {
    param([string]$Mensaje)
    $ts = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    Add-Content -Path $LOG_FILE -Value "[$ts] $Mensaje" -ErrorAction SilentlyContinue
}

function Encabezado {
    Clear-Host
    Write-Host ""
    Write-Host "  +----------------------------------------------------------+" -ForegroundColor DarkBlue
    Write-Host "  |    SERVIDOR FTP - WINDOWS SERVER 2022 (IIS/FTP)         |" -ForegroundColor White
    Write-Host "  +----------------------------------------------------------+" -ForegroundColor DarkBlue
    Write-Host ""
}

function Pausar { Write-Host ""; Read-Host "  Presione [Enter] para continuar" }

function Obtener-EstadoIIS {
    try {
        $f = Get-WindowsFeature -Name Web-FTP-Server -ErrorAction SilentlyContinue
        return ($null -ne $f -and $f.InstallState -eq "Installed")
    } catch { return $false }
}

function Establecer-Permisos {
    param([string]$Ruta, [string]$Principal, [string]$Derechos,
          [string]$Heredar = "ContainerInherit,ObjectInherit", [string]$Tipo = "Allow")
    try {
        $acl  = Get-Acl -Path $Ruta
        $perm = New-Object System.Security.AccessControl.FileSystemAccessRule(
            $Principal,
            [System.Security.AccessControl.FileSystemRights]$Derechos,
            [System.Security.AccessControl.InheritanceFlags]$Heredar,
            [System.Security.AccessControl.PropagationFlags]"None",
            [System.Security.AccessControl.AccessControlType]$Tipo)
        $acl.AddAccessRule($perm)
        Set-Acl -Path $Ruta -AclObject $acl
    } catch { Escribir-Advert "Advertencia permisos '$Ruta': $_" }
}

function Quitar-Permiso {
    param([string]$Ruta, [string]$Principal)
    try {
        $acl   = Get-Acl -Path $Ruta
        $rules = $acl.Access | Where-Object { $_.IdentityReference -like "*$Principal*" }
        foreach ($r in $rules) { $acl.RemoveAccessRule($r) | Out-Null }
        Set-Acl -Path $Ruta -AclObject $acl
    } catch { }
}

function Configurar-Permisos-Base {
    Escribir-Info "Aplicando permisos NTFS base..."

    # general: IIS_IUSRS e IUSR con lectura (anonimo FTP usa IUSR)
    # Heredar ContainerInherit+ObjectInherit para que subcarpetas y archivos hereden
    Establecer-Permisos -Ruta $FTP_PUBLICA -Principal "IUSR"     -Derechos "ReadAndExecute" -Heredar "ContainerInherit,ObjectInherit" -Tipo Allow
    Establecer-Permisos -Ruta $FTP_PUBLICA -Principal "IIS_IUSRS"-Derechos "ReadAndExecute" -Heredar "ContainerInherit,ObjectInherit" -Tipo Allow
    Establecer-Permisos -Ruta $FTP_PUBLICA -Principal "Everyone" -Derechos "ReadAndExecute" -Heredar "ContainerInherit,ObjectInherit" -Tipo Allow
    Establecer-Permisos -Ruta $FTP_PUBLICA -Principal $GRUPO_FTP -Derechos "Modify"         -Heredar "ContainerInherit,ObjectInherit" -Tipo Allow

    # grupos: solo su grupo puede leer/escribir
    Establecer-Permisos -Ruta $FTP_GRUPO1 -Principal $GRUPO_1 -Derechos "Modify" -Heredar "ContainerInherit,ObjectInherit" -Tipo Allow
    Establecer-Permisos -Ruta $FTP_GRUPO2 -Principal $GRUPO_2 -Derechos "Modify" -Heredar "ContainerInherit,ObjectInherit" -Tipo Allow

    # data/Usuarios: cada usuario solo accede a su carpeta (se aplica al crear)
    Establecer-Permisos -Ruta $FTP_USUARIOS -Principal "CREATOR OWNER" -Derechos "FullControl" -Heredar "ContainerInherit,ObjectInherit" -Tipo Allow

    Escribir-Ok "Permisos NTFS base aplicados."
}

function Desactivar-Politica-Contrasenas {
    # Desactiva la politica de complejidad de contrasenas de Windows
    # para permitir contrasenas simples en entorno educativo
    try {
        $tmpInf = "$env:TEMP\secpol_ftp.inf"
        $tmpDb  = "$env:TEMP\secpol_ftp.sdb"

        $infContent = @"
[Unicode]
Unicode=yes
[System Access]
PasswordComplexity = 0
MinimumPasswordLength = 1
MaximumPasswordAge = -1
MinimumPasswordAge = 0
PasswordHistorySize = 0
[Version]
signature="`$CHICAGO`$"
Revision=1
"@
        $infContent | Out-File -FilePath $tmpInf -Encoding Unicode -Force
        secedit /configure /db $tmpDb /cfg $tmpInf /quiet 2>$null | Out-Null
        Remove-Item $tmpInf -ErrorAction SilentlyContinue
        Remove-Item $tmpDb  -ErrorAction SilentlyContinue
        Escribir-Ok "Politica de contrasenas simplificada (entorno educativo)."
    } catch {
        Escribir-Advert "No se pudo modificar la politica de contrasenas: $_"
    }
}

function Crear-Junctions-Usuario {
    param([string]$Usuario, [string]$Grupo)
    $homeDir = "$FTP_HOMES\$Usuario"
    if (-not (Test-Path $homeDir)) { New-Item -ItemType Directory -Path $homeDir -Force | Out-Null }

    # Junction general -> Data\general (contenido compartido publico)
    $jGeneral = "$homeDir\general"
    if (Test-Path $jGeneral) { [System.IO.Directory]::Delete($jGeneral, $false) 2>$null }
    New-Item -ItemType Junction -Path $jGeneral -Target $FTP_PUBLICA -Force | Out-Null

    # Junction grupo -> Data\reprobados o recursadores
    $grupoRuta = if ($Grupo -eq $GRUPO_1) { $FTP_GRUPO1 } else { $FTP_GRUPO2 }
    $jGrupo    = "$homeDir\$Grupo"
    if (Test-Path $jGrupo) { [System.IO.Directory]::Delete($jGrupo, $false) 2>$null }
    New-Item -ItemType Junction -Path $jGrupo -Target $grupoRuta -Force | Out-Null

    # Carpeta personal real + junction
    $dirPersonal = "$FTP_USUARIOS\$Usuario"
    if (-not (Test-Path $dirPersonal)) { New-Item -ItemType Directory -Path $dirPersonal -Force | Out-Null }
    $jPersonal = "$homeDir\$Usuario"
    if (Test-Path $jPersonal) { [System.IO.Directory]::Delete($jPersonal, $false) 2>$null }
    New-Item -ItemType Junction -Path $jPersonal -Target $dirPersonal -Force | Out-Null

    # Permisos NTFS en homeDir: usuario tiene acceso de lectura en raiz
    Establecer-Permisos -Ruta $homeDir     -Principal $Usuario -Derechos "ReadAndExecute" -Heredar "None" -Tipo Allow
    # Permisos en carpeta personal: control total
    Establecer-Permisos -Ruta $dirPersonal -Principal $Usuario -Derechos "FullControl" -Heredar "ContainerInherit,ObjectInherit" -Tipo Allow
    # Permisos en general: lectura y escritura (ya heredados del grupo ftplocales)
    Establecer-Permisos -Ruta $FTP_PUBLICA -Principal $Usuario -Derechos "Modify" -Heredar "ContainerInherit,ObjectInherit" -Tipo Allow
    # Permisos en carpeta de grupo
    Establecer-Permisos -Ruta $grupoRuta   -Principal $Usuario -Derechos "Modify" -Heredar "ContainerInherit,ObjectInherit" -Tipo Allow
}

function Eliminar-Junctions-Usuario {
    param([string]$Usuario)
    $homeDir = "$FTP_HOMES\$Usuario"
    if (Test-Path $homeDir) {
        Get-ChildItem $homeDir -Attributes ReparsePoint -ErrorAction SilentlyContinue |
            ForEach-Object { [System.IO.Directory]::Delete($_.FullName, $false) }
        Remove-Item $homeDir -Recurse -Force -ErrorAction SilentlyContinue
    }
}

function Crear-Usuario-Logica {
    param([string]$Usuario, [SecureString]$Password, [string]$Grupo)
    $params = @{
        Name = $Usuario; Password = $Password; FullName = "FTP Usuario $Usuario"
        Description = "Usuario FTP - Grupo $Grupo"; PasswordNeverExpires = $true
        UserMayNotChangePassword = $false; AccountNeverExpires = $true
    }
    New-LocalUser @params | Out-Null
    Add-LocalGroupMember -Group "${GRUPO_FTP}" -Member "${Usuario}"
    Add-LocalGroupMember -Group "${Grupo}" -Member "${Usuario}"
    Crear-Junctions-Usuario -Usuario $Usuario -Grupo $Grupo
    $dirPersonal = "$FTP_USUARIOS\$Usuario"
    Establecer-Permisos -Ruta $dirPersonal -Principal $Usuario -Derechos "FullControl" -Heredar "ContainerInherit,ObjectInherit" -Tipo Allow
    $homeDir = "$FTP_HOMES\$Usuario"
    Establecer-Permisos -Ruta $homeDir -Principal $Usuario -Derechos "ReadAndExecute" -Heredar "None" -Tipo Allow
    Registrar-Log "Usuario '$Usuario' creado en grupo '$Grupo'."
    return $true
}

function Instalar-FTP {
    Encabezado
    Write-Host "  [ INSTALACION E IDEMPOTENCIA DEL SERVIDOR FTP ]" -ForegroundColor White
    Separador

    if (Obtener-EstadoIIS) {
        Escribir-Advert "IIS FTP ya esta instalado. Verificando configuracion..."
    } else {
        Escribir-Info "Instalando roles Web-Server, Web-FTP-Server..."
        try {
            Install-WindowsFeature -Name Web-Server, Web-FTP-Server, Web-Scripting-Tools `
                                   -IncludeManagementTools -ErrorAction Stop | Out-Null
            Escribir-Ok "Roles IIS y FTP instalados."
        } catch {
            Escribir-Error "Error al instalar: $_"
            Pausar; return
        }
    }

    try {
        Import-Module WebAdministration -ErrorAction Stop
        Escribir-Ok "Modulo WebAdministration cargado."
    } catch {
        Escribir-Error "No se pudo cargar WebAdministration: $_"
        Pausar; return
    }

    Escribir-Info "Creando estructura de directorios..."
    $dirs = @($FTP_RAIZ, $FTP_DATA, $FTP_HOMES, $FTP_PUBLICA,
              $FTP_GRUPO1, $FTP_GRUPO2, $FTP_USUARIOS, "$FTP_HOMES\Public")
    foreach ($d in $dirs) {
        if (-not (Test-Path $d)) { New-Item -ItemType Directory -Path $d -Force | Out-Null }
    }
    Escribir-Ok "Estructura de directorios creada."

    foreach ($g in @($GRUPO_1, $GRUPO_2, $GRUPO_FTP)) {
        if (-not (Get-LocalGroup -Name $g -ErrorAction SilentlyContinue)) {
            New-LocalGroup -Name "${g}" -Description "Grupo FTP $g" | Out-Null
            Escribir-Ok "Grupo local '$g' creado."
        } else { Escribir-Advert "Grupo '$g' ya existe." }
    }

    # -- Detener servicios antes de modificar configuracion --
    # Desactivar politica de complejidad antes de crear usuarios
    Desactivar-Politica-Contrasenas

    Escribir-Info "Deteniendo servicios IIS/FTP para configurar..."
    Stop-Service FTPSVC -ErrorAction SilentlyContinue
    Stop-Service W3SVC  -ErrorAction SilentlyContinue
    Start-Sleep -Seconds 3

    # -- Eliminar sitio si existe y recrear --
    Escribir-Info "Configurando sitio FTP '$NOMBRE_SITIO'..."
    if (Get-WebSite -Name $NOMBRE_SITIO -ErrorAction SilentlyContinue) {
        Remove-WebSite -Name $NOMBRE_SITIO -ErrorAction SilentlyContinue
        Start-Sleep -Seconds 2
    }
    New-WebFtpSite -Name $NOMBRE_SITIO -Port $PUERTO_FTP -PhysicalPath $FTP_RAIZ -Force | Out-Null
    Start-Sleep -Seconds 2
    Escribir-Ok "Sitio FTP '$NOMBRE_SITIO' creado."

    # -- Configurar con appcmd (herramienta nativa IIS 10) --
    $appcmd = Join-Path $env:windir "system32\inetsrv\appcmd.exe"

    # Aislamiento: IsolateAllDirectories (nombre exacto del enum en IIS 10)
    & $appcmd set config `
        -section:system.applicationHost/sites `
        "/[name='$NOMBRE_SITIO'].ftpServer.userIsolation.mode:IsolateAllDirectories" `
        /commit:apphost | Out-Null

    # Autenticacion anonima ON
    & $appcmd set config `
        -section:system.applicationHost/sites `
        "/[name='$NOMBRE_SITIO'].ftpServer.security.authentication.anonymousAuthentication.enabled:true" `
        /commit:apphost | Out-Null

    # Autenticacion basica ON (usuarios locales del sistema)
    & $appcmd set config `
        -section:system.applicationHost/sites `
        "/[name='$NOMBRE_SITIO'].ftpServer.security.authentication.basicAuthentication.enabled:true" `
        /commit:apphost | Out-Null

    # SSL: SslAllow = no requerir SSL (enum exacto de IIS 10)
    & $appcmd set config `
        -section:system.applicationHost/sites `
        "/[name='$NOMBRE_SITIO'].ftpServer.security.ssl.controlChannelPolicy:SslAllow" `
        /commit:apphost | Out-Null

    & $appcmd set config `
        -section:system.applicationHost/sites `
        "/[name='$NOMBRE_SITIO'].ftpServer.security.ssl.dataChannelPolicy:SslAllow" `
        /commit:apphost | Out-Null

    # Puertos pasivos (propiedad global del servidor, no del sitio)
    & $appcmd set config `
        -section:system.ftpServer/firewallSupport `
        /lowDataChannelPort:49152 /highDataChannelPort:65535 `
        /commit:apphost | Out-Null

    Escribir-Ok "Configuracion FTP aplicada (aislamiento, auth, SSL, pasivo)."

    # -- Reglas de autorizacion FTP --
    # Limpiar reglas existentes del sitio
    & $appcmd set config "$NOMBRE_SITIO" `
        -section:system.ftpServer/security/authorization `
        /commit:apphost | Out-Null

    # Anonimo: solo lectura
    & $appcmd set config "$NOMBRE_SITIO" `
        -section:system.ftpServer/security/authorization `
        /+"[accessType='Allow',users='?',permissions='Read']" `
        /commit:apphost 2>$null | Out-Null

    # Usuarios autenticados: lectura y escritura
    & $appcmd set config "$NOMBRE_SITIO" `
        -section:system.ftpServer/security/authorization `
        /+"[accessType='Allow',users='*',permissions='Read,Write']" `
        /commit:apphost 2>$null | Out-Null

    Escribir-Ok "Reglas de autorizacion FTP configuradas."

    # -- Junction anonimo -> general --
    $anonGeneral = "$FTP_HOMES\Public\general"
    if (-not (Test-Path $anonGeneral)) {
        New-Item -ItemType Junction -Path $anonGeneral -Target $FTP_PUBLICA | Out-Null
        Escribir-Ok "Junction anonimo -> general creado."
    }

    # -- Permisos NTFS --
    Configurar-Permisos-Base

    # -- Reglas de Firewall --
    Escribir-Info "Configurando reglas de firewall..."
    $reglas = @(
        @{ Name = "FTP-Puerto-21"; Port = "21";          Desc = "FTP Puerto Control" },
        @{ Name = "FTP-Pasivo";    Port = "49152-65535"; Desc = "FTP Puertos Pasivos" }
    )
    foreach ($r in $reglas) {
        Remove-NetFirewallRule -Name $r.Name -ErrorAction SilentlyContinue
        New-NetFirewallRule -Name $r.Name -DisplayName $r.Desc `
            -Protocol TCP -LocalPort $r.Port -Action Allow `
            -Direction Inbound -ErrorAction SilentlyContinue | Out-Null
    }
    Escribir-Ok "Reglas de firewall configuradas."

    # -- Iniciar servicios --
    Escribir-Info "Iniciando servicios W3SVC y FTPSVC..."
    Start-Service W3SVC  -ErrorAction SilentlyContinue
    Start-Sleep -Seconds 2
    Start-Service FTPSVC -ErrorAction SilentlyContinue
    Start-Sleep -Seconds 2
    Set-Service FTPSVC -StartupType Automatic

    # Iniciar el sitio via appcmd (mas confiable que Start-WebSite)
    & $appcmd start site "$NOMBRE_SITIO" 2>$null | Out-Null

    $svc = Get-Service FTPSVC -ErrorAction SilentlyContinue
    if ($svc -and $svc.Status -eq "Running") {
        Escribir-Ok "Servicio FTPSVC en ejecucion."
    } else {
        Escribir-Advert "FTPSVC puede no estar activo. Intente reiniciar el servicio (Opcion 7)."
    }

    Separador
    Escribir-Ok "Instalacion y configuracion completadas."
    Pausar
}

function Verificar-Instalacion {
    Encabezado
    Write-Host "  [ VERIFICACION DE LA INSTALACION ]" -ForegroundColor White
    Separador
    if (Obtener-EstadoIIS) { Escribir-Ok "Caracteristica Web-FTP-Server: INSTALADA" } else { Escribir-Error "Caracteristica Web-FTP-Server: NO INSTALADA" }
    $svc = Get-Service FTPSVC -ErrorAction SilentlyContinue
    if ($svc) {
        if ($svc.Status -eq "Running") { Escribir-Ok "Servicio FTPSVC: EN EJECUCION" } else { Escribir-Error "Servicio FTPSVC: $($svc.Status)" }
    } else { Escribir-Error "Servicio FTPSVC: NO ENCONTRADO" }
    try {
        Import-Module WebAdministration -ErrorAction SilentlyContinue
        $sitio = Get-WebSite -Name $NOMBRE_SITIO -ErrorAction SilentlyContinue
        if ($sitio) { Escribir-Ok "Sitio FTP '$NOMBRE_SITIO': Estado = $($sitio.State)" } else { Escribir-Error "Sitio FTP '$NOMBRE_SITIO': NO ENCONTRADO" }
    } catch { }
    $escucha = netstat -an 2>$null | Select-String ":21 " | Where-Object { $_ -match "LISTEN" }
    if ($escucha) { Escribir-Ok "Puerto 21: ESCUCHANDO" } else { Escribir-Error "Puerto 21: NO escuchando" }
    foreach ($ruta in @($FTP_RAIZ, $FTP_DATA, $FTP_PUBLICA, $FTP_GRUPO1, $FTP_GRUPO2, $FTP_HOMES)) {
        if (Test-Path $ruta) { Escribir-Ok "Directorio existe: $ruta" } else { Escribir-Error "Directorio FALTANTE: $ruta" }
    }
    foreach ($g in @($GRUPO_1, $GRUPO_2, $GRUPO_FTP)) {
        if (Get-LocalGroup -Name $g -ErrorAction SilentlyContinue) { Escribir-Ok "Grupo local '$g': existe" } else { Escribir-Error "Grupo local '$g': NO existe" }
    }
    Separador; Write-Host "  Reglas de firewall FTP:" -ForegroundColor Cyan
    foreach ($nombre in @("FTP-Puerto-21", "FTP-Pasivo")) {
        $r = Get-NetFirewallRule -Name $nombre -ErrorAction SilentlyContinue
        if ($r) { Escribir-Ok "Regla '$nombre': $($r.Enabled)" } else { Escribir-Error "Regla '$nombre': NO existe" }
    }
    Separador; Write-Host "  Usuarios FTP registrados:" -ForegroundColor Cyan
    $miembros = Get-LocalGroupMember -Group "${GRUPO_FTP}" -ErrorAction SilentlyContinue
    if ($miembros) {
        foreach ($m in $miembros) {
            $n = $m.Name.Split("\")[-1]; $gv = ""
            $en1 = Get-LocalGroupMember -Group "${GRUPO_1}" -ErrorAction SilentlyContinue | Where-Object { $_.Name -like "*$n*" }
            $en2 = Get-LocalGroupMember -Group "${GRUPO_2}" -ErrorAction SilentlyContinue | Where-Object { $_.Name -like "*$n*" }
            if ($en1) { $gv = $GRUPO_1 } elseif ($en2) { $gv = $GRUPO_2 }
            Write-Host "    -> $n  [$gv]" -ForegroundColor Green
        }
    } else { Escribir-Info "No hay usuarios FTP creados aun." }
    Pausar
}

function Crear-Usuarios-Masivo {
    Encabezado
    Write-Host "  [ CREACION MASIVA DE USUARIOS FTP ]" -ForegroundColor White; Separador
    # Asegurar que la politica de contrasenas no bloquee la creacion
    Desactivar-Politica-Contrasenas

    $num = Read-Host "  Cuantos usuarios desea crear?"
    if (-not ($num -match '^\d+$') -or [int]$num -lt 1) { Escribir-Error "Numero invalido."; Pausar; return }

    for ($i = 1; $i -le [int]$num; $i++) {
        Write-Host ""; Write-Host "  --- Usuario $i de $num ---" -ForegroundColor Yellow
        $usr = $null
        do {
            $usr = (Read-Host "    Nombre de usuario").Trim().ToLower()
            if ([string]::IsNullOrEmpty($usr)) { Escribir-Error "Nombre vacio."; $usr = $null; continue }
            if (Get-LocalUser -Name $usr -ErrorAction SilentlyContinue) { Escribir-Advert "El usuario '$usr' ya existe."; $usr = $null; continue }
        } while ($null -eq $usr)

        $p1 = $null; $p1t = ""
        do {
            $p1  = Read-Host "    Contrasena" -AsSecureString
            $p2  = Read-Host "    Confirmar contrasena" -AsSecureString
            $p1t = [Runtime.InteropServices.Marshal]::PtrToStringAuto([Runtime.InteropServices.Marshal]::SecureStringToBSTR($p1))
            $p2t = [Runtime.InteropServices.Marshal]::PtrToStringAuto([Runtime.InteropServices.Marshal]::SecureStringToBSTR($p2))
            if ($p1t -ne $p2t) { Escribir-Error "Las contrasenas no coinciden."; $p1 = $null }
        } while ($null -eq $p1 -or $p1t -ne $p2t)

        $grp = $null
        do {
            Write-Host "    Grupos disponibles:"; Write-Host "      1) $GRUPO_1"; Write-Host "      2) $GRUPO_2"
            $gs = Read-Host "    Seleccione grupo (1 o 2)"
            if ($gs -eq "1") { $grp = $GRUPO_1 } elseif ($gs -eq "2") { $grp = $GRUPO_2 } else { Escribir-Error "Opcion invalida."; $grp = $null }
        } while ($null -eq $grp)

        try { Crear-Usuario-Logica -Usuario $usr -Password $p1 -Grupo $grp; Escribir-Ok "Usuario '$usr' creado en grupo '$grp'." }
        catch { Escribir-Error "Error al crear '$usr': $_" }
    }
    Restart-Service FTPSVC -ErrorAction SilentlyContinue
    Escribir-Ok "Servicio FTP reiniciado. Usuarios listos."; Pausar
}

function Anadir-Usuario-Individual {
    Encabezado
    Write-Host "  [ ANADIR USUARIO INDIVIDUAL ]" -ForegroundColor White; Separador
    Desactivar-Politica-Contrasenas
    $usr = $null
    do {
        $usr = (Read-Host "  Nombre de usuario").Trim().ToLower()
        if ([string]::IsNullOrEmpty($usr)) { Escribir-Error "Nombre vacio."; $usr = $null; continue }
        if (Get-LocalUser -Name $usr -ErrorAction SilentlyContinue) { Escribir-Advert "El usuario ya existe."; $usr = $null; continue }
    } while ($null -eq $usr)

    $p1 = $null; $p1t = ""
    do {
        $p1  = Read-Host "  Contrasena" -AsSecureString
        $p2  = Read-Host "  Confirmar"  -AsSecureString
        $p1t = [Runtime.InteropServices.Marshal]::PtrToStringAuto([Runtime.InteropServices.Marshal]::SecureStringToBSTR($p1))
        $p2t = [Runtime.InteropServices.Marshal]::PtrToStringAuto([Runtime.InteropServices.Marshal]::SecureStringToBSTR($p2))
        if ($p1t -ne $p2t) { Escribir-Error "Contrasenas distintas."; $p1 = $null }
    } while ($null -eq $p1 -or $p1t -ne $p2t)

    $grp = $null
    do {
        Write-Host "  Grupos disponibles:"; Write-Host "    1) $GRUPO_1"; Write-Host "    2) $GRUPO_2"
        $gs = Read-Host "  Seleccione (1 o 2)"
        if ($gs -eq "1") { $grp = $GRUPO_1 } elseif ($gs -eq "2") { $grp = $GRUPO_2 } else { Escribir-Error "Invalido."; $grp = $null }
    } while ($null -eq $grp)

    try { Crear-Usuario-Logica -Usuario $usr -Password $p1 -Grupo $grp; Restart-Service FTPSVC -ErrorAction SilentlyContinue; Escribir-Ok "Usuario '$usr' anadido en grupo '$grp'." }
    catch { Escribir-Error "Error: $_" }
    Pausar
}

function Cambiar-Grupo-Usuario {
    Encabezado
    Write-Host "  [ CAMBIAR GRUPO DE USUARIO ]" -ForegroundColor White; Separador
    $miembros = Get-LocalGroupMember -Group "${GRUPO_FTP}" -ErrorAction SilentlyContinue
    if (-not $miembros) { Escribir-Info "No hay usuarios FTP registrados."; Pausar; return }
    Write-Host "  Usuarios FTP:"
    foreach ($m in $miembros) {
        $n = $m.Name.Split("\")[-1]; $gv = ""
        $e1 = Get-LocalGroupMember -Group "${GRUPO_1}" -ErrorAction SilentlyContinue | Where-Object { $_.Name -like "*$n*" }
        $e2 = Get-LocalGroupMember -Group "${GRUPO_2}" -ErrorAction SilentlyContinue | Where-Object { $_.Name -like "*$n*" }
        if ($e1) { $gv = $GRUPO_1 } elseif ($e2) { $gv = $GRUPO_2 }
        Write-Host "    -> $n  [$gv]" -ForegroundColor Green
    }
    Write-Host ""
    $usr = (Read-Host "  Nombre del usuario a cambiar").Trim()
    if (-not (Get-LocalUser -Name $usr -ErrorAction SilentlyContinue)) { Escribir-Error "Usuario '$usr' no existe."; Pausar; return }
    $grpActual = ""; 
    $e1 = Get-LocalGroupMember -Group "${GRUPO_1}" -ErrorAction SilentlyContinue | Where-Object { $_.Name -like "*$usr*" }
    $e2 = Get-LocalGroupMember -Group "${GRUPO_2}" -ErrorAction SilentlyContinue | Where-Object { $_.Name -like "*$usr*" }
    if ($e1) { $grpActual = $GRUPO_1 } elseif ($e2) { $grpActual = $GRUPO_2 }
    if (-not $grpActual) { Escribir-Error "El usuario no tiene grupo FTP asignado."; Pausar; return }
    $grpNuevo = if ($grpActual -eq $GRUPO_1) { $GRUPO_2 } else { $GRUPO_1 }
    Write-Host "  Grupo actual: $grpActual  ->  Nuevo grupo: $grpNuevo" -ForegroundColor Yellow
    $conf = Read-Host "  Confirmar? (s/N)"
    if ($conf.ToLower() -ne "s") { Escribir-Info "Cancelado."; Pausar; return }
    Eliminar-Junctions-Usuario -Usuario $usr
    Remove-LocalGroupMember -Group "${grpActual}" -Member "${usr}" -ErrorAction SilentlyContinue
    Add-LocalGroupMember -Group "${grpNuevo}" -Member "${usr}"
    $rutaAnterior = if ($grpActual -eq $GRUPO_1) { $FTP_GRUPO1 } else { $FTP_GRUPO2 }
    $rutaNueva    = if ($grpNuevo  -eq $GRUPO_1) { $FTP_GRUPO1 } else { $FTP_GRUPO2 }
    Quitar-Permiso -Ruta $rutaAnterior -Principal $usr
    Establecer-Permisos -Ruta $rutaNueva -Principal $usr -Derechos "Modify" -Heredar "ContainerInherit,ObjectInherit" -Tipo Allow
    Crear-Junctions-Usuario -Usuario $usr -Grupo $grpNuevo
    Restart-Service FTPSVC -ErrorAction SilentlyContinue
    Escribir-Ok "Usuario '$usr' movido de '$grpActual' a '$grpNuevo'."; Pausar
}

function Listar-Usuarios {
    Encabezado
    Write-Host "  [ USUARIOS FTP REGISTRADOS ]" -ForegroundColor White; Separador
    Write-Host ("  {0,-20} {1,-15} {2}" -f "USUARIO", "GRUPO", "ESTADO"); Separador
    $miembros = Get-LocalGroupMember -Group "${GRUPO_FTP}" -ErrorAction SilentlyContinue
    if (-not $miembros) { Escribir-Info "No hay usuarios FTP."; Pausar; return }
    foreach ($m in $miembros) {
        $n = $m.Name.Split("\")[-1]; $gv = ""
        $e1 = Get-LocalGroupMember -Group "${GRUPO_1}" -ErrorAction SilentlyContinue | Where-Object { $_.Name -like "*$n*" }
        $e2 = Get-LocalGroupMember -Group "${GRUPO_2}" -ErrorAction SilentlyContinue | Where-Object { $_.Name -like "*$n*" }
        if ($e1) { $gv = $GRUPO_1 } elseif ($e2) { $gv = $GRUPO_2 }
        $est = if (Get-LocalUser -Name $n -ErrorAction SilentlyContinue) { "activo" } else { "error" }
        Write-Host ("  {0,-20} {1,-15} {2}" -f $n, $gv, $est) -ForegroundColor Green
    }
    Pausar
}

function Configurar-Permisos {
    Encabezado
    Write-Host "  [ CONFIGURACION DE PERMISOS NTFS ]" -ForegroundColor White; Separador
    Configurar-Permisos-Base
    $miembros = Get-LocalGroupMember -Group "${GRUPO_FTP}" -ErrorAction SilentlyContinue
    if ($miembros) {
        foreach ($m in $miembros) {
            $n = $m.Name.Split("\")[-1]; $dirP = "$FTP_USUARIOS\$n"
            if (Test-Path $dirP) {
                Establecer-Permisos -Ruta $dirP -Principal $n -Derechos "FullControl" -Heredar "ContainerInherit,ObjectInherit" -Tipo Allow
                Escribir-Ok "Permisos de '$n' actualizados."
            }
        }
    }
    Restart-Service FTPSVC -ErrorAction SilentlyContinue
    Escribir-Ok "Permisos aplicados y FTP reiniciado."; Pausar
}

function Validar-Estado {
    Encabezado
    Write-Host "  [ VALIDACION DEL ESTADO DEL SERVIDOR ]" -ForegroundColor White; Separador
    $svc = Get-Service FTPSVC -ErrorAction SilentlyContinue
    Write-Host "  Servicio FTPSVC:" -ForegroundColor Cyan
    if ($svc) { Write-Host "    Estado: $($svc.Status)  |  Inicio: $($svc.StartType)" } else { Escribir-Error "Servicio no encontrado." }
    Write-Host ""
    try {
        Import-Module WebAdministration -ErrorAction SilentlyContinue
        $s = Get-WebSite -Name $NOMBRE_SITIO -ErrorAction SilentlyContinue
        Write-Host "  Sitio IIS FTP:" -ForegroundColor Cyan
        if ($s) { Write-Host "    Nombre: $($s.Name)  |  Estado: $($s.State)  |  Puerto: $PUERTO_FTP" } else { Escribir-Error "Sitio no encontrado." }
    } catch { }
    Write-Host ""
    Write-Host "  Conexiones activas en puerto 21:" -ForegroundColor Cyan
    $conex = netstat -an 2>$null | Select-String ":21 "
    if ($conex) { $conex | ForEach-Object { Write-Host "    $_" } } else { Write-Host "    Ninguna conexion activa." }
    Write-Host ""
    Write-Host "  Uso de disco en $FTP_RAIZ :" -ForegroundColor Cyan
    Get-ChildItem $FTP_RAIZ -ErrorAction SilentlyContinue | ForEach-Object {
        $sz = (Get-ChildItem $_.FullName -Recurse -ErrorAction SilentlyContinue | Measure-Object Length -Sum).Sum
        $mb = [math]::Round($sz / 1MB, 2)
        Write-Host "    $($_.Name): $mb MB"
    }
    Pausar
}

function Eliminar-Usuario {
    Encabezado
    Write-Host "  [ ELIMINAR USUARIO FTP ]" -ForegroundColor White; Separador
    $miembros = Get-LocalGroupMember -Group "${GRUPO_FTP}" -ErrorAction SilentlyContinue
    if (-not $miembros) { Escribir-Info "No hay usuarios FTP para eliminar."; Pausar; return }
    foreach ($m in $miembros) {
        $n = $m.Name.Split("\")[-1]; $gv = ""
        $e1 = Get-LocalGroupMember -Group "${GRUPO_1}" -ErrorAction SilentlyContinue | Where-Object { $_.Name -like "*$n*" }
        $e2 = Get-LocalGroupMember -Group "${GRUPO_2}" -ErrorAction SilentlyContinue | Where-Object { $_.Name -like "*$n*" }
        if ($e1) { $gv = $GRUPO_1 } elseif ($e2) { $gv = $GRUPO_2 }
        Write-Host "    -> $n  [$gv]" -ForegroundColor Green
    }
    Write-Host ""
    $usr = (Read-Host "  Nombre del usuario a eliminar").Trim()
    if (-not (Get-LocalUser -Name $usr -ErrorAction SilentlyContinue)) { Escribir-Error "Usuario '$usr' no existe."; Pausar; return }
    $datos = Read-Host "  Eliminar tambien sus datos personales? (s/N)"
    $conf  = Read-Host "  Confirmar eliminacion de '$usr'? (s/N)"
    if ($conf.ToLower() -ne "s") { Escribir-Info "Cancelado."; Pausar; return }
    Eliminar-Junctions-Usuario -Usuario $usr
    if ($datos.ToLower() -eq "s") { Remove-Item "$FTP_USUARIOS\$usr" -Recurse -Force -ErrorAction SilentlyContinue }
    Remove-LocalUser -Name $usr -ErrorAction SilentlyContinue
    Restart-Service FTPSVC -ErrorAction SilentlyContinue
    Escribir-Ok "Usuario '$usr' eliminado."; Pausar
}

function Ver-Logs {
    Encabezado
    Write-Host "  [ REGISTROS DEL SERVIDOR FTP ]" -ForegroundColor White; Separador
    Write-Host "    1) Log IIS FTP  (C:\Windows\System32\LogFiles\MSFTPSVC1)"
    Write-Host "    2) Log de administracion ($LOG_FILE)"
    Write-Host "    3) Eventos del visor (FTP)"
    Write-Host "    0) Volver"; Write-Host ""
    $opt = Read-Host "  Seleccione"
    if ($opt -eq "1") {
        $logDir = "C:\Windows\System32\LogFiles\MSFTPSVC1"
        if (Test-Path $logDir) {
            $ultimo = Get-ChildItem $logDir -Filter "*.log" | Sort-Object LastWriteTime | Select-Object -Last 1
            if ($ultimo) { Get-Content $ultimo.FullName | Select-Object -Last 50 | More } else { Escribir-Info "No hay logs aun." }
        } else { Escribir-Info "Directorio de logs no encontrado." }
    } elseif ($opt -eq "2") {
        if (Test-Path $LOG_FILE) { Get-Content $LOG_FILE | More } else { Escribir-Info "Log vacio." }
    } elseif ($opt -eq "3") {
        Get-EventLog -LogName Application -Source "Microsoft-Windows-FTPSVC*" -Newest 20 -ErrorAction SilentlyContinue | Format-List
    }
    Pausar
}

function Menu-Usuarios {
    while ($true) {
        Encabezado
        Write-Host "  [ GESTION DE USUARIOS ]" -ForegroundColor White; Separador
        Write-Host "    1) Creacion masiva de usuarios"
        Write-Host "    2) Anadir usuario individual"
        Write-Host "    3) Cambiar grupo de usuario"
        Write-Host "    4) Listar usuarios"
        Write-Host "    5) Eliminar usuario"
        Write-Host "    0) Volver al menu principal"; Separador
        $opt = Read-Host "  Seleccione"
        if      ($opt -eq "1") { Crear-Usuarios-Masivo }
        elseif  ($opt -eq "2") { Anadir-Usuario-Individual }
        elseif  ($opt -eq "3") { Cambiar-Grupo-Usuario }
        elseif  ($opt -eq "4") { Listar-Usuarios }
        elseif  ($opt -eq "5") { Eliminar-Usuario }
        elseif  ($opt -eq "0") { return }
        else { Escribir-Error "Opcion invalida."; Start-Sleep 1 }
    }
}

function Menu-Principal {
    if (-not (Test-Path (Split-Path $LOG_FILE))) { New-Item -ItemType Directory -Path (Split-Path $LOG_FILE) -Force | Out-Null }
    while ($true) {
        Encabezado
        Write-Host "  Sistema Operativo: Windows Server 2022" -ForegroundColor Cyan
        Write-Host "  Servidor FTP:      IIS (FTPSVC)"        -ForegroundColor Cyan
        Write-Host "  Grupos FTP:        $GRUPO_1  |  $GRUPO_2" -ForegroundColor Cyan
        Separador
        Write-Host ""
        Write-Host "  OPCIONES DISPONIBLES:" -ForegroundColor White
        Write-Host ""
        Write-Host "    1) Instalar y configurar IIS FTP"
        Write-Host "    2) Verificar instalacion"
        Write-Host "    3) Gestion de usuarios y grupos"
        Write-Host "    4) Configurar / reestablecer permisos NTFS"
        Write-Host "    5) Validar estado del servidor"
        Write-Host "    6) Ver logs"
        Write-Host "    7) Reiniciar servicio FTP"
        Write-Host "    0) Salir"
        Write-Host ""; Separador
        $opt = Read-Host "  Seleccione una opcion"
        if      ($opt -eq "1") { Instalar-FTP }
        elseif  ($opt -eq "2") { Verificar-Instalacion }
        elseif  ($opt -eq "3") { Menu-Usuarios }
        elseif  ($opt -eq "4") { Configurar-Permisos }
        elseif  ($opt -eq "5") { Validar-Estado }
        elseif  ($opt -eq "6") { Ver-Logs }
        elseif  ($opt -eq "7") {
            Restart-Service FTPSVC -ErrorAction SilentlyContinue
            $s = Get-Service FTPSVC -ErrorAction SilentlyContinue
            if ($s -and $s.Status -eq "Running") { Escribir-Ok "FTP reiniciado." } else { Escribir-Error "Error al reiniciar." }
            Pausar
        } elseif ($opt -eq "0") {
            Write-Host ""; Escribir-Info "Saliendo del administrador FTP. Hasta luego!"; Write-Host ""; exit 0
        } else { Escribir-Error "Opcion invalida."; Start-Sleep 1 }
    }
}

Menu-Principal
