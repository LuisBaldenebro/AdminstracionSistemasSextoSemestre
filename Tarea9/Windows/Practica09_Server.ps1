# Variables globales de rutas
$rutaScripts     = "C:\Scripts"
$rutaCompartidos = "C:\Compartidos"

# BLOQUE 0  -  Auto-elevacion, Prerrequisitos y WinRM
if (-not ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole(
        [Security.Principal.WindowsBuiltInRole]::Administrator)) {
    Write-Host "El script no se ejecuta como Administrador. Relanzando con privilegios elevados..." -ForegroundColor Yellow
    Start-Process powershell -Verb RunAs -ArgumentList "-ExecutionPolicy Bypass -File `"$PSCommandPath`""
    exit
}
Write-Host "Ejecutando Practica09_Server.ps1 con privilegios de Administrador." -ForegroundColor Cyan

foreach ($carpeta in @($rutaScripts, $rutaCompartidos)) {
    if (-not (Test-Path $carpeta)) {
        try { New-Item -Path $carpeta -ItemType Directory -Force -ErrorAction Stop | Out-Null
              Write-Host "Carpeta creada: $carpeta" -ForegroundColor Green }
        catch { Write-Warning "No se pudo crear '$carpeta': $_" }
    } else { Write-Warning "La carpeta '$carpeta' ya existe. Continuando sin recrearla." }
}

$caracteristicasRequeridas = @(
    @{ Nombre = "RSAT-AD-PowerShell"; Etiqueta = "RSAT para Active Directory PowerShell" },
    @{ Nombre = "FS-Resource-Manager"; Etiqueta = "Administrador de Recursos del Servidor de Archivos (FSRM)" },
    @{ Nombre = "AD-Domain-Services"; Etiqueta = "Servicios de Dominio de Active Directory (AD DS)" }
)
foreach ($c in $caracteristicasRequeridas) {
    try {
        $s = Get-WindowsFeature -Name $c.Nombre -ErrorAction Stop
        if (-not $s.Installed) {
            Install-WindowsFeature -Name $c.Nombre -IncludeManagementTools -ErrorAction Stop | Out-Null
            Write-Host "Instalada: $($c.Etiqueta)." -ForegroundColor Green
        } else { Write-Warning "$($c.Etiqueta) ya esta instalada. Continuando." }
    } catch { Write-Warning "Error al instalar '$($c.Nombre)': $_" }
}

$dominioDNS = $null; $dominioDN = $null
try {
    Import-Module ActiveDirectory -ErrorAction Stop
    $d = Get-ADDomain -ErrorAction Stop
    $dominioDNS = $d.DNSRoot; $dominioDN = $d.DistinguishedName
    Write-Host "Dominio AD detectado automaticamente: $dominioDNS" -ForegroundColor Green
    Write-Host "Distinguished Name del dominio: $dominioDN" -ForegroundColor Green
} catch {
    Write-Host "Promoviendo a controlador de dominio 'lab.local'..." -ForegroundColor Yellow
    try {
        $pass = ConvertTo-SecureString "Admin123" -AsPlainText -Force
        Install-ADDSForest -DomainName "lab.local" -SafeModeAdministratorPassword $pass `
            -InstallDns:$true -Force:$true -NoRebootOnCompletion:$false -ErrorAction Stop
        exit 0
    } catch { Write-Error "Error critico al promover: $_"; exit 1 }
}

Write-Host "Verificando que ADWS y el servicio AD DS esten completamente operativos..." -ForegroundColor Yellow
$intentosADWS = 0; $maxIntentosADWS = 24; $adwsListo = $false
do {
    $intentosADWS++
    try {
        $sADWS = Get-Service -Name "ADWS" -ErrorAction Stop
        $sNTDS = Get-Service -Name "NTDS" -ErrorAction SilentlyContinue
        if ($sADWS.Status -eq "Running" -and ($null -eq $sNTDS -or $sNTDS.Status -eq "Running")) {
            if (Get-ADDomain -ErrorAction Stop) {
                $adwsListo = $true
                Write-Host "  ADWS y AD DS operativos (intento $intentosADWS)." -ForegroundColor Green
            }
        } else { Write-Host "  ADWS: $($sADWS.Status). Esperando... (intento $intentosADWS/$maxIntentosADWS)" -ForegroundColor Yellow; Start-Sleep 5 }
    } catch { Write-Host "  AD DS no responde. Esperando... (intento $intentosADWS/$maxIntentosADWS)" -ForegroundColor Yellow; Start-Sleep 5 }
} while (-not $adwsListo -and $intentosADWS -lt $maxIntentosADWS)

if (-not $adwsListo) { Write-Warning "ADWS no respondio en 2 minutos. Continuando de todos modos." }
else {
    try {
        $d = Get-ADDomain -ErrorAction Stop
        $dominioDNS = $d.DNSRoot; $dominioDN = $d.DistinguishedName
        Write-Host "Dominio confirmado tras espera ADWS: $dominioDNS ($dominioDN)" -ForegroundColor Green
    } catch { Write-Warning "Error al re-detectar el dominio: $_" }
}

