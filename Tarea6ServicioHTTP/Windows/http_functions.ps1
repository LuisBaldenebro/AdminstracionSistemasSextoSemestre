function Verificar-Administrador {
    param([string]$ScriptPath = "")
    $id = [Security.Principal.WindowsIdentity]::GetCurrent()
    $pr = New-Object Security.Principal.WindowsPrincipal($id)
    if (-not $pr.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
        Write-Host "  [!!] Se requiere ejecutar como Administrador." -ForegroundColor Red
        exit 1
    }
}

function Establecer-PoliticaEjecucion {
    Set-ExecutionPolicy Bypass -Scope Process      -Force -ErrorAction SilentlyContinue
    Set-ExecutionPolicy Bypass -Scope LocalMachine -Force -ErrorAction SilentlyContinue
}

function Escribir-Titulo {
    param([string]$Texto)
    Write-Host ""
    Write-Host ("=" * 62) -ForegroundColor Cyan
    Write-Host "  $Texto"  -ForegroundColor Cyan
    Write-Host ("=" * 62) -ForegroundColor Cyan
}
function Escribir-Separador { Write-Host ("-" * 62) -ForegroundColor DarkGray }
function Escribir-Exito { param([string]$M) Write-Host "  [OK]  $M" -ForegroundColor Green  }
function Escribir-Aviso { param([string]$M) Write-Host "  [!!]  $M" -ForegroundColor Yellow }
function Escribir-Error { param([string]$M) Write-Host "  [XX]  $M" -ForegroundColor Red    }
function Escribir-Info  { param([string]$M) Write-Host "  [--]  $M" -ForegroundColor Cyan   }

function Pausar {
    Write-Host ""
    Write-Host "  Presiona ENTER para continuar..." -ForegroundColor DarkGray
    Read-Host | Out-Null
}

function Leer-Entrada {
    param(
        [string]$Mensaje,
        [string]$Predeterminado = "",
        [string]$Patron = ".*"
    )
    do {
        if ($Predeterminado -ne "") {
            $raw = Read-Host "  $Mensaje [$Predeterminado]"
        } else {
            $raw = Read-Host "  $Mensaje"
        }
        if ($null -eq $raw -or $raw.Trim() -eq "") {
            $valor = $Predeterminado
        } else {
            $valor = ($raw.Trim() -replace '[<>|&;`]', '').Trim()
            if ($valor -eq "" -and $Predeterminado -ne "") { $valor = $Predeterminado }
        }
        if ($valor -eq "" -or $valor -notmatch $Patron) {
            Write-Host "  [XX]  Entrada invalida. Intenta de nuevo." -ForegroundColor Red
        }
    } while ($valor -eq "" -or $valor -notmatch $Patron)
    return $valor
}

function Leer-Puerto {
    param([int]$PuertoPredeterminado = 8080)
    do {
        $entrada = Leer-Entrada "Puerto de escucha" "$PuertoPredeterminado" "^\d+$"
        $puerto  = [int]$entrada
        if ($puerto -lt 1 -or $puerto -gt 65535) {
            Escribir-Error "Puerto fuera de rango (1-65535)."; $puerto = 0; continue
        }
        $reservados = @(21,22,23,25,53,110,143,443,445,3306,3389,5985,5986)
        if ($reservados -contains $puerto) {
            Escribir-Aviso "Puerto $puerto reservado. Elige otro."; $puerto = 0; continue
        }
        if (Verificar-PuertoOcupado $puerto) {
            Escribir-Aviso "Puerto $puerto ya esta en uso."
            $r = Leer-Entrada "Usar otro puerto? (s/n)" "s" "^[sSnN]$"
            if ($r -match "^[sS]$") { $puerto = 0 }
        }
    } while ($puerto -eq 0)
    return $puerto
}

function Verificar-PuertoOcupado {
    param([int]$Puerto)
    $conn = Get-NetTCPConnection -State Listen -ErrorAction SilentlyContinue |
            Where-Object { $_.LocalPort -eq $Puerto }
    return ($null -ne $conn)
}

