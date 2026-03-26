[CmdletBinding()]
param([switch]$Menu)

Set-ExecutionPolicy Bypass -Scope Process -Force
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

# CONFIGURACION
$DomainName        = 'lab.local'
$DCIp              = '192.168.100.1'
$SafeModePwd       = 'P@ssw0rd123!'
$CsvPath           = 'C:\Lab\usuarios.csv'
$UsersBasePath     = 'C:\Carpetas'
$QuotaCuatesMB     = 10
$QuotaNoCuatesMB   = 5
$BlockedExtensions = @('*.mp3','*.mp4','*.exe','*.msi','*.bat','*.vbs')
$OUCuates          = 'OU=Cuates,DC=lab,DC=local'
$OUNoCuates        = 'OU=NoCuates,DC=lab,DC=local'
$GrupoCuates       = 'GRP-Cuates'
$GrupoNoCuates     = 'GRP-NoCuates'
$GPOHorarios       = 'GPO-LogonHours'
$GPOAppLocker      = 'GPO-AppLocker'
$DomainDN          = 'DC=lab,DC=local'

$SEP = '=' * 50
$script:Exitosos = 0
$script:Omitidos = 0
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

function Import-FsrmModuloRobust {
    $nombres = @('FileServerResourceManager','FSRM','FSRMModule')
    foreach ($nombre in $nombres) {
        try {
            Import-Module $nombre -Force -ErrorAction Stop
            if (Get-Command Get-FsrmQuota -ErrorAction SilentlyContinue) {
                Write-OK "Modulo FSRM cargado como '$nombre'."
                return $true
            }
        } catch { }
    }
    if (Get-Command Get-FsrmQuota -ErrorAction SilentlyContinue) {
        Write-OK 'Cmdlets FSRM disponibles directamente (sin import).'
        return $true
    }
    return $false
}

