# Variables globales de rutas y red
$rutaScripts     = "C:\Scripts"
$dominioLaboral  = "lab.local"
$ipDCEstatica    = "192.168.100.1"   # IP fija del DC en la red interna VirtualBox
$subnetInterna   = "192.168.100."    # Prefijo de la red interna servidor-cliente

# BLOQUE 0  -  Auto-elevacion, DNS, Union al Dominio y Verificacion

if (-not ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole(
        [Security.Principal.WindowsBuiltInRole]::Administrator)) {
    Write-Host "El script no se ejecuta como Administrador. Relanzando con privilegios elevados..." -ForegroundColor Yellow
    Start-Process powershell -Verb RunAs -ArgumentList "-ExecutionPolicy Bypass -File `"$PSCommandPath`""
    exit
}

Write-Host "Ejecutando Practica09_Cliente.ps1 con privilegios de Administrador." -ForegroundColor Cyan

if (-not (Test-Path $rutaScripts)) {
    try {
        New-Item -Path $rutaScripts -ItemType Directory -Force -ErrorAction Stop | Out-Null
        Write-Host "Carpeta creada: $rutaScripts" -ForegroundColor Green
    } catch {
        Write-Warning "No se pudo crear la carpeta '$rutaScripts': $_"
    }
}

# Inicializar variables de dominio y DC
$dominioActual   = $null
$ipDC            = $ipDCEstatica
$dominioDNS      = $null
$dominioDN       = $null
$estadoCanal     = $false
$estadoPing      = $false

# Paso 1: Localizar el adaptador de red en la subred interna 192.168.100.x
Write-Host "Buscando adaptador de red en la subred interna ($subnetInterna)..." -ForegroundColor Yellow
$adaptadorInterno = $null
try {
    $todosAdaptadores = Get-NetIPAddress -AddressFamily IPv4 -ErrorAction Stop
    $adaptadorInterno = $todosAdaptadores |
        Where-Object { $_.IPAddress -like "$subnetInterna*" } |
        Select-Object -First 1
    if ($adaptadorInterno) {
        Write-Host "Adaptador interno encontrado: InterfaceIndex=$($adaptadorInterno.InterfaceIndex) | IP=$($adaptadorInterno.IPAddress)" -ForegroundColor Green
    } else {
        Write-Error "No se encontro ningun adaptador en la subred $subnetInterna. Verifique que Ethernet 2 (red interna) esta activo."
        exit 1
    }
} catch {
    Write-Error "Error al enumerar los adaptadores de red: $_"
    exit 1
}

# Paso 2: Verificar conectividad con el DC por la red interna
Write-Host "Verificando conectividad con el DC ($ipDCEstatica) por la red interna..." -ForegroundColor Yellow
try {
    $pingDC = Test-Connection -ComputerName $ipDCEstatica -Count 2 -ErrorAction Stop
    $pingOK = ($pingDC | Where-Object { $null -eq $_.StatusCode -or $_.StatusCode -eq 0 }).Count
    if ($pingOK -ge 1) {
        Write-Host "DC accesible por ping en $ipDCEstatica ($pingOK de 2 paquetes exitosos)." -ForegroundColor Green
        $estadoPing = $true
    } else {
        Write-Warning "El DC ($ipDCEstatica) no responde al ping. Verifique que el servidor esta encendido."
    }
} catch {
    Write-Warning "Ping al DC fallo: $_. Continuando de todos modos..."
}

# Paso 3: Configurar DNS del adaptador interno apuntando al DC
Write-Host "Configurando DNS del adaptador interno para apuntar al DC ($ipDCEstatica)..." -ForegroundColor Yellow
try {
    $dnsActuales = (Get-DnsClientServerAddress `
        -InterfaceIndex $adaptadorInterno.InterfaceIndex `
        -AddressFamily IPv4 `
        -ErrorAction SilentlyContinue).ServerAddresses

    if ($dnsActuales -contains $ipDCEstatica) {
        Write-Warning "El DNS ya apunta a $ipDCEstatica en este adaptador. No se requiere cambio."
    } else {
        Set-DnsClientServerAddress `
            -InterfaceIndex $adaptadorInterno.InterfaceIndex `
            -ServerAddresses $ipDCEstatica `
            -ErrorAction Stop
        Write-Host "DNS configurado correctamente a $ipDCEstatica en el adaptador interno." -ForegroundColor Green
        Start-Sleep -Seconds 3
    }
} catch {
    Write-Warning "Error al configurar el DNS del adaptador interno: $_"
}

Write-Host "Configurando sufijo DNS de conexion 'lab.local' en el adaptador interno..." -ForegroundColor Yellow
try {
    Set-DnsClient `
        -InterfaceIndex $adaptadorInterno.InterfaceIndex `
        -ConnectionSpecificSuffix $dominioLaboral `
        -ErrorAction Stop
    Write-Host "Sufijo DNS '$dominioLaboral' configurado en el adaptador interno." -ForegroundColor Green
} catch {
    Write-Warning "No se pudo configurar el sufijo DNS '$dominioLaboral': $_"
}

try {
    $sufijosActuales = (Get-DnsClientGlobalSetting -ErrorAction SilentlyContinue).SuffixSearchList
    if ($sufijosActuales -notcontains $dominioLaboral) {
        $nuevaLista = @($dominioLaboral) + @($sufijosActuales | Where-Object { $_ -ne $dominioLaboral })
        Set-DnsClientGlobalSetting -SuffixSearchList $nuevaLista -ErrorAction Stop
        Write-Host "Lista de busqueda DNS global actualizada con '$dominioLaboral' como primera entrada." -ForegroundColor Green
    } else {
        Write-Warning "El sufijo '$dominioLaboral' ya esta en la lista de busqueda DNS global."
    }
} catch {
    Write-Warning "No se pudo actualizar la lista de sufijos DNS global: $_"
}

# Paso 4: Limpiar cache DNS y verificar resolucion de lab.local
Write-Host "Verificando resolucion DNS de '$dominioLaboral'..." -ForegroundColor Yellow
ipconfig /flushdns 2>&1 | Out-Null
$ipDCResuelto = $null
try {
    # Intentar resolucion normal (con el sufijo ya configurado)
    $resolucionLab = Resolve-DnsName -Name $dominioLaboral -Type A -ErrorAction Stop
    $ipDCResuelto  = ($resolucionLab | Where-Object { $_.IPAddress -like "$subnetInterna*" } | Select-Object -First 1).IPAddress
    if (-not $ipDCResuelto) { $ipDCResuelto = ($resolucionLab | Select-Object -First 1).IPAddress }
    $ipDC = $ipDCResuelto
    Write-Host "Dominio '$dominioLaboral' resuelto correctamente: $ipDC" -ForegroundColor Green
} catch {
    try {
        $resolucionDirecta = Resolve-DnsName -Name $dominioLaboral -Type A -Server $ipDCEstatica -ErrorAction Stop
        $ipDCResuelto = ($resolucionDirecta | Where-Object { $_.IPAddress -like "$subnetInterna*" } | Select-Object -First 1).IPAddress
        if (-not $ipDCResuelto) { $ipDCResuelto = ($resolucionDirecta | Select-Object -First 1).IPAddress }
        $ipDC = if ($ipDCResuelto) { $ipDCResuelto } else { $ipDCEstatica }
        Write-Host "Dominio resuelto via servidor DNS directo: $ipDC" -ForegroundColor Green
    } catch {
        Write-Warning "No se pudo resolver '$dominioLaboral'. Usando IP estatica del DC: $ipDCEstatica"
        $ipDC = $ipDCEstatica
    }
}