function Asegurar-Chocolatey {
    $chocoExe = "C:\ProgramData\chocolatey\bin\choco.exe"
    if (Test-Path $chocoExe) {
        Escribir-Exito "Chocolatey disponible."
        if ($env:PATH -notlike "*chocolatey*") {
            $env:PATH = [System.Environment]::GetEnvironmentVariable("PATH","Machine") + ";" +
                        [System.Environment]::GetEnvironmentVariable("PATH","User")
        }
        return
    }
    Escribir-Info "Instalando Chocolatey..."
    [System.Net.ServicePointManager]::SecurityProtocol = `
        [System.Net.ServicePointManager]::SecurityProtocol -bor 3072
    try {
        $script = (New-Object System.Net.WebClient).DownloadString(
            'https://community.chocolatey.org/install.ps1')
        Invoke-Expression $script *>&1 | Out-Null
    } catch {
        Escribir-Aviso "No se pudo instalar Chocolatey: $($_.Exception.Message)"
        return
    }
    $env:PATH = [System.Environment]::GetEnvironmentVariable("PATH","Machine") + ";" +
                [System.Environment]::GetEnvironmentVariable("PATH","User")
    $env:ChocolateyInstall = "C:\ProgramData\chocolatey"
    Start-Sleep -Seconds 3
    if (Test-Path $chocoExe) { Escribir-Exito "Chocolatey instalado." }
}

function Detectar-RutaNginx {
    $posibles = @("C:\nginx","C:\tools\nginx",
        "C:\ProgramData\chocolatey\lib\nginx\tools\nginx*",
        "$env:ProgramFiles\nginx*")
    foreach ($p in $posibles) {
        $candidatos = Resolve-Path $p -ErrorAction SilentlyContinue
        foreach ($c in $candidatos) {
            if (Test-Path "$($c.Path)\nginx.exe") { return $c.Path }
        }
    }
    $e = Get-ChildItem "C:\" -Filter "nginx.exe" -Recurse -ErrorAction SilentlyContinue |
         Select-Object -First 1
    if ($e) { return $e.DirectoryName }
    return $null
}

function Escribir-ConfSinBOM {
    param([string]$Ruta, [string]$Contenido)
    $utf8NoBom = [System.Text.UTF8Encoding]::new($false)
    [System.IO.File]::WriteAllText($Ruta, $Contenido, $utf8NoBom)
}

function Verificar-YReiniciar-Apache {
    param([string]$Dir = "C:\Apache24")
    $httpdExe   = "$Dir\bin\httpd.exe"
    $confApache = "$Dir\conf\httpd.conf"

    if (-not (Test-Path $httpdExe)) {
        Escribir-Error "httpd.exe no encontrado en $Dir\bin\"
        return $false
    }

    # Validar config antes de reiniciar
    $testOut = & $httpdExe -t 2>&1
    if ($LASTEXITCODE -ne 0) {
        Escribir-Error "httpd.conf tiene errores - NO se reinicia:"
        $testOut | ForEach-Object { Write-Host "    $_" -ForegroundColor Red }
        return $false
    }

    # Intentar via servicio
    $svc = Get-Service "Apache24" -ErrorAction SilentlyContinue
    if ($svc) {
        Restart-Service "Apache24" -Force -ErrorAction SilentlyContinue
        Start-Sleep -Seconds 3
        $svc = Get-Service "Apache24" -ErrorAction SilentlyContinue
        if ($svc -and $svc.Status -eq "Running") {
            Escribir-Exito "Servicio Apache24 activo."
            return $true
        }
    }

    # Fallback: arrancar como proceso
    Stop-Process -Name httpd -Force -ErrorAction SilentlyContinue
    Start-Sleep -Seconds 1
    Start-Process -FilePath $httpdExe -WorkingDirectory $Dir -WindowStyle Hidden
    Start-Sleep -Seconds 3
    if (Get-Process httpd -ErrorAction SilentlyContinue) {
        Escribir-Exito "Apache activo como proceso."
        return $true
    }

    Escribir-Error "Apache no pudo arrancar. Log:"
    if (Test-Path "$Dir\logs\error.log") {
        Get-Content "$Dir\logs\error.log" -Tail 10 |
            ForEach-Object { Write-Host "    $_" -ForegroundColor Red }
    }
    return $false
}

# ----------------------------------------------------------
#  MODULO 1 - GESTION DINAMICA DE VERSIONES
# ----------------------------------------------------------

function Obtener-VersionesApache {
    $v = @(
        [PSCustomObject]@{ Etiqueta="[1] v2.4.x Estable  - Descarga automatica"; Version="2.4-estable";  URLs=@() },
        [PSCustomObject]@{ Etiqueta="[2] v2.4.x Reciente - Descarga automatica"; Version="2.4-reciente"; URLs=@() },
        [PSCustomObject]@{ Etiqueta="[3] v2.4.x Ultima   - Descarga automatica"; Version="2.4-ultima";   URLs=@() }
    )
    Escribir-Info "Apache: la version exacta se resuelve en tiempo real desde apachelounge.com"
    return $v
}

function Obtener-VersionesNginx {
    $v = @(
        [PSCustomObject]@{ Etiqueta="[1] v1.24.0 - Estable";    Version="1.24.0"; URL="https://nginx.org/download/nginx-1.24.0.zip" },
        [PSCustomObject]@{ Etiqueta="[2] v1.26.2 - Recomendada"; Version="1.26.2"; URL="https://nginx.org/download/nginx-1.26.2.zip" },
        [PSCustomObject]@{ Etiqueta="[3] v1.27.4 - Mas nueva";  Version="1.27.4"; URL="https://nginx.org/download/nginx-1.27.4.zip" }
    )
    return $v
}

function Obtener-VersionesIIS {
    $v = @(
        [PSCustomObject]@{ Etiqueta="[1] Basico    - IIS + contenido estatico";  Version="10.0-basico";    URL="" },
        [PSCustomObject]@{ Etiqueta="[2] Estandar  - IIS + ASP.NET";             Version="10.0-estandar";  URL="" },
        [PSCustomObject]@{ Etiqueta="[3] Completo  - IIS + todos los modulos";   Version="10.0-completo";  URL="" }
    )
    Escribir-Info "IIS 10 incluido en Windows Server 2022 (sin descarga)."
    return $v
}

function Mostrar-MenuVersiones {
    param([array]$Versiones, [string]$Servicio)
    Escribir-Titulo "Selecciona la Version de $Servicio"
    $validas = $Versiones | Where-Object { $_ -is [PSCustomObject] -and $_.Etiqueta }
    for ($i = 0; $i -lt $validas.Count; $i++) {
        Write-Host "  $($validas[$i].Etiqueta)"           -ForegroundColor White
        Write-Host "    Version: $($validas[$i].Version)" -ForegroundColor DarkGray
    }
    Escribir-Separador
    $max = $validas.Count
    $sel = Leer-Entrada "Elige una opcion (1-$max)" "2" "^[1-$max]$"
    return $validas[[int]$sel - 1]
}

# ----------------------------------------------------------
#  HERRAMIENTAS DE DESCARGA
# ----------------------------------------------------------

function Instalar-VCRedist {
    if (Test-Path "$env:SystemRoot\System32\vcruntime140.dll") {
        Escribir-Exito "VC++ Redistributable ya presente."
        return
    }
    Escribir-Info "Instalando VC++ Redistributable 2015-2026..."
    New-Item -ItemType Directory -Path "C:\Temp" -Force | Out-Null
    $vcExe = "C:\Temp\vc_redist.x64.exe"
    $url   = "https://aka.ms/vc14/vc_redist.x64.exe"
    $curlExe = "$env:SystemRoot\System32\curl.exe"
    if (Test-Path $curlExe) {
        & $curlExe -sL --max-redirs 10 --max-time 120 --retry 3 -o $vcExe $url 2>&1 | Out-Null
    }
    if (-not ((Test-Path $vcExe) -and (Get-Item $vcExe).Length -gt 1MB)) {
        try { (New-Object System.Net.WebClient).DownloadFile($url, $vcExe) } catch {}
    }
    if ((Test-Path $vcExe) -and (Get-Item $vcExe).Length -gt 1MB) {
        $p = Start-Process $vcExe -ArgumentList "/install /quiet /norestart" -Wait -PassThru
        Remove-Item $vcExe -Force -ErrorAction SilentlyContinue
        if ($p.ExitCode -in @(0,3010,1638)) { Escribir-Exito "VC++ instalado." }
        else { Escribir-Aviso "VC++ codigo salida: $($p.ExitCode)" }
    } else {
        Escribir-Aviso "No se pudo descargar VC++ Redist."
    }
}

function Obtener-UrlApacheLounge {
    Write-Host "  Consultando apachelounge.com para URL actual..." -ForegroundColor Cyan
    try {
        [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
        $wc = New-Object System.Net.WebClient
        $wc.Headers.Add("User-Agent", "Mozilla/5.0 (Windows NT 10.0; Win64; x64) Chrome/124.0")
        $html = $wc.DownloadString("https://www.apachelounge.com/download/")
        $wc.Dispose()
        $match = [regex]::Match($html, 'httpd-([\d\.\-]+Win64-VS1[78])\.zip',
                                [System.Text.RegularExpressions.RegexOptions]::IgnoreCase)
        if ($match.Success) {
            $zipName = $match.Value
            $vsDir   = if ($zipName -like "*VS18*") { "VS18" } else { "VS17" }
            $url     = "https://www.apachelounge.com/download/$vsDir/binaries/$zipName"
            Escribir-Exito "URL detectada: $zipName"
            return $url
        }
    } catch {
        Write-Host "  No se pudo consultar apachelounge.com: $($_.Exception.Message)" -ForegroundColor DarkGray
    }
    Escribir-Aviso "Usando URL de respaldo..."
    return "https://www.apachelounge.com/download/VS18/binaries/httpd-2.4.66-260223-Win64-VS18.zip"
}

function Descargar-ConReintentos {
    param([string]$URL, [string]$Destino)
    [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
    $curlExe = "$env:SystemRoot\System32\curl.exe"
    Remove-Item $Destino -Force -ErrorAction SilentlyContinue
    if (Test-Path $curlExe) {
        Write-Host "  Descargando con curl..." -ForegroundColor DarkGray
        & $curlExe -L --progress-bar `
            -A "Mozilla/5.0 (Windows NT 10.0; Win64; x64) Chrome/124.0 Safari/537.36" `
            -e "https://www.apachelounge.com/download/" `
            --max-redirs 10 --connect-timeout 30 --max-time 600 `
            --retry 3 --retry-delay 5 -o $Destino $URL 2>&1
    }
    if ((Test-Path $Destino) -and (Get-Item $Destino).Length -gt 1MB) { return $true }
    Remove-Item $Destino -Force -ErrorAction SilentlyContinue
    Write-Host "  Descargando con Invoke-WebRequest..." -ForegroundColor DarkGray
    try {
        Invoke-WebRequest -Uri $URL -OutFile $Destino `
            -Headers @{"User-Agent"="Mozilla/5.0 Chrome/124.0";"Referer"="https://www.apachelounge.com/download/"} `
            -UseBasicParsing -TimeoutSec 600 -ErrorAction Stop
    } catch { Write-Host "    $($_.Exception.Message)" -ForegroundColor DarkGray }
    if ((Test-Path $Destino) -and (Get-Item $Destino).Length -gt 1MB) { return $true }
    Remove-Item $Destino -Force -ErrorAction SilentlyContinue
    Write-Host "  Descargando con WebClient..." -ForegroundColor DarkGray
    try {
        $wc = New-Object System.Net.WebClient
        $wc.Headers.Add("User-Agent","Mozilla/5.0 Chrome/124.0")
        $wc.Headers.Add("Referer","https://www.apachelounge.com/download/")
        $wc.DownloadFile($URL, $Destino)
        $wc.Dispose()
    } catch { Write-Host "    $($_.Exception.Message)" -ForegroundColor DarkGray }
    if ((Test-Path $Destino) -and (Get-Item $Destino).Length -gt 1MB) { return $true }
    return $false
}

# ----------------------------------------------------------
#  INSTALACION IIS
# ----------------------------------------------------------

function Instalar-IIS {
    param([object]$VersionInfo, [int]$Puerto)
    Escribir-Titulo "Instalando IIS - $($VersionInfo.Version)"
    $features = @("Web-Server","Web-WebServer","Web-Common-Http","Web-Default-Doc",
        "Web-Dir-Browsing","Web-Http-Errors","Web-Static-Content","Web-Http-Logging",
        "Web-Stat-Compression","Web-Filtering","Web-Mgmt-Tools","Web-Mgmt-Console",
        "Web-Scripting-Tools","Web-Mgmt-Service")
    switch ($VersionInfo.Version) {
        "10.0-estandar" { $features += @("Web-Asp-Net45","Web-Net-Ext45","Web-ISAPI-Ext",
            "Web-ISAPI-Filter","Web-Windows-Auth","Web-Basic-Auth","Web-App-Dev") }
        "10.0-completo" { $features += @("Web-Asp-Net45","Web-Net-Ext45","Web-ISAPI-Ext",
            "Web-ISAPI-Filter","Web-Windows-Auth","Web-Basic-Auth","Web-Digest-Auth",
            "Web-App-Dev","Web-Dyn-Compression","Web-Http-Redirect","Web-Http-Tracing",
            "Web-Performance","Web-Security","Web-WebSockets") }
    }
    Escribir-Info "Activando caracteristicas de IIS..."
    foreach ($f in $features) {
        $r = Install-WindowsFeature -Name $f -IncludeManagementTools -ErrorAction SilentlyContinue
        if ($r.Success) { Escribir-Exito "Activada: $f" }
        else            { Escribir-Aviso "Ya activa o no disponible: $f" }
    }
    Import-Module WebAdministration -Force -ErrorAction SilentlyContinue
    Start-Service W3SVC -ErrorAction SilentlyContinue
    Start-Sleep -Seconds 2
    $poolName = "AppPool_Puerto$Puerto"
    if (-not (Test-Path "IIS:\AppPools\$poolName")) {
        New-WebAppPool -Name $poolName -ErrorAction SilentlyContinue | Out-Null
    }
    Set-ItemProperty "IIS:\AppPools\$poolName" -Name processModel.identityType -Value 4
    Set-ItemProperty "IIS:\AppPools\$poolName" -Name managedPipelineMode       -Value 0
    Set-ItemProperty "IIS:\AppPools\$poolName" -Name managedRuntimeVersion      -Value ""
    $rutaWeb = "C:\inetpub\wwwroot"
    New-Item -ItemType Directory -Path $rutaWeb -Force | Out-Null
    Get-WebBinding -Name "Default Web Site" -ErrorAction SilentlyContinue |
        Remove-WebBinding -ErrorAction SilentlyContinue
    New-WebBinding -Name "Default Web Site" -IPAddress "*" -Port $Puerto -Protocol "http" -Force
    Set-ItemProperty "IIS:\Sites\Default Web Site" -Name applicationPool -Value $poolName
    Set-ItemProperty "IIS:\Sites\Default Web Site" -Name physicalPath    -Value $rutaWeb
    Set-WebConfigurationProperty -Filter "/system.webServer/security/authentication/anonymousAuthentication" `
        -PSPath "IIS:\Sites\Default Web Site" -Name "enabled" -Value $true
    Set-WebConfigurationProperty -Filter "/system.webServer/security/authentication/anonymousAuthentication" `
        -PSPath "IIS:\Sites\Default Web Site" -Name "userName" -Value ""
    Set-WebConfigurationProperty -Filter "/system.webServer/security/authentication/windowsAuthentication" `
        -PSPath "IIS:\Sites\Default Web Site" -Name "enabled" -Value $false -ErrorAction SilentlyContinue
    Clear-WebConfiguration -Filter "system.webServer/defaultDocument/files" `
        -PSPath "IIS:\Sites\Default Web Site" -ErrorAction SilentlyContinue
    foreach ($doc in @("index.html","index.htm","default.html","iisstart.htm")) {
        Add-WebConfigurationProperty -Filter "system.webServer/defaultDocument/files" `
            -PSPath "IIS:\Sites\Default Web Site" -Name "." -Value @{value=$doc} -ErrorAction SilentlyContinue
    }
    Set-WebConfigurationProperty -Filter "system.webServer/defaultDocument" `
        -PSPath "IIS:\Sites\Default Web Site" -Name "enabled" -Value $true
    Configurar-PermisoInetpub -AppPoolName $poolName
    Crear-PaginaIndex "IIS" $VersionInfo.Version $Puerto $rutaWeb
    Restart-Service W3SVC -Force -ErrorAction SilentlyContinue
    Start-Sleep -Seconds 2
    Escribir-Exito "IIS iniciado en puerto $Puerto."
    Escribir-Info  "Accede en: http://localhost:$Puerto"
}

# ----------------------------------------------------------
#  INSTALACION APACHE
# ----------------------------------------------------------

function Instalar-Apache {
    param([object]$VersionInfo, [int]$Puerto)
    Escribir-Titulo "Instalando Apache HTTP Server para Windows Server 2022"

    $dir  = "C:\Apache24"
    $temp = "C:\Temp\apache_install"

    # 1. VC++ Redistributable primero
    Instalar-VCRedist

    # 2. Limpiar instalacion previa
    Escribir-Info "Limpiando instalacion previa..."
    Stop-Service "Apache24" -Force -ErrorAction SilentlyContinue
    Start-Sleep -Seconds 1
    if (Test-Path "$dir\bin\httpd.exe") {
        & "$dir\bin\httpd.exe" -k uninstall -n "Apache24" 2>&1 | Out-Null
    }
    sc.exe stop   "Apache24" 2>&1 | Out-Null
    sc.exe delete "Apache24" 2>&1 | Out-Null
    Start-Sleep -Seconds 2
    Remove-Item $dir  -Recurse -Force -ErrorAction SilentlyContinue
    Remove-Item $temp -Recurse -Force -ErrorAction SilentlyContinue
    New-Item -ItemType Directory -Path $dir  -Force | Out-Null
    New-Item -ItemType Directory -Path $temp -Force | Out-Null

    $httpdExe  = $null
    $apacheVer = "2.4.x"

    # METODO A: winget
    Escribir-Info "Metodo 1/3: winget install Apache.Httpd..."
    $winget = Get-Command winget -ErrorAction SilentlyContinue
    if ($winget) {
        winget install -e --id Apache.Httpd --silent --accept-package-agreements `
            --accept-source-agreements 2>&1 |
            Where-Object { $_ -match "(Apache|install|error|found)" } |
            ForEach-Object { Write-Host "    $_" -ForegroundColor DarkGray }
        Start-Sleep -Seconds 4
        $found = Get-ChildItem "C:\" -Filter "httpd.exe" -Recurse -Depth 8 `
                    -ErrorAction SilentlyContinue | Select-Object -First 1
        if ($found) {
            $httpdExe  = $found.FullName
            $apacheVer = if ($found.FullName -match "(\d+\.\d+\.\d+)") { $Matches[1] } else { "2.4.x" }
            Escribir-Exito "Apache instalado via winget: $httpdExe"
        }
    } else {
        Escribir-Aviso "winget no disponible."
    }

    # METODO B: Descarga directa con URL dinamica
    if (-not $httpdExe) {
        Escribir-Info "Metodo 2/3: descarga directa (URL dinamica desde apachelounge.com)..."
        $zipPath = "$temp\apache.zip"
        $zipUrl  = Obtener-UrlApacheLounge
        $descargaOk = Descargar-ConReintentos -URL $zipUrl -Destino $zipPath
        if ($descargaOk) {
            Escribir-Exito "ZIP descargado ($([math]::Round((Get-Item $zipPath).Length/1MB,1)) MB)."
            try {
                $extractDir = "$temp\extracted"
                New-Item -ItemType Directory $extractDir -Force | Out-Null
                Expand-Archive -Path $zipPath -DestinationPath $extractDir -Force
                $found = Get-ChildItem $extractDir -Filter "httpd.exe" -Recurse `
                            -ErrorAction SilentlyContinue | Select-Object -First 1
                if ($found) {
                    $apacheSrc = Split-Path (Split-Path $found.FullName -Parent) -Parent
                    Remove-Item $dir -Recurse -Force -ErrorAction SilentlyContinue
                    New-Item -ItemType Directory $dir -Force | Out-Null
                    Copy-Item "$apacheSrc\*" $dir -Recurse -Force
                    $httpdExe = "$dir\bin\httpd.exe"
                    if ($zipUrl -match 'httpd-([\d\.]+)-') { $apacheVer = $Matches[1] }
                    Escribir-Exito "Apache extraido en $dir (v$apacheVer)"
                } else { Escribir-Error "No se encontro httpd.exe en el ZIP." }
            } catch { Escribir-Error "Error al extraer: $($_.Exception.Message)" }
        } else { Escribir-Aviso "Descarga directa fallida." }
    }

    # METODO C: Chocolatey
    if (-not $httpdExe) {
        Escribir-Info "Metodo 3/3: Chocolatey..."
        Asegurar-Chocolatey
        $chocoExe = "C:\ProgramData\chocolatey\bin\choco.exe"
        if (Test-Path $chocoExe) {
            & $chocoExe install apache-httpd -y --force --no-progress --ignore-checksums 2>&1 |
                Where-Object { $_ -match "(install|error|apache)" -and $_ -ne "" } |
                ForEach-Object { Write-Host "    $_" -ForegroundColor DarkGray }
            Start-Sleep -Seconds 3
            $found = Get-ChildItem "C:\" -Filter "httpd.exe" -Recurse -Depth 10 `
                        -ErrorAction SilentlyContinue | Select-Object -First 1
            if ($found) { $httpdExe = $found.FullName; Escribir-Exito "Apache via Chocolatey: $httpdExe" }
        }
    }

    # Normalizar a C:\Apache24
    if ($httpdExe -and (Test-Path $httpdExe)) {
        $dirReal = Split-Path (Split-Path $httpdExe -Parent) -Parent
        if ($dirReal -ne $dir) {
            Escribir-Info "Normalizando a $dir..."
            Remove-Item $dir -Recurse -Force -ErrorAction SilentlyContinue
            Copy-Item $dirReal $dir -Recurse -Force -ErrorAction SilentlyContinue
        }
    }
    if (-not (Test-Path "$dir\bin\httpd.exe")) {
        Escribir-Error "Apache no pudo instalarse."
        Escribir-Aviso "Verifica la conexion a internet y vuelve a intentarlo."
        Remove-Item $temp -Recurse -Force -ErrorAction SilentlyContinue
        return
    }
    $httpdExe = "$dir\bin\httpd.exe"
    Escribir-Exito "httpd.exe listo: $httpdExe"

    # Configurar httpd.conf SIN BOM
    $confApache = "$dir\conf\httpd.conf"
    if (-not (Test-Path $confApache)) {
        Escribir-Error "httpd.conf no encontrado."
        return
    }
    Escribir-Info "Configurando httpd.conf (puerto $Puerto)..."
    $srvRoot = $dir -replace '\\', '/'
    $conf    = [System.IO.File]::ReadAllText($confApache)
    $conf    = $conf.TrimStart([char]0xFEFF)  # Quitar BOM si existe
    $conf = $conf -replace 'Define SRVROOT "[^"]*"',     "Define SRVROOT `"$srvRoot`""
    $conf = $conf -replace '(?m)^ServerRoot "[^"]*"',    "ServerRoot `"$srvRoot`""
    $conf = $conf -replace '(?m)^Listen \S+',            "Listen $Puerto"
    $conf = $conf -replace '(?m)^#?ServerName [^\r\n]*', "ServerName localhost:$Puerto"
    $conf = $conf -replace '#LoadModule headers_module',  'LoadModule headers_module'
    $conf = $conf -replace '#LoadModule rewrite_module',  'LoadModule rewrite_module'
    Escribir-ConfSinBOM -Ruta $confApache -Contenido $conf
    Escribir-Exito "httpd.conf configurado (sin BOM)."

    # Permisos NTFS
    icacls $dir /grant "SYSTEM:(OI)(CI)(F)"         /T /Q 2>&1 | Out-Null
    icacls $dir /grant "Administrators:(OI)(CI)(F)" /T /Q 2>&1 | Out-Null
    icacls $dir /grant "Everyone:(OI)(CI)(RX)"      /T /Q 2>&1 | Out-Null
    Escribir-Exito "Permisos NTFS aplicados."

    # Validar y registrar servicio
    $testOut = & $httpdExe -t 2>&1
    if ($LASTEXITCODE -ne 0) {
        Escribir-Error "Errores en httpd.conf:"
        $testOut | ForEach-Object { Write-Host "    $_" -ForegroundColor Red }
        Remove-Item $temp -Recurse -Force -ErrorAction SilentlyContinue
        return
    }
    Escribir-Exito "Configuracion valida."

    sc.exe stop   "Apache24" 2>&1 | Out-Null
    sc.exe delete "Apache24" 2>&1 | Out-Null
    Start-Sleep -Seconds 1
    & $httpdExe -k install -n "Apache24" 2>&1 | Out-Null
    sc.exe config "Apache24" start= auto 2>&1 | Out-Null
    Start-Sleep -Seconds 1
    sc.exe start "Apache24" 2>&1 | Out-Null
    Start-Sleep -Seconds 5

    $svc = Get-Service "Apache24" -ErrorAction SilentlyContinue
    if ($svc -and $svc.Status -eq "Running") {
        Escribir-Exito "Servicio Apache24 en ejecucion."
    } else {
        Escribir-Aviso "Iniciando Apache como proceso directo..."
        Start-Process -FilePath $httpdExe -WorkingDirectory $dir -WindowStyle Hidden
        Start-Sleep -Seconds 4
        if (-not (Get-Process httpd -ErrorAction SilentlyContinue)) {
            Escribir-Error "Apache no pudo arrancar."
            if (Test-Path "$dir\logs\error.log") {
                Get-Content "$dir\logs\error.log" -Tail 15 |
                    ForEach-Object { Write-Host "    $_" -ForegroundColor Red }
            }
            Remove-Item $temp -Recurse -Force -ErrorAction SilentlyContinue
            return
        }
        Escribir-Exito "Apache corriendo como proceso."
    }

    # Firewall
    netsh advfirewall firewall delete rule name="Apache-HTTP-$Puerto" 2>&1 | Out-Null
    netsh advfirewall firewall add rule name="Apache-HTTP-$Puerto" `
        protocol=TCP dir=in localport=$Puerto action=allow profile=any enable=yes 2>&1 | Out-Null
    Escribir-Exito "Puerto $Puerto abierto en Firewall."

    # Pagina index
    $htdocs = "$dir\htdocs"
    New-Item -ItemType Directory -Path $htdocs -Force | Out-Null
    Crear-PaginaIndex "Apache" $apacheVer $Puerto $htdocs

    # Verificar HTTP
    $ok = $false
    for ($i = 1; $i -le 8; $i++) {
        Start-Sleep -Seconds 2
        try {
            $r = Invoke-WebRequest -Uri "http://localhost:$Puerto" -UseBasicParsing -TimeoutSec 5 -ErrorAction Stop
            if ($r.StatusCode -lt 500) { $ok = $true; break }
        } catch {}
        Write-Host "  [$i/8] Esperando respuesta HTTP en :$Puerto..." -ForegroundColor DarkGray
    }

    $ip = (Get-NetIPAddress -AddressFamily IPv4 -ErrorAction SilentlyContinue |
           Where-Object { $_.InterfaceAlias -notlike "*Loopback*" } |
           Select-Object -First 1).IPAddress

    Write-Host ""
    Write-Host ("=" * 62) -ForegroundColor $(if ($ok) { "Green" } else { "Yellow" })
    if ($ok) { Escribir-Exito "APACHE INSTALADO Y RESPONDIENDO EN PUERTO $Puerto" }
    else      { Escribir-Aviso "APACHE INSTALADO (verifica en el navegador)" }
    Write-Host ("=" * 62) -ForegroundColor $(if ($ok) { "Green" } else { "Yellow" })
    Escribir-Info "URL local  : http://localhost:$Puerto"
    if ($ip) { Escribir-Info "URL en red : http://${ip}:$Puerto" }
    Escribir-Info "Web root   : $htdocs"
    Escribir-Info "Log errores: $dir\logs\error.log"
    Write-Host ""

    Remove-Item $temp -Recurse -Force -ErrorAction SilentlyContinue
}

# ----------------------------------------------------------
#  INSTALACION NGINX
# ----------------------------------------------------------

function Arrancar-Nginx {
    param([string]$DirNginx = "C:\nginx")
    $nginxExe  = "$DirNginx\nginx.exe"
    $confNginx = "$DirNginx\conf\nginx.conf"
    if (-not (Test-Path $nginxExe)) { Escribir-Error "nginx.exe no encontrado."; return $false }
    Stop-Process -Name nginx -Force -ErrorAction SilentlyContinue
    Start-Sleep -Seconds 1
    if (Test-Path $confNginx) {
        $bytes = [System.IO.File]::ReadAllBytes($confNginx)
        if ($bytes.Length -ge 3 -and $bytes[0] -eq 0xEF -and $bytes[1] -eq 0xBB -and $bytes[2] -eq 0xBF) {
            [System.IO.File]::WriteAllBytes($confNginx, $bytes[3..($bytes.Length - 1)])
        }
    }
    $testOut = & $nginxExe -p $DirNginx -t 2>&1
    if ($LASTEXITCODE -ne 0) {
        Escribir-Error "nginx.conf tiene errores:"
        $testOut | ForEach-Object { Write-Host "    $_" -ForegroundColor Red }
        return $false
    }
    $proc = Start-Process -FilePath $nginxExe -ArgumentList "-p `"$DirNginx`"" `
        -WorkingDirectory $DirNginx -WindowStyle Hidden -PassThru -ErrorAction SilentlyContinue
    Start-Sleep -Seconds 2
    if ($proc -and (-not $proc.HasExited)) { Escribir-Exito "Nginx corriendo (PID $($proc.Id))."; return $true }
    if (Test-Path "$DirNginx\logs\error.log") {
        Get-Content "$DirNginx\logs\error.log" -Tail 8 |
            ForEach-Object { Write-Host "    $_" -ForegroundColor Red }
    }
    return $false
}