# FASE DC - Promocion como Domain Controller
function Invoke-FaseDC {
    Write-Fase 'FASE DC: Comprobacion y promocion como Domain Controller'

    $domainRole = (Get-WmiObject Win32_ComputerSystem).DomainRole
    if ($domainRole -ge 4) {
        Write-OK 'El servidor ya es Domain Controller. Se omite esta fase.'
        return $false
    }

    Write-Warn 'El servidor NO es DC todavia. Iniciando promocion automatica...'

    # Configurar IP estatica en el adaptador activo
    Write-Info "Configurando IP estatica $DCIp..."
    try {
        $adp = Get-NetAdapter | Where-Object { $_.Status -eq 'Up' } | Select-Object -First 1
        $cur = (Get-NetIPAddress -InterfaceIndex $adp.ifIndex -AddressFamily IPv4 -ErrorAction SilentlyContinue).IPAddress
        if ($cur -ne $DCIp) {
            Remove-NetIPAddress -InterfaceIndex $adp.ifIndex -AddressFamily IPv4 -Confirm:$false -ErrorAction SilentlyContinue
            Remove-NetRoute     -InterfaceIndex $adp.ifIndex -AddressFamily IPv4 -Confirm:$false -ErrorAction SilentlyContinue
            New-NetIPAddress -InterfaceIndex $adp.ifIndex -IPAddress $DCIp -PrefixLength 24 `
                -DefaultGateway ($DCIp -replace '\d+$', '254') -ErrorAction Stop | Out-Null
            Set-DnsClientServerAddress -InterfaceIndex $adp.ifIndex -ServerAddresses '127.0.0.1' | Out-Null
            Write-OK "IP estatica $DCIp configurada. DNS -> 127.0.0.1"
        } else { Write-Warn "IP $DCIp ya estaba configurada." }
    } catch { Write-Warn "No se pudo configurar IP automaticamente: $_" }

    # Instalar rol AD DS
    Write-Info 'Instalando rol AD-Domain-Services...'
    $feat = Install-WindowsFeature -Name AD-Domain-Services -IncludeManagementTools -Restart:$false -Confirm:$false
    if (-not ($feat.Success -or $feat.ExitCode -eq 'NoChangeNeeded')) {
        Write-Err 'Fallo la instalacion del rol AD DS. Revisa el Event Log.'
        return $false
    }
    Write-OK 'Rol AD DS listo.'

    # Promover como primer DC del bosque
    Write-Info "Promoviendo como primer DC de '$DomainName'..."
    Write-Info '(La VM se reiniciara automaticamente al terminar)'
    try {
        Import-Module ADDSDeployment -Force -ErrorAction Stop
        $dsrmPwd = ConvertTo-SecureString $SafeModePwd -AsPlainText -Force
        Install-ADDSForest `
            -DomainName                    $DomainName `
            -DomainNetbiosName             ($DomainName.Split('.')[0].ToUpper()) `
            -SafeModeAdministratorPassword $dsrmPwd `
            -InstallDns `
            -NoDnsOnNetwork `
            -CreateDnsDelegation:$false `
            -DatabasePath                  'C:\Windows\NTDS' `
            -LogPath                       'C:\Windows\NTDS' `
            -SysvolPath                    'C:\Windows\SYSVOL' `
            -Force `
            -Confirm:$false
        Restart-Computer -Force
    } catch {
        Write-Err "Error durante la promocion: $_"
    }
    return $true
}

# Funcion auxiliar: verificar que ADWS este respondiendo.
function Test-ADWSDisponible {
    try {
        $null = Get-ADDomain -ErrorAction Stop
        return $true
    } catch {
        Write-Host ''
        Write-Host '  ╔══════════════════════════════════════════════════════════════╗' -ForegroundColor Red
        Write-Host '  ║  ERROR: Active Directory Web Services no responde.           ║' -ForegroundColor Red
        Write-Host '  ║                                                              ║' -ForegroundColor Red
        Write-Host '  ║  Posibles causas:                                            ║' -ForegroundColor Red
        Write-Host '  ║  1. El servidor NO esta promovido como DC todavia.           ║' -ForegroundColor Red
        Write-Host '  ║     -> Ejecuta el script SIN argumentos por primera vez.    ║' -ForegroundColor Red
        Write-Host '  ║  2. El servicio ADWS no ha arrancado tras el reinicio.       ║' -ForegroundColor Red
        Write-Host '  ║     -> Espera 1-2 min y vuelve a ejecutar.                  ║' -ForegroundColor Red
        Write-Host '  ║  3. La IP del DC no es la correcta ($DCIp).                 ║' -ForegroundColor Red
        Write-Host '  ╚══════════════════════════════════════════════════════════════╝' -ForegroundColor Red
        Write-Host ''
        return $false
    }
}

# FASE 0 - Inicializacion
function Invoke-Fase0 {
    Write-Fase 'FASE 0: Inicializacion y modulos'

    $features = @(
        'AD-Domain-Services',
        'FS-Resource-Manager',
        'RSAT-AD-PowerShell',
        'GPMC'
    )

    Write-Info 'Verificando e instalando roles necesarios...'
    $result = Install-WindowsFeature -Name $features `
        -IncludeManagementTools -Restart:$false -Confirm:$false

    if ($result.RestartNeeded -eq 'Yes') {
        Write-Warn 'Se requiere reinicio para activar los roles.'
        Write-Warn 'Reiniciando en 10 segundos. Vuelve a ejecutar el script despues.'
        Start-Sleep -Seconds 10
        Restart-Computer -Force
        exit
    }
    Write-OK 'Roles verificados. No se requiere reinicio.'

    # Modulos criticos: AD y GroupPolicy
    $modulosCriticos = @('ActiveDirectory','GroupPolicy')
    $faltanCriticos  = @()

    foreach ($mod in $modulosCriticos) {
        try {
            Import-Module $mod -Force -ErrorAction Stop -WarningAction SilentlyContinue
            Write-OK "Modulo '$mod' cargado."
        } catch {
            Write-Err "Modulo critico '$mod' no disponible: $_"
            $faltanCriticos += $mod
        }
    }

    if ($faltanCriticos.Count -gt 0) {
        Write-Host ''
        Write-Host '  ╔══════════════════════════════════════════════════════╗' -ForegroundColor Red
        Write-Host '  ║  REINICIA EL SERVIDOR y vuelve a ejecutar.          ║' -ForegroundColor Red
        Write-Host "  ║  Faltan: $($faltanCriticos -join ', ')$('' * (40 - ($faltanCriticos -join ', ').Length))║" -ForegroundColor Red
        Write-Host '  ╚══════════════════════════════════════════════════════╝' -ForegroundColor Red
        exit 1
    }

    # FSRMModule
    $fsrmOk = Import-FsrmModuloRobust
    if (-not $fsrmOk) {
        Write-Warn 'FSRM se intentara cargar en Fase 3. Si falla, verifica que el rol FS-Resource-Manager este instalado.'
    }

    $fecha = Get-Date -Format 'dd/MM/yyyy HH:mm'
    Write-Banner "Gobernanza, Cuotas y Control de Aplicaciones`n  Servidor : $env:COMPUTERNAME`n  Dominio  : $DomainName`n  Fecha    : $fecha"
    $script:Exitosos++
}

# FASE 1 - Estructura organizativa
function Invoke-Fase1 {
    Write-Fase 'FASE 1: Estructura organizativa - OUs, grupos y usuarios'

    foreach ($ou in @(
        @{Name='Cuates';   Path=$DomainDN},
        @{Name='NoCuates'; Path=$DomainDN}
    )) {
        try {
            New-ADOrganizationalUnit -Name $ou.Name -Path $ou.Path `
                -ProtectedFromAccidentalDeletion $false -Confirm:$false -ErrorAction Stop
            Write-OK "OU '$($ou.Name)' creada."
            $script:Exitosos++
        } catch {
            if ($_.Exception.Message -match 'already exists|ya existe|already in use') {
                Write-Warn "OU '$($ou.Name)' ya existe, se omite."
                $script:Omitidos++
            } else {
                Write-Err "Error creando OU '$($ou.Name)': $_"
                $script:Fallidos++
            }
        }
    }

    foreach ($grp in @(
        @{Name=$GrupoCuates;   Path=$OUCuates},
        @{Name=$GrupoNoCuates; Path=$OUNoCuates}
    )) {
        try {
            New-ADGroup -Name $grp.Name -GroupScope Global -GroupCategory Security `
                -Path $grp.Path -Confirm:$false -ErrorAction Stop
            Write-OK "Grupo '$($grp.Name)' creado."
            $script:Exitosos++
        } catch {
            if ($_.Exception.Message -match 'already exists|ya existe') {
                Write-Warn "Grupo '$($grp.Name)' ya existe, se omite."
                $script:Omitidos++
            } else {
                Write-Err "Error creando grupo '$($grp.Name)': $_"
                $script:Fallidos++
            }
        }
    }

    if (-not (Test-Path $CsvPath)) {
        Write-Err "No se encuentra el CSV: $CsvPath"
        $script:Fallidos++
        return
    }

    $usuarios = Import-Csv -Path $CsvPath -Encoding UTF8
    $total    = $usuarios.Count
    $i        = 0

    foreach ($u in $usuarios) {
        $i++
        Write-Progress -Activity 'Creando usuarios' `
            -Status "[$i/$total] $($u.Nombre) $($u.Apellido)" `
            -PercentComplete (($i / $total) * 100)
        Write-Info "[$i/$total] Creando usuario $($u.Nombre) $($u.Apellido)..."

        $ouPath = if ($u.Departamento -eq 'Cuates') { $OUCuates } else { $OUNoCuates }
        $grupo  = if ($u.Departamento -eq 'Cuates') { $GrupoCuates } else { $GrupoNoCuates }
        $secPwd = ConvertTo-SecureString $u.Contrasena -AsPlainText -Force

        try {
            New-ADUser `
                -Name              "$($u.Nombre) $($u.Apellido)" `
                -GivenName         $u.Nombre `
                -Surname           $u.Apellido `
                -SamAccountName    $u.Usuario `
                -UserPrincipalName "$($u.Usuario)@$DomainName" `
                -AccountPassword   $secPwd `
                -Enabled           $true `
                -Path              $ouPath `
                -Department        $u.Departamento `
                -Confirm:$false `
                -ErrorAction       Stop
            Add-ADGroupMember -Identity $grupo -Members $u.Usuario -Confirm:$false
            Write-OK "Usuario '$($u.Usuario)' creado en $($u.Departamento)."
            $script:Exitosos++
        } catch {
            if ($_.Exception.Message -match 'already exists|ya existe') {
                Write-Warn "Usuario '$($u.Usuario)' ya existe, se omite."
                $script:Omitidos++
            } else {
                Write-Err "Error al crear '$($u.Usuario)': $_"
                $script:Fallidos++
            }
        }
    }
    Write-Progress -Activity 'Creando usuarios' -Completed

    Write-Info '-- Verificacion: usuarios en OUs --'
    foreach ($ou in @($OUCuates, $OUNoCuates)) {
        $count = (Get-ADUser -Filter * -SearchBase $ou -ErrorAction SilentlyContinue | Measure-Object).Count
        Write-Info "  $ou --> $count usuario(s)"
    }
}

# FASE 2 - Logon Hours
function Build-LogonHoursArray {
    param([int]$StartHour, [int]$EndHour, [int[]]$WeekDays)
    $bytes = New-Object byte[] 21
    $utcOffset = 6
    foreach ($day in $WeekDays) {
        $startUtc = ($StartHour + $utcOffset) % 24
        $endUtc   = ($EndHour   + $utcOffset) % 24
        for ($h = 0; $h -lt 24; $h++) {
            $active = if ($startUtc -le $endUtc) {
                ($h -ge $startUtc -and $h -lt $endUtc)
            } else {
                ($h -ge $startUtc -or $h -lt $endUtc)
            }
            if ($active) {
                $byteIndex = $day * 3 + [math]::Floor($h / 8)
                $bitPos    = $h % 8
                $bytes[$byteIndex] = $bytes[$byteIndex] -bor (1 -shl $bitPos)
            }
        }
    }
    return $bytes
}

function Invoke-Fase2 {
    Write-Fase 'FASE 2: Logon Hours - restriccion de horarios'

    $horaCuates = Build-LogonHoursArray -StartHour 8  -EndHour 15 -WeekDays @(1,2,3,4,5)
    $horaNoC    = Build-LogonHoursArray -StartHour 15 -EndHour 2  -WeekDays @(1,2,3,4,5)

    foreach ($grpInfo in @(
        @{Grupo=$GrupoCuates;   Horas=$horaCuates; Desc='Lun-Vie 08:00-15:00'},
        @{Grupo=$GrupoNoCuates; Horas=$horaNoC;    Desc='Lun-Vie 15:00-02:00'}
    )) {
        Write-Info "Aplicando horario '$($grpInfo.Desc)' al grupo $($grpInfo.Grupo)..."
        $miembros = Get-ADGroupMember -Identity $grpInfo.Grupo -ErrorAction SilentlyContinue
        $count = 0
        foreach ($m in $miembros) {
            try {
                [byte[]]$horasByte = $grpInfo.Horas
                Set-ADUser -Identity $m.SamAccountName `
                    -OtherAttributes @{'logonHours' = $horasByte} `
                    -ErrorAction Stop
                $count++
            } catch {
                Write-Err "Error en $($m.SamAccountName): $_"
                $script:Fallidos++
            }
        }
        Write-OK "$count usuario(s) del grupo $($grpInfo.Grupo) actualizados."
        $script:Exitosos++
    }

    try {
        $gpo = Get-GPO -Name $GPOHorarios -ErrorAction SilentlyContinue
        if (-not $gpo) {
            $gpo = New-GPO -Name $GPOHorarios -Comment 'Restriccion de horarios' -Confirm:$false
            Write-OK "GPO '$GPOHorarios' creada."
        } else {
            Write-Warn "GPO '$GPOHorarios' ya existe, actualizando..."
        }
        Set-GPRegistryValue -Name $GPOHorarios `
            -Key 'HKLM\System\CurrentControlSet\Services\LanManServer\Parameters' `
            -ValueName 'EnableForcedLogOff' -Type DWord -Value 1 -Confirm:$false | Out-Null
        New-GPLink -Name $GPOHorarios -Target $DomainDN `
            -Enforced Yes -LinkEnabled Yes -Confirm:$false -ErrorAction SilentlyContinue | Out-Null
        Write-OK "GPO '$GPOHorarios' vinculada con Enforced."
        $script:Exitosos++
    } catch {
        Write-Err "Error configurando GPO de horarios: $_"
        $script:Fallidos++
    }

    Write-Info '-- Verificacion: LogonHours --'
    $mC  = (Get-ADGroupMember $GrupoCuates  -ErrorAction SilentlyContinue | Select-Object -First 1).SamAccountName
    $mNC = (Get-ADGroupMember $GrupoNoCuates -ErrorAction SilentlyContinue | Select-Object -First 1).SamAccountName
    foreach ($sam in @($mC, $mNC)) {
        if ($sam) {
            $u = Get-ADUser $sam -Properties logonHours -ErrorAction SilentlyContinue
            $lh = $u.logonHours
            if ($lh -and $lh.Count -gt 0) {
                Write-Info "  $sam --> bytes[0-5]: $($lh[0..5] -join ',')"
            } else {
                try {
                    $dn   = $u.DistinguishedName
                    $adsi = [adsi]"LDAP://$dn"
                    $lhRaw = $adsi.logonHours.Value
                    if ($lhRaw) {
                        Write-Info "  $sam --> bytes[0-5] (ADSI): $($lhRaw[0..5] -join ',')"
                    } else {
                        Write-Warn "  $sam --> LogonHours vacio (sin restriccion)."
                    }
                } catch {
                    Write-Warn "  $sam --> No se pudo leer LogonHours."
                }
            }
        }
    }
}

# FASE 3 - FSRM
function Invoke-Fase3 {
    Write-Fase 'FASE 3: FSRM - Cuotas de disco y apantallamiento de archivos'

    $fsrmOk = Import-FsrmModuloRobust
    if (-not $fsrmOk) {
        Write-Err 'No se encontraron los cmdlets FSRM.'
        Write-Err 'Verifica que el rol FS-Resource-Manager este instalado y reinicia el servidor.'
        $script:Fallidos++
        return
    }

    Write-Info 'Verificando servicio FSRM (SrmSvc)...'
    try {
        $svc = Get-Service -Name SrmSvc -ErrorAction Stop
        if ($svc.Status -ne 'Running') {
            Start-Service -Name SrmSvc -ErrorAction Stop
            Start-Sleep -Seconds 3
            Write-OK 'Servicio SrmSvc iniciado.'
        } else {
            # Reiniciar para forzar re-registro del provider CIM
            Restart-Service -Name SrmSvc -Force -ErrorAction SilentlyContinue
            Start-Sleep -Seconds 3
            Write-OK 'Servicio SrmSvc reiniciado (provider CIM refrescado).'
        }
    } catch {
        Write-Warn "No se pudo gestionar SrmSvc: $_"
        Write-Warn 'Continuando de todas formas...'
    }

    if (-not (Test-Path $UsersBasePath)) {
        New-Item -ItemType Directory -Path $UsersBasePath -Force | Out-Null
        Write-OK "Carpeta raiz creada: $UsersBasePath"
    }

    try {
        $fg = Get-FsrmFileGroup -Name 'Archivos-Bloqueados' -ErrorAction SilentlyContinue
        if ($fg) {
            Set-FsrmFileGroup -Name 'Archivos-Bloqueados' -IncludePattern $BlockedExtensions -Confirm:$false | Out-Null
            Write-Warn 'FsrmFileGroup actualizado.'
        } else {
            New-FsrmFileGroup -Name 'Archivos-Bloqueados' -IncludePattern $BlockedExtensions -Confirm:$false | Out-Null
            Write-OK 'FsrmFileGroup creado.'
        }
        $script:Exitosos++
    } catch {
        Write-Err "Error FsrmFileGroup: $_"
        $script:Fallidos++
    }

    $limCuatesB   = [long]($QuotaCuatesMB   * 1MB)
    $limNoCuatesB = [long]($QuotaNoCuatesMB * 1MB)

    foreach ($tmpl in @(
        @{Name='Cuota-Cuates-10MB';  Limit=$limCuatesB;   MB=$QuotaCuatesMB},
        @{Name='Cuota-NoCuates-5MB'; Limit=$limNoCuatesB; MB=$QuotaNoCuatesMB}
    )) {
        try {
            if (-not (Get-FsrmQuotaTemplate -Name $tmpl.Name -ErrorAction SilentlyContinue)) {
                New-FsrmQuotaTemplate -Name $tmpl.Name -Size $tmpl.Limit -SoftLimit:$false -Confirm:$false | Out-Null
                Write-OK "Plantilla '$($tmpl.Name)' creada ($($tmpl.MB) MB)."
            } else {
                Write-Warn "Plantilla '$($tmpl.Name)' ya existe."
            }
        } catch { Write-Err "Error plantilla '$($tmpl.Name)': $_" }
    }

    $usuarios = Import-Csv -Path $CsvPath -Encoding UTF8
    $total    = $usuarios.Count
    $i        = 0

    foreach ($u in $usuarios) {
        $i++
        Write-Progress -Activity 'Configurando FSRM' `
            -Status "[$i/$total] $($u.Usuario)" `
            -PercentComplete (($i / $total) * 100)
        Write-Info "[$i/$total] Configurando '$($u.Usuario)'..."

        $carpeta  = "$UsersBasePath\$($u.Usuario)"
        $esCuate  = ($u.Departamento -eq 'Cuates')
        $limiteB  = if ($esCuate) { $limCuatesB    } else { $limNoCuatesB    }
        $limiteMB = if ($esCuate) { $QuotaCuatesMB } else { $QuotaNoCuatesMB }

        if (-not (Test-Path $carpeta)) {
            New-Item -ItemType Directory -Path $carpeta -Force | Out-Null
        }

        try {
            if (Get-FsrmQuota -Path $carpeta -ErrorAction SilentlyContinue) {
                Set-FsrmQuota -Path $carpeta -Size $limiteB -SoftLimit:$false -Confirm:$false | Out-Null
                Write-Warn "  Cuota actualizada: $limiteMB MB"
            } else {
                New-FsrmQuota -Path $carpeta -Size $limiteB -SoftLimit:$false -Confirm:$false | Out-Null
                Write-OK "  Cuota creada: $limiteMB MB"
            }
            $script:Exitosos++
        } catch {
            Write-Err "  Error cuota '$carpeta': $_"
            $script:Fallidos++
        }

        try {
            $accion = New-FsrmAction -Type Event -EventType Warning `
                -Body 'Archivo bloqueado por [Source Io Owner] en [File Screen Path]: [Violated File Group]' `
                -Confirm:$false
            if (Get-FsrmFileScreen -Path $carpeta -ErrorAction SilentlyContinue) {
                Set-FsrmFileScreen -Path $carpeta `
                    -IncludeGroup @('Archivos-Bloqueados') -Active:$true `
                    -Notification @($accion) -Confirm:$false | Out-Null
                Write-Warn '  Pantalla actualizada.'
            } else {
                New-FsrmFileScreen -Path $carpeta `
                    -IncludeGroup @('Archivos-Bloqueados') -Active:$true `
                    -Notification @($accion) -Confirm:$false | Out-Null
                Write-OK '  Pantalla creada (modo activo).'
            }
        } catch {
            Write-Err "  Error pantalla '$carpeta': $_"
            $script:Fallidos++
        }
    }
    Write-Progress -Activity 'Configurando FSRM' -Completed

    $qCount = (Get-FsrmQuota      -ErrorAction SilentlyContinue | Measure-Object).Count
    $sCount = (Get-FsrmFileScreen -ErrorAction SilentlyContinue | Measure-Object).Count
    Write-Info "  Cuotas activas   : $qCount"
    Write-Info "  Pantallas activas: $sCount"
}

# FASE 4 - AppLocker
function Invoke-Fase4 {
    Write-Fase 'FASE 4: AppLocker - control de ejecucion de aplicaciones'

    try {
        Set-Service -Name AppIDSvc -StartupType Automatic -ErrorAction SilentlyContinue
        Start-Service -Name AppIDSvc -ErrorAction SilentlyContinue
        Write-OK 'Servicio AppIDSvc habilitado e iniciado.'
        $script:Exitosos++
    } catch { Write-Warn "No se pudo configurar AppIDSvc: $_" }

    $notepadPath = $env:SystemRoot + '\System32\notepad.exe'
    $notepadHash = if (Test-Path $notepadPath) {
        $h = (Get-FileHash -Path $notepadPath -Algorithm SHA256).Hash
        Write-OK "Hash SHA-256 notepad.exe: $h"
        $h
    } else { Write-Warn 'notepad.exe no encontrado.'; '0' }

    try {
        $sidCuates = (Get-ADGroup $GrupoCuates  -ErrorAction Stop).SID.Value
        $sidNoC    = (Get-ADGroup $GrupoNoCuates -ErrorAction Stop).SID.Value
        Write-OK "SIDs obtenidos -> Cuates: $sidCuates | NoCuates: $sidNoC"
    } catch {
        Write-Err "No se pudieron obtener los SIDs de AD: $_"
        Write-Err 'Asegurate de que el servidor es DC y los grupos existen (ejecuta Fase1 primero).'
        $script:Fallidos++
        return
    }

    $g1 = [System.Guid]::NewGuid().ToString()
    $g2 = [System.Guid]::NewGuid().ToString()
    $g3 = [System.Guid]::NewGuid().ToString()
    $g4 = [System.Guid]::NewGuid().ToString()
    $g5 = [System.Guid]::NewGuid().ToString()
    $g6 = [System.Guid]::NewGuid().ToString()
    $g7 = [System.Guid]::NewGuid().ToString()

    $hashData = "0x$notepadHash"
    $xmlPath  = $env:TEMP + '\applocker-policy.xml'

    $xmlPolicy = @"
<AppLockerPolicy Version="1">
  <RuleCollection Type="Exe" EnforcementMode="Enabled">
    <FilePathRule Id="$g1" Description="" Name="Admins - Todo" UserOrGroupSid="S-1-5-32-544" Action="Allow">
      <Conditions><FilePathCondition Path="*"/></Conditions>
    </FilePathRule>
    <FilePathRule Id="$g2" Description="" Name="Cuates - Windows" UserOrGroupSid="$sidCuates" Action="Allow">
      <Conditions><FilePathCondition Path="%WINDIR%\*"/></Conditions>
    </FilePathRule>
    <FilePathRule Id="$g3" Description="" Name="Cuates - ProgramFiles" UserOrGroupSid="$sidCuates" Action="Allow">
      <Conditions><FilePathCondition Path="%PROGRAMFILES%\*"/></Conditions>
    </FilePathRule>
    <FileHashRule Id="$g4" Description="" Name="NoCuates - Denegar Notepad" UserOrGroupSid="$sidNoC" Action="Deny">
      <Conditions>
        <FileHashCondition>
          <FileHash Type="SHA256" Data="$hashData" SourceFileName="notepad.exe" SourceFileLength="0"/>
        </FileHashCondition>
      </Conditions>
    </FileHashRule>
    <FilePathRule Id="$g5" Description="" Name="NoCuates - Windows" UserOrGroupSid="$sidNoC" Action="Allow">
      <Conditions><FilePathCondition Path="%WINDIR%\*"/></Conditions>
    </FilePathRule>
  </RuleCollection>
  <RuleCollection Type="Msi" EnforcementMode="Enabled">
    <FilePathRule Id="$g6" Description="" Name="Admins MSI" UserOrGroupSid="S-1-5-32-544" Action="Allow">
      <Conditions><FilePathCondition Path="*"/></Conditions>
    </FilePathRule>
  </RuleCollection>
  <RuleCollection Type="Script" EnforcementMode="Enabled">
    <FilePathRule Id="$g7" Description="" Name="Admins Scripts" UserOrGroupSid="S-1-5-32-544" Action="Allow">
      <Conditions><FilePathCondition Path="*"/></Conditions>
    </FilePathRule>
  </RuleCollection>
</AppLockerPolicy>
"@

    $xmlPolicy | Out-File -FilePath $xmlPath -Encoding UTF8 -Force

    try {
        Set-AppLockerPolicy -XmlPolicy $xmlPath -Merge -ErrorAction Stop
        Write-OK 'Politica AppLocker aplicada correctamente.'
        $script:Exitosos++
    } catch {
        Write-Err "Error al aplicar AppLocker: $_"
        $script:Fallidos++
    }

    try {
        if (-not (Get-GPO -Name $GPOAppLocker -ErrorAction SilentlyContinue)) {
            New-GPO -Name $GPOAppLocker -Comment 'Control AppLocker' -Confirm:$false | Out-Null
            Write-OK "GPO '$GPOAppLocker' creada."
        }
        New-GPLink -Name $GPOAppLocker -Target $DomainDN `
            -Enforced Yes -LinkEnabled Yes -Confirm:$false -ErrorAction SilentlyContinue | Out-Null
        Write-OK "GPO '$GPOAppLocker' vinculada con Enforced."
        $script:Exitosos++
    } catch {
        Write-Err "Error GPO AppLocker: $_"
        $script:Fallidos++
    }

    try {
        $pol = Get-AppLockerPolicy -Effective -ErrorAction SilentlyContinue
        if ($pol) {
            $n = 0; foreach ($c in $pol.RuleCollections) { $n += $c.Count }
            Write-Info "  Reglas efectivas: $n"
        }
    } catch { Write-Warn 'No se pudo leer politica efectiva.' }

    Remove-Item $xmlPath -Force -ErrorAction SilentlyContinue
}

# Resumen final
function Show-ResumenFinal {
    Write-Banner 'RESUMEN FINAL DE EJECUCION'
    Write-Host "  Operaciones exitosas : $script:Exitosos" -ForegroundColor Green
    Write-Host "  Operaciones omitidas : $script:Omitidos" -ForegroundColor Yellow
    Write-Host "  Operaciones fallidas : $script:Fallidos" -ForegroundColor Red
    Write-Host ''
    foreach ($fase in @(
        'Fase 0 - Inicializacion',
        'Fase 1 - OUs y Usuarios',
        'Fase 2 - Logon Hours   ',
        'Fase 3 - FSRM Cuotas   ',
        'Fase 4 - AppLocker     '
    )) { Write-Host "  $fase : OK" -ForegroundColor Green }
}

# Funciones del menu
function Menu-VerEstadoCuotas {
    Write-Banner 'Estado de cuotas FSRM'
    Get-FsrmQuota -ErrorAction SilentlyContinue |
        Select-Object Path,
            @{N='Limite_MB'; E={[math]::Round($_.Size / 1MB, 1)}},
            @{N='Usado_MB';  E={[math]::Round($_.Usage / 1MB, 2)}} |
        Format-Table -AutoSize
}
function Menu-VerEventosFSRM {
    Write-Banner 'Eventos FSRM (ultimos 20)'
    Get-WinEvent -LogName 'Microsoft-Windows-FSRM-Manager/Operational' `
        -MaxEvents 20 -ErrorAction SilentlyContinue |
        Select-Object TimeCreated, Id, Message | Format-Table -AutoSize -Wrap
}
function Menu-VerHorarios {
    Write-Banner 'Horarios de inicio de sesion'
    foreach ($grp in @($GrupoCuates, $GrupoNoCuates)) {
        Write-Info "Grupo: $grp"
        Get-ADGroupMember $grp -ErrorAction SilentlyContinue | ForEach-Object {
            $u = Get-ADUser $_.SamAccountName -Properties LogonHours
            Write-Host "    $($u.SamAccountName) --> $($u.LogonHours[0..5] -join ',')" -ForegroundColor Cyan
        }
    }
}
function Menu-VerPoliticaAppLocker {
    Write-Banner 'Politica AppLocker efectiva'
    Get-AppLockerPolicy -Effective -ErrorAction SilentlyContinue | Format-List
}
function Menu-ProbarAccesoUsuario {
    $sam = Read-Host '  SamAccountName del usuario a probar'
    if (-not $sam) { return }
    $notePath = $env:SystemRoot + '\System32\notepad.exe'
    try {
        $result = Test-AppLockerPolicy -Path $notePath -User $sam -ErrorAction Stop
        Write-Info "  Resultado para '$sam': $($result.PolicyDecision)"
    } catch { Write-Err "Error al probar: $_" }
}
function Menu-ResumenSistema {
    Write-Banner 'Resumen General del Sistema'
    Write-Info "Dominio     : $((Get-ADDomain).DNSRoot)"
    Write-Info "Servidor    : $env:COMPUTERNAME"
    Write-Info "Usuarios AD : $((Get-ADUser -Filter * | Measure-Object).Count)"
    Write-Info "Grupos      : $((Get-ADGroup -Filter * | Measure-Object).Count)"
    Write-Info "OUs         : $((Get-ADOrganizationalUnit -Filter * | Measure-Object).Count)"
    Write-Info "Cuotas FSRM : $((Get-FsrmQuota -ErrorAction SilentlyContinue | Measure-Object).Count)"
    Write-Info "GPOs        : $((Get-GPO -All | Measure-Object).Count)"
}
function Menu-AgregarUsuario {
    Write-Banner 'Agregar usuario individual'
    $nombre   = Read-Host '  Nombre'
    $apellido = Read-Host '  Apellido'
    $usuario  = Read-Host '  SamAccountName'
    $pwd      = Read-Host '  Contrasena' -AsSecureString
    $dept     = Read-Host '  Departamento (Cuates/NoCuates)'
    $ouPath   = if ($dept -eq 'Cuates') { $OUCuates }    else { $OUNoCuates }
    $grupo    = if ($dept -eq 'Cuates') { $GrupoCuates } else { $GrupoNoCuates }
    try {
        New-ADUser -Name "$nombre $apellido" -GivenName $nombre -Surname $apellido `
            -SamAccountName $usuario -UserPrincipalName "$usuario@$DomainName" `
            -AccountPassword $pwd -Enabled $true -Path $ouPath -Department $dept `
            -Confirm:$false -ErrorAction Stop
        Add-ADGroupMember -Identity $grupo -Members $usuario -Confirm:$false
        Write-OK "Usuario '$usuario' creado en $dept."
    } catch { Write-Err "Error: $_" }
}
function Menu-EliminarUsuario {
    $sam = Read-Host '  SamAccountName a eliminar'
    try {
        Remove-ADUser -Identity $sam -Confirm:$false -Force -ErrorAction Stop
        Write-OK "Usuario '$sam' eliminado."
    } catch { Write-Err "Error: $_" }
}
function Menu-VerUsuariosPorOU {
    Write-Banner 'Usuarios por OU'
    foreach ($ou in @($OUCuates, $OUNoCuates)) {
        Write-Info $ou
        Get-ADUser -Filter * -SearchBase $ou -Properties Department -ErrorAction SilentlyContinue |
            Select-Object SamAccountName, Name, Department |
            Format-Table -AutoSize | Out-String | Write-Host
    }
}

# MENU INTERACTIVO
function Show-Menu {
    do {
        Clear-Host
        Write-Host ''
        Write-Host '  ╔══════════════════════════════════════════╗' -ForegroundColor Cyan
        Write-Host '  ║     GESTION DE AD - SERVIDOR             ║' -ForegroundColor Cyan
        Write-Host '  ╠══════════════════════════════════════════╣' -ForegroundColor Cyan
        Write-Host '  ║  USUARIOS                                ║' -ForegroundColor Cyan
        Write-Host '  ║  [1]  Crear usuarios desde CSV           ║' -ForegroundColor Cyan
        Write-Host '  ║  [2]  Agregar un usuario individual      ║' -ForegroundColor Cyan
        Write-Host '  ║  [3]  Eliminar un usuario                ║' -ForegroundColor Cyan
        Write-Host '  ║  [4]  Ver usuarios por OU                ║' -ForegroundColor Cyan
        Write-Host '  ║                                          ║' -ForegroundColor Cyan
        Write-Host '  ║  CUOTAS Y ALMACENAMIENTO                 ║' -ForegroundColor Cyan
        Write-Host '  ║  [5]  Aplicar/modificar cuotas FSRM      ║' -ForegroundColor Cyan
        Write-Host '  ║  [6]  Ver estado de cuotas               ║' -ForegroundColor Cyan
        Write-Host '  ║  [7]  Ver eventos de bloqueo FSRM        ║' -ForegroundColor Cyan
        Write-Host '  ║                                          ║' -ForegroundColor Cyan
        Write-Host '  ║  ACCESO Y HORARIOS                       ║' -ForegroundColor Cyan
        Write-Host '  ║  [8]  Modificar horarios de grupos       ║' -ForegroundColor Cyan
        Write-Host '  ║  [9]  Ver horarios actuales              ║' -ForegroundColor Cyan
        Write-Host '  ║                                          ║' -ForegroundColor Cyan
        Write-Host '  ║  APPLOCKER                               ║' -ForegroundColor Cyan
        Write-Host '  ║  [10] Re-aplicar reglas AppLocker        ║' -ForegroundColor Cyan
        Write-Host '  ║  [11] Ver politica AppLocker efectiva    ║' -ForegroundColor Cyan
        Write-Host '  ║  [12] Probar acceso de un usuario        ║' -ForegroundColor Cyan
        Write-Host '  ║                                          ║' -ForegroundColor Cyan
        Write-Host '  ║  SISTEMA                                 ║' -ForegroundColor Cyan
        Write-Host '  ║  [13] Ver resumen general del sistema    ║' -ForegroundColor Cyan
        Write-Host '  ║  [14] Re-ejecutar todas las fases        ║' -ForegroundColor Cyan
        Write-Host '  ║  [0]  Salir                              ║' -ForegroundColor Cyan
        Write-Host '  ╚══════════════════════════════════════════╝' -ForegroundColor Cyan
        Write-Host ''

        $opcion = Read-Host '  Selecciona una opcion'
        switch ($opcion) {
            '1'  { Invoke-Fase1 }
            '2'  { Menu-AgregarUsuario }
            '3'  { Menu-EliminarUsuario }
            '4'  { Menu-VerUsuariosPorOU }
            '5'  { Invoke-Fase3 }
            '6'  { Menu-VerEstadoCuotas }
            '7'  { Menu-VerEventosFSRM }
            '8'  { Invoke-Fase2 }
            '9'  { Menu-VerHorarios }
            '10' { Invoke-Fase4 }
            '11' { Menu-VerPoliticaAppLocker }
            '12' { Menu-ProbarAccesoUsuario }
            '13' { Menu-ResumenSistema }
            '14' { Invoke-Fase1; Invoke-Fase2; Invoke-Fase3; Invoke-Fase4 }
            '0'  { Write-OK 'Saliendo. Hasta pronto!'; return }
            default { Write-Warn 'Opcion no valida. Intenta de nuevo.' }
        }
        if ($opcion -ne '0') { Pause-Menu }
    } while ($true)
}

# PUNTO DE ENTRADA
if ($Menu) {
    Invoke-Fase0
    if (-not (Test-ADWSDisponible)) { exit 1 }
    Show-Menu
} else {
    $reinicio = Invoke-FaseDC
    if ($reinicio) { exit 0 }

    Invoke-Fase0

    if (-not (Test-ADWSDisponible)) { exit 1 }

    Invoke-Fase1
    Invoke-Fase2
    Invoke-Fase3
    Invoke-Fase4
    Show-ResumenFinal
}