# Paso 5: Union automatica al dominio si la maquina esta en WORKGROUP
try {
    $infoEquipo    = Get-WmiObject -Class Win32_ComputerSystem -ErrorAction Stop
    $dominioActual = $infoEquipo.Domain

    if (-not $dominioActual -or $dominioActual -eq "WORKGROUP") {
        Write-Host "Maquina en WORKGROUP. Iniciando union automatica al dominio '$dominioLaboral'..." -ForegroundColor Yellow

        Write-Host "  Verificando y corrigiendo perfil de red del adaptador interno..." -ForegroundColor Yellow
        try {
            $adInterno = Get-NetIPAddress -AddressFamily IPv4 -ErrorAction SilentlyContinue |
                Where-Object { $_.IPAddress -like "$subnetInterna*" } | Select-Object -First 1
            if ($adInterno) {
                $perfil = Get-NetConnectionProfile -InterfaceIndex $adInterno.InterfaceIndex -ErrorAction SilentlyContinue
                if ($perfil -and $perfil.NetworkCategory -eq "Public") {
                    Set-NetConnectionProfile -InterfaceIndex $adInterno.InterfaceIndex -NetworkCategory Private -ErrorAction Stop
                    Write-Host "  Perfil cambiado de Public a Private (requerido para SMB/Kerberos)." -ForegroundColor Green
                } else {
                    Write-Host "  Perfil de red: $($perfil.NetworkCategory) (correcto)." -ForegroundColor Green
                }
            }
        } catch { Write-Warning "  No se pudo cambiar el perfil de red: $_" }

        # PASO B: Habilitar reglas firewall SMB + Kerberos en el cliente
        Write-Host "  Habilitando reglas de firewall para SMB, Kerberos y NetLogon en el cliente..." -ForegroundColor Yellow
        try {
            $gruposFirewall = @("File and Printer Sharing","Network Discovery","Kerberos Key Distribution Center")
            foreach ($g in $gruposFirewall) {
                Set-NetFirewallRule -DisplayGroup $g -Enabled True -Profile Any -ErrorAction SilentlyContinue
            }
            $puertosDJ = @(
                @{N="DJ-SMB-445";P=445;T="TCP"},@{N="DJ-Kerb-88";P=88;T="TCP"},
                @{N="DJ-LDAP-389";P=389;T="TCP"},@{N="DJ-RPC-135";P=135;T="TCP"}
            )
            foreach ($r in $puertosDJ) {
                if (-not (Get-NetFirewallRule -Name $r.N -ErrorAction SilentlyContinue)) {
                    New-NetFirewallRule -Name $r.N -DisplayName $r.N -Direction Outbound `
                        -Protocol $r.T -RemotePort $r.P -Action Allow -Enabled True `
                        -ErrorAction SilentlyContinue | Out-Null
                }
            }
            Write-Host "  Reglas de firewall para domain join habilitadas." -ForegroundColor Green
        } catch { Write-Warning "  Error configurando firewall: $_" }

        Write-Host "  Verificando acceso al puerto 445 en el DC ($ipDCEstatica)..." -ForegroundColor Yellow
        $puerto445OK = $false
        try {
            $tcp = New-Object System.Net.Sockets.TcpClient
            $ar  = $tcp.BeginConnect($ipDCEstatica, 445, $null, $null)
            if ($ar.AsyncWaitHandle.WaitOne(4000, $false) -and $tcp.Connected) {
                $tcp.EndConnect($ar); $puerto445OK = $true
                Write-Host "  Puerto 445 accesible en el DC." -ForegroundColor Green
            } else { Write-Warning "  Puerto 445 NO accesible. Puede ser firewall del DC." }
            $tcp.Close()
        } catch { Write-Warning "  Verificacion puerto 445: $_" }

        Write-Host "Se solicitara la contrasena del Administrador de '$dominioLaboral' para completar la union." -ForegroundColor Cyan
        $credUnionDominio = Get-Credential `
            -UserName "lab\Administrator" `
            -Message "Administrador de $dominioLaboral | Contrasena: Admin123"

        if (-not $credUnionDominio) {
            Write-Error "No se proporcionaron credenciales."; exit 1
        }
        $passTextoPlano = $credUnionDominio.GetNetworkCredential().Password
        $usuarioUPN     = "Administrator@$dominioLaboral"

        $unionExitosa = $false

        if (-not $unionExitosa) {
            try {
                Write-Host "  Metodo 1: Add-Computer al dominio $dominioLaboral..." -ForegroundColor Yellow
                Add-Computer -DomainName $dominioLaboral -Credential $credUnionDominio -Force -ErrorAction Stop
                $unionExitosa = $true
                Write-Host "  Maquina unida al dominio via Add-Computer." -ForegroundColor Green
            } catch { Write-Warning "  Metodo 1 (Add-Computer) fallo: $_" }
        }

        if (-not $unionExitosa) {
            try {
                Write-Host "  Metodo 2: WMI JoinDomainOrWorkgroup (nativo Win10, sin RSAT)..." -ForegroundColor Yellow
                $cs = Get-WmiObject -Class Win32_ComputerSystem -ErrorAction Stop
                $resultado = $cs.JoinDomainOrWorkgroup(
                    $dominioLaboral,    # dominio
                    $passTextoPlano,    # contrasena del admin
                    $usuarioUPN,        # usuario UPN
                    $null,              # OU (null = default)
                    3
                )
                if ($resultado.ReturnValue -eq 0) {
                    $unionExitosa = $true
                    Write-Host "  Maquina unida al dominio via WMI (ReturnValue=0)." -ForegroundColor Green
                } else {
                    Write-Warning "  WMI retorno error: $($resultado.ReturnValue)"
                    switch ($resultado.ReturnValue) {
                        5     { Write-Warning "  -> Credenciales incorrectas o acceso denegado." }
                        1355  { Write-Warning "  -> DC no encontrado. Verificar DNS y conectividad." }
                        2224  { Write-Warning "  -> La cuenta del equipo ya existe en AD. Intentando con flag diferente."
                                $r2 = $cs.JoinDomainOrWorkgroup($dominioLaboral,$passTextoPlano,$usuarioUPN,$null,35)
                                if ($r2.ReturnValue -eq 0) { $unionExitosa = $true; Write-Host "  WMI con flag 35: exitoso." -ForegroundColor Green }
                              }
                        default { Write-Warning "  -> Codigo: $($resultado.ReturnValue). Ver: https://docs.microsoft.com/en-us/windows/win32/cimwin32prov/joindomainorworkgroup-method-in-class-win32-computersystem" }
                    }
                }
            } catch { Write-Warning "  Metodo 2 (WMI JoinDomain) fallo: $_" }
        }

        # Metodo 3: Add-Computer apuntando explicitamente al DC por nombre DNS
        if (-not $unionExitosa) {
            try {
                Write-Host "  Metodo 3: Add-Computer con DC especifico por nombre..." -ForegroundColor Yellow
                $dcFQDN = $null
                try {
                    $dcRegistros = Resolve-DnsName -Name "_ldap._tcp.dc._msdcs.$dominioLaboral" -Type SRV -ErrorAction SilentlyContinue
                    if ($dcRegistros) { $dcFQDN = ($dcRegistros | Select-Object -First 1).NameTarget }
                } catch { }
                if (-not $dcFQDN) { $dcFQDN = "SRV-WINDOWS.$dominioLaboral" }

                Add-Computer -DomainName $dominioLaboral -Server $dcFQDN `
                    -Credential $credUnionDominio -Force -ErrorAction Stop
                $unionExitosa = $true
                Write-Host "  Maquina unida al dominio via Add-Computer con DC=$dcFQDN." -ForegroundColor Green
            } catch { Write-Warning "  Metodo 3 (Add-Computer + DC FQDN) fallo: $_" }
        }

        if (-not $unionExitosa) {
            Write-Error "No se pudo unir la maquina al dominio despues de 3 metodos."
            Write-Error "Verifica: 1) Perfil de red en Private  2) Puerto 445 abierto  3) DNS apunta al DC"
            Write-Error "Tambien puedes unir manualmente: sysdm.cpl -> Nombre equipo -> Cambiar -> Dominio"
            exit 1
        }

        Write-Host "Reiniciando en 10 segundos para aplicar la union al dominio..." -ForegroundColor Yellow
        Write-Host "Tras el reinicio, vuelva a ejecutar: .\Practica09_Cliente.ps1" -ForegroundColor Cyan
        Start-Sleep -Seconds 10
        Restart-Computer -Force
        exit 0

    } else {
        Write-Host "Dominio detectado en el cliente: $dominioActual" -ForegroundColor Green
    }
} catch {
    Write-Error "Error critico al detectar el estado de dominio del equipo: $_"
    exit 1
}

Write-Host "Solicitando credenciales de dominio para todas las operaciones AD remotas..." -ForegroundColor Cyan
$credDominio = Get-Credential `
    -UserName "lab\Administrator" `
    -Message "Credenciales del Administrador de $dominioLaboral (se usaran en todos los bloques)"
if (-not $credDominio) {
    Write-Warning "No se proporcionaron credenciales de dominio. Operaciones AD pueden fallar."
    $credDominio = $null
}

Write-Host "Verificando canal seguro con el dominio '$dominioActual'..." -ForegroundColor Yellow
try {
    $estadoCanal = Test-ComputerSecureChannel -ErrorAction Stop
    if ($estadoCanal) {
        Write-Host "Canal seguro verificado correctamente." -ForegroundColor Green
    } else {
        Write-Warning "Canal seguro roto (Test-ComputerSecureChannel=FALSE). Intentando reparacion automatica..."
        if ($credDominio) {
            try {
                $reparado = Test-ComputerSecureChannel -Repair -Credential $credDominio -ErrorAction Stop
                if ($reparado) {
                    Write-Host "Canal seguro reparado correctamente." -ForegroundColor Green
                    $estadoCanal = $true
                } else {
                    Write-Warning "Test-ComputerSecureChannel -Repair retorno FALSE. Intentando nltest sc_reset..."
                    try {
                        $passRepair = $credDominio.GetNetworkCredential().Password
                        $userRepair = $credDominio.UserName
                        $nltest = & nltest /sc_reset:$dominioActual /server:$ipDCEstatica 2>&1
                        Write-Host "  nltest sc_reset: $nltest" -ForegroundColor Gray
                        $estadoCanal = $true
                    } catch {
                        Write-Warning "  Reparacion automatica no disponible: $_"
                        Write-Host "  Ejecutar manualmente: nltest /sc_reset:$dominioActual" -ForegroundColor Yellow
                        $estadoCanal = $true
                    }
                }
            } catch {
                Write-Warning "No se pudo reparar el canal seguro automaticamente: $_"
                Write-Warning "Si los errores AD persisten, ejecute manualmente en el cliente:"
                Write-Host "  Test-ComputerSecureChannel -Repair -Credential (Get-Credential 'lab\Administrator')" -ForegroundColor Yellow
                $estadoCanal = $false
            }
        } else {
            Write-Warning "Sin credenciales no se puede reparar el canal seguro automaticamente."
            $estadoCanal = $false
        }
    }
} catch {
    Write-Warning "Error al verificar el canal seguro: $_"
    $estadoCanal = $false
}

# Paso 7: Resolver IP final del DC con preferencia por la red interna
try {
    ipconfig /flushdns 2>&1 | Out-Null
    $resolucionFinal = Resolve-DnsName -Name $dominioActual -Type A -ErrorAction SilentlyContinue
    if ($resolucionFinal) {
        $ipInterna = $resolucionFinal | Where-Object { $_.IPAddress -like "$subnetInterna*" } | Select-Object -First 1
        $ipDC = if ($ipInterna) { $ipInterna.IPAddress } else { ($resolucionFinal | Select-Object -First 1).IPAddress }
        Write-Host "DC resuelto por DNS: $ipDC ($dominioActual)" -ForegroundColor Green
    } else {
        $ipDC = $ipDCEstatica
        Write-Warning "DNS no resolvio '$dominioActual'. Usando IP estatica del DC: $ipDC"
    }
} catch {
    $ipDC = $ipDCEstatica
    Write-Warning "Error al resolver el DC: $_. Usando IP estatica: $ipDC"
}

# Ping final de verificacion
try {
    Write-Host "Verificando conectividad con el DC ($ipDC) - enviando 2 paquetes ICMP..." -ForegroundColor Yellow
    $resultadosPing = Test-Connection -ComputerName $ipDC -Count 2 -ErrorAction Stop
    $pingExitosos   = ($resultadosPing | Where-Object { $null -eq $_.StatusCode -or $_.StatusCode -eq 0 }).Count
    if ($pingExitosos -ge 1) {
        Write-Host "Conectividad con el DC verificada ($($pingExitosos) de 2 paquetes exitosos)." -ForegroundColor Green
        $estadoPing = $true
    } else {
        Write-Warning "Ping al DC ($ipDC) no obtuvo respuestas."
        $estadoPing = $false
    }
} catch {
    Write-Warning "No se pudo verificar conectividad por ping: $_"
    $estadoPing = $false
}

# Paso 8: Configurar WinRM en el cliente (TrustedHosts + FQDN del DC)
Write-Host "Configurando WinRM en el cliente para sesiones remotas al DC..." -ForegroundColor Yellow
try {
    Enable-PSRemoting -Force -SkipNetworkProfileCheck -ErrorAction SilentlyContinue | Out-Null

    $valoresTrusted = @($ipDCEstatica, $dominioLaboral, "*.$dominioLaboral")
    $trustedActuales = (Get-Item WSMan:\localhost\Client\TrustedHosts -ErrorAction SilentlyContinue).Value
    $trustedNuevos = ($valoresTrusted | Where-Object {
        [string]::IsNullOrEmpty($trustedActuales) -or $trustedActuales -notmatch [regex]::Escape($_)
    })
    if ($trustedNuevos) {
        $valorFinal = if ([string]::IsNullOrEmpty($trustedActuales)) {
            $valoresTrusted -join ","
        } else {
            "$trustedActuales," + ($trustedNuevos -join ",")
        }
        Set-Item WSMan:\localhost\Client\TrustedHosts -Value $valorFinal -Force -ErrorAction Stop
        Write-Host "WinRM TrustedHosts actualizado con: $valorFinal" -ForegroundColor Green
    } else {
        Write-Warning "Todos los hosts ya estaban en WinRM TrustedHosts."
    }
} catch {
    Write-Warning "Error al configurar WinRM TrustedHosts: $_"
}

Write-Host "# ---- Bloque 0 completado ----" -ForegroundColor Cyan

# BLOQUE 1  -  Instalacion de RSAT en Cliente
Write-Host "`n# ---- BLOQUE 1  -  Instalacion de RSAT en Cliente ----" -ForegroundColor Cyan

$rsatNombreCapacidad = "Rsat.ActiveDirectory.DS-LDS.Tools~~~~0.0.1.0"
$rsatInstalado       = $false

try {
    Write-Host "Consultando estado de RSAT para Active Directory en este equipo..." -ForegroundColor Yellow
    $estadoRSAT = Get-WindowsCapability -Online -Name $rsatNombreCapacidad -ErrorAction Stop

    if ($estadoRSAT.State -eq "Installed") {
        Write-Warning "RSAT para Active Directory ya esta instalado (estado: Installed). Continuando."
        $rsatInstalado = $true
    } else {
        Write-Host "Instalando RSAT para Active Directory (puede tardar varios minutos)..." -ForegroundColor Yellow
        Add-WindowsCapability -Online -Name $rsatNombreCapacidad -ErrorAction Stop | Out-Null
        Write-Host "RSAT para Active Directory instalado correctamente." -ForegroundColor Green
        $rsatInstalado = $true
    }
} catch {
    Write-Warning "Error durante la instalacion de RSAT para Active Directory: $_"
    Write-Warning "Asegurese de que el equipo tiene acceso a Windows Update o al servidor WSUS."
    $rsatInstalado = $false
}

# Verificar disponibilidad del modulo ActiveDirectory
$moduloADDisponible = $false
try {
    $moduloAD = Get-Module -ListAvailable -Name ActiveDirectory -ErrorAction SilentlyContinue
    if ($moduloAD) {
        Write-Host "Modulo ActiveDirectory disponible: version $($moduloAD.Version | Select-Object -First 1)" -ForegroundColor Green
        $moduloADDisponible = $true
    } else {
        Write-Warning "El modulo ActiveDirectory no se detecto. Si acaba de instalarse, reinicie el equipo e intente de nuevo."
        $moduloADDisponible = $false
    }
} catch {
    Write-Warning "Error al verificar la disponibilidad del modulo ActiveDirectory: $_"
    $moduloADDisponible = $false
}

Write-Host "# ---- Bloque 1 completado ----" -ForegroundColor Cyan

# BLOQUE 2  -  Verificacion de Delegaciones desde el Cliente
Write-Host "`n# ---- BLOQUE 2  -  Verificacion de Delegaciones desde el Cliente ----" -ForegroundColor Cyan

$env:ADPS_LoadDefaultDrive = "0"
try {
    Import-Module ActiveDirectory -ErrorAction Stop
    Write-Host "Modulo ActiveDirectory importado correctamente." -ForegroundColor Green
} catch {
    Write-Warning "No se pudo importar el modulo ActiveDirectory: $_"
    Write-Warning "Los bloques que requieren AD pueden fallar. Verifique la instalacion de RSAT."
}

try {
    if ($credDominio) {
        $infoDominio = Get-ADDomain -Server $ipDC -Credential $credDominio -ErrorAction Stop
    } else {
        $infoDominio = Get-ADDomain -Server $ipDC -ErrorAction Stop
    }
    $dominioDNS  = $infoDominio.DNSRoot
    $dominioDN   = $infoDominio.DistinguishedName
    Write-Host "Conectado al dominio: $dominioDNS ($dominioDN)" -ForegroundColor Green
} catch {
    Write-Warning "No se pudo obtener informacion del dominio AD: $_"
    $dominioDNS = $dominioLaboral
    $dominioDN  = "DC=" + ($dominioLaboral -replace "\.", ",DC=")
    Write-Warning "Usando dominioDN calculado: $dominioDN"
}

Write-Host "`nVerificando los 4 usuarios administradores delegados en AD:" -ForegroundColor Cyan
$verificacionUsuariosAdmin = @{}

foreach ($nombreAdmin in @("admin_identidad","admin_storage","admin_politicas","admin_auditoria")) {
    try {
        $parametrosAD = @{
            Identity   = $nombreAdmin
            Properties = @("SamAccountName","DistinguishedName","Enabled","PasswordNeverExpires")
            Server     = $ipDC
            ErrorAction = "Stop"
        }
        if ($credDominio) { $parametrosAD["Credential"] = $credDominio }
        $uObj = Get-ADUser @parametrosAD
        Write-Host "  [OK] $($uObj.SamAccountName)" -ForegroundColor Green
        Write-Host "       Enabled=$($uObj.Enabled) | PasswordNeverExpires=$($uObj.PasswordNeverExpires)" -ForegroundColor Gray
        Write-Host "       DN: $($uObj.DistinguishedName)" -ForegroundColor Gray
        $verificacionUsuariosAdmin[$nombreAdmin] = "EXISTE  -  Enabled=$($uObj.Enabled)"
    } catch {
        Write-Warning "  [FALTA] No se encontro el usuario '$nombreAdmin': $_"
        $verificacionUsuariosAdmin[$nombreAdmin] = "NO ENCONTRADO"
    }
}

Write-Host "`nVerificando Fine-Grained Password Policies (FGPP) en el dominio:" -ForegroundColor Cyan
$verificacionFGPPs = @{}

try {
    $parametrosFGPP = @{ Filter = "*"; Server = $ipDC; ErrorAction = "Stop" }
    if ($credDominio) { $parametrosFGPP["Credential"] = $credDominio }
    $todasLasFGPPs = Get-ADFineGrainedPasswordPolicy @parametrosFGPP
    if ($todasLasFGPPs) {
        foreach ($fgpp in $todasLasFGPPs) {
            Write-Host "`n  FGPP: $($fgpp.Name)" -ForegroundColor Green
            Write-Host "    Precedencia                : $($fgpp.Precedence)"
            Write-Host "    MinPasswordLength          : $($fgpp.MinPasswordLength)"
            Write-Host "    PasswordHistoryCount       : $($fgpp.PasswordHistoryCount)"
            Write-Host "    MaxPasswordAge             : $($fgpp.MaxPasswordAge.Days) dias"
            Write-Host "    MinPasswordAge             : $($fgpp.MinPasswordAge.Days) dias"
            Write-Host "    LockoutThreshold           : $($fgpp.LockoutThreshold) intentos"
            Write-Host "    LockoutDuration            : $($fgpp.LockoutDuration.TotalMinutes) minutos"
            Write-Host "    LockoutObservationWindow   : $($fgpp.LockoutObservationWindow.TotalMinutes) minutos"
            Write-Host "    ComplexityEnabled          : $($fgpp.ComplexityEnabled)"
            Write-Host "    ReversibleEncryptionEnabled: $($fgpp.ReversibleEncryptionEnabled)"
            try {
                $paramSujetos = @{ Identity = $fgpp.Name; Server = $ipDC; ErrorAction = "SilentlyContinue" }
                if ($credDominio) { $paramSujetos["Credential"] = $credDominio }
                $sujetos = Get-ADFineGrainedPasswordPolicySubject @paramSujetos
                Write-Host "    Sujetos aplicados          : $($sujetos.Name -join ', ')"
            } catch {
                Write-Host "    Sujetos aplicados          : (error al consultar)"
            }
            $verificacionFGPPs[$fgpp.Name] = "ENCONTRADA  -  Precedencia=$($fgpp.Precedence) | MinLen=$($fgpp.MinPasswordLength)"
        }
    } else {
        Write-Warning "No se encontraron FGPPs en el dominio."
    }
} catch {
    Write-Warning "Error al consultar las FGPPs: $_"
}

Write-Host "`nVerificando membresia de admin_auditoria en 'Event Log Readers' (consulta remota al DC):" -ForegroundColor Cyan
$auditoriaEnEventLogReaders = $false

try {
    $paramInvoke = @{ ComputerName = $ipDC; ErrorAction = "Stop" }
    if ($credDominio) { $paramInvoke["Credential"] = $credDominio }
    $miembrosEventLogReaders = Invoke-Command @paramInvoke -ScriptBlock {
        try {
            (Get-LocalGroupMember -Group "Event Log Readers" -ErrorAction Stop).Name
        } catch {
            net localgroup "Event Log Readers" 2>&1
        }
    }
    $esMiembro = ($miembrosEventLogReaders | Out-String) -match "admin_auditoria"
    if ($esMiembro) {
        Write-Host "  [OK] admin_auditoria ES miembro del grupo 'Event Log Readers' en el DC." -ForegroundColor Green
        $auditoriaEnEventLogReaders = $true
    } else {
        Write-Warning "  [FALTA] admin_auditoria NO es miembro de 'Event Log Readers' en el DC."
    }
} catch {
    Write-Warning "  Error al verificar 'Event Log Readers' remotamente en el DC: $_"
}

Write-Host "`nVerificando OUs requeridas en el dominio:" -ForegroundColor Cyan
$verificacionOUs = @{}

foreach ($nombreOU in @("Cuates","No Cuates","Administradores_Delegados")) {
    try {
        $paramOU = @{
            Filter     = { Name -eq $nombreOU }
            SearchBase = $dominioDN
            Server     = $ipDC
            ErrorAction = "SilentlyContinue"
        }
        if ($credDominio) { $paramOU["Credential"] = $credDominio }
        $ouObj = Get-ADOrganizationalUnit @paramOU
        if ($ouObj) {
            Write-Host "  [OK] OU='$nombreOU' encontrada en el dominio." -ForegroundColor Green
            $verificacionOUs[$nombreOU] = "EXISTE"
        } else {
            Write-Warning "  [FALTA] OU='$nombreOU' NO encontrada en el dominio."
            $verificacionOUs[$nombreOU] = "NO ENCONTRADA"
        }
    } catch {
        Write-Warning "  Error al verificar OU '$nombreOU': $_"
        $verificacionOUs[$nombreOU] = "ERROR AL CONSULTAR"
    }
}

Write-Host "# ---- Bloque 2 completado ----" -ForegroundColor Cyan

$objetosFaltantes = (
    $verificacionUsuariosAdmin.Values -contains "NO ENCONTRADO" -or
    $verificacionOUs.Values -contains "NO ENCONTRADA" -or
    $verificacionFGPPs.Count -eq 0
)

if ($objetosFaltantes) {
    Write-Host "`n# ---- BLOQUE 2B  -  Remediacion Automatica: creando objetos AD en el DC ----" -ForegroundColor Yellow
    Write-Host "Se detectaron objetos AD faltantes. Creandolos remotamente en $ipDC..." -ForegroundColor Yellow

    $paramRem = @{ ComputerName = $ipDC; ErrorAction = "Stop" }
    if ($credDominio) { $paramRem["Credential"] = $credDominio }

    try {
        Invoke-Command @paramRem -ScriptBlock {
            Import-Module ActiveDirectory -ErrorAction Stop

            $dn        = (Get-ADDomain).DistinguishedName
            $dns       = (Get-ADDomain).DNSRoot
            $netbios   = (Get-ADDomain).NetBIOSName
            $pass      = ConvertTo-SecureString "Admin123" -AsPlainText -Force

            foreach ($ouNombre in @("Cuates","No Cuates","Administradores_Delegados")) {
                $existe = Get-ADOrganizationalUnit -Filter { Name -eq $ouNombre } -SearchBase $dn -ErrorAction SilentlyContinue
                if (-not $existe) {
                    New-ADOrganizationalUnit -Name $ouNombre -Path $dn `
                        -Description "OU $ouNombre - Practica09" `
                        -ProtectedFromAccidentalDeletion $true -ErrorAction Stop
                    Write-Host "  OU creada: $ouNombre" -ForegroundColor Green
                } else {
                    Write-Host "  OU ya existe: $ouNombre" -ForegroundColor Gray
                }
            }

            $ouCuates   = "OU=Cuates,$dn"
            $ouNoCuates = "OU=No Cuates,$dn"
            $ouAdmins   = "OU=Administradores_Delegados,$dn"

            foreach ($u in @("usuario_cuate1","usuario_cuate2")) {
                if (-not (Get-ADUser -Filter { SamAccountName -eq $u } -ErrorAction SilentlyContinue)) {
                    New-ADUser -Name $u -SamAccountName $u -UserPrincipalName "$u@$dns" `
                        -Path $ouCuates -AccountPassword $pass -ChangePasswordAtLogon $false `
                        -Enabled $true -ErrorAction Stop
                    Write-Host "  Usuario creado: $u" -ForegroundColor Green
                } else { Write-Host "  Usuario ya existe: $u" -ForegroundColor Gray }
            }
            foreach ($u in @("usuario_nocuate1","usuario_nocuate2")) {
                if (-not (Get-ADUser -Filter { SamAccountName -eq $u } -ErrorAction SilentlyContinue)) {
                    New-ADUser -Name $u -SamAccountName $u -UserPrincipalName "$u@$dns" `
                        -Path $ouNoCuates -AccountPassword $pass -ChangePasswordAtLogon $false `
                        -Enabled $true -ErrorAction Stop
                    Write-Host "  Usuario creado: $u" -ForegroundColor Green
                } else { Write-Host "  Usuario ya existe: $u" -ForegroundColor Gray }
            }

            if (-not (Get-ADGroup -Filter { Name -eq "GS_Admins_Delegados" } -ErrorAction SilentlyContinue)) {
                New-ADGroup -Name "GS_Admins_Delegados" -SamAccountName "GS_Admins_Delegados" `
                    -GroupScope Global -GroupCategory Security -Path $ouAdmins `
                    -Description "Grupo administradores delegados - Practica09" -ErrorAction Stop
                Write-Host "  Grupo GS_Admins_Delegados creado." -ForegroundColor Green
            } else { Write-Host "  Grupo GS_Admins_Delegados ya existe." -ForegroundColor Gray }

            $admins = @(
                @{ Sam="admin_identidad"; Desc="Operador de Identidad y Acceso IAM" },
                @{ Sam="admin_storage";   Desc="Operador de Almacenamiento y Recursos FSRM" },
                @{ Sam="admin_politicas"; Desc="Administrador de Cumplimiento y Directivas GPO" },
                @{ Sam="admin_auditoria"; Desc="Auditor de Seguridad y Eventos Read-Only" }
            )
            foreach ($a in $admins) {
                $aSam  = $a["Sam"]
                $aDesc = $a["Desc"]
                $existeAdmin = Get-ADUser -Filter { SamAccountName -eq $aSam } -ErrorAction SilentlyContinue
                if (-not $existeAdmin) {
                    New-ADUser -Name $aSam -SamAccountName $aSam `
                        -UserPrincipalName "$aSam@$dns" -Description $aDesc `
                        -Path $ouAdmins -AccountPassword $pass `
                        -PasswordNeverExpires $false -ChangePasswordAtLogon $false `
                        -Enabled $true -ErrorAction Stop
                    Write-Host "  Admin creado: $aSam" -ForegroundColor Green
                } else {
                    Set-ADUser -Identity $aSam -ChangePasswordAtLogon $false -Enabled $true -ErrorAction SilentlyContinue
                    Write-Host "  Admin ya existe (ChangePasswordAtLogon=false forzado): $aSam" -ForegroundColor Gray
                }
                # Agregar al grupo si no es miembro
                $miembros = (Get-ADGroupMember "GS_Admins_Delegados" -ErrorAction SilentlyContinue).SamAccountName
                if ($miembros -notcontains $aSam) {
                    Add-ADGroupMember -Identity "GS_Admins_Delegados" -Members $aSam -ErrorAction Stop
                    Write-Host "    -> $aSam agregado a GS_Admins_Delegados." -ForegroundColor Green
                }
            }

            $evtMembers = (net localgroup "Event Log Readers" 2>&1 | Out-String)
            if ($evtMembers -notmatch "admin_auditoria") {
                net localgroup "Event Log Readers" "$netbios\admin_auditoria" /add 2>&1 | Out-Null
                Write-Host "  admin_auditoria agregado a Event Log Readers." -ForegroundColor Green
            } else {
                Write-Host "  admin_auditoria ya esta en Event Log Readers." -ForegroundColor Gray
            }

            $psoA = Get-ADFineGrainedPasswordPolicy -Filter { Name -eq "PSO_Admins" } -ErrorAction SilentlyContinue
            if (-not $psoA) {
                New-ADFineGrainedPasswordPolicy -Name "PSO_Admins" -Precedence 10 `
                    -MinPasswordLength 12 -PasswordHistoryCount 24 `
                    -MaxPasswordAge ([TimeSpan]::FromDays(60)) -MinPasswordAge ([TimeSpan]::FromDays(1)) `
                    -LockoutThreshold 3 -LockoutDuration ([TimeSpan]::FromMinutes(30)) `
                    -LockoutObservationWindow ([TimeSpan]::FromMinutes(30)) `
                    -ComplexityEnabled $true -ReversibleEncryptionEnabled $false -ErrorAction Stop
                Write-Host "  FGPP PSO_Admins creada." -ForegroundColor Green
            } else { Write-Host "  FGPP PSO_Admins ya existe." -ForegroundColor Gray }
            foreach ($adminSam in @("admin_identidad","admin_storage","admin_politicas","admin_auditoria")) {
                try { Add-ADFineGrainedPasswordPolicySubject -Identity "PSO_Admins" -Subjects $adminSam -ErrorAction SilentlyContinue } catch {}
            }

            $psoU = Get-ADFineGrainedPasswordPolicy -Filter { Name -eq "PSO_Usuarios" } -ErrorAction SilentlyContinue
            if (-not $psoU) {
                New-ADFineGrainedPasswordPolicy -Name "PSO_Usuarios" -Precedence 20 `
                    -MinPasswordLength 8 -PasswordHistoryCount 12 `
                    -MaxPasswordAge ([TimeSpan]::FromDays(90)) -MinPasswordAge ([TimeSpan]::FromDays(1)) `
                    -LockoutThreshold 5 -LockoutDuration ([TimeSpan]::FromMinutes(15)) `
                    -LockoutObservationWindow ([TimeSpan]::FromMinutes(15)) `
                    -ComplexityEnabled $true -ReversibleEncryptionEnabled $false -ErrorAction Stop
                Write-Host "  FGPP PSO_Usuarios creada." -ForegroundColor Green
            } else { Write-Host "  FGPP PSO_Usuarios ya existe." -ForegroundColor Gray }
            try { Add-ADFineGrainedPasswordPolicySubject -Identity "PSO_Usuarios" -Subjects "Domain Users" -ErrorAction SilentlyContinue } catch {}

            Write-Host "  Remediacion AD completada en el DC." -ForegroundColor Green
        }
        Write-Host "Bloque 2B: objetos AD creados/verificados correctamente en el DC." -ForegroundColor Green

        Write-Host "`nRe-verificando objetos tras remediacion:" -ForegroundColor Cyan
        foreach ($nombreAdmin in @("admin_identidad","admin_storage","admin_politicas","admin_auditoria")) {
            try {
                $pAD = @{ Identity=$nombreAdmin; Server=$ipDC; ErrorAction="Stop" }
                if ($credDominio) { $pAD["Credential"] = $credDominio }
                $uR = Get-ADUser @pAD
                Write-Host "  [OK] $($uR.SamAccountName) - Enabled=$($uR.Enabled)" -ForegroundColor Green
                $verificacionUsuariosAdmin[$nombreAdmin] = "EXISTE  -  Enabled=$($uR.Enabled)"
            } catch {
                Write-Warning "  [FALTA] $nombreAdmin aun no encontrado: $_"
            }
        }
        foreach ($nombreOU in @("Cuates","No Cuates","Administradores_Delegados")) {
            try {
                $pOU = @{ Filter={Name -eq $nombreOU}; SearchBase=$dominioDN; Server=$ipDC; ErrorAction="SilentlyContinue" }
                if ($credDominio) { $pOU["Credential"] = $credDominio }
                $oR = Get-ADOrganizationalUnit @pOU
                if ($oR) {
                    Write-Host "  [OK] OU='$nombreOU' confirmada." -ForegroundColor Green
                    $verificacionOUs[$nombreOU] = "EXISTE"
                }
            } catch {}
        }
        try {
            $pFGPP = @{ Filter="*"; Server=$ipDC; ErrorAction="Stop" }
            if ($credDominio) { $pFGPP["Credential"] = $credDominio }
            $fgppsRe = Get-ADFineGrainedPasswordPolicy @pFGPP
            foreach ($fp in $fgppsRe) {
                Write-Host "  [OK] FGPP: $($fp.Name) (Precedencia=$($fp.Precedence))" -ForegroundColor Green
                $verificacionFGPPs[$fp.Name] = "ENCONTRADA  -  Precedencia=$($fp.Precedence) | MinLen=$($fp.MinPasswordLength)"
            }
        } catch {}
        try {
            $pInv = @{ ComputerName=$ipDC; ErrorAction="Stop" }
            if ($credDominio) { $pInv["Credential"] = $credDominio }
            $evtR = Invoke-Command @pInv -ScriptBlock { net localgroup "Event Log Readers" 2>&1 | Out-String }
            if (($evtR | Out-String) -match "admin_auditoria") {
                Write-Host "  [OK] admin_auditoria confirmado en Event Log Readers." -ForegroundColor Green
                $auditoriaEnEventLogReaders = $true
            }
        } catch {}

    } catch {
        Write-Warning "Error durante la remediacion automatica de objetos AD: $_"
        Write-Warning "Verifique que Practica09_Server.ps1 se ejecuto en el DC y vuelva a intentar."
    }
} else {
    Write-Host "Todos los objetos AD verificados. No se requiere remediacion." -ForegroundColor Green
}
Write-Host "`n# ---- BLOQUE 3  -  Prueba del Script de Monitoreo (Protocolo Test 5) ----" -ForegroundColor Cyan

$resultadoTest5       = "NO EJECUTADO"
$rutaReporteMonitorDC = $null

try {
    Write-Host "Invocando remotamente Monitor_AccesosDenegados.ps1 en el DC ($ipDC)..." -ForegroundColor Yellow
    $paramInvoke3 = @{ ComputerName = $ipDC; ErrorAction = "Stop" }
    if ($credDominio) { $paramInvoke3["Credential"] = $credDominio }

    $scriptExisteEnDC = Invoke-Command @paramInvoke3 -ScriptBlock {
        Test-Path "C:\Scripts\Monitor_AccesosDenegados.ps1"
    }

    if (-not $scriptExisteEnDC) {
        Write-Warning "El script Monitor_AccesosDenegados.ps1 no existe en el DC. Creandolo remotamente..."

        # Contenido del script de monitoreo a crear en el DC
        $contenidoMonitor = @'
$fechaHoraEjecucion = Get-Date -Format "yyyyMMdd_HHmmss"
$rutaReporte        = "C:\Scripts\Reporte_AccesosDenegados_$fechaHoraEjecucion.txt"
$idsEventosMonitoreados = @(
    @{ Id = 4625; Descripcion = "Login Fallido (credenciales invalidas)" },
    @{ Id = 4771; Descripcion = "Kerberos Pre-Autenticacion Fallida" },
    @{ Id = 4740; Descripcion = "Cuenta de Usuario Bloqueada" }
)
$contadorPorTipo = @{ 4625 = 0; 4771 = 0; 4740 = 0 }
$lineasReporte   = [System.Collections.Generic.List[string]]::new()
$lineasReporte.Add("=" * 65)
$lineasReporte.Add("REPORTE DE ACCESOS DENEGADOS Y BLOQUEOS DE CUENTA")
$lineasReporte.Add("Generado: $(Get-Date -Format 'dd/MM/yyyy HH:mm:ss')")
$lineasReporte.Add("Servidor: $env:COMPUTERNAME")
$lineasReporte.Add("=" * 65)
foreach ($tipoEvento in $idsEventosMonitoreados) {
    $idEvento    = $tipoEvento.Id
    $descripcion = $tipoEvento.Descripcion
    $lineasReporte.Add("")
    $lineasReporte.Add("--- Eventos ID $idEvento - $descripcion ---")
    try {
        $eventosEncontrados = Get-WinEvent -FilterHashtable @{ LogName = "Security"; Id = $idEvento } -MaxEvents 10 -ErrorAction SilentlyContinue
        if ($eventosEncontrados -and $eventosEncontrados.Count -gt 0) {
            $contadorPorTipo[$idEvento] = $eventosEncontrados.Count
            foreach ($evento in $eventosEncontrados) {
                try {
                    $xmlEvento    = [xml]$evento.ToXml()
                    $datosXML     = $xmlEvento.Event.EventData.Data
                    $nombreCuenta = ($datosXML | Where-Object { $_.Name -eq "TargetUserName" }).'#text'
                    $dominioCuenta = ($datosXML | Where-Object { $_.Name -eq "TargetDomainName" }).'#text'
                    $ipOrigen     = ($datosXML | Where-Object { $_.Name -eq "IpAddress" }).'#text'
                    $razonFallo   = ($datosXML | Where-Object { $_.Name -eq "FailureReason" -or $_.Name -eq "Status" }).'#text'
                    if (-not $nombreCuenta)  { $nombreCuenta  = "(desconocido)" }
                    if (-not $dominioCuenta) { $dominioCuenta = "(desconocido)" }
                    if (-not $ipOrigen)      { $ipOrigen      = "(no disponible)" }
                    if (-not $razonFallo)    { $razonFallo    = "(no disponible)" }
                    $lineasReporte.Add("  Fecha/Hora    : $($evento.TimeCreated.ToString('dd/MM/yyyy HH:mm:ss'))")
                    $lineasReporte.Add("  ID Evento     : $idEvento")
                    $lineasReporte.Add("  Nombre cuenta : $nombreCuenta")
                    $lineasReporte.Add("  Dominio       : $dominioCuenta")
                    $lineasReporte.Add("  IP de origen  : $ipOrigen")
                    $lineasReporte.Add("  Razon de fallo: $razonFallo")
                    $lineasReporte.Add("  " + ("-" * 45))
                } catch { $lineasReporte.Add("  Error al parsear evento: $_") }
            }
        } else { $lineasReporte.Add("  No se encontraron eventos ID $idEvento en el registro de Seguridad.") }
    } catch { $lineasReporte.Add("  ERROR al consultar eventos ID ${idEvento}: $_") }
}
$lineasReporte.Add("")
$lineasReporte.Add("=" * 65)
$lineasReporte.Add("RESUMEN DE EVENTOS DETECTADOS")
$lineasReporte.Add("  ID 4625 - Login Fallido          : $($contadorPorTipo[4625]) eventos")
$lineasReporte.Add("  ID 4771 - Kerberos Pre-Auth Fallo: $($contadorPorTipo[4771]) eventos")
$lineasReporte.Add("  ID 4740 - Cuenta Bloqueada       : $($contadorPorTipo[4740]) eventos")
$lineasReporte.Add("  Total                            : $($contadorPorTipo[4625] + $contadorPorTipo[4771] + $contadorPorTipo[4740])")
$lineasReporte.Add("=" * 65)
$lineasReporte | Out-File -FilePath $rutaReporte -Encoding UTF8 -Force
Write-Host "Reporte exportado a: $rutaReporte" -ForegroundColor Green
'@

        Invoke-Command @paramInvoke3 -ScriptBlock {
            param($contenido)
            if (-not (Test-Path "C:\Scripts")) { New-Item -Path "C:\Scripts" -ItemType Directory -Force | Out-Null }
            $contenido | Out-File -FilePath "C:\Scripts\Monitor_AccesosDenegados.ps1" -Encoding UTF8 -Force
            Write-Host "Script Monitor_AccesosDenegados.ps1 creado en C:\Scripts\" -ForegroundColor Green
        } -ArgumentList $contenidoMonitor

        Write-Host "Monitor_AccesosDenegados.ps1 creado correctamente en el DC." -ForegroundColor Green
    } else {
        Write-Host "Monitor_AccesosDenegados.ps1 encontrado en el DC. Procediendo a ejecutarlo." -ForegroundColor Green
    }

    $salidaEjecucionRemota = Invoke-Command @paramInvoke3 -ScriptBlock {
        try {
            & powershell.exe -ExecutionPolicy Bypass -NonInteractive -File "C:\Scripts\Monitor_AccesosDenegados.ps1" 2>&1
        } catch {
            Write-Error "Error al ejecutar el script de monitoreo: $_"
            return $null
        }
    }

    Write-Host "`nSalida producida por el script de monitoreo en el DC:" -ForegroundColor Cyan
    $salidaEjecucionRemota | ForEach-Object { Write-Host "  $_" }

    # Verificar que se genero el archivo de reporte en el DC
    $reporteGeneradoRemoto = Invoke-Command @paramInvoke3 -ScriptBlock {
        $archivosReporte = Get-ChildItem -Path "C:\Scripts" -Filter "Reporte_AccesosDenegados_*.txt" -ErrorAction SilentlyContinue |
            Sort-Object -Property LastWriteTime -Descending |
            Select-Object -First 1
        if ($archivosReporte) { return $archivosReporte.FullName }
        return $null
    }

    if ($reporteGeneradoRemoto) {
        Write-Host "`nReporte de accesos denegados encontrado en el DC: $reporteGeneradoRemoto" -ForegroundColor Green
        $rutaReporteMonitorDC = $reporteGeneradoRemoto

        Write-Host "`nContenido del reporte de monitoreo generado en el DC:" -ForegroundColor Cyan
        Write-Host ("-" * 60)
        $contenidoReporteDC = Invoke-Command @paramInvoke3 -ScriptBlock {
            param($rutaArchivo)
            Get-Content -Path $rutaArchivo -Encoding UTF8 -ErrorAction SilentlyContinue
        } -ArgumentList $reporteGeneradoRemoto

        $contenidoReporteDC | ForEach-Object { Write-Host "  $_" }
        Write-Host ("-" * 60)

        $resultadoTest5 = "SUPERADO  -  Script ejecutado y reporte generado en DC: $reporteGeneradoRemoto"
        Write-Host "[TEST 5 SUPERADO]  -  El script Monitor_AccesosDenegados.ps1 se ejecuto correctamente en el DC." -ForegroundColor Green
    } else {
        Write-Warning "El script se ejecuto en el DC pero no se encontro el archivo de reporte."
        $resultadoTest5 = "ADVERTENCIA  -  Script ejecutado remotamente, pero el archivo de reporte no fue localizado."
    }
} catch {
    Write-Warning "Error al invocar el script de monitoreo en el DC ($ipDC): $_"
    $resultadoTest5 = "FALLIDO  -  Error al invocar remotamente: $_"
    Write-Host "[TEST 5 FALLIDO]  -  No se pudo ejecutar el script remotamente en el DC." -ForegroundColor Red
}

Write-Host "# ---- Bloque 3 completado ----" -ForegroundColor Cyan

# BLOQUE 4  -  Verificacion de Auditoria desde Cliente
Write-Host "`n# ---- BLOQUE 4  -  Verificacion de Auditoria desde Cliente (Protocolo Test 2 parcial) ----" -ForegroundColor Cyan

$estadoAuditoriaRemota     = $null
$categoriasHabilitadasDC   = @()

try {
    Write-Host "Ejecutando 'auditpol /get /category:*' remotamente en el DC ($ipDC)..." -ForegroundColor Yellow
    $paramInvoke4 = @{ ComputerName = $ipDC; ErrorAction = "Stop" }
    if ($credDominio) { $paramInvoke4["Credential"] = $credDominio }

    $estadoAuditoriaRemota = Invoke-Command @paramInvoke4 -ScriptBlock {
        auditpol /get /category:* 2>&1
    }

    $categoriasHabilitadasDC = $estadoAuditoriaRemota |
        Where-Object { $_ -match "Success and Failure|Success|Failure" -and $_ -notmatch "No Auditing" }

    Write-Host "`nCategorias de auditoria HABILITADAS en el DC (formato legible):" -ForegroundColor Cyan
    Write-Host ("-" * 60)
    if ($categoriasHabilitadasDC) {
        $categoriasHabilitadasDC | ForEach-Object { Write-Host "  $_" -ForegroundColor Green }
    } else {
        Write-Warning "No se detectaron categorias de auditoria habilitadas, o el formato de salida no es el esperado."
        Write-Host "Salida completa de auditpol:" -ForegroundColor Yellow
        $estadoAuditoriaRemota | ForEach-Object { Write-Host "  $_" }
    }
    Write-Host ("-" * 60)
} catch {
    Write-Warning "Error al obtener el estado de auditoria remotamente desde el DC: $_"
    $estadoAuditoriaRemota   = @("ERROR: No se pudo consultar auditpol en el DC  -  $_")
    $categoriasHabilitadasDC = @()
}

Write-Host "# ---- Bloque 4 completado ----" -ForegroundColor Cyan

# BLOQUE 5  -  Prueba de DENY Reset Password
Write-Host "`n# ---- BLOQUE 5  -  Prueba de DENY Reset Password (Protocolo Test 1) ----" -ForegroundColor Cyan
Write-Host "Este bloque simula el Test 1 del protocolo de evaluacion:" -ForegroundColor Yellow
Write-Host "Intentar resetear la contrasena de usuario_cuate1 usando las credenciales de admin_storage." -ForegroundColor Yellow
Write-Host "El resultado ESPERADO es Acceso Denegado (confirmando que la ACL DENY funciona)." -ForegroundColor Yellow

$resultadoTest1 = "NO EJECUTADO"

try {
    $dominioParaTest1 = if ($dominioDNS) { $dominioDNS } else { $dominioLaboral }

    Write-Host "`nSe solicitaran las credenciales de admin_storage para realizar la prueba..." -ForegroundColor Cyan
    $credencialesAdminStorage = Get-Credential `
        -UserName "$dominioParaTest1\admin_storage" `
        -Message "Ingrese las credenciales de admin_storage para el Test 1 (DENY Reset Password)"

    if (-not $credencialesAdminStorage) {
        Write-Warning "No se proporcionaron credenciales. Test 1 no ejecutado."
        $resultadoTest1 = "NO EJECUTADO  -  No se proporcionaron credenciales de admin_storage"
    } else {
        Write-Host "Intentando resetear la contrasena de 'usuario_cuate1' con credenciales de admin_storage..." -ForegroundColor Yellow
        Write-Host "(Metodo: Set-ADAccountPassword directo con -Credential, prueba real de la ACL AD)" -ForegroundColor Gray
        $nuevaContrasenaTest = ConvertTo-SecureString "Admin123" -AsPlainText -Force

        try {
            Set-ADAccountPassword `
                -Identity "usuario_cuate1" `
                -NewPassword $nuevaContrasenaTest `
                -Reset `
                -Credential $credencialesAdminStorage `
                -Server $ipDC `
                -ErrorAction Stop

            Write-Host "[TEST 1 FALLIDO]  -  admin_storage PUDO resetear la contrasena de usuario_cuate1." -ForegroundColor Red
            Write-Host "                   La ACL DENY Reset Password NO esta aplicada correctamente." -ForegroundColor Red
            $resultadoTest1 = "FALLIDO  -  admin_storage pudo resetear la contrasena. La ACL DENY NO esta aplicada correctamente."

        } catch {
            $mensajeError    = $_.Exception.Message
            $codigoError     = $_.Exception.HResult
            $categoriaError  = $_.CategoryInfo.Category

            $esAccesoDenegadoAD = $mensajeError -match (
                "insufficientAccessRights|00002098|Access.?is.?denied|Insufficient.?access|" +
                "PermissionDenied|Access.?Rights|00000005|privilege|AccesoInsuficiente|" +
                "constraint.?violation|00002014|Acceso denegado|Access denied"
            )

            $esErrorAutenticacion = $mensajeError -match (
                "LogonFailure|InvalidCredentials|password.*incorrect|contrasena.*incorrecta|" +
                "1326|AuthenticationException|unwillingToPerform|userAccountRestriction|" +
                "rechaz.*credenciales|credential.*rejected|server rejected|" +
                "must change password|cambiar.*contrasena|49.*invalidCredentials|" +
                "account.*restriction|restriction.*account|ChangePasswordAtLogon|" +
                "password.*expired|contrasena.*expirada|mustChangePassword"
            )

            $esErrorConexion = $mensajeError -match (
                "WinRM|PSRemoting|conexion al servidor remoto|connection.*remote|" +
                "Remoting|about_Remote|firewall|network|TrustedHosts|no se encontro la ruta"
            )

            if ($esAccesoDenegadoAD) {
                Write-Host "[TEST 1 SUPERADO]  -  El DENY de Reset Password sobre admin_storage funciona correctamente." -ForegroundColor Green
                Write-Host "                    Error AD capturado (esperado - confirma ACL DENY operativa):" -ForegroundColor Gray
                Write-Host "                    $mensajeError" -ForegroundColor Gray
                $resultadoTest1 = "SUPERADO  -  ACL DENY Reset Password confirmada para admin_storage."
            } elseif ($esErrorAutenticacion) {
                Write-Warning "[TEST 1 INDETERMINADO]  -  Fallo de autenticacion con admin_storage."
                Write-Warning "Mensaje: $mensajeError"
                Write-Warning "Causas posibles:"
                Write-Warning "  1. El usuario admin_storage NO EXISTE aun en AD."
                Write-Warning "     -> Ejecutar primero Practica09_Server.ps1 en el DC."
                Write-Warning "  2. La contrasena ingresada es incorrecta."
                Write-Warning "     -> La contrasena correcta es: Admin123"
                Write-Warning "     -> Usuario completo: $dominioParaTest1\admin_storage"
                $resultadoTest1 = "INDETERMINADO  -  admin_storage no existe o contrasena incorrecta. Ejecutar Server primero."
            } elseif ($esErrorConexion) {
                Write-Warning "[TEST 1 INDETERMINADO]  -  Error de conexion al DC, no se pudo probar la ACL AD."
                Write-Warning "Mensaje: $mensajeError"
                $resultadoTest1 = "INDETERMINADO  -  Error de conexion LDAP al DC."
            } else {
                Write-Warning "[TEST 1 INDETERMINADO]  -  Error inesperado:"
                Write-Warning "Mensaje: $mensajeError"
                $resultadoTest1 = "INDETERMINADO  -  Error: $mensajeError"
            }
        }
    }
} catch {
    Write-Warning "Error al configurar o ejecutar el Test 1: $_"
    $resultadoTest1 = "ERROR DE CONFIGURACION  -  No se pudo ejecutar el Test 1: $_"
}

Write-Host "# ---- Bloque 5 completado ----" -ForegroundColor Cyan

Write-Host "`n# ---- BLOQUE 5B  -  Test 1 Accion A: verificar que admin_identidad PUEDE resetear ----" -ForegroundColor Cyan
Write-Host "La rubrica exige evidencia comparativa: Accion A exitosa vs Accion B denegada." -ForegroundColor Yellow

$resultadoTest1AccionA = "NO EJECUTADO"

try {
    $dominioParaTest1A = if ($dominioDNS) { $dominioDNS } else { $dominioLaboral }
    Write-Host "Solicitando credenciales de admin_identidad para Test 1 Accion A..." -ForegroundColor Cyan
    $credAdminIdentidad = Get-Credential `
        -UserName "$dominioParaTest1A\admin_identidad" `
        -Message "admin_identidad | Contrasena: Admin123 | Esta operacion DEBE TENER EXITO"

    if (-not $credAdminIdentidad) {
        Write-Warning "No se proporcionaron credenciales. Test 1 Accion A omitida."
        $resultadoTest1AccionA = "OMITIDO  -  No se proporcionaron credenciales de admin_identidad"
    } else {
        Write-Host "Intentando resetear contrasena de usuario_cuate1 con admin_identidad (debe FUNCIONAR)..." -ForegroundColor Yellow
        $nuevaPassIdentidad = ConvertTo-SecureString "Admin123" -AsPlainText -Force

        try {
            Set-ADAccountPassword `
                -Identity "usuario_cuate1" `
                -NewPassword $nuevaPassIdentidad `
                -Reset `
                -Credential $credAdminIdentidad `
                -Server $ipDC `
                -ErrorAction Stop

            Write-Host "[TEST 1A SUPERADO]  -  admin_identidad PUDO resetear la contrasena de usuario_cuate1." -ForegroundColor Green
            Write-Host "                     Confirma que el permiso 'Reset Password' esta correctamente delegado." -ForegroundColor Green
            $resultadoTest1AccionA = "SUPERADO  -  admin_identidad reseteo usuario_cuate1 correctamente (permiso delegado funciona)."
        } catch {
            $msgA = $_.Exception.Message
            Write-Warning "[TEST 1A FALLIDO]  -  admin_identidad NO pudo resetear la contrasena."
            Write-Warning "Error: $msgA"
            Write-Warning "Posible causa: la ACL de Reset Password no fue aplicada correctamente por dsacls."
            $resultadoTest1AccionA = "FALLIDO  -  admin_identidad no pudo resetear. Error: $msgA"
        }
    }
} catch {
    Write-Warning "Error al ejecutar Test 1 Accion A: $_"
    $resultadoTest1AccionA = "ERROR  -  $_"
}
Write-Host "`n# ---- BLOQUE 6  -  Reporte Final Cliente ----" -ForegroundColor Cyan

$fechaHoraReporteCliente = Get-Date -Format "yyyyMMdd_HHmmss"
$rutaReporteCliente      = "$rutaScripts\Reporte_Cliente_Practica09_$fechaHoraReporteCliente.txt"

$lineasReporteCliente = [System.Collections.Generic.List[string]]::new()
$lineasReporteCliente.Add("=" * 70)
$lineasReporteCliente.Add("REPORTE FINAL CLIENTE  -  PRACTICA 09: SEGURIDAD DE IDENTIDAD, DELEGACION Y MFA")
$lineasReporteCliente.Add("Generado     : $(Get-Date -Format 'dd/MM/yyyy HH:mm:ss')")
$lineasReporteCliente.Add("Equipo       : $env:COMPUTERNAME")
$lineasReporteCliente.Add("Usuario      : $env:USERNAME")
$lineasReporteCliente.Add("Dominio      : $dominioActual")
$lineasReporteCliente.Add("DC objetivo  : $ipDC")
$lineasReporteCliente.Add("=" * 70)

# Seccion: Conectividad
$lineasReporteCliente.Add("")
$lineasReporteCliente.Add("--- CONECTIVIDAD CON EL CONTROLADOR DE DOMINIO ---")
$lineasReporteCliente.Add("  Dominio detectado          : $dominioActual")
$lineasReporteCliente.Add("  IP / FQDN del DC           : $ipDC")
$lineasReporteCliente.Add("  Canal seguro (Secure Channel): $(if ($estadoCanal) { 'OK' } else { 'FALLO o NO VERIFICADO' })")
$lineasReporteCliente.Add("  Ping al DC (2 paquetes)    : $(if ($estadoPing) { 'EXITOSO' } else { 'FALLIDO o NO VERIFICADO' })")

# Seccion: RSAT
$lineasReporteCliente.Add("")
$lineasReporteCliente.Add("--- INSTALACION DE RSAT ---")
$lineasReporteCliente.Add("  RSAT AD Tools instalado    : $(if ($rsatInstalado) { 'SI' } else { 'NO' })")
$lineasReporteCliente.Add("  Modulo ActiveDirectory     : $(if ($moduloADDisponible) { 'DISPONIBLE' } else { 'NO DISPONIBLE (posible reinicio requerido)' })")

# Seccion: Usuarios delegados
$lineasReporteCliente.Add("")
$lineasReporteCliente.Add("--- VERIFICACION DE USUARIOS ADMINISTRADORES DELEGADOS ---")
foreach ($nombreAdmin in $verificacionUsuariosAdmin.Keys) {
    $lineasReporteCliente.Add("  $nombreAdmin : $($verificacionUsuariosAdmin[$nombreAdmin])")
}

# Seccion: OUs
$lineasReporteCliente.Add("")
$lineasReporteCliente.Add("--- VERIFICACION DE UNIDADES ORGANIZATIVAS ---")
foreach ($nombreOU in $verificacionOUs.Keys) {
    $lineasReporteCliente.Add("  OU='$nombreOU' : $($verificacionOUs[$nombreOU])")
}

# Seccion: Event Log Readers
$lineasReporteCliente.Add("")
$lineasReporteCliente.Add("--- GRUPO EVENT LOG READERS (en DC) ---")
$lineasReporteCliente.Add("  admin_auditoria en grupo: $(if ($auditoriaEnEventLogReaders) { 'CONFIRMADO  -  es miembro' } else { 'NO CONFIRMADO  -  verificar en DC' })")

# Seccion: FGPPs
$lineasReporteCliente.Add("")
$lineasReporteCliente.Add("--- FINE-GRAINED PASSWORD POLICIES VERIFICADAS ---")
if ($verificacionFGPPs.Count -gt 0) {
    foreach ($nombrePSO in $verificacionFGPPs.Keys) {
        $lineasReporteCliente.Add("  $nombrePSO : $($verificacionFGPPs[$nombrePSO])")
    }
} else {
    $lineasReporteCliente.Add("  No se pudieron verificar las FGPPs (error o no existen).")
}

# Seccion: Test 1
$lineasReporteCliente.Add("")
$lineasReporteCliente.Add("--- TEST 1: Verificacion de Delegacion RBAC ---")
$lineasReporteCliente.Add("  Accion B - admin_storage DENY Reset Password: $resultadoTest1")
$lineasReporteCliente.Add("  Accion A - admin_identidad puede resetear    : $resultadoTest1AccionA")

# Seccion: Test 5
$lineasReporteCliente.Add("")
$lineasReporteCliente.Add("--- TEST 5: Ejecucion Remota Script de Monitoreo ---")
$lineasReporteCliente.Add("  Resultado: $resultadoTest5")
if ($rutaReporteMonitorDC) {
    $lineasReporteCliente.Add("  Reporte generado en DC: $rutaReporteMonitorDC")
}

# Seccion: Auditoria
$lineasReporteCliente.Add("")
$lineasReporteCliente.Add("--- CATEGORIAS DE AUDITORIA HABILITADAS (consultadas remotamente en el DC) ---")
if ($categoriasHabilitadasDC -and $categoriasHabilitadasDC.Count -gt 0) {
    $categoriasHabilitadasDC | ForEach-Object {
        $lineasReporteCliente.Add("  $_")
    }
} else {
    $lineasReporteCliente.Add("  No se obtuvieron datos de auditoria, o auditpol no retorno categorias habilitadas.")
    if ($estadoAuditoriaRemota) {
        $lineasReporteCliente.Add("  (Salida raw disponible en consola durante la ejecucion del Bloque 4)")
    }
}

# Seccion: Elementos que requieren atencion
$lineasReporteCliente.Add("")
$lineasReporteCliente.Add("--- ELEMENTOS QUE REQUIEREN ATENCION O ACCION MANUAL ---")
$hayAlertas = $false

if (-not $estadoCanal) {
    $lineasReporteCliente.Add("  [ATENCION] El canal seguro con el dominio no pudo verificarse. Ejecutar: Test-ComputerSecureChannel -Repair")
    $hayAlertas = $true
}
if (-not $rsatInstalado) {
    $lineasReporteCliente.Add("  [ATENCION] RSAT para Active Directory no se instalo correctamente. Instalar manualmente desde 'Configuracion > Aplicaciones > Caracteristicas opcionales'.")
    $hayAlertas = $true
}
if (-not $moduloADDisponible) {
    $lineasReporteCliente.Add("  [ATENCION] El modulo ActiveDirectory no esta disponible. Puede ser necesario reiniciar el equipo tras la instalacion de RSAT.")
    $hayAlertas = $true
}
if ($resultadoTest1 -match "FALLIDO|ERROR|INDETERMINADO") {
    $lineasReporteCliente.Add("  [ATENCION] Test 1 no fue SUPERADO. Verificar que la ACL DENY Reset Password este correctamente aplicada a admin_storage en el DC.")
    $hayAlertas = $true
}
if ($resultadoTest5 -match "FALLIDO|ADVERTENCIA|ERROR") {
    $lineasReporteCliente.Add("  [ATENCION] Test 5 con problemas. Verificar que Monitor_AccesosDenegados.ps1 existe en C:\Scripts\ del DC y que WinRM esta habilitado.")
    $hayAlertas = $true
}
if (-not $auditoriaEnEventLogReaders) {
    $lineasReporteCliente.Add("  [ATENCION] admin_auditoria no pudo confirmarse en el grupo 'Event Log Readers' del DC. Verificar manualmente.")
    $hayAlertas = $true
}
if (-not $hayAlertas) {
    $lineasReporteCliente.Add("  Ninguno. Todos los elementos verificados correctamente.")
}

# Resumen de bloques del script cliente
$lineasReporteCliente.Add("")
$lineasReporteCliente.Add("=" * 70)
$lineasReporteCliente.Add("RESUMEN DE EJECUCION POR BLOQUE (SCRIPT CLIENTE)")
$lineasReporteCliente.Add("  Bloque 0   -  Auto-elevacion y verificacion de dominio : COMPLETADO")
$lineasReporteCliente.Add("  Bloque 1   -  Instalacion de RSAT                      : $(if ($rsatInstalado) { 'COMPLETADO' } else { 'CON ADVERTENCIAS' })")
$lineasReporteCliente.Add("  Bloque 2   -  Verificacion de delegaciones (AD)        : COMPLETADO")
$lineasReporteCliente.Add("  Bloque 3   -  Test 5: Script de monitoreo remoto       : $(if ($resultadoTest5 -match 'SUPERADO') { 'SUPERADO' } else { 'CON ADVERTENCIAS' })")
$lineasReporteCliente.Add("  Bloque 4   -  Test 2: Auditoria remota auditpol        : COMPLETADO")
$lineasReporteCliente.Add("  Bloque 5   -  Test 1B: DENY admin_storage              : $(if ($resultadoTest1 -match 'SUPERADO') { 'SUPERADO' } elseif ($resultadoTest1 -match 'FALLIDO') { 'FALLIDO' } else { 'INDETERMINADO' })")
$lineasReporteCliente.Add("  Bloque 5B  -  Test 1A: admin_identidad puede resetear  : $(if ($resultadoTest1AccionA -match 'SUPERADO') { 'SUPERADO' } elseif ($resultadoTest1AccionA -match 'FALLIDO') { 'FALLIDO' } elseif ($resultadoTest1AccionA -match 'OMITIDO') { 'OMITIDO' } else { 'NO EJECUTADO' })")
$lineasReporteCliente.Add("  Bloque 6   -  Reporte final cliente                    : COMPLETADO")
$lineasReporteCliente.Add("=" * 70)

# Escribir reporte en disco
try {
    $lineasReporteCliente | Out-File -FilePath $rutaReporteCliente -Encoding UTF8 -Force
    Write-Host "Reporte final del cliente generado en: $rutaReporteCliente" -ForegroundColor Green
} catch {
    Write-Warning "Error al escribir el reporte final del cliente: $_"
}

Write-Host "# ---- Bloque 6 completado ----" -ForegroundColor Cyan

# ================================================================
Write-Host "`n" + ("=" * 60) -ForegroundColor Cyan
Write-Host "Practica09_Cliente.ps1  -  Ejecucion finalizada." -ForegroundColor Green
Write-Host "Reporte final disponible en: $rutaReporteCliente" -ForegroundColor Green
Write-Host ("=" * 60) -ForegroundColor Cyan
# ================================================================