function Registrar-NginxArranqueAutomatico {
    param([string]$DirNginx = "C:\nginx")
    $taskName = "Nginx_HTTP_Server"
    Unregister-ScheduledTask -TaskName $taskName -Confirm:$false -ErrorAction SilentlyContinue
    $action    = New-ScheduledTaskAction -Execute "$DirNginx\nginx.exe" `
                    -Argument "-p `"$DirNginx`"" -WorkingDirectory $DirNginx
    $trigger   = New-ScheduledTaskTrigger -AtStartup
    $settings  = New-ScheduledTaskSettingsSet -ExecutionTimeLimit (New-TimeSpan -Seconds 0) `
                    -RestartCount 3 -RestartInterval (New-TimeSpan -Minutes 1) -StartWhenAvailable $true
    $principal = New-ScheduledTaskPrincipal -UserId "SYSTEM" -LogonType ServiceAccount -RunLevel Highest
    Register-ScheduledTask -TaskName $taskName -Action $action -Trigger $trigger `
        -Settings $settings -Principal $principal -Force | Out-Null
    Escribir-Exito "Tarea programada '$taskName' creada."
}

function Instalar-Nginx {
    param([object]$VersionInfo, [int]$Puerto)
    Escribir-Titulo "Instalando Nginx para Windows - v$($VersionInfo.Version)"
    $dirFinal    = "C:\nginx"
    $dirDescarga = "C:\Temp\nginx_install"
    $archivoZip  = "$dirDescarga\nginx.zip"
    New-Item -ItemType Directory -Path $dirDescarga -Force | Out-Null
    Stop-Process -Name nginx -Force -ErrorAction SilentlyContinue
    Unregister-ScheduledTask -TaskName "Nginx_HTTP_Server" -Confirm:$false -ErrorAction SilentlyContinue
    if (Test-Path $dirFinal) { Remove-Item $dirFinal -Recurse -Force -ErrorAction SilentlyContinue }
    Escribir-Info "Descargando Nginx $($VersionInfo.Version)..."
    try {
        [System.Net.ServicePointManager]::SecurityProtocol = `
            [System.Net.ServicePointManager]::SecurityProtocol -bor 3072
        Invoke-WebRequest -Uri $VersionInfo.URL -OutFile $archivoZip -UseBasicParsing -TimeoutSec 120 -ErrorAction Stop
        Expand-Archive -Path $archivoZip -DestinationPath $dirDescarga -Force
        $sub = Get-ChildItem $dirDescarga -Directory |
               Where-Object { $_.Name -like "nginx*" } | Select-Object -First 1
        if ($sub) {
            New-Item -ItemType Directory -Path $dirFinal -Force | Out-Null
            Copy-Item "$($sub.FullName)\*" $dirFinal -Recurse -Force
        }
    } catch { Escribir-Aviso "Descarga directa fallida: $($_.Exception.Message)" }
    if (-not (Test-Path "$dirFinal\nginx.exe")) {
        Asegurar-Chocolatey | Out-Null
        & "C:\ProgramData\chocolatey\bin\choco.exe" install nginx -y --force --no-progress 2>&1 | Out-Null
        $rutaDetectada = Detectar-RutaNginx
        if ($rutaDetectada -and $rutaDetectada -ne $dirFinal) {
            New-Item -ItemType Directory -Path $dirFinal -Force | Out-Null
            Copy-Item "$rutaDetectada\*" $dirFinal -Recurse -Force
        }
    }
    if (-not (Test-Path "$dirFinal\nginx.exe")) { Escribir-Error "No se pudo instalar Nginx."; return }
    foreach ($d in @("logs","html","temp","client_body_temp","proxy_temp","fastcgi_temp")) {
        New-Item -ItemType Directory -Path "$dirFinal\$d" -Force | Out-Null
    }
    $confNginx = "$dirFinal\conf\nginx.conf"
    $conf = [System.IO.File]::ReadAllText($confNginx).TrimStart([char]0xFEFF)
    $conf = $conf -replace '(\blisten\s+)\d+(\s*;)', "`${1}$Puerto`$2"
    [System.IO.File]::WriteAllText($confNginx, $conf, [System.Text.UTF8Encoding]::new($false))
    Arrancar-Nginx -DirNginx $dirFinal
    Registrar-NginxArranqueAutomatico -DirNginx $dirFinal
    Configurar-PermisoNginx -DirNginx $dirFinal
    Crear-PaginaIndex "Nginx" $VersionInfo.Version $Puerto "$dirFinal\html"
    $ip = (Get-NetIPAddress -AddressFamily IPv4 -ErrorAction SilentlyContinue |
           Where-Object { $_.InterfaceAlias -notlike "*Loopback*" } |
           Select-Object -First 1).IPAddress
    Escribir-Exito "====== NGINX INSTALADO ======"
    Escribir-Info  "Acceso local  : http://localhost:$Puerto"
    if ($ip) { Escribir-Info "Acceso en red : http://${ip}:$Puerto" }
}

# ----------------------------------------------------------
#  MODULO 3 - FIREWALL (sin reglas duplicadas)
# ----------------------------------------------------------

function Configurar-Firewall {
    param([int]$Puerto, [string]$Servicio)
    Escribir-Titulo "Configuracion de Firewall - Puerto $Puerto"

    # Eliminar TODAS las reglas HTTP existentes para evitar duplicados
    Get-NetFirewallRule -ErrorAction SilentlyContinue |
        Where-Object { $_.DisplayName -like "HTTP-*" } |
        Remove-NetFirewallRule -ErrorAction SilentlyContinue
    netsh advfirewall firewall delete rule name="Apache-HTTP-$Puerto" 2>&1 | Out-Null

    # Crear solo la regla necesaria
    New-NetFirewallRule -DisplayName "HTTP-$Servicio-Puerto$Puerto" `
        -Direction Inbound -Protocol TCP -LocalPort $Puerto `
        -Action Allow -Profile Any -Enabled True -ErrorAction Stop | Out-Null
    Escribir-Exito "Puerto $Puerto abierto en el Firewall."

    Escribir-Info "Reglas Firewall HTTP activas:"
    Get-NetFirewallRule -ErrorAction SilentlyContinue |
        Where-Object { $_.DisplayName -like "HTTP-*" } |
        Format-Table DisplayName, Enabled, Action -AutoSize
}

# ----------------------------------------------------------
#  MODULO 4 - SEGURIDAD
# ----------------------------------------------------------

function Ocultar-VersionIIS {
    Escribir-Titulo "Seguridad IIS - Ocultando Version"
    Import-Module WebAdministration -Force -ErrorAction SilentlyContinue
    try {
        Remove-WebConfigurationProperty -PSPath 'MACHINE/WEBROOT/APPHOST' `
            -Filter 'system.webServer/httpProtocol/customHeaders' `
            -Name '.' -AtElement @{name='X-Powered-By'} -ErrorAction SilentlyContinue
        Escribir-Exito "X-Powered-By eliminado."
    } catch {}
    try {
        Set-WebConfigurationProperty -PSPath 'MACHINE/WEBROOT/APPHOST' `
            -Filter 'system.webServer/security/requestFiltering' `
            -Name 'removeServerHeader' -Value $true
        Escribir-Exito "Encabezado Server ocultado."
    } catch {
        & "$env:windir\system32\inetsrv\appcmd.exe" set config `
            /section:requestFiltering /removeServerHeader:true 2>&1 | Out-Null
    }
    Restart-Service W3SVC -Force -ErrorAction SilentlyContinue
}