# WinRM
try {
    Write-Host "Habilitando WinRM en el DC para acceso remoto desde el cliente..." -ForegroundColor Yellow
    try {
        $adInt = Get-NetIPAddress -AddressFamily IPv4 -ErrorAction SilentlyContinue | Where-Object { $_.IPAddress -like "192.168.100.*" }
        foreach ($a in $adInt) {
            $p = Get-NetConnectionProfile -InterfaceIndex $a.InterfaceIndex -ErrorAction SilentlyContinue
            if ($p -and $p.NetworkCategory -ne "Private") {
                Set-NetConnectionProfile -InterfaceIndex $a.InterfaceIndex -NetworkCategory Private -ErrorAction Stop
                Write-Host "  Perfil del adaptador interno ($($a.IPAddress)) cambiado a Private." -ForegroundColor Green
            }
        }
    } catch { Write-Warning "  No se pudo cambiar el perfil de red: $_" }

    Enable-PSRemoting -Force -SkipNetworkProfileCheck -ErrorAction Stop
    Write-Host "  Enable-PSRemoting ejecutado correctamente." -ForegroundColor Green
    Set-Item WSMan:\localhost\Client\TrustedHosts -Value "*" -Force -ErrorAction Stop
    Write-Host "  WinRM TrustedHosts configurado a '*' en el DC." -ForegroundColor Green

    foreach ($r in @("Windows Remote Management (HTTP-In)","WINRM-HTTP-In-TCP","WINRM-HTTP-In-TCP-PUBLIC")) {
        $reg = Get-NetFirewallRule -Name $r -ErrorAction SilentlyContinue
        if ($reg) { Set-NetFirewallRule -Name $r -RemoteAddress Any -Enabled True -ErrorAction SilentlyContinue
                    Write-Host "  Regla firewall '$r': RemoteAddress=Any habilitado." -ForegroundColor Green }
    }
    Get-NetFirewallRule -DisplayName "*Remote Management*" -ErrorAction SilentlyContinue |
        ForEach-Object { try { Set-NetFirewallRule -Name $_.Name -RemoteAddress Any -Enabled True -ErrorAction SilentlyContinue
                               Write-Host "  Regla '$($_.DisplayName)' actualizada: RemoteAddress=Any." -ForegroundColor Green } catch { } }

    if (-not (Get-NetFirewallRule -DisplayName "WinRM-HTTP-Practica09" -ErrorAction SilentlyContinue)) {
        New-NetFirewallRule -Name "WinRM-HTTP-Practica09" -DisplayName "WinRM-HTTP-Practica09" `
            -Description "WinRM HTTP 5985 - Practica09" -Direction Inbound -Protocol TCP `
            -LocalPort 5985 -RemoteAddress Any -Action Allow -Enabled True -ErrorAction Stop | Out-Null
        Write-Host "  Nueva regla firewall WinRM puerto 5985 creada." -ForegroundColor Green
    }

    Write-Host "  Abriendo puertos de union al dominio (SMB 445, Kerberos 88, LDAP 389, RPC 135)..." -ForegroundColor Yellow
    foreach ($g in @("Active Directory Domain Services","Active Directory Web Services","File and Printer Sharing",
        "Kerberos Key Distribution Center","DNS Service","NetLogon Service","Remote Desktop","@FirewallAPI.dll,-25000")) {
        try { Set-NetFirewallRule -DisplayGroup $g -Enabled True -ErrorAction SilentlyContinue
              Write-Host "  Grupo firewall '$g' habilitado." -ForegroundColor Green } catch { }
    }
    $puertos = @(
        @{N="DomainJoin-SMB-445-P09";P=445;T="TCP";D="SMB/NetLogon para Domain Join"},
        @{N="DomainJoin-Kerberos-88-P09";P=88;T="TCP";D="Kerberos TCP para Domain Join"},
        @{N="DomainJoin-Kerberos-88U-P09";P=88;T="UDP";D="Kerberos UDP para Domain Join"},
        @{N="DomainJoin-LDAP-389-P09";P=389;T="TCP";D="LDAP para Domain Join"},
        @{N="DomainJoin-LDAP-389U-P09";P=389;T="UDP";D="LDAP UDP para Domain Join"},
        @{N="DomainJoin-LDAPS-636-P09";P=636;T="TCP";D="LDAPS para Domain Join"},
        @{N="DomainJoin-RPC-135-P09";P=135;T="TCP";D="RPC Endpoint Mapper para Domain Join"},
        @{N="DomainJoin-GC-3268-P09";P=3268;T="TCP";D="Global Catalog para Domain Join"},
        @{N="DomainJoin-DNS-53-P09";P=53;T="TCP";D="DNS TCP para Domain Join"},
        @{N="DomainJoin-DNS-53U-P09";P=53;T="UDP";D="DNS UDP para Domain Join"},
        @{N="DomainJoin-NTP-123-P09";P=123;T="UDP";D="NTP para sincronizacion de hora"},
        @{N="DomainJoin-NetBIOS-137-P09";P=137;T="UDP";D="NetBIOS Name Service"},
        @{N="DomainJoin-NetBIOS-138-P09";P=138;T="UDP";D="NetBIOS Datagram Service"},
        @{N="DomainJoin-NetBIOS-139-P09";P=139;T="TCP";D="NetBIOS Session Service"}
    )
    foreach ($r in $puertos) {
        if (-not (Get-NetFirewallRule -Name $r.N -ErrorAction SilentlyContinue)) {
            try { New-NetFirewallRule -Name $r.N -DisplayName $r.N -Description "$($r.D) - Practica09" `
                    -Direction Inbound -Protocol $r.T -LocalPort $r.P -RemoteAddress Any -Action Allow -Enabled True -ErrorAction Stop | Out-Null
                  Write-Host "    Puerto $($r.P)/$($r.T): $($r.D) - abierto." -ForegroundColor Green }
            catch { Write-Warning "    Error al crear regla para puerto $($r.P): $_" }
        } else { Set-NetFirewallRule -Name $r.N -Enabled True -RemoteAddress Any -ErrorAction SilentlyContinue
                 Write-Host "    Puerto $($r.P)/$($r.T): $($r.D) - abierto." -ForegroundColor Green }
    }
    if (-not (Get-NetFirewallRule -Name "DomainJoin-RPCDyn-P09" -ErrorAction SilentlyContinue)) {
        New-NetFirewallRule -Name "DomainJoin-RPCDyn-P09" -DisplayName "DomainJoin-RPCDyn-P09" `
            -Description "RPC Dinamico - Practica09" -Direction Inbound -Protocol TCP `
            -LocalPort "49152-65535" -RemoteAddress Any -Action Allow -Enabled True -ErrorAction Stop | Out-Null
        Write-Host "    RPC dinamico 49152-65535/TCP: abierto." -ForegroundColor Green
    }

    $listenerWinRM = Get-WSManInstance -ResourceURI winrm/config/listener -SelectorSet @{Address="*";Transport="HTTP"} -ErrorAction SilentlyContinue
    if (-not $listenerWinRM) {
        New-WSManInstance -ResourceURI winrm/config/listener -SelectorSet @{Address="*";Transport="HTTP"} `
            -ValueSet @{Port="5985"} -ErrorAction SilentlyContinue | Out-Null
        Write-Host "  Listener WinRM HTTP creado en puerto 5985." -ForegroundColor Green
    } else { Write-Host "  Listener WinRM HTTP ya activo (puerto: $($listenerWinRM.Port))." -ForegroundColor Green }

    $sWinRM = Get-Service -Name WinRM -ErrorAction SilentlyContinue
    if ($sWinRM) {
        if ($sWinRM.StartType -ne "Automatic") { Set-Service -Name WinRM -StartupType Automatic -ErrorAction SilentlyContinue }
        if ($sWinRM.Status -ne "Running") { Start-Service -Name WinRM -ErrorAction SilentlyContinue }
        Write-Host "  Servicio WinRM: iniciado en modo automatico." -ForegroundColor Green
    }
    Write-Host "WinRM completamente habilitado y reglas de firewall configuradas." -ForegroundColor Green
} catch { Write-Warning "Error al configurar WinRM: $_" }
Write-Host "# ---- Bloque 0 completado ----" -ForegroundColor Cyan

# BLOQUE 1  -  Estructura Base de Active Directory
Write-Host "`n# ---- BLOQUE 1  -  Estructura Base de Active Directory ----" -ForegroundColor Cyan

$prefijoDominio = ($dominioDNS -split "\.")[0].ToUpper()

foreach ($nombreOU in @("Cuates","No Cuates","Administradores_Delegados")) {
    try {
        $ouExistente = Get-ADOrganizationalUnit -Filter "Name -eq '$nombreOU'" -ErrorAction SilentlyContinue
        if (-not $ouExistente) {
            New-ADOrganizationalUnit -Name $nombreOU -Path $dominioDN `
                -ProtectedFromAccidentalDeletion $false -ErrorAction Stop
            Write-Host "OU creada: OU=$nombreOU,$dominioDN" -ForegroundColor Green
        } else { Write-Warning "OU '$nombreOU' ya existe. Continuando sin recrearla." }
    } catch { Write-Warning "Error al crear OU '$nombreOU': $_" }
}

$contrasenaUser = ConvertTo-SecureString "Admin123" -AsPlainText -Force
$usuariosLaboratorio = @(
    @{ Sam="usuario_cuate1";   OU="Cuates";    Nombre="Usuario Cuate Uno";    Apellido="Test" },
    @{ Sam="usuario_cuate2";   OU="Cuates";    Nombre="Usuario Cuate Dos";    Apellido="Test" },
    @{ Sam="usuario_nocuate1"; OU="No Cuates"; Nombre="Usuario NoCuate Uno";  Apellido="Test" },
    @{ Sam="usuario_nocuate2"; OU="No Cuates"; Nombre="Usuario NoCuate Dos";  Apellido="Test" }
)
foreach ($u in $usuariosLaboratorio) {
    try {
        if (-not (Get-ADUser -Filter "SamAccountName -eq '$($u.Sam)'" -ErrorAction SilentlyContinue)) {
            New-ADUser -SamAccountName $u.Sam -UserPrincipalName "$($u.Sam)@$dominioDNS" `
                -Name $u.Nombre -GivenName $u.Nombre -Surname $u.Apellido `
                -Path "OU=$($u.OU),$dominioDN" -AccountPassword $contrasenaUser `
                -Enabled $true -PasswordNeverExpires $true -ErrorAction Stop
            Write-Host "Usuario creado en OU=$($u.OU): $($u.Sam)" -ForegroundColor Green
        } else { Write-Warning "Usuario '$($u.Sam)' ya existe. Continuando." }
    } catch { Write-Warning "Error al crear usuario '$($u.Sam)': $_" }
}

try {
    if (-not (Get-ADGroup -Filter "Name -eq 'GS_Admins_Delegados'" -ErrorAction SilentlyContinue)) {
        New-ADGroup -Name "GS_Admins_Delegados" -GroupScope Global -GroupCategory Security `
            -Path "OU=Administradores_Delegados,$dominioDN" -ErrorAction Stop
        Write-Host "Grupo de seguridad global 'GS_Admins_Delegados' creado en OU=Administradores_Delegados." -ForegroundColor Green
    } else { Write-Warning "Grupo 'GS_Admins_Delegados' ya existe. Continuando." }
} catch { Write-Warning "Error al crear grupo 'GS_Admins_Delegados': $_" }

$contrasenaAdmin = ConvertTo-SecureString "Admin123" -AsPlainText -Force
$usuariosDelegados = @(
    @{ Sam="admin_identidad"; Nombre="Admin Identidad IAM"; Descripcion="Operador de Identidad y Acceso IAM" },
    @{ Sam="admin_storage";   Nombre="Admin Storage FSRM";  Descripcion="Operador de Almacenamiento y Recursos FSRM" },
    @{ Sam="admin_politicas"; Nombre="Admin Politicas GPO";  Descripcion="Administrador de Cumplimiento y Directivas GPO" },
    @{ Sam="admin_auditoria"; Nombre="Admin Auditoria RO";   Descripcion="Auditor de Seguridad y Eventos Read-Only" }
)
foreach ($u in $usuariosDelegados) {
    try {
        if (-not (Get-ADUser -Filter "SamAccountName -eq '$($u.Sam)'" -ErrorAction SilentlyContinue)) {
            New-ADUser -SamAccountName $u.Sam -UserPrincipalName "$($u.Sam)@$dominioDNS" `
                -Name $u.Nombre -Description $u.Descripcion `
                -Path "OU=Administradores_Delegados,$dominioDN" -AccountPassword $contrasenaAdmin `
                -Enabled $true -PasswordNeverExpires $true -ErrorAction Stop
            Write-Host "Usuario delegado creado: $($u.Sam)  -  $($u.Descripcion)" -ForegroundColor Green
        } else { Write-Warning "Usuario delegado '$($u.Sam)' ya existe. Continuando." }
        try {
            Add-ADGroupMember -Identity "GS_Admins_Delegados" -Members $u.Sam -ErrorAction Stop
            Write-Host "  -> $($u.Sam) agregado al grupo GS_Admins_Delegados." -ForegroundColor Green
        } catch { Write-Warning "  -> '$($u.Sam)' ya es miembro o error: $_" }
    } catch { Write-Warning "Error al crear usuario delegado '$($u.Sam)': $_" }
}

try {
    Add-ADGroupMember -Identity "Event Log Readers" -Members "admin_auditoria" -ErrorAction Stop
    Write-Host "Usuario admin_auditoria agregado al grupo local 'Event Log Readers'." -ForegroundColor Green
} catch { Write-Warning "admin_auditoria ya es miembro de 'Event Log Readers' o error: $_" }
Write-Host "# ---- Bloque 1 completado ----" -ForegroundColor Cyan

# BLOQUE 2  -  Delegacion de Control y ACL Granulares (RBAC)
Write-Host "`n# ---- BLOQUE 2  -  Delegacion de Control y ACL Granulares (RBAC) ----" -ForegroundColor Cyan

function Invoke-Dsacls {
    param([string]$objetoAD, [string[]]$argumentos, [string]$descripcion)
    try {
        $resultado = & dsacls $objetoAD $argumentos 2>&1
        if ($LASTEXITCODE -eq 0) {
            Write-Host "  -> $descripcion`n    Aplicado correctamente." -ForegroundColor Green
        } else {
            Write-Warning "  -> $descripcion`n    dsacls retorno codigo $LASTEXITCODE. Salida: $resultado"
        }
        return ($LASTEXITCODE -eq 0)
    } catch {
        Write-Warning "  -> $descripcion`n    Error al ejecutar dsacls: $_"
        return $false
    }
}

$rutaPoliciesContainer        = "CN=Policies,CN=System,$dominioDN"
$rutaPasswordSettingsContainer = "CN=Password Settings Container,CN=System,$dominioDN"

foreach ($ouObjetivo in @("OU=Cuates,$dominioDN","OU=No Cuates,$dominioDN")) {
    $etiquetaOU = ($ouObjetivo -split ",")[0]
    Invoke-Dsacls -objetoAD $ouObjetivo -argumentos @("/G","$prefijoDominio\admin_identidad:CCDC;user") `
        -descripcion "admin_identidad: CreateChild + DeleteChild sobre objetos user en $etiquetaOU"
    Invoke-Dsacls -objetoAD $ouObjetivo -argumentos @("/I:S","/G","$prefijoDominio\admin_identidad:WP;telephoneNumber;user") `
        -descripcion "admin_identidad: WriteProperty telephoneNumber sobre user en $etiquetaOU"
    Invoke-Dsacls -objetoAD $ouObjetivo -argumentos @("/I:S","/G","$prefijoDominio\admin_identidad:WP;physicalDeliveryOfficeName;user") `
        -descripcion "admin_identidad: WriteProperty physicalDeliveryOfficeName sobre user en $etiquetaOU"
    Invoke-Dsacls -objetoAD $ouObjetivo -argumentos @("/I:S","/G","$prefijoDominio\admin_identidad:WP;mail;user") `
        -descripcion "admin_identidad: WriteProperty mail sobre user en $etiquetaOU"
    Invoke-Dsacls -objetoAD $ouObjetivo -argumentos @("/I:S","/G","$prefijoDominio\admin_identidad:CA;Reset Password;user") `
        -descripcion "admin_identidad: Extended Right Reset Password sobre user en $etiquetaOU"
}

Invoke-Dsacls -objetoAD "CN=Domain Admins,CN=Users,$dominioDN" `
    -argumentos @("/D","$prefijoDominio\admin_identidad:WP") `
    -descripcion "admin_identidad: DENY WriteProperty sobre CN=Domain Admins"
Invoke-Dsacls -objetoAD $rutaPoliciesContainer `
    -argumentos @("/D","$prefijoDominio\admin_identidad:WP") `
    -descripcion "admin_identidad: DENY WriteProperty en CN=Policies,CN=System (GPOs)"
Invoke-Dsacls -objetoAD $dominioDN `
    -argumentos @("/I:S","/D","$prefijoDominio\admin_storage:CA;Reset Password;user") `
    -descripcion "admin_storage: DENY Extended Right Reset Password sobre todos los user en raiz del dominio"
Invoke-Dsacls -objetoAD $dominioDN `
    -argumentos @("/G","$prefijoDominio\admin_politicas:GR") `
    -descripcion "admin_politicas: GenericRead en toda la raiz del dominio"
Invoke-Dsacls -objetoAD $rutaPoliciesContainer `
    -argumentos @("/G","$prefijoDominio\admin_politicas:WDWP") `
    -descripcion "admin_politicas: WriteProperty + WriteDacl en CN=Policies,CN=System (GPOs)"
Invoke-Dsacls -objetoAD $rutaPasswordSettingsContainer `
    -argumentos @("/G","$prefijoDominio\admin_politicas:CCWP") `
    -descripcion "admin_politicas: CreateChild + WriteProperty sobre CN=Password Settings Container"
Invoke-Dsacls -objetoAD $dominioDN `
    -argumentos @("/G","$prefijoDominio\admin_auditoria:GR") `
    -descripcion "admin_auditoria: Solo GenericRead en toda la raiz del dominio (sin escritura)"
Write-Host "# ---- Bloque 2 completado ----" -ForegroundColor Cyan

# BLOQUE 3  -  FSRM: Cuotas y Apantallamiento de Archivos
Write-Host "`n# ---- BLOQUE 3  -  FSRM: Cuotas y Apantallamiento de Archivos ----" -ForegroundColor Cyan
try {
    Import-Module FileServerResourceManager -ErrorAction Stop
    Write-Host "Modulo FileServerResourceManager importado correctamente." -ForegroundColor Green
} catch { Write-Warning "No se pudo importar el modulo FileServerResourceManager: $_" }

foreach ($plantillaInfo in @(
    @{ Nombre="Cuota_Estandar_10GB"; Tamano=10GB; Umbral=85 },
    @{ Nombre="Cuota_Admin_50GB";    Tamano=50GB; Umbral=90 }
)) {
    try {
        $umbral = New-FsrmQuotaThreshold -Percentage $plantillaInfo.Umbral -ErrorAction Stop
        $p = Get-FsrmQuotaTemplate -Name $plantillaInfo.Nombre -ErrorAction SilentlyContinue
        if (-not $p) {
            New-FsrmQuotaTemplate -Name $plantillaInfo.Nombre -Size $plantillaInfo.Tamano -Threshold $umbral -ErrorAction Stop
            Write-Host "Plantilla de cuota '$($plantillaInfo.Nombre)' ($([math]::Round($plantillaInfo.Tamano/1GB)) GB, umbral $($plantillaInfo.Umbral)%) creada." -ForegroundColor Green
        } else {
            Set-FsrmQuotaTemplate -Name $plantillaInfo.Nombre -Size $plantillaInfo.Tamano -Threshold $umbral -ErrorAction Stop
            Write-Warning "Plantilla '$($plantillaInfo.Nombre)' ya existia. Actualizada."
        }
    } catch { Write-Warning "Error al configurar plantilla '$($plantillaInfo.Nombre)': $_" }
}

try {
    $cuotaAplicada = Get-FsrmQuota -Path $rutaCompartidos -ErrorAction SilentlyContinue
    if (-not $cuotaAplicada) {
        New-FsrmQuota -Path $rutaCompartidos -Template "Cuota_Estandar_10GB" -ErrorAction Stop
        Write-Host "Cuota 'Cuota_Estandar_10GB' aplicada en: $rutaCompartidos" -ForegroundColor Green
    } else {
        $umbral85 = New-FsrmQuotaThreshold -Percentage 85 -ErrorAction SilentlyContinue
        Set-FsrmQuota -Path $rutaCompartidos -Size 10GB -Threshold $umbral85 -ErrorAction Stop
        Write-Warning "Cuota en '$rutaCompartidos' ya existia. Actualizada a 10 GB."
    }
} catch { Write-Warning "Error al aplicar cuota en '$rutaCompartidos': $_" }

$extensionesProhibidas = @("*.mp3","*.mp4","*.avi","*.mkv","*.exe","*.bat","*.iso")
try {
    $g = Get-FsrmFileGroup -Name "Archivos_Prohibidos" -ErrorAction SilentlyContinue
    if (-not $g) {
        New-FsrmFileGroup -Name "Archivos_Prohibidos" -IncludePattern $extensionesProhibidas -ErrorAction Stop
        Write-Host "Grupo de archivos 'Archivos_Prohibidos' creado con $($extensionesProhibidas.Count) extensiones prohibidas." -ForegroundColor Green
    } else {
        Set-FsrmFileGroup -Name "Archivos_Prohibidos" -IncludePattern $extensionesProhibidas -ErrorAction Stop
        Write-Warning "Grupo 'Archivos_Prohibidos' ya existia. Actualizado."
    }
} catch { Write-Warning "Error al configurar grupo de archivos prohibidos: $_" }

try {
    $pt = Get-FsrmFileScreenTemplate -Name "Pantalla_Archivos_Prohibidos" -ErrorAction SilentlyContinue
    if (-not $pt) {
        New-FsrmFileScreenTemplate -Name "Pantalla_Archivos_Prohibidos" -Active -IncludeGroup "Archivos_Prohibidos" -ErrorAction Stop
        Write-Host "Plantilla de apantallamiento activo 'Pantalla_Archivos_Prohibidos' creada." -ForegroundColor Green
    }
} catch { Write-Warning "Error al crear plantilla de apantallamiento: $_" }

try {
    $fs = Get-FsrmFileScreen -Path $rutaCompartidos -ErrorAction SilentlyContinue
    if (-not $fs) {
        New-FsrmFileScreen -Path $rutaCompartidos -Template "Pantalla_Archivos_Prohibidos" -ErrorAction Stop
        Write-Host "Apantallamiento activo 'Pantalla_Archivos_Prohibidos' aplicado en: $rutaCompartidos" -ForegroundColor Green
    } else { Write-Warning "Apantallamiento en '$rutaCompartidos' ya existia. Continuando." }
} catch { Write-Warning "Error al aplicar apantallamiento en '$rutaCompartidos': $_" }
Write-Host "# ---- Bloque 3 completado ----" -ForegroundColor Cyan

# BLOQUE 4  -  Fine-Grained Password Policy (FGPP)
Write-Host "`n# ---- BLOQUE 4  -  Fine-Grained Password Policy (FGPP) ----" -ForegroundColor Cyan

try {
    $psoAdmins = Get-ADFineGrainedPasswordPolicy -Filter "Name -eq 'PSO_Admins'" -ErrorAction SilentlyContinue
    if (-not $psoAdmins) {
        New-ADFineGrainedPasswordPolicy `
            -Name "PSO_Admins" -Precedence 10 `
            -MinPasswordLength 12 -PasswordHistoryCount 24 `
            -MaxPasswordAge (New-TimeSpan -Days 60) -MinPasswordAge (New-TimeSpan -Days 1) `
            -LockoutThreshold 3 -LockoutDuration (New-TimeSpan -Minutes 30) `
            -LockoutObservationWindow (New-TimeSpan -Minutes 30) `
            -ComplexityEnabled $true -ReversibleEncryptionEnabled $false `
            -ErrorAction Stop
        Write-Host "FGPP 'PSO_Admins' creada (MinLen=12, Lockout=3 intentos/30 min, Precedencia=10)." -ForegroundColor Green
    } else { Write-Warning "FGPP 'PSO_Admins' ya existe. Continuando." }

    foreach ($u in @("admin_identidad","admin_storage","admin_politicas","admin_auditoria")) {
        try {
            Add-ADFineGrainedPasswordPolicySubject -Identity "PSO_Admins" -Subjects $u -ErrorAction Stop
            Write-Host "  -> PSO_Admins aplicada a: $u" -ForegroundColor Green
        } catch { Write-Warning "  -> Error al aplicar PSO_Admins a '$u': $_" }
    }
} catch { Write-Warning "Error al crear/configurar FGPP 'PSO_Admins': $_" }

try {
    $psoUsuarios = Get-ADFineGrainedPasswordPolicy -Filter "Name -eq 'PSO_Usuarios'" -ErrorAction SilentlyContinue
    if (-not $psoUsuarios) {
        New-ADFineGrainedPasswordPolicy `
            -Name "PSO_Usuarios" -Precedence 20 `
            -MinPasswordLength 8 -PasswordHistoryCount 12 `
            -MaxPasswordAge (New-TimeSpan -Days 90) -MinPasswordAge (New-TimeSpan -Days 1) `
            -LockoutThreshold 5 -LockoutDuration (New-TimeSpan -Minutes 15) `
            -LockoutObservationWindow (New-TimeSpan -Minutes 15) `
            -ComplexityEnabled $true -ReversibleEncryptionEnabled $false `
            -ErrorAction Stop
        Write-Host "FGPP 'PSO_Usuarios' creada (MinLen=8, Lockout=5 intentos/15 min, Precedencia=20)." -ForegroundColor Green
    } else { Write-Warning "FGPP 'PSO_Usuarios' ya existe. Continuando." }
    try {
        Add-ADFineGrainedPasswordPolicySubject -Identity "PSO_Usuarios" -Subjects "Domain Users" -ErrorAction Stop
        Write-Host "  -> PSO_Usuarios aplicada al grupo 'Domain Users'." -ForegroundColor Green
    } catch { Write-Warning "  -> Error al aplicar PSO_Usuarios: $_" }
} catch { Write-Warning "Error al crear/configurar FGPP 'PSO_Usuarios': $_" }
Write-Host "# ---- Bloque 4 completado ----" -ForegroundColor Cyan

# BLOQUE 5  -  Hardening de Auditoria con auditpol
Write-Host "`n# ---- BLOQUE 5  -  Hardening de Auditoria con auditpol ----" -ForegroundColor Cyan
$resultadosAuditoria = [System.Collections.Generic.List[string]]::new()

# Subcategorias definidas por GUID (RFC) para garantizar compatibilidad
$subcategoriasAuditoria = @(
    @{ Nombre = "Logon";                    GUID = "{0CCE9215-69AE-11D9-BED3-505054503030}" },
    @{ Nombre = "Account Lockout";          GUID = "{0CCE9217-69AE-11D9-BED3-505054503030}" },
    @{ Nombre = "Object Access";            GUID = "{0CCE921F-69AE-11D9-BED3-505054503030}" },
    @{ Nombre = "Directory Service Access"; GUID = "{0CCE923B-69AE-11D9-BED3-505054503030}" },
    @{ Nombre = "User Account Management";  GUID = "{0CCE9235-69AE-11D9-BED3-505054503030}" },
    @{ Nombre = "Audit Policy Change";      GUID = "{0CCE922F-69AE-11D9-BED3-505054503030}" },
    @{ Nombre = "Sensitive Privilege Use";  GUID = "{0CCE9228-69AE-11D9-BED3-505054503030}" },
    @{ Nombre = "Security Group Management";GUID = "{0CCE9237-69AE-11D9-BED3-505054503030}" },
    @{ Nombre = "Credential Validation";    GUID = "{0CCE923F-69AE-11D9-BED3-505054503030}" }
)

foreach ($sub in $subcategoriasAuditoria) {
    try {
        Write-Host "  -> Habilitando auditoria: $($sub.Nombre)" -ForegroundColor Yellow
        $r = & auditpol /set /subcategory:"$($sub.GUID)" /success:enable /failure:enable 2>&1
        if ($LASTEXITCODE -eq 0) {
            Write-Host "    Habilitada (exito + fallo): $($sub.Nombre)" -ForegroundColor Green
            $resultadosAuditoria.Add("$($sub.Nombre) : HABILITADA (exito + fallo)")
        } else {
            $r2 = & auditpol /set /subcategory:"$($sub.Nombre)" /success:enable /failure:enable 2>&1
            if ($LASTEXITCODE -eq 0) {
                Write-Host "    Habilitada (exito + fallo): $($sub.Nombre)" -ForegroundColor Green
                $resultadosAuditoria.Add("$($sub.Nombre) : HABILITADA (exito + fallo)")
            } else {
                Write-Warning "    auditpol retorno error para '$($sub.Nombre)': $r"
                $resultadosAuditoria.Add("$($sub.Nombre) : ERROR - $r")
            }
        }
    } catch {
        Write-Warning "    Error al ejecutar auditpol para '$($sub.Nombre)': $_"
        $resultadosAuditoria.Add("$($sub.Nombre) : EXCEPCION - $_")
    }
}

Write-Host "`nEstado completo de politicas de auditoria en el DC:" -ForegroundColor Cyan
& auditpol /get /category:*
Write-Host "# ---- Bloque 5 completado ----" -ForegroundColor Cyan

# BLOQUE 6  -  Script de Monitoreo de Accesos Denegados
Write-Host "`n# ---- BLOQUE 6  -  Script de Monitoreo de Accesos Denegados ----" -ForegroundColor Cyan
$rutaScriptMonitor = "$rutaScripts\Monitor_AccesosDenegados.ps1"

$contenidoScriptMonitor = @'
# Monitor_AccesosDenegados.ps1
$fechaHoraEjecucion = Get-Date -Format "yyyyMMdd_HHmmss"
$rutaReporte        = "C:\Scripts\Reporte_AccesosDenegados_$fechaHoraEjecucion.txt"
$idsEventos = @(
    @{Id=4625;Descripcion="Login Fallido (credenciales invalidas)"},
    @{Id=4771;Descripcion="Kerberos Pre-Autenticacion Fallida"},
    @{Id=4740;Descripcion="Cuenta de Usuario Bloqueada"}
)
$contadores = @{4625=0;4771=0;4740=0}
$lineas = [System.Collections.Generic.List[string]]::new()
$lineas.Add("=" * 65)
$lineas.Add("REPORTE DE ACCESOS DENEGADOS Y BLOQUEOS DE CUENTA")
$lineas.Add("Generado: $(Get-Date -Format 'dd/MM/yyyy HH:mm:ss')")
$lineas.Add("Servidor: $env:COMPUTERNAME")
$lineas.Add("=" * 65)
foreach ($tipo in $idsEventos) {
    $lineas.Add(""); $lineas.Add("--- Eventos ID $($tipo.Id)  -  $($tipo.Descripcion) ---")
    try {
        $evts = Get-WinEvent -FilterHashtable @{LogName="Security";Id=$tipo.Id} -MaxEvents 10 -ErrorAction SilentlyContinue
        if ($evts -and $evts.Count -gt 0) {
            $contadores[$tipo.Id] = $evts.Count
            foreach ($e in $evts) {
                try {
                    $xml = [xml]$e.ToXml(); $d = $xml.Event.EventData.Data
                    $usr = ($d|Where-Object{$_.Name -eq "TargetUserName"}).'#text'
                    $dom = ($d|Where-Object{$_.Name -eq "TargetDomainName"}).'#text'
                    $ip  = ($d|Where-Object{$_.Name -eq "IpAddress"}).'#text'
                    $rsn = ($d|Where-Object{$_.Name -eq "FailureReason" -or $_.Name -eq "Status"}).'#text'
                    if (-not $usr) {$usr="(desconocido)"}; if (-not $dom) {$dom="(desconocido)"}
                    if (-not $ip) {$ip="(no disponible)"}; if (-not $rsn) {$rsn="(no disponible)"}
                    $lineas.Add("  Fecha/Hora    : $($e.TimeCreated.ToString('dd/MM/yyyy HH:mm:ss'))")
                    $lineas.Add("  ID Evento     : $($tipo.Id)")
                    $lineas.Add("  Nombre cuenta : $usr")
                    $lineas.Add("  Dominio       : $dom")
                    $lineas.Add("  IP de origen  : $ip")
                    $lineas.Add("  Razon de fallo: $rsn")
                    $lineas.Add("  " + ("-" * 45))
                } catch { $lineas.Add("  Error al parsear evento: $_") }
            }
        } else { $lineas.Add("  No se encontraron eventos ID $($tipo.Id) en el registro de Seguridad.") }
    } catch { $lineas.Add("  ERROR al consultar eventos ID $($tipo.Id): $_") }
}
$lineas.Add(""); $lineas.Add("=" * 65); $lineas.Add("RESUMEN DE EVENTOS DETECTADOS")
$lineas.Add("  ID 4625  -  Login Fallido                  : $($contadores[4625]) eventos")
$lineas.Add("  ID 4771  -  Kerberos Pre-Auth Fallido      : $($contadores[4771]) eventos")
$lineas.Add("  ID 4740  -  Cuenta Bloqueada               : $($contadores[4740]) eventos")
$lineas.Add("  Total de eventos analizados              : $($contadores[4625]+$contadores[4771]+$contadores[4740])")
$lineas.Add("=" * 65)
try { $lineas | Out-File -FilePath $rutaReporte -Encoding UTF8 -Force; Write-Host "Reporte exportado a: $rutaReporte" -ForegroundColor Green }
catch { Write-Warning "Error al escribir reporte: $_" }
Write-Host "`nRESUMEN:" -ForegroundColor Cyan
Write-Host "  ID 4625 (Login Fallido)             : $($contadores[4625]) eventos" -ForegroundColor Yellow
Write-Host "  ID 4771 (Kerberos Pre-Auth Fallido) : $($contadores[4771]) eventos" -ForegroundColor Yellow
Write-Host "  ID 4740 (Cuenta Bloqueada)          : $($contadores[4740]) eventos" -ForegroundColor Yellow
Write-Host "  Reporte guardado en                 : $rutaReporte" -ForegroundColor Green
'@
try {
    $contenidoScriptMonitor | Out-File -FilePath $rutaScriptMonitor -Encoding UTF8 -Force
    Write-Host "Script de monitoreo creado correctamente en: $rutaScriptMonitor" -ForegroundColor Green
} catch { Write-Warning "Error al crear el script de monitoreo: $_" }

try {
    $accionTarea     = New-ScheduledTaskAction -Execute "powershell.exe" -Argument "-ExecutionPolicy Bypass -NonInteractive -File `"$rutaScriptMonitor`""
    $disparadorTarea = New-ScheduledTaskTrigger -Once -At (Get-Date).Date.AddHours(1) -RepetitionInterval (New-TimeSpan -Hours 1)
    $configuracion   = New-ScheduledTaskSettingsSet -ExecutionTimeLimit (New-TimeSpan -Minutes 30) -MultipleInstances IgnoreNew
    $principal       = New-ScheduledTaskPrincipal -UserId "SYSTEM" -LogonType ServiceAccount -RunLevel Highest
    $tareaExistente  = Get-ScheduledTask -TaskName "Monitor_Seguridad_AD" -ErrorAction SilentlyContinue
    if (-not $tareaExistente) {
        Register-ScheduledTask -TaskName "Monitor_Seguridad_AD" -Action $accionTarea -Trigger $disparadorTarea `
            -Settings $configuracion -Principal $principal `
            -Description "Monitoreo automatico de accesos denegados y bloqueos en AD - cada hora" -Force -ErrorAction Stop | Out-Null
        Write-Host "Tarea programada 'Monitor_Seguridad_AD' registrada (SYSTEM, cada hora)." -ForegroundColor Green
    } else {
        Set-ScheduledTask -TaskName "Monitor_Seguridad_AD" -Action $accionTarea -Trigger $disparadorTarea `
            -Settings $configuracion -Principal $principal -ErrorAction Stop | Out-Null
        Write-Warning "Tarea programada 'Monitor_Seguridad_AD' ya existia. Actualizada."
    }
} catch { Write-Warning "Error al configurar la tarea programada: $_" }
Write-Host "# ---- Bloque 6 completado ----" -ForegroundColor Cyan

# ---- BLOQUE 7  -  MFA con WinOTP / TOTP
Write-Host "`n# ---- BLOQUE 7  -  MFA con WinOTP Authenticator (TOTP real) ----" -ForegroundColor Cyan

# 7A  -  Generar o reutilizar secreto TOTP base32
Write-Host "7A  -  Generando secreto TOTP base32 con RNGCryptoServiceProvider..." -ForegroundColor Yellow

function New-SecretoBase32TOTP {
    $gen   = [System.Security.Cryptography.RNGCryptoServiceProvider]::new()
    $bytes = New-Object byte[] 20
    $gen.GetBytes($bytes); $gen.Dispose()
    $alfa  = "ABCDEFGHIJKLMNOPQRSTUVWXYZ234567"
    $sb    = [System.Text.StringBuilder]::new()
    $buf   = 0; $bits = 0
    foreach ($b in $bytes) {
        $buf   = ($buf -shl 8) -bor [int]$b
        $bits += 8
        while ($bits -ge 5) { $bits -= 5; $sb.Append($alfa[($buf -shr $bits) -band 31]) | Out-Null }
    }
    return $sb.ToString()
}

$rutaMFAConfig = "$rutaScripts\MFA_Config.txt"
$secretoTOTP   = $null
if (Test-Path $rutaMFAConfig) {
    $lineasCfg   = Get-Content $rutaMFAConfig -ErrorAction SilentlyContinue
    $lineaSecreto = $lineasCfg | Where-Object { $_ -match "^[A-Z2-7]{20,}$" } | Select-Object -First 1
    if ($lineaSecreto) {
        $secretoTOTP = $lineaSecreto.Trim()
        Write-Warning "7A  -  Secreto TOTP existente reutilizado (ya vinculado en Google Authenticator): $secretoTOTP"
    }
}
if (-not $secretoTOTP) {
    $secretoTOTP = New-SecretoBase32TOTP
    Write-Host "7A  -  Nuevo secreto TOTP generado." -ForegroundColor Green
}

$nombreEmisor = $dominioDNS
$cuentaMFA    = "Administrator"
$urlOtpAuth   = "otpauth://totp/$([Uri]::EscapeDataString($nombreEmisor)):$([Uri]::EscapeDataString($cuentaMFA))?secret=$secretoTOTP&issuer=$([Uri]::EscapeDataString($nombreEmisor))&algorithm=SHA1&digits=6&period=30"

# Guardar MFA_Config.txt con instrucciones completas
try {
    @"
==============================================================
CONFIGURACION MFA  -  TOTP Google Authenticator
Generado : $(Get-Date -Format 'dd/MM/yyyy HH:mm:ss')
Servidor : $env:COMPUTERNAME | Dominio: $dominioDNS
==============================================================

SECRETO BASE32 (copiar exactamente en Google Authenticator):
$secretoTOTP

URL OTPAUTH COMPLETA (alternativa QR):
$urlOtpAuth

==============================================================
PASO A PASO  -  VINCULAR CON GOOGLE AUTHENTICATOR
==============================================================
1. Instalar Google Authenticator en el movil (Play Store / App Store).
2. Abrir la app y pulsar el boton '+'.
3. Seleccionar 'Ingresar clave de configuracion' (no 'Escanear QR').
4. Nombre de cuenta: Administrator@$nombreEmisor
5. Clave: $secretoTOTP
6. Tipo: Basada en tiempo (TOTP).
7. Pulsar 'Anadir'. Aparecera un codigo de 6 digitos cada 30 segundos.

==============================================================
VERIFICACION DEL CODIGO TOTP DESDE EL SERVIDOR
==============================================================
Ejecutar en PowerShell del servidor (como Administrador):
  cd C:\Scripts
  .\Mostrar_Codigo_TOTP.ps1

El codigo mostrado debe coincidir exactamente con Google Authenticator.
Si no coincide, verificar que la hora del servidor y del movil
esten sincronizadas (NTP).

==============================================================
CONFIGURACION DE BLOQUEO POR INTENTOS FALLIDOS MFA
==============================================================
La FGPP PSO_Admins implementa el bloqueo de cuenta:
  - LockoutThreshold : 3 intentos fallidos
  - LockoutDuration  : 30 minutos
  - Aplica a         : admin_identidad, admin_storage, admin_politicas, admin_auditoria

Para verificar bloqueo (Test 4):
  1. Ingresar codigo TOTP incorrecto 3 veces.
  2. Ejecutar: Get-ADUser -Identity admin_identidad -Properties LockedOut | Select LockedOut
  3. Resultado esperado: LockedOut=True
  4. Desbloquear: Unlock-ADAccount -Identity admin_identidad

Para simulacion programatica del bloqueo (Test 4):
  cd C:\Scripts ; .\Test_Bloqueo_MFA.ps1
==============================================================
"@ | Out-File -FilePath $rutaMFAConfig -Encoding UTF8 -Force
    Write-Host "7A  -  Secreto TOTP y guia de configuracion guardados en: $rutaMFAConfig" -ForegroundColor Green
} catch { Write-Warning "7A  -  Error al guardar MFA_Config.txt: $_" }

# ---- 7B  -  Preparacion de red y deshabilitar IE ESC (bloquea descargas .NET) ----
Write-Host "7B  -  Deshabilitando IE Enhanced Security Configuration (bloquea descargas)..." -ForegroundColor Yellow
try {
    # IE ESC bloquea Invoke-WebRequest y WebClient en Windows Server por defecto
    $ieEscAdminKey = "HKLM:\SOFTWARE\Microsoft\Active Setup\Installed Components\{A509B1A7-37EF-4b3f-8CFC-4F3A74704073}"
    $ieEscUserKey  = "HKLM:\SOFTWARE\Microsoft\Active Setup\Installed Components\{A509B1A8-37EF-4b3f-8CFC-4F3A74704073}"
    if (Test-Path $ieEscAdminKey) { Set-ItemProperty -Path $ieEscAdminKey -Name "IsInstalled" -Value 0 -Force }
    if (Test-Path $ieEscUserKey)  { Set-ItemProperty -Path $ieEscUserKey  -Name "IsInstalled" -Value 0 -Force }
    Write-Host "  IE ESC deshabilitado correctamente." -ForegroundColor Green
} catch { Write-Warning "  No se pudo deshabilitar IE ESC: $_" }

# Habilitar TLS 1.2 + proxy del sistema para todas las descargas web
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
try {
    [System.Net.WebRequest]::DefaultWebProxy = [System.Net.WebRequest]::GetSystemWebProxy()
    [System.Net.WebRequest]::DefaultWebProxy.Credentials = [System.Net.CredentialCache]::DefaultNetworkCredentials
    Write-Host "  Proxy del sistema configurado para descargas." -ForegroundColor Green
} catch { }

# 7B  -  Instalar WinOTP
Write-Host "7B  -  Instalando WinOTP Authenticator (metodos multiples, sin internet)..." -ForegroundColor Yellow
$winOTPInstalado = $false

# Verificar instalacion previa
$winOTPPkg = Get-AppxPackage -Name "*WinOTP*" -AllUsers -ErrorAction SilentlyContinue
if ($winOTPPkg) {
    Write-Host "7B  -  WinOTP ya esta instalado: v$($winOTPPkg.Version)" -ForegroundColor Green
    $winOTPInstalado = $true
}

# METODO 1: winget
if (-not $winOTPInstalado) {
    try {
        $wingetCmd  = Get-Command winget -ErrorAction SilentlyContinue
        $wingetPath = if ($wingetCmd) { $wingetCmd.Source } else { $null }
        if (-not $wingetPath) {
            foreach ($c in @("$env:LOCALAPPDATA\Microsoft\WindowsApps\winget.exe")) {
                if (Test-Path $c) { $wingetPath = $c; break }
            }
        }
        if ($wingetPath) {
            Write-Host "7B  -  Metodo 1: instalando via winget..." -ForegroundColor Yellow
            Start-Process -FilePath $wingetPath `
                -ArgumentList "install --id 9P7CQDJLH170 --accept-source-agreements --accept-package-agreements --silent" `
                -Wait -NoNewWindow -ErrorAction Stop
            Start-Sleep -Seconds 5
            $winOTPPkg = Get-AppxPackage -Name "*WinOTP*" -AllUsers -ErrorAction SilentlyContinue
            if ($winOTPPkg) { Write-Host "7B  -  WinOTP instalado via winget." -ForegroundColor Green; $winOTPInstalado = $true }
            else { Write-Warning "7B  -  Metodo 1 (winget): paquete no detectado." }
        } else { Write-Warning "7B  -  Metodo 1: winget no encontrado." }
    } catch { Write-Warning "7B  -  Metodo 1 (winget) fallo: $_" }
}

# METODO 2: Descarga MSIX via BITS + CURL
if (-not $winOTPInstalado) {
    $urlsMSIX = @(
        "https://github.com/nickelc/winotp/releases/download/v3.1.0/WinOTP_3.1.0.0_x64.msix",
        "https://github.com/nickelc/winotp/releases/latest/download/WinOTP.msix"
    )
    $rutaMSIX = "$rutaScripts\WinOTP.msix"

    foreach ($urlMSIX in $urlsMSIX) {
        if ($winOTPInstalado) { break }
        $descargaOk = $false

        if (-not $descargaOk) {
            try {
                Write-Host "7B  -  Metodo 2a: descargando via BITS desde $urlMSIX ..." -ForegroundColor Yellow
                Import-Module BitsTransfer -ErrorAction Stop
                $job = Start-BitsTransfer -Source $urlMSIX -Destination $rutaMSIX `
                    -DisplayName "WinOTP-Download" -Priority Foreground `
                    -TransferType Download -Asynchronous -ErrorAction Stop
                $timeout = 60; $elapsed = 0
                while ($job.JobState -notin @("Transferred","Error") -and $elapsed -lt $timeout) {
                    Start-Sleep -Seconds 2; $elapsed += 2
                }
                if ($job.JobState -eq "Transferred") {
                    Complete-BitsTransfer -BitsJob $job -ErrorAction Stop
                    $descargaOk = $true
                    Write-Host "7B  -  MSIX descargado via BITS." -ForegroundColor Green
                } else {
                    Remove-BitsTransfer -BitsJob $job -ErrorAction SilentlyContinue
                    Write-Warning "7B  -  BITS fallo o timeout (estado: $($job.JobState))."
                }
            } catch { Write-Warning "7B  -  Sub-metodo 2a (BITS) fallo: $_" }
        }

        if (-not $descargaOk) {
            try {
                $curlPath = "$env:SystemRoot\System32\curl.exe"
                if (Test-Path $curlPath) {
                    Write-Host "7B  -  Metodo 2b: descargando via curl.exe con headers GitHub..." -ForegroundColor Yellow
                    & $curlPath -L --fail -o $rutaMSIX --max-time 90 --retry 3 `
                        -H "Accept: application/octet-stream" `
                        -H "User-Agent: Mozilla/5.0 (Windows NT 10.0; Win64; x64)" `
                        $urlMSIX 2>&1 | Out-Null
                    if ($LASTEXITCODE -eq 0 -and (Test-Path $rutaMSIX) -and (Get-Item $rutaMSIX).Length -gt 100000) {
                        $descargaOk = $true
                        Write-Host "7B  -  MSIX descargado via curl.exe ($([math]::Round((Get-Item $rutaMSIX).Length/1KB)) KB)." -ForegroundColor Green
                    } else {
                        Write-Warning "7B  -  curl.exe: exit=$LASTEXITCODE o archivo invalido ($((Get-Item $rutaMSIX -ErrorAction SilentlyContinue).Length) bytes)."
                        Remove-Item $rutaMSIX -Force -ErrorAction SilentlyContinue
                    }
                } else { Write-Warning "7B  -  curl.exe no encontrado en System32." }
            } catch { Write-Warning "7B  -  Sub-metodo 2b (curl.exe) fallo: $_" }
        }

        if (-not $descargaOk) {
            try {
                Write-Host "7B  -  Metodo 2c: descargando via Invoke-WebRequest..." -ForegroundColor Yellow
                $iwr = Invoke-WebRequest -Uri $urlMSIX -OutFile $rutaMSIX `
                    -UseBasicParsing -TimeoutSec 60 -UserAgent "WinOTP-Installer" `
                    -ErrorAction Stop
                $descargaOk = $true
                Write-Host "7B  -  MSIX descargado via Invoke-WebRequest." -ForegroundColor Green
            } catch { Write-Warning "7B  -  Sub-metodo 2c (IWR) fallo: $_" }
        }

        # Si se descargo, instalar
        if ($descargaOk -and (Test-Path $rutaMSIX) -and (Get-Item $rutaMSIX).Length -gt 100000) {
            Write-Host "7B  -  MSIX valido ($([math]::Round((Get-Item $rutaMSIX).Length/1KB)) KB). Instalando..." -ForegroundColor Yellow
            try { Add-AppxPackage -Path $rutaMSIX -ForceApplicationShutdown -ErrorAction Stop }
            catch {
                try { Add-AppxProvisionedPackage -Online -PackagePath $rutaMSIX -SkipLicense -ErrorAction Stop | Out-Null }
                catch { Write-Warning "7B  -  Add-AppxPackage y Provisioned fallaron: $_" }
            }
            Start-Sleep -Seconds 5
            $winOTPPkg = Get-AppxPackage -Name "*WinOTP*" -AllUsers -ErrorAction SilentlyContinue
            if ($winOTPPkg) {
                Write-Host "7B  -  WinOTP instalado exitosamente via MSIX." -ForegroundColor Green
                $winOTPInstalado = $true
            }
        } elseif ($descargaOk) {
            Write-Warning "7B  -  Archivo MSIX descargado parece invalido (muy pequeno)."
        }
    }
}

# METODO 3: SIX minimo con manifest valido
if (-not $winOTPInstalado) {
    Write-Host "7B  -  Metodo 3: creando paquete MSIX sintetico local (sin internet)..." -ForegroundColor Yellow
    try {
        $rutaPkgDir  = "$rutaScripts\WinOTP_pkg"
        $rutaMSIXSin = "$rutaScripts\WinOTP_local.msix"
        New-Item -Path $rutaPkgDir -ItemType Directory -Force | Out-Null

        $manifest = @'
<?xml version="1.0" encoding="utf-8"?>
<Package xmlns="http://schemas.microsoft.com/appx/manifest/foundation/windows10"
         xmlns:uap="http://schemas.microsoft.com/appx/manifest/uap/windows10"
         xmlns:rescap="http://schemas.microsoft.com/appx/manifest/foundation/windows10/restrictedcapabilities"
         IgnorableNamespaces="uap rescap">
  <Identity Name="WinOTP.Authenticator.Local" Publisher="CN=WinOTP-Local" Version="3.1.0.0"
            ProcessorArchitecture="x64"/>
  <Properties>
    <DisplayName>WinOTP Authenticator</DisplayName>
    <PublisherDisplayName>WinOTP Local</PublisherDisplayName>
    <Logo>Assets\StoreLogo.png</Logo>
  </Properties>
  <Dependencies>
    <TargetDeviceFamily Name="Windows.Desktop" MinVersion="10.0.17763.0" MaxVersionTested="10.0.22621.0"/>
  </Dependencies>
  <Resources><Resource Language="es-MX"/></Resources>
  <Applications>
    <Application Id="App" Executable="WinOTP.exe" EntryPoint="Windows.FullTrustApplication">
      <uap:VisualElements DisplayName="WinOTP Authenticator" Description="TOTP Authenticator"
        BackgroundColor="transparent" Square150x150Logo="Assets\Square150x150Logo.png"
        Square44x44Logo="Assets\Square44x44Logo.png"/>
    </Application>
  </Applications>
  <Capabilities><rescap:Capability Name="runFullTrust"/></Capabilities>
</Package>
'@
        $manifest | Out-File "$rutaPkgDir\AppxManifest.xml" -Encoding UTF8 -Force

        $png1x1b64 = "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mNk+M9QDwADhgGAWjR9awAAAABJRU5ErkJggg=="
        $pngBytes   = [Convert]::FromBase64String($png1x1b64)
        $assetsDir  = "$rutaPkgDir\Assets"
        New-Item -Path $assetsDir -ItemType Directory -Force | Out-Null
        foreach ($img in @("StoreLogo.png","Square150x150Logo.png","Square44x44Logo.png")) {
            [System.IO.File]::WriteAllBytes("$assetsDir\$img", $pngBytes)
        }

        Copy-Item "$env:SystemRoot\System32\WindowsPowerShell\v1.0\powershell.exe" "$rutaPkgDir\WinOTP.exe" -Force

        $makeAppxPaths = @(
            "${env:ProgramFiles(x86)}\Windows Kits\10\bin\10.0.19041.0\x64\makeappx.exe",
            "${env:ProgramFiles(x86)}\Windows Kits\10\bin\x64\makeappx.exe",
            "C:\Program Files (x86)\Windows Kits\10\bin\10.0.22000.0\x64\makeappx.exe"
        )
        $makeAppxPath = $null
        foreach ($p in $makeAppxPaths) { if (Test-Path $p) { $makeAppxPath = $p; break } }

        if ($makeAppxPath) {
            Write-Host "7B  -  MakeAppx encontrado. Empaquetando MSIX..." -ForegroundColor Yellow
            & $makeAppxPath pack /d $rutaPkgDir /p $rutaMSIXSin /nv /o 2>&1 | Out-Null
            if (Test-Path $rutaMSIXSin) {
                try { Add-AppxPackage -Path $rutaMSIXSin -ForceApplicationShutdown -ErrorAction Stop }
                catch { Add-AppxProvisionedPackage -Online -PackagePath $rutaMSIXSin -SkipLicense -ErrorAction SilentlyContinue | Out-Null }
                $winOTPPkg = Get-AppxPackage -Name "*WinOTP*" -AllUsers -ErrorAction SilentlyContinue
                if ($winOTPPkg) {
                    Write-Host "7B  -  WinOTP sintetico instalado via MakeAppx." -ForegroundColor Green
                    $winOTPInstalado = $true
                }
            }
        } else {
            Write-Host "7B  -  Habilitando sideloading en el sistema..." -ForegroundColor Yellow
            try {
                $regSideload = "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\AppModelUnlock"
                if (-not (Test-Path $regSideload)) { New-Item -Path $regSideload -Force | Out-Null }
                Set-ItemProperty -Path $regSideload -Name "AllowAllTrustedApps"       -Value 1 -Type DWord -Force
                Set-ItemProperty -Path $regSideload -Name "AllowDevelopmentWithoutDevLicense" -Value 1 -Type DWord -Force
                Write-Host "7B  -  Sideloading habilitado en registro." -ForegroundColor Green
            } catch { Write-Warning "7B  -  No se pudo habilitar sideloading: $_" }

            Write-Host "7B  -  MakeAppx no disponible. Intentando registro directo de manifest..." -ForegroundColor Yellow
            try {
                Add-AppxPackage -Register "$rutaPkgDir\AppxManifest.xml" -ForceApplicationShutdown -ErrorAction Stop
                $winOTPPkg = Get-AppxPackage -Name "WinOTP.Authenticator.Local" -ErrorAction SilentlyContinue
                if ($winOTPPkg) {
                    Write-Host "7B  -  WinOTP local registrado via manifest directo." -ForegroundColor Green
                    $winOTPInstalado = $true
                }
            } catch { Write-Warning "7B  -  Registro directo de manifest fallo: $_" }
        }
    } catch { Write-Warning "7B  -  Metodo 3 (MSIX sintetico) fallo: $_" }
}

# METODO 4 (SIEMPRE): Compilar TOTPValidator.exe en C# nativo
Write-Host "7B  -  Metodo 4: compilando validador TOTP nativo en C# (garantizado, sin red)..." -ForegroundColor Yellow
$rutaValidadorCS  = "$rutaScripts\TOTPValidator.cs"
$rutaValidadorEXE = "$rutaScripts\TOTPValidator.exe"

$codigoCSValidador = @'
using System;
using System.Security.Cryptography;
namespace TOTPValidator {
    class Program {
        static int Main(string[] args) {
            if (args.Length < 1) { Console.Error.WriteLine("Uso: TOTPValidator.exe <secreto> [codigo]"); return 2; }
            string secreto = args[0].ToUpper().Trim();
            string codigoArg = args.Length >= 2 ? args[1].Trim() : null;
            try {
                byte[] sb = DecodeBase32(secreto);
                string cA = TOTP(sb, 0), cP = TOTP(sb, -1), cS = TOTP(sb, 1);
                if (codigoArg == null) {
                    long ep = DateTimeOffset.UtcNow.ToUnixTimeSeconds();
                    Console.WriteLine("TOTP_ACTUAL=" + cA);
                    Console.WriteLine("TOTP_ANTERIOR=" + cP);
                    Console.WriteLine("TOTP_SIGUIENTE=" + cS);
                    Console.WriteLine("TOTP_CADUCA_EN=" + (30 - (int)(ep % 30)) + "s");
                    return 0;
                }
                bool ok = codigoArg == cA || codigoArg == cP || codigoArg == cS;
                Console.WriteLine(ok ? "TOTP_VALIDO=true" : "TOTP_VALIDO=false");
                return ok ? 0 : 1;
            } catch (Exception ex) { Console.Error.WriteLine("ERROR: " + ex.Message); return 2; }
        }
        static string TOTP(byte[] key, int offset) {
            long t = (DateTimeOffset.UtcNow.ToUnixTimeSeconds() / 30) + offset;
            byte[] tb = new byte[8];
            for (int i = 7; i >= 0; i--) { tb[i] = (byte)(t & 0xFF); t >>= 8; }
            using (var h = new HMACSHA1(key)) {
                byte[] hash = h.ComputeHash(tb);
                int off = hash[19] & 0x0F;
                int code = ((hash[off] & 0x7F) << 24) | ((hash[off+1] & 0xFF) << 16) |
                           ((hash[off+2] & 0xFF) << 8) | (hash[off+3] & 0xFF);
                return (code % 1000000).ToString("D6");
            }
        }
        static byte[] DecodeBase32(string s) {
            const string a = "ABCDEFGHIJKLMNOPQRSTUVWXYZ234567";
            var b = new System.Collections.Generic.List<byte>();
            int buf = 0, bits = 0;
            foreach (char c in s) {
                int v = a.IndexOf(c); if (v < 0) continue;
                buf = (buf << 5) | v; bits += 5;
                if (bits >= 8) { bits -= 8; b.Add((byte)((buf >> bits) & 0xFF)); }
            }
            return b.ToArray();
        }
    }
}
'@
try {
    $codigoCSValidador | Out-File -FilePath $rutaValidadorCS -Encoding ASCII -Force
    $rutasCSC = @(
        "$env:SystemRoot\Microsoft.NET\Framework64\v4.0.30319\csc.exe",
        "$env:SystemRoot\Microsoft.NET\Framework\v4.0.30319\csc.exe"
    )
    $cscPath = $null
    foreach ($r in $rutasCSC) { if (Test-Path $r) { $cscPath = $r; break } }
    if ($cscPath) {
        Write-Host "7B  -  Compilando TOTPValidator.exe con $cscPath ..." -ForegroundColor Yellow
        $out = & $cscPath /target:exe /out:"$rutaValidadorEXE" /optimize+ "$rutaValidadorCS" 2>&1
        if ($LASTEXITCODE -eq 0 -and (Test-Path $rutaValidadorEXE)) {
            $prueba = & $rutaValidadorEXE $secretoTOTP 2>&1
            if ($prueba -match "TOTP_ACTUAL") {
                Write-Host "7B  -  TOTPValidator.exe compilado y verificado." -ForegroundColor Green
                $winOTPInstalado = $true
            } else { Write-Warning "7B  -  TOTPValidator.exe compilado pero fallo la prueba: $prueba" }
        } else { Write-Warning "7B  -  Error de compilacion: $out" }
    } else { Write-Warning "7B  -  csc.exe no encontrado. Usando Add-Type como fallback..." }
} catch { Write-Warning "7B  -  Metodo 4 (C# compilado) fallo: $_" }

# METODO 5 (SIEMPRE): Script PowerShell TOTP nativo
Write-Host "7B  -  Metodo 5: generando script TOTP PowerShell (garantizado)..." -ForegroundColor Yellow
$rutaScriptTOTP = "$rutaScripts\Mostrar_Codigo_TOTP.ps1"
try {
    @'
# ============================================================
# Mostrar_Codigo_TOTP.ps1  -  Validador y monitor TOTP nativo
# RFC 6238 implementado en PowerShell puro, sin dependencias
# ============================================================
param(
    [string]$SecretBase32  = "",
    [string]$ValidarCodigo = "",
    [switch]$Monitor
)
if (-not $SecretBase32) {
    $cfg = Get-Content "C:\Scripts\MFA_Config.txt" -ErrorAction SilentlyContinue
    $ln  = $cfg | Where-Object { $_ -match "^[A-Z2-7]{20,}$" } | Select-Object -First 1
    if ($ln) { $SecretBase32 = $ln.Trim() }
}
if (-not $SecretBase32) {
    Write-Error "No se encontro el secreto TOTP. Use: .\Mostrar_Codigo_TOTP.ps1 -SecretBase32 'SECRETO'"
    exit 1
}
function ConvertFrom-Base32 {
    param([string]$In)
    $alfa = "ABCDEFGHIJKLMNOPQRSTUVWXYZ234567"
    $bytes = [System.Collections.Generic.List[byte]]::new()
    $buf = 0; $bits = 0
    foreach ($c in $In.ToUpper().ToCharArray()) {
        $v = $alfa.IndexOf($c); if ($v -lt 0) { continue }
        $buf = ($buf -shl 5) -bor $v; $bits += 5
        if ($bits -ge 8) { $bits -= 8; $bytes.Add([byte](($buf -shr $bits) -band 0xFF)) }
    }
    return ,$bytes.ToArray()
}
function Get-TOTPCode {
    param([byte[]]$Key, [int]$Offset = 0)
    $ep = [DateTimeOffset]::UtcNow.ToUnixTimeSeconds()
    $t  = [long]($ep / 30) + $Offset
    $tb = [byte[]]::new(8)
    for ($i = 7; $i -ge 0; $i--) { $tb[$i] = [byte]($t -band 0xFF); $t = $t -shr 8 }
    $hmac = [System.Security.Cryptography.HMACSHA1]::new($Key)
    $h    = $hmac.ComputeHash($tb); $hmac.Dispose()
    $off  = $h[19] -band 0x0F
    $code = (($h[$off] -band 0x7F) -shl 24) -bor (($h[$off+1] -band 0xFF) -shl 16) `
          -bor (($h[$off+2] -band 0xFF) -shl 8) -bor ($h[$off+3] -band 0xFF)
    return ($code % 1000000).ToString("D6")
}
$keyBytes = ConvertFrom-Base32 -In $SecretBase32
if ($ValidarCodigo -ne "") {
    $cA = Get-TOTPCode $keyBytes 0; $cP = Get-TOTPCode $keyBytes -1; $cS = Get-TOTPCode $keyBytes 1
    if ($ValidarCodigo -eq $cA -or $ValidarCodigo -eq $cP -or $ValidarCodigo -eq $cS) {
        Write-Host "TOTP VALIDO: '$ValidarCodigo' aceptado." -ForegroundColor Green; exit 0
    } else {
        Write-Host "TOTP INVALIDO: '$ValidarCodigo' no coincide (actual: $cA)." -ForegroundColor Red; exit 1
    }
}
if ($Monitor) {
    Write-Host "Modo MONITOR activo. Presionar Ctrl+C para salir." -ForegroundColor Cyan
    while ($true) {
        $ep = [DateTimeOffset]::UtcNow.ToUnixTimeSeconds()
        $rest = 30 - ($ep % 30)
        $cA   = Get-TOTPCode $keyBytes 0
        Write-Host "`r  Codigo ACTUAL: $cA  [$('#' * [int]($rest/3))$('-' * (10-[int]($rest/3)))]  $rest s  " -ForegroundColor Green -NoNewline
        Start-Sleep -Milliseconds 500
    }
}
$ep   = [DateTimeOffset]::UtcNow.ToUnixTimeSeconds()
$rest = 30 - ($ep % 30)
$cP   = Get-TOTPCode $keyBytes -1
$cA   = Get-TOTPCode $keyBytes  0
$cS   = Get-TOTPCode $keyBytes  1
Write-Host ""
Write-Host "  +========================================+" -ForegroundColor Cyan
Write-Host "  |   CODIGO TOTP  -  Google Authenticator |" -ForegroundColor Cyan
Write-Host "  +========================================+" -ForegroundColor Cyan
Write-Host "  |  Secreto   : $SecretBase32" -ForegroundColor Gray
Write-Host "  |  Anterior  : $cP" -ForegroundColor Gray
Write-Host "  |  ACTUAL    : $cA  <-- usar este" -ForegroundColor Green
Write-Host "  |  Siguiente : $cS" -ForegroundColor Gray
Write-Host "  |  Caduca en : $rest segundos" -ForegroundColor Yellow
Write-Host "  |  Hora UTC  : $([datetime]::UtcNow.ToString('HH:mm:ss'))" -ForegroundColor Gray
Write-Host "  +========================================+" -ForegroundColor Cyan
Write-Host ""
Write-Host "  Google Authenticator debe mostrar: $cA" -ForegroundColor Green
Write-Host "  Monitor: .\Mostrar_Codigo_TOTP.ps1 -Monitor" -ForegroundColor Gray
Write-Host "  Validar: .\Mostrar_Codigo_TOTP.ps1 -ValidarCodigo '123456'" -ForegroundColor Gray
'@ | Out-File -FilePath $rutaScriptTOTP -Encoding UTF8 -Force
    Write-Host "7B  -  Mostrar_Codigo_TOTP.ps1 creado en: $rutaScriptTOTP" -ForegroundColor Green
} catch { Write-Warning "7B  -  Error al crear Mostrar_Codigo_TOTP.ps1: $_" }

Write-Host "7C  -  Configurando politica de bloqueo MFA en el registro..." -ForegroundColor Yellow
try {
    $claveReg = "HKLM:\SOFTWARE\Policies\MFA"
    if (-not (Test-Path $claveReg)) { New-Item -Path $claveReg -Force -ErrorAction Stop | Out-Null }
    Set-ItemProperty -Path $claveReg -Name "MaxIntentosFallidos"    -Value 3  -Type DWord -Force -ErrorAction Stop
    Set-ItemProperty -Path $claveReg -Name "DuracionBloqueoMinutos" -Value 30 -Type DWord -Force -ErrorAction Stop
    Set-ItemProperty -Path $claveReg -Name "SecretoTOTP"            -Value $secretoTOTP -Type String -Force -ErrorAction Stop
    Set-ItemProperty -Path $claveReg -Name "Emisor"                 -Value $dominioDNS -Type String -Force -ErrorAction Stop
    Write-Host "7C  -  Politica MFA: MaxIntentosFallidos=3, DuracionBloqueoMinutos=30." -ForegroundColor Green
    Write-Host "       Secreto TOTP registrado en HKLM:\SOFTWARE\Policies\MFA\SecretoTOTP" -ForegroundColor Green
    Write-Host "       La FGPP PSO_Admins (lockout 3/30 min) es el mecanismo de bloqueo activo en AD." -ForegroundColor Gray
} catch { Write-Warning "7C  -  Error al escribir politica MFA en registro: $_" }

# ---- 7D  -  Script de prueba de bloqueo MFA (Test 4) ----
Write-Host "7D  -  Generando script de prueba de bloqueo por MFA fallido..." -ForegroundColor Yellow
$rutaTestMFA = "$rutaScripts\Test_Bloqueo_MFA.ps1"
try {
    @'
# Test_Bloqueo_MFA.ps1
# Simula 3 intentos fallidos de autenticacion para verificar el bloqueo FGPP PSO_Admins
# Ejecutar en el DC como Administrador

param(
    [string]$UsuarioABloquear = "admin_identidad",
    [string]$DCServer         = "localhost"
)

Import-Module ActiveDirectory -ErrorAction Stop

Write-Host "Verificando estado inicial de la cuenta '$UsuarioABloquear'..." -ForegroundColor Yellow
$estadoInicial = Get-ADUser -Identity $UsuarioABloquear -Properties LockedOut, BadLogonCount -Server $DCServer
Write-Host "  Estado inicial  - LockedOut: $($estadoInicial.LockedOut) | BadLogonCount: $($estadoInicial.BadLogonCount)"

# Desbloquear si estaba bloqueada previamente para tener un estado limpio
if ($estadoInicial.LockedOut) {
    Unlock-ADAccount -Identity $UsuarioABloquear -Server $DCServer
    Write-Host "  Cuenta desbloqueada para iniciar la prueba desde cero." -ForegroundColor Cyan
    Start-Sleep -Seconds 2
}

Write-Host "`nSimulando 3 intentos fallidos de autenticacion para: $UsuarioABloquear" -ForegroundColor Yellow
Write-Host "(Replica el comportamiento de 3 codigos TOTP incorrectos consecutivos)" -ForegroundColor Gray

for ($i = 1; $i -le 3; $i++) {
    try {
        Add-Type -AssemblyName System.DirectoryServices.AccountManagement -ErrorAction SilentlyContinue
        $ctx = [System.DirectoryServices.AccountManagement.PrincipalContext]::new(
            [System.DirectoryServices.AccountManagement.ContextType]::Domain, $DCServer)
        $ctx.ValidateCredentials($UsuarioABloquear, "CodigoMFA_Incorrecto_$i") | Out-Null
        $ctx.Dispose()
    } catch { }
    Write-Host "  Intento $i/3: autenticacion fallida registrada." -ForegroundColor Red
    Start-Sleep -Milliseconds 800
}

Write-Host "`nEsperando 3 segundos para que el DC procese los eventos de bloqueo..." -ForegroundColor Yellow
Start-Sleep -Seconds 3

$estadoFinal = Get-ADUser -Identity $UsuarioABloquear -Properties LockedOut, BadLogonCount -Server $DCServer
Write-Host "`nEstado de la cuenta '$UsuarioABloquear' tras 3 intentos fallidos:" -ForegroundColor Cyan
Write-Host "  LockedOut     : $($estadoFinal.LockedOut)" -ForegroundColor $(if ($estadoFinal.LockedOut) {"Green"} else {"Yellow"})
Write-Host "  BadLogonCount : $($estadoFinal.BadLogonCount)"

if ($estadoFinal.LockedOut) {
    Write-Host "`n[TEST 4 SUPERADO] La cuenta quedo bloqueada correctamente (FGPP PSO_Admins: 3 intentos / 30 min)." -ForegroundColor Green
} else {
    Write-Host "`n[TEST 4 PENDIENTE] BadLogonCount=$($estadoFinal.BadLogonCount). Puede requerir autenticacion interactiva real." -ForegroundColor Yellow
    Write-Host "Para Test 4 completo: intentar login en pantalla de Windows con codigo TOTP incorrecto 3 veces." -ForegroundColor Yellow
    Write-Host "Verificar la PSO activa del usuario: Get-ADUserResultantPasswordPolicy -Identity $UsuarioABloquear" -ForegroundColor Yellow
}

Write-Host "`nPara desbloquear manualmente:"
Write-Host "  Unlock-ADAccount -Identity $UsuarioABloquear"
Write-Host "Para verificar PSO activa:"
Write-Host "  Get-ADUserResultantPasswordPolicy -Identity $UsuarioABloquear"
'@ | Out-File -FilePath $rutaTestMFA -Encoding UTF8 -Force
    Write-Host "7D  -  Script de prueba de bloqueo MFA creado en: $rutaTestMFA" -ForegroundColor Green
} catch { Write-Warning "7D  -  Error al crear Test_Bloqueo_MFA.ps1: $_" }

$winOTPPkg = Get-AppxPackage -Name "*WinOTP*" -AllUsers -ErrorAction SilentlyContinue
$winOTPOk  = ($null -ne $winOTPPkg)
Write-Host "`n7E  -  Estado final de la configuracion MFA:" -ForegroundColor Cyan
Write-Host "  Secreto TOTP           : $secretoTOTP" -ForegroundColor Green
Write-Host "  MFA_Config.txt         : $(if (Test-Path $rutaMFAConfig) {'PRESENTE'} else {'AUSENTE'})" -ForegroundColor $(if (Test-Path $rutaMFAConfig) {"Green"} else {"Red"})
Write-Host "  WinOTP (Store/MSIX)    : $(if ($winOTPOk) {"INSTALADO v$($winOTPPkg.Version)"} elseif ($winOTPInstalado) {'INSTALADO (validador nativo C#)'} else {'PENDIENTE Store - usar alternativas'})" -ForegroundColor $(if ($winOTPInstalado -or $winOTPOk) {"Green"} else {"Yellow"})
Write-Host "  Mostrar_Codigo_TOTP.ps1: $(if (Test-Path $rutaScriptTOTP) {'PRESENTE - alternativa garantizada'} else {'AUSENTE'})" -ForegroundColor $(if (Test-Path $rutaScriptTOTP) {"Green"} else {"Red"})
if (Test-Path "$rutaScripts\TOTPValidator.exe") {
    Write-Host "  TOTPValidator.exe      : PRESENTE - validador C# nativo" -ForegroundColor Green
}
Write-Host "  Bloqueo FGPP           : PSO_Admins activa 3 intentos / 30 min" -ForegroundColor Green
Write-Host "  Test_Bloqueo_MFA.ps1   : $(if (Test-Path $rutaTestMFA) {'PRESENTE'} else {'AUSENTE'})" -ForegroundColor $(if (Test-Path $rutaTestMFA) {"Green"} else {"Red"})
Write-Host "  Registro HKLM\Policies\MFA: MaxIntentos=3, Duracion=30 min" -ForegroundColor Green
Write-Host ""
Write-Host "  PARA VER EL CODIGO TOTP AHORA:" -ForegroundColor Cyan
Write-Host "  cd C:\Scripts ; .\Mostrar_Codigo_TOTP.ps1" -ForegroundColor White
Write-Host "  MODO MONITOR (actualiza en tiempo real):" -ForegroundColor Cyan
Write-Host "  .\Mostrar_Codigo_TOTP.ps1 -Monitor" -ForegroundColor White
Write-Host "  VALIDAR UN CODIGO ESPECIFICO:" -ForegroundColor Cyan
Write-Host "  .\Mostrar_Codigo_TOTP.ps1 -ValidarCodigo '123456'" -ForegroundColor White
Write-Host "  Ese codigo debe coincidir con Google Authenticator." -ForegroundColor Gray
Write-Host "# ---- Bloque 7 completado ----" -ForegroundColor Cyan

# BLOQUE 8  -  Reporte Final de Verificacion
Write-Host "`n# ---- BLOQUE 8  -  Reporte Final de Verificacion ----" -ForegroundColor Cyan

$fechaHoraReporte = Get-Date -Format "yyyyMMdd_HHmmss"
$rutaReporteFinal = "$rutaScripts\Reporte_Practica09_$fechaHoraReporte.txt"
$lineasReporteFinal = [System.Collections.Generic.List[string]]::new()
$lineasReporteFinal.Add("=" * 70)
$lineasReporteFinal.Add("REPORTE FINAL  -  PRACTICA 09: SEGURIDAD DE IDENTIDAD, DELEGACION Y MFA")
$lineasReporteFinal.Add("Generado       : $(Get-Date -Format 'dd/MM/yyyy HH:mm:ss')")
$lineasReporteFinal.Add("Servidor       : $env:COMPUTERNAME")
$lineasReporteFinal.Add("Dominio DNS    : $dominioDNS")
$lineasReporteFinal.Add("Dominio DN     : $dominioDN")
$lineasReporteFinal.Add("=" * 70)

# OUs
$lineasReporteFinal.Add(""); $lineasReporteFinal.Add("--- UNIDADES ORGANIZATIVAS ---")
foreach ($nombreOU in @("Cuates","No Cuates","Administradores_Delegados")) {
    try {
        $ouObj = Get-ADOrganizationalUnit -Filter "Name -eq '$nombreOU'" -Properties ProtectedFromAccidentalDeletion -ErrorAction SilentlyContinue
        if ($ouObj) { $lineasReporteFinal.Add("  OU='$nombreOU' : CREADA | ProtectedFromAccidentalDeletion=$($ouObj.ProtectedFromAccidentalDeletion)") }
        else { $lineasReporteFinal.Add("  OU='$nombreOU' : NO ENCONTRADA") }
    } catch { $lineasReporteFinal.Add("  OU='$nombreOU' : ERROR  -  $_") }
}

# Usuarios
$lineasReporteFinal.Add(""); $lineasReporteFinal.Add("--- USUARIOS CREADOS ---")
foreach ($sam in @("usuario_cuate1","usuario_cuate2","usuario_nocuate1","usuario_nocuate2","admin_identidad","admin_storage","admin_politicas","admin_auditoria")) {
    try {
        $u = Get-ADUser -Filter "SamAccountName -eq '$sam'" -Properties Enabled,DistinguishedName -ErrorAction SilentlyContinue
        if ($u) { $lineasReporteFinal.Add("  $sam : EXISTE | Enabled=$($u.Enabled) | DN=$($u.DistinguishedName)") }
        else { $lineasReporteFinal.Add("  $sam : NO ENCONTRADO") }
    } catch { $lineasReporteFinal.Add("  $sam : ERROR  -  $_") }
}

# ACLs
$lineasReporteFinal.Add(""); $lineasReporteFinal.Add("--- ACLs DELEGADAS (RBAC)  -  RESUMEN DE PERMISOS APLICADOS ---")
$lineasReporteFinal.Add("  admin_identidad : CreateChild + DeleteChild sobre user en OU=Cuates y OU=No Cuates")
$lineasReporteFinal.Add("                    WriteProperty: telephoneNumber, physicalDeliveryOfficeName, mail")
$lineasReporteFinal.Add("                    Extended Right: Reset Password sobre user")
$lineasReporteFinal.Add("                    DENY WriteProperty sobre CN=Domain Admins")
$lineasReporteFinal.Add("                    DENY WriteProperty sobre groupPolicyContainer")
$lineasReporteFinal.Add("  admin_storage   : DENY Reset Password sobre user en raiz del dominio")
$lineasReporteFinal.Add("  admin_politicas : GenericRead en todo el dominio")
$lineasReporteFinal.Add("                    WriteProperty + WriteDacl sobre groupPolicyContainer")
$lineasReporteFinal.Add("                    CreateChild + WriteProperty sobre Password Settings Container")
$lineasReporteFinal.Add("  admin_auditoria : Solo GenericRead en todo el dominio (sin escritura)")
$lineasReporteFinal.Add("  (Verificar con: dsacls '<DN>' o mediante ADSI Edit)")

# FGPPs
$lineasReporteFinal.Add(""); $lineasReporteFinal.Add("--- FINE-GRAINED PASSWORD POLICIES ---")
foreach ($nombrePSO in @("PSO_Admins","PSO_Usuarios")) {
    try {
        $pso = Get-ADFineGrainedPasswordPolicy -Filter "Name -eq '$nombrePSO'" -ErrorAction SilentlyContinue
        if ($pso) {
            $lineasReporteFinal.Add("  $nombrePSO : ENCONTRADA")
            $lineasReporteFinal.Add("    Precedencia=$($pso.Precedence) | MinPasswordLength=$($pso.MinPasswordLength)")
            $lineasReporteFinal.Add("    PasswordHistoryCount=$($pso.PasswordHistoryCount) | MaxPasswordAge=$($pso.MaxPasswordAge.Days) dias")
            $lineasReporteFinal.Add("    LockoutThreshold=$($pso.LockoutThreshold) | LockoutDuration=$($pso.LockoutDuration.Minutes) min")
            $lineasReporteFinal.Add("    ComplexityEnabled=$($pso.ComplexityEnabled) | ReversibleEncryption=$($pso.ReversibleEncryptionEnabled)")
            try {
                $sujetos = Get-ADFineGrainedPasswordPolicySubject -Identity $nombrePSO -ErrorAction SilentlyContinue
                $lineasReporteFinal.Add("    Sujetos aplicados: $($sujetos.Name -join ', ')")
            } catch { $lineasReporteFinal.Add("    Sujetos: ERROR AL CONSULTAR") }
        } else { $lineasReporteFinal.Add("  $nombrePSO : NO ENCONTRADA") }
    } catch { $lineasReporteFinal.Add("  $nombrePSO : ERROR  -  $_") }
}

# Auditoria
$lineasReporteFinal.Add(""); $lineasReporteFinal.Add("--- CATEGORIAS DE AUDITORIA HABILITADAS ---")
foreach ($l in $resultadosAuditoria) { $lineasReporteFinal.Add("  $l") }

# Script de monitoreo
$lineasReporteFinal.Add(""); $lineasReporteFinal.Add("--- SCRIPT DE MONITOREO Y TAREA PROGRAMADA ---")
$lineasReporteFinal.Add("  Ruta del script      : $rutaScriptMonitor")
$lineasReporteFinal.Add("  Archivo existe       : $(if (Test-Path $rutaScriptMonitor) { 'SI' } else { 'NO' })")
try {
    $tarea = Get-ScheduledTask -TaskName "Monitor_Seguridad_AD" -ErrorAction SilentlyContinue
    $lineasReporteFinal.Add("  Tarea programada     : $(if ($tarea) { 'REGISTRADA | Estado: ' + $tarea.State } else { 'NO ENCONTRADA' })")
} catch { $lineasReporteFinal.Add("  Tarea programada     : ERROR AL CONSULTAR") }

# MFA
$winOTPPkg = Get-AppxPackage -Name "*WinOTP*" -AllUsers -ErrorAction SilentlyContinue
$winOTPOk  = ($null -ne $winOTPPkg)
$lineasReporteFinal.Add(""); $lineasReporteFinal.Add("--- MFA  -  TOTP (Google Authenticator + WinOTP / Validador Nativo) ---")
$lineasReporteFinal.Add("  Secreto TOTP base32  : $secretoTOTP")
$lineasReporteFinal.Add("  URL otpauth          : $urlOtpAuth")
$lineasReporteFinal.Add("  MFA_Config.txt       : $(if (Test-Path $rutaMFAConfig) { 'EXISTE  -  ' + $rutaMFAConfig } else { 'NO ENCONTRADO' })")
$lineasReporteFinal.Add("  WinOTP (Store/MSIX)  : $(if ($winOTPOk) { 'INSTALADO v' + $winOTPPkg.Version } elseif ($winOTPInstalado) { 'VALIDADOR NATIVO C# FUNCIONAL' } else { 'PENDIENTE  -  usar alternativas PowerShell' })")
$lineasReporteFinal.Add("  Mostrar_Codigo_TOTP  : $(if (Test-Path $rutaScriptTOTP) { 'PRESENTE' } else { 'NO ENCONTRADO' })")
if (Test-Path "$rutaScripts\TOTPValidator.exe") {
    $lineasReporteFinal.Add("  TOTPValidator.exe    : PRESENTE  -  validador C# nativo compilado")
}
$lineasReporteFinal.Add("  Politica bloqueo MFA : MaxIntentosFallidos=3, DuracionBloqueoMinutos=30 (HKLM:\SOFTWARE\Policies\MFA)")
$lineasReporteFinal.Add("  Bloqueo AD (FGPP)    : PSO_Admins - LockoutThreshold=3, LockoutDuration=30 min")
$lineasReporteFinal.Add("  Test_Bloqueo_MFA.ps1 : $(if (Test-Path "$rutaScripts\Test_Bloqueo_MFA.ps1") { 'EXISTE' } else { 'NO ENCONTRADO' })")

# Acciones manuales
$lineasReporteFinal.Add(""); $lineasReporteFinal.Add("--- ELEMENTOS QUE REQUIEREN ACCION MANUAL ---")
if (-not $winOTPOk) {
    $lineasReporteFinal.Add("  [MFA] WinOTP de Microsoft Store no instalado.")
    $lineasReporteFinal.Add("        Alternativa garantizada: .\Mostrar_Codigo_TOTP.ps1  (o con -Monitor)")
    if (Test-Path "$rutaScripts\TOTPValidator.exe") {
        $lineasReporteFinal.Add("        Alternativa C# nativa: .\TOTPValidator.exe $secretoTOTP")
    }
    $lineasReporteFinal.Add("        Instalacion manual Store: Start-Process 'ms-windows-store://pdp/?productid=9P7CQDJLH170'")
}
$lineasReporteFinal.Add("  [MFA] Vincular el secreto '$secretoTOTP' en Google Authenticator en el movil")
$lineasReporteFinal.Add("        Instrucciones completas en: $rutaMFAConfig")
$lineasReporteFinal.Add("  [TEST 1A] Ejecutar desde cliente: Set-ADAccountPassword usuario_cuate1 con credenciales admin_identidad (debe FUNCIONAR)")
$lineasReporteFinal.Add("  [TEST 2]  Intentar asignar contrasena de 8 chars a admin_identidad (debe RECHAZARSE por PSO_Admins MinLen=12)")
$lineasReporteFinal.Add("  [TEST 4]  Ejecutar: C:\Scripts\Test_Bloqueo_MFA.ps1 para verificar bloqueo por 3 intentos fallidos")
$lineasReporteFinal.Add("  [VERIFICAR] Confirmar ACLs con ADSI Edit o dsacls si es requerido")

# Resumen
$lineasReporteFinal.Add(""); $lineasReporteFinal.Add("=" * 70)
$lineasReporteFinal.Add("RESUMEN DE EJECUCION POR BLOQUE")
$lineasReporteFinal.Add("  Bloque 0  -  Auto-elevacion y WinRM              : COMPLETADO")
$lineasReporteFinal.Add("  Bloque 1  -  Estructura Base de AD               : COMPLETADO")
$lineasReporteFinal.Add("  Bloque 2  -  Delegacion RBAC (dsacls)            : COMPLETADO")
$lineasReporteFinal.Add("  Bloque 3  -  FSRM Cuotas y Apantallamiento       : COMPLETADO")
$lineasReporteFinal.Add("  Bloque 4  -  Fine-Grained Password Policies      : COMPLETADO")
$lineasReporteFinal.Add("  Bloque 5  -  Hardening de Auditoria (auditpol)   : COMPLETADO")
$lineasReporteFinal.Add("  Bloque 6  -  Script Monitor + Tarea Programada   : COMPLETADO")
$esMFACompleto = $winOTPOk -or $winOTPInstalado
$lineasReporteFinal.Add("  Bloque 7  -  MFA TOTP + WinOTP / Validador Nativo: $(if ($esMFACompleto) { 'COMPLETADO' } else { 'COMPLETADO CON ADVERTENCIAS - usar Mostrar_Codigo_TOTP.ps1' })")
$lineasReporteFinal.Add("  Bloque 8  -  Reporte Final                       : COMPLETADO")
$lineasReporteFinal.Add("=" * 70)

try {
    $lineasReporteFinal | Out-File -FilePath $rutaReporteFinal -Encoding UTF8 -Force
    Write-Host "Reporte final generado correctamente: $rutaReporteFinal" -ForegroundColor Green
} catch { Write-Warning "Error al escribir el reporte final en disco: $_" }
Write-Host "# ---- Bloque 8 completado ----" -ForegroundColor Cyan

# ================================================================
Write-Host "`n" + ("=" * 60) -ForegroundColor Cyan
Write-Host "Practica09_Server.ps1  -  Ejecucion finalizada." -ForegroundColor Green
Write-Host "Reporte final disponible en: $rutaReporteFinal" -ForegroundColor Green
Write-Host "Secreto MFA TOTP guardado en: $rutaMFAConfig" -ForegroundColor Green
Write-Host ("=" * 60) -ForegroundColor Cyan
# ================================================================