function Ocultar-VersionApache {
    # FIX v7: todos los archivos .conf se escriben SIN BOM
    param([string]$DirConf = "C:\Apache24\conf")
    Escribir-Titulo "Seguridad Apache - Ocultando Version"
    if (-not (Test-Path $DirConf)) { Escribir-Aviso "Directorio conf no encontrado."; return }

    New-Item -ItemType Directory -Path "$DirConf\extra" -Force | Out-Null
    $confExtra = "$DirConf\extra\httpd-security.conf"
    Escribir-ConfSinBOM -Ruta $confExtra -Contenido "ServerTokens Prod`r`nServerSignature Off"

    $confP = "$DirConf\httpd.conf"
    $contenido = [System.IO.File]::ReadAllText($confP).TrimStart([char]0xFEFF)
    if ($contenido -notmatch "Include conf/extra/httpd-security.conf") {
        $contenido += "`r`nInclude conf/extra/httpd-security.conf"
    }
    Escribir-ConfSinBOM -Ruta $confP -Contenido $contenido
    Escribir-Exito "ServerTokens Prod configurado."

    # Reiniciar y verificar
    Verificar-YReiniciar-Apache -Dir "C:\Apache24" | Out-Null
}

function Ocultar-VersionNginx {
    param([string]$DirNginx = "C:\nginx")
    Escribir-Titulo "Seguridad Nginx - Ocultando Version"
    if (-not (Test-Path "$DirNginx\conf\nginx.conf")) {
        $d = Detectar-RutaNginx; if ($d) { $DirNginx = $d }
    }
    $confNginx = "$DirNginx\conf\nginx.conf"
    if (-not (Test-Path $confNginx)) { Escribir-Error "nginx.conf no encontrado."; return }
    $utf8NoBom = [System.Text.UTF8Encoding]::new($false)
    $c = [System.IO.File]::ReadAllText($confNginx).TrimStart([char]0xFEFF)
    $c = if ($c -notmatch 'server_tokens') {
             $c -replace '(http\s*\{)', "`$1`r`n    server_tokens off;"
         } else { $c -replace 'server_tokens\s+\w+;', 'server_tokens off;' }
    [System.IO.File]::WriteAllText($confNginx, $c, $utf8NoBom)
    & "$DirNginx\nginx.exe" -p $DirNginx -s reload 2>&1 | Out-Null
    Escribir-Exito "server_tokens off aplicado."
}

# ----------------------------------------------------------
#  MODULO 5 - PERMISOS NTFS
# ----------------------------------------------------------

function Configurar-PermisoInetpub {
    param([string]$AppPoolName = "DefaultAppPool")
    Escribir-Titulo "Permisos NTFS - inetpub (IIS)"
    $ruta = "C:\inetpub\wwwroot"
    New-Item -ItemType Directory -Path $ruta -Force | Out-Null
    icacls $ruta /grant "IUSR:(OI)(CI)(RX)"           /T /Q 2>&1 | Out-Null
    icacls $ruta /grant "IIS_IUSRS:(OI)(CI)(RX)"       /T /Q 2>&1 | Out-Null
    icacls $ruta /grant "SYSTEM:(OI)(CI)(F)"            /T /Q 2>&1 | Out-Null
    icacls $ruta /grant "Administrators:(OI)(CI)(F)"    /T /Q 2>&1 | Out-Null
    icacls $ruta /grant "IIS AppPool\${AppPoolName}:(OI)(CI)(RX)" /T /Q 2>&1 | Out-Null
    Escribir-Exito "Permisos aplicados en $ruta"
    $usuario = "srv_iis_web"
    if (-not (Get-LocalUser -Name $usuario -ErrorAction SilentlyContinue)) {
        $passwd = ConvertTo-SecureString "P@ssIIS$(Get-Random -Maximum 9999)x!" -AsPlainText -Force
        New-LocalUser -Name $usuario -Password $passwd -PasswordNeverExpires $true `
            -UserMayNotChangePassword $true -Description "Usuario IIS" -ErrorAction SilentlyContinue | Out-Null
        Add-LocalGroupMember -Group "IIS_IUSRS" -Member $usuario -ErrorAction SilentlyContinue
        Escribir-Exito "Usuario '$usuario' creado."
    }
}

function Configurar-PermisoApache {
    Escribir-Titulo "Permisos NTFS - Apache"
    $ruta = "C:\Apache24\htdocs"
    New-Item -ItemType Directory -Path $ruta -Force | Out-Null
    icacls $ruta /grant "SYSTEM:(OI)(CI)(F)"         /T /Q 2>&1 | Out-Null
    icacls $ruta /grant "Administrators:(OI)(CI)(F)" /T /Q 2>&1 | Out-Null
    icacls $ruta /grant "Everyone:(OI)(CI)(RX)"      /T /Q 2>&1 | Out-Null
    Escribir-Exito "Permisos aplicados en $ruta"
}

function Configurar-PermisoNginx {
    param([string]$DirNginx = "C:\nginx")
    Escribir-Titulo "Permisos NTFS - Nginx"
    $ruta = "$DirNginx\html"
    New-Item -ItemType Directory -Path $ruta -Force | Out-Null
    icacls $ruta /grant "SYSTEM:(OI)(CI)(F)"         /T /Q 2>&1 | Out-Null
    icacls $ruta /grant "Administrators:(OI)(CI)(F)" /T /Q 2>&1 | Out-Null
    icacls $ruta /grant "Everyone:(OI)(CI)(RX)"      /T /Q 2>&1 | Out-Null
    Escribir-Exito "Permisos aplicados en $ruta"
}

# ----------------------------------------------------------
#  MODULO 6 - ENCABEZADOS HTTP
# ----------------------------------------------------------

function Aplicar-EncabezadosIIS {
    param([int]$Puerto = 80)
    Escribir-Titulo "Encabezados de Seguridad - IIS"
    Import-Module WebAdministration -Force -ErrorAction SilentlyContinue
    foreach ($enc in @(@{name="X-Frame-Options";value="SAMEORIGIN"},@{name="X-Content-Type-Options";value="nosniff"})) {
        try {
            Remove-WebConfigurationProperty -PSPath 'MACHINE/WEBROOT/APPHOST' `
                -Filter "system.webServer/httpProtocol/customHeaders" `
                -Name '.' -AtElement @{name=$enc.name} -ErrorAction SilentlyContinue
            Add-WebConfigurationProperty -PSPath 'MACHINE/WEBROOT/APPHOST' `
                -Filter "system.webServer/httpProtocol/customHeaders" -Name '.' -Value $enc
            Escribir-Exito "Encabezado $($enc.name) agregado."
        } catch {}
    }
    foreach ($m in @("TRACE","TRACK","DELETE")) {
        Add-WebConfigurationProperty -PSPath 'MACHINE/WEBROOT/APPHOST' `
            -Filter "system.webServer/security/requestFiltering/verbs" `
            -Name '.' -Value @{verb=$m; allowed=$false} -ErrorAction SilentlyContinue
    }
    Restart-Service W3SVC -Force -ErrorAction SilentlyContinue
    Escribir-Exito "Encabezados IIS aplicados."
}

function Aplicar-EncabezadosApache {
    # FIX v7: usa WriteAllText sin BOM en todos los archivos .conf
    param([string]$DirConf = "C:\Apache24\conf")
    Escribir-Titulo "Encabezados de Seguridad - Apache"

    New-Item -ItemType Directory -Path "$DirConf\extra" -Force | Out-Null
    $confSeg = "$DirConf\extra\httpd-security.conf"

    # Leer contenido existente sin BOM
    $lineasActuales = @()
    if (Test-Path $confSeg) {
        $lineasActuales = ([System.IO.File]::ReadAllText($confSeg).TrimStart([char]0xFEFF)) -split "`n" |
                          ForEach-Object { $_.TrimEnd() }
    }

    foreach ($linea in @(
        "Header always set X-Frame-Options SAMEORIGIN",
        "Header always set X-Content-Type-Options nosniff",
        "<LimitExcept GET POST HEAD>",
        "    Require all denied",
        "</LimitExcept>"
    )) {
        if ($lineasActuales -notcontains $linea) { $lineasActuales += $linea }
    }
    Escribir-ConfSinBOM -Ruta $confSeg -Contenido ($lineasActuales -join "`r`n")

    # Asegurar mod_headers habilitado en httpd.conf SIN BOM
    $confP = "$DirConf\httpd.conf"
    $contenido = [System.IO.File]::ReadAllText($confP).TrimStart([char]0xFEFF)
    $contenido = $contenido -replace '#LoadModule headers_module', 'LoadModule headers_module'
    Escribir-ConfSinBOM -Ruta $confP -Contenido $contenido

    Escribir-Exito "Encabezados de seguridad configurados."

    # Reiniciar y verificar que Apache siga activo
    $activo = Verificar-YReiniciar-Apache -Dir "C:\Apache24"
    if ($activo) { Escribir-Exito "Apache activo tras aplicar encabezados." }
    else         { Escribir-Error "Apache no arranco. Revisa $DirConf\httpd.conf" }
}

function Aplicar-EncabezadosNginx {
    param([string]$DirNginx = "C:\nginx")
    Escribir-Titulo "Encabezados de Seguridad - Nginx"
    if (-not (Test-Path "$DirNginx\conf\nginx.conf")) {
        $d = Detectar-RutaNginx; if ($d) { $DirNginx = $d }
    }
    $confNginx = "$DirNginx\conf\nginx.conf"
    if (-not (Test-Path $confNginx)) { Escribir-Error "nginx.conf no encontrado."; return }
    $utf8NoBom = [System.Text.UTF8Encoding]::new($false)
    $c = [System.IO.File]::ReadAllText($confNginx).TrimStart([char]0xFEFF)
    if ($c -notmatch 'X-Frame-Options') {
        $hdr = "`r`n    add_header X-Frame-Options `"SAMEORIGIN`" always;`r`n    add_header X-Content-Type-Options `"nosniff`" always;"
        $c = $c -replace '(\blocation\s+/\s*\{)', "$hdr`r`n    `$1"
    }
    [System.IO.File]::WriteAllText($confNginx, $c, $utf8NoBom)
    & "$DirNginx\nginx.exe" -p $DirNginx -s reload 2>&1 | Out-Null
    Escribir-Exito "Encabezados Nginx aplicados."
}

# ----------------------------------------------------------
#  MODULO 7 - PAGINA INDEX
# ----------------------------------------------------------

function Crear-PaginaIndex {
    param([string]$Servicio, [string]$Version, [int]$Puerto, [string]$RutaWeb)
    Escribir-Titulo "Creando Pagina Index - $Servicio"
    New-Item -ItemType Directory -Path $RutaWeb -Force | Out-Null
    $fecha   = Get-Date -Format "dd/MM/yyyy HH:mm:ss"
    $ipLocal = (Get-NetIPAddress -AddressFamily IPv4 -ErrorAction SilentlyContinue |
                Where-Object { $_.InterfaceAlias -notlike "*Loopback*" } |
                Select-Object -First 1).IPAddress
    $html  = "<!DOCTYPE html>`r`n<html lang=`"es`">`r`n<head>`r`n"
    $html += "  <meta charset=`"UTF-8`">`r`n"
    $html += "  <meta name=`"viewport`" content=`"width=device-width, initial-scale=1.0`">`r`n"
    $html += "  <title>Servidor $Servicio - Puerto $Puerto</title>`r`n"
    $html += "  <style>`r`n"
    $html += "    *{margin:0;padding:0;box-sizing:border-box}`r`n"
    $html += "    body{font-family:Segoe UI,Tahoma,sans-serif;"
    $html += "background:linear-gradient(135deg,#0a0e1a,#1a237e,#0d47a1);"
    $html += "min-height:100vh;display:flex;align-items:center;justify-content:center;color:#fff}`r`n"
    $html += "    .card{background:rgba(255,255,255,.08);border:1px solid rgba(255,255,255,.15);"
    $html += "border-radius:20px;padding:48px 56px;text-align:center;max-width:620px;width:90%}`r`n"
    $html += "    h1{font-size:2em;font-weight:700;margin-bottom:8px}`r`n"
    $html += "    .sub{color:rgba(255,255,255,.5);margin-bottom:26px}`r`n"
    $html += "    .row{background:rgba(255,255,255,.1);border-radius:10px;padding:12px 18px;"
    $html += "margin:8px 0;display:flex;justify-content:space-between}`r`n"
    $html += "    .row span:first-child{color:rgba(255,255,255,.5);font-size:.85em}`r`n"
    $html += "    .row span:last-child{font-weight:600;color:#64b5f6}`r`n"
    $html += "    .ok{color:#69f0ae!important}`r`n"
    $html += "    .badge{background:#1565c0;padding:6px 16px;border-radius:20px;"
    $html += "font-size:.8em;margin-top:20px;display:inline-block}`r`n"
    $html += "    .pie{margin-top:18px;font-size:.7em;color:rgba(255,255,255,.28)}`r`n"
    $html += "  </style>`r`n</head>`r`n<body>`r`n  <div class=`"card`">`r`n"
    $html += "    <h1>Servidor: $Servicio</h1>`r`n"
    $html += "    <p class=`"sub`">Windows Server 2022 - Despliegue automatizado</p>`r`n"
    $html += "    <div class=`"row`"><span>Servidor</span><span>$Servicio</span></div>`r`n"
    $html += "    <div class=`"row`"><span>Version</span><span>$Version</span></div>`r`n"
    $html += "    <div class=`"row`"><span>Puerto</span><span>$Puerto</span></div>`r`n"
    $html += "    <div class=`"row`"><span>Estado</span><span class=`"ok`">Activo</span></div>`r`n"
    $html += "    <div class=`"row`"><span>IP Local</span><span>$ipLocal</span></div>`r`n"
    $html += "    <div class=`"row`"><span>Sistema</span><span>Windows Server 2022</span></div>`r`n"
    $html += "    <span class=`"badge`">deploy_windows.ps1</span>`r`n"
    $html += "    <p class=`"pie`">$fecha</p>`r`n  </div>`r`n</body>`r`n</html>`r`n"
    Set-Content -Path (Join-Path $RutaWeb "index.html") -Value $html -Encoding UTF8
    Escribir-Exito "index.html creado en: $RutaWeb"
}

# ----------------------------------------------------------
#  ESTADO Y DIAGNOSTICO
# ----------------------------------------------------------

function Ver-EstadoServicios {
    Escribir-Titulo "Estado de Servicios HTTP Instalados"
    foreach ($svc in @(@{N="W3SVC";D="IIS (W3SVC)"},@{N="Apache24";D="Apache HTTP Server"})) {
        $estado = Get-Service -Name $svc.N -ErrorAction SilentlyContinue
        if ($estado) {
            $color = if ($estado.Status -eq "Running") { "Green" } else { "Red" }
            Write-Host ("  {0,-30} -> {1}" -f $svc.D, $estado.Status) -ForegroundColor $color
        } else {
            Write-Host ("  {0,-30} -> No instalado" -f $svc.D) -ForegroundColor DarkGray
        }
    }
    $procNginx = Get-Process nginx -ErrorAction SilentlyContinue
    if ($procNginx) {
        Write-Host ("  {0,-30} -> Running" -f "Nginx") -ForegroundColor Green
    } elseif (Test-Path "C:\nginx\nginx.exe") {
        Write-Host ("  {0,-30} -> Detenido" -f "Nginx") -ForegroundColor Yellow
    } else {
        Write-Host ("  {0,-30} -> No instalado" -f "Nginx") -ForegroundColor DarkGray
    }
    Write-Host ""
    Escribir-Info "Puertos TCP en escucha:"
    Get-NetTCPConnection -State Listen -ErrorAction SilentlyContinue |
        Where-Object { $_.LocalPort -in @(80,8080,8181,8282,9090,443) } |
        Sort-Object LocalPort | Format-Table LocalPort, OwningProcess, State -AutoSize
}

function Desinstalar-Servicio {
    Escribir-Titulo "Desinstalacion de Servicio HTTP"
    Write-Host "  [1] Desinstalar IIS"    -ForegroundColor White
    Write-Host "  [2] Desinstalar Apache" -ForegroundColor White
    Write-Host "  [3] Desinstalar Nginx"  -ForegroundColor White
    Write-Host "  [4] Volver al menu"     -ForegroundColor DarkGray
    Escribir-Separador
    $op = Leer-Entrada "Elige una opcion" "4" "^[1-4]$"
    switch ($op) {
        "1" { Stop-Service W3SVC -Force -ErrorAction SilentlyContinue
              Remove-WindowsFeature -Name "Web-Server" -ErrorAction SilentlyContinue | Out-Null
              Escribir-Exito "IIS desinstalado." }
        "2" { Stop-Service "Apache24" -Force -ErrorAction SilentlyContinue
              if (Test-Path "C:\Apache24\bin\httpd.exe") {
                  & "C:\Apache24\bin\httpd.exe" -k uninstall 2>&1 | Out-Null
              }
              sc.exe delete "Apache24" 2>&1 | Out-Null
              Remove-Item "C:\Apache24" -Recurse -Force -ErrorAction SilentlyContinue
              Escribir-Exito "Apache desinstalado." }
        "3" { Stop-Process -Name nginx -Force -ErrorAction SilentlyContinue
              Unregister-ScheduledTask -TaskName "Nginx_HTTP_Server" -Confirm:$false -ErrorAction SilentlyContinue
              Remove-Item "C:\nginx" -Recurse -Force -ErrorAction SilentlyContinue
              Get-NetFirewallRule -ErrorAction SilentlyContinue |
                  Where-Object { $_.DisplayName -like "HTTP-Nginx-*" } |
                  Remove-NetFirewallRule -ErrorAction SilentlyContinue
              Escribir-Exito "Nginx desinstalado." }
        "4" { return }
    }
}

function Aplicar-TodasSeguridades {
    param([string]$Servicio, [int]$Puerto)
    Escribir-Titulo "Aplicando Seguridad Completa - $Servicio"
    switch ($Servicio) {
        "IIS"    { Ocultar-VersionIIS
                   Aplicar-EncabezadosIIS -Puerto $Puerto
                   Configurar-PermisoInetpub -AppPoolName "AppPool_Puerto$Puerto" }
        "Apache" { Ocultar-VersionApache
                   Aplicar-EncabezadosApache
                   Configurar-PermisoApache
                   # Garantizar que Apache quede activo despues de toda la seguridad
                   Verificar-YReiniciar-Apache -Dir "C:\Apache24" | Out-Null }
        "Nginx"  { $r = Detectar-RutaNginx; if (-not $r) { $r = "C:\nginx" }
                   Ocultar-VersionNginx    -DirNginx $r
                   Aplicar-EncabezadosNginx -DirNginx $r
                   Configurar-PermisoNginx  -DirNginx $r }
    }
    # Firewall limpio (sin duplicados)
    Configurar-Firewall -Puerto $Puerto -Servicio $Servicio
    Escribir-Exito "Seguridad completa aplicada para $Servicio."

    # Confirmacion final para Apache
    if ($Servicio -eq "Apache") {
        Start-Sleep -Seconds 2
        try {
            $resp = Invoke-WebRequest -Uri "http://localhost:$Puerto" `
                        -UseBasicParsing -TimeoutSec 5 -ErrorAction Stop
            Escribir-Exito "Apache respondiendo en http://localhost:$Puerto (HTTP $($resp.StatusCode))"
        } catch {
            Escribir-Aviso "No se pudo verificar HTTP. Comprueba el servicio manualmente:"
            Escribir-Info  "  Get-Service Apache24"
            Escribir-Info  "  http://localhost:$Puerto"
        }
    }
}
