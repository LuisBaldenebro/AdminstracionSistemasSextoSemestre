Set-StrictMode -Version 2.0
$ErrorActionPreference = "Stop"

# ── Colores ───────────────────────────────────────────────────────────────────
$CK="Green"; $CE="Red"; $CA="Yellow"; $CI="Gray"; $CT="Cyan"; $CM="White"; $CR="Magenta"

# ── Rutas ─────────────────────────────────────────────────────────────────────
$RT="C:\GestorServicios"; $RCE="$RT\Certificados"; $RLO="$RT\Logs"; $RDE="$RT\Descargas"
$LOG="$RLO\gestor_$(Get-Date -Format 'yyyyMMdd_HHmmss').log"

# ── Puertos por servicio (sin conflictos) ─────────────────────────────────────
${PIF}=21;   ${PIS}=990;  ${PIW}=8082   # IIS-FTP : FTP-ctrl / FTPS-implicito / Estado-Web
${PIH}=80;   ${PHL}=443               # IIS-HTTP: HTTP / HTTPS
${PAH}=8080; ${PAS}=8443              # Apache  : HTTP / HTTPS
${PNH}=8081; ${PNS}=8444              # Nginx   : HTTP / HTTPS

# ── Dominio para certificados SSL (rúbrica: reprobados.com) ───────────────────
$DOMINIO_PRINCIPAL = "www.reprobados.com"
$DOMINIO_ALT       = "reprobados.com"

# ── Estado global ─────────────────────────────────────────────────────────────
$global:FTP_SERVIDOR=""; $global:FTP_USUARIO=""; $global:FTP_CLAVE=""; $global:FTP_PUERTO=21
$global:SVC=@{
    "IIS-FTP" =@{Instalado=$false;SSL=$false;UV="Nunca"}
    "IIS-HTTP"=@{Instalado=$false;SSL=$false;UV="Nunca"}
    "Apache"  =@{Instalado=$false;SSL=$false;UV="Nunca"}
    "Nginx"   =@{Instalado=$false;SSL=$false;UV="Nunca"}
}

# UTILIDADES BASICAS
function ILog { param($m,$n="INFO") try{Add-Content $LOG "[$(Get-Date -f 'yyyy-MM-dd HH:mm:ss')] [$n] $m" -Encoding UTF8}catch{} }
function OK   { param($m) Write-Host "  [OK]  $m" -Fore $CK; ILog $m "OK" }
function ERR  { param($m) Write-Host "  [ERR] $m" -Fore $CE; ILog $m "ERR" }
function AVI  { param($m) Write-Host "  [!]   $m" -Fore $CA; ILog $m "AVI" }
function INF  { param($m) Write-Host "  [i]   $m" -Fore $CI; ILog $m "INF" }
function SN   { param($q) do{$r=Read-Host "$q [S/N]"}while($r -notin "S","s","N","n"); return($r -in "S","s") }

function IPLoc {
    try {
        $ip = (Get-NetIPAddress -AddressFamily IPv4 -EA SilentlyContinue |
               Where-Object {$_.IPAddress -ne "127.0.0.1" -and $_.PrefixOrigin -ne "WellKnown"} |
               Select-Object -First 1).IPAddress
        if ($ip) { return $ip } else { return "127.0.0.1" }
    } catch { return "127.0.0.1" }
}

function CLS2 {
    try{$host.UI.RawUI.FlushInputBuffer()}catch{}
    [Console]::Out.Flush(); Start-Sleep -Milliseconds 350
    [Console]::Clear(); Start-Sleep -Milliseconds 100; [Console]::Clear()
    Write-Host ""
    Write-Host "  ============================================================" -Fore $CT
    Write-Host "   GESTOR DE SERVICIOS WEB v3.0 - WINDOWS SERVER 2022         " -Fore $CT
    Write-Host "  ============================================================" -Fore $CT
    Write-Host ""
}

function Init {
    foreach($d in $RT,$RCE,$RLO,$RDE){
        if(-not(Test-Path $d)){New-Item -ItemType Directory $d -Force|Out-Null}
    }
}

# FIREWALL
function AbrirPuerto {
    param([int]$p,[string]$n,[string]$proto="TCP")
    if(-not(Get-NetFirewallRule -DisplayName "GS_${n}_$p" -EA SilentlyContinue)){
        New-NetFirewallRule -DisplayName "GS_${n}_$p" -Direction Inbound -Protocol $proto `
            -LocalPort $p -Action Allow -Profile Any -Enabled True|Out-Null
        OK "Puerto $p/$proto abierto"
    }
}
function AbrirPuertos {
    param([string]$s)
    switch($s){
        "IIS-FTP"  {
            AbrirPuerto ${PIF} "IIS-FTP-Ctrl"; AbrirPuerto ${PIS} "IIS-FTP-SSL"; AbrirPuerto ${PIW} "IIS-FTP-Web"
            if(-not(Get-NetFirewallRule -DisplayName "GS_IIS-FTP-Pasivo" -EA SilentlyContinue)){
                New-NetFirewallRule -DisplayName "GS_IIS-FTP-Pasivo" -Direction Inbound `
                    -Protocol TCP -LocalPort 49152-65535 -Action Allow -Profile Any|Out-Null
                OK "Rango pasivo FTP (49152-65535)"
            }
        }
        "IIS-HTTP" {AbrirPuerto ${PIH} "IIS-HTTP";   AbrirPuerto ${PHL} "IIS-HTTPS"}
        "Apache"   {AbrirPuerto ${PAH} "Apache-HTTP"; AbrirPuerto ${PAS} "Apache-HTTPS"}
        "Nginx"    {AbrirPuerto ${PNH} "Nginx-HTTP";  AbrirPuerto ${PNS} "Nginx-HTTPS"}
    }
}

# PAGINAS HTML
$CSS_BASE = @'
*{margin:0;padding:0;box-sizing:border-box}
body{font-family:'Segoe UI',system-ui,sans-serif;background:#0f0f0f;color:#e0e0e0;
     min-height:100vh;display:flex;align-items:center;justify-content:center}
.w{width:100%;max-width:480px;padding:16px}
.card{background:#1a1a1a;border-radius:8px;overflow:hidden;border:1px solid #2a2a2a}
.top{height:3px}.body{padding:36px 32px 28px}
.dot-row{display:flex;align-items:center;gap:8px;margin-bottom:28px}
.dot{width:8px;height:8px;border-radius:50%;background:#3fb950;flex-shrink:0}
.dot-txt{font-size:11px;font-weight:600;letter-spacing:.08em;text-transform:uppercase;color:#3fb950}
h1{font-size:22px;font-weight:600;color:#fff;margin-bottom:4px}
.sub{font-size:13px;color:#555;margin-bottom:28px}
.grid{display:grid;grid-template-columns:1fr 1fr;gap:8px;margin-bottom:16px}
.cell{background:#111;border:1px solid #1e1e1e;border-radius:6px;padding:12px 14px}
.lbl{font-size:10px;font-weight:600;letter-spacing:.07em;text-transform:uppercase;color:#444;margin-bottom:5px}
.val{font-size:14px;font-weight:600}
.ok-bar{border:1px solid #1a3320;background:#0a1a10;border-radius:6px;padding:10px 14px;
        font-size:12px;color:#3fb950;display:flex;align-items:center;gap:8px;margin-bottom:12px}
.ok-bar::before{content:'';display:inline-block;width:12px;height:12px;
                border-radius:50%;border:2px solid #3fb950;flex-shrink:0}
.info-box{border-radius:6px;padding:12px 14px;font-size:12px;color:#777;line-height:1.9}
footer{margin-top:18px;font-size:11px;color:#2a2a2a;text-align:right}
'@

function PaginaIISHTTP {
    param([string]$Ruta)
    if(-not(Test-Path $Ruta)){New-Item -ItemType Directory $Ruta -Force|Out-Null}
    $ip=IPLoc; $maq=$env:COMPUTERNAME; $f=Get-Date -f 'dd/MM/yyyy HH:mm'
    $html = @"
<!DOCTYPE html>
<html lang="es">
<head>
<meta charset="UTF-8">
<meta name="viewport" content="width=device-width,initial-scale=1">
<title>IIS - HTTP</title>
<style>
$CSS_BASE
.top{background:#0078d4}
.val{color:#0078d4}
.info-box{background:#0a1220;border:1px solid #0d2a50}
.info-box span{color:#3a9bdc;font-weight:600}
</style>
</head>
<body>
<div class="w">
  <div class="card">
    <div class="top"></div>
    <div class="body">
      <div class="dot-row"><div class="dot"></div><span class="dot-txt">Servidor activo</span></div>
      <h1>IIS - HTTP</h1>
      <p class="sub">Internet Information Services / Windows Server 2022</p>
      <div class="grid">
        <div class="cell"><div class="lbl">Puerto HTTP</div><div class="val">${PIH}</div></div>
        <div class="cell"><div class="lbl">Puerto HTTPS</div><div class="val">${PHL}</div></div>
        <div class="cell"><div class="lbl">Maquina</div><div class="val">$maq</div></div>
        <div class="cell"><div class="lbl">IP Local</div><div class="val">$ip</div></div>
      </div>
      <div class="ok-bar">Servicio IIS funcionando correctamente</div>
      <div class="info-box">
        Dominio: <span>$DOMINIO_PRINCIPAL</span><br>
        URL HTTP: <span>http://$ip</span><br>
        URL HTTPS: <span>https://$ip</span> (requiere SSL activado)<br>
        Fecha: <span>$f</span>
      </div>
    </div>
  </div>
  <footer>GestorServicios v3.0</footer>
</div>
</body>
</html>
"@
    try{Set-Content (Join-Path $Ruta "index.html") $html -Encoding UTF8; OK "Pagina IIS-HTTP: $Ruta"}
    catch{AVI "Pagina IIS-HTTP no creada: $($_.Exception.Message)"}
}

function PaginaApache {
    param([string]$Ruta)
    if(-not(Test-Path $Ruta)){New-Item -ItemType Directory $Ruta -Force|Out-Null}
    $ip=IPLoc; $maq=$env:COMPUTERNAME; $f=Get-Date -f 'dd/MM/yyyy HH:mm'
    $html = @"
<!DOCTYPE html>
<html lang="es">
<head>
<meta charset="UTF-8">
<meta name="viewport" content="width=device-width,initial-scale=1">
<title>Apache HTTP Server</title>
<style>
$CSS_BASE
.top{background:#c0392b}
.val{color:#e74c3c}
.info-box{background:#1a0a0a;border:1px solid #4a1010}
.info-box span{color:#e74c3c;font-weight:600}
</style>
</head>
<body>
<div class="w">
  <div class="card">
    <div class="top"></div>
    <div class="body">
      <div class="dot-row"><div class="dot"></div><span class="dot-txt">Servidor activo</span></div>
      <h1>Apache HTTP Server</h1>
      <p class="sub">Apache Software Foundation / Windows Server 2022</p>
      <div class="grid">
        <div class="cell"><div class="lbl">Puerto HTTP</div><div class="val">${PAH}</div></div>
        <div class="cell"><div class="lbl">Puerto HTTPS</div><div class="val">${PAS}</div></div>
        <div class="cell"><div class="lbl">Maquina</div><div class="val">$maq</div></div>
        <div class="cell"><div class="lbl">IP Local</div><div class="val">$ip</div></div>
      </div>
      <div class="ok-bar">Servicio Apache funcionando correctamente</div>
      <div class="info-box">
        Dominio: <span>$DOMINIO_PRINCIPAL</span><br>
        URL HTTP: <span>http://$ip`:${PAH}</span><br>
        URL HTTPS: <span>https://$ip`:${PAS}</span> (requiere SSL activado)<br>
        Fecha: <span>$f</span>
      </div>
    </div>
  </div>
  <footer>GestorServicios v3.0</footer>
</div>
</body>
</html>
"@
    try{Set-Content (Join-Path $Ruta "index.html") $html -Encoding UTF8; OK "Pagina Apache: $Ruta"}
    catch{AVI "Pagina Apache no creada: $($_.Exception.Message)"}
}

function PaginaNginx {
    param([string]$Ruta)
    if(-not(Test-Path $Ruta)){New-Item -ItemType Directory $Ruta -Force|Out-Null}
    $ip=IPLoc; $maq=$env:COMPUTERNAME; $f=Get-Date -f 'dd/MM/yyyy HH:mm'
    $html = @"
<!DOCTYPE html>
<html lang="es">
<head>
<meta charset="UTF-8">
<meta name="viewport" content="width=device-width,initial-scale=1">
<title>Nginx Web Server</title>
<style>
$CSS_BASE
.top{background:#009639}
.val{color:#00b347}
.info-box{background:#0a1a0e;border:1px solid #0d3a1a}
.info-box span{color:#00b347;font-weight:600}
</style>
</head>
<body>
<div class="w">
  <div class="card">
    <div class="top"></div>
    <div class="body">
      <div class="dot-row"><div class="dot"></div><span class="dot-txt">Servidor activo</span></div>
      <h1>Nginx Web Server</h1>
      <p class="sub">nginx.org / Windows Server 2022</p>
      <div class="grid">
        <div class="cell"><div class="lbl">Puerto HTTP</div><div class="val">${PNH}</div></div>
        <div class="cell"><div class="lbl">Puerto HTTPS</div><div class="val">${PNS}</div></div>
        <div class="cell"><div class="lbl">Maquina</div><div class="val">$maq</div></div>
        <div class="cell"><div class="lbl">IP Local</div><div class="val">$ip</div></div>
      </div>
      <div class="ok-bar">Servicio Nginx funcionando correctamente</div>
      <div class="info-box">
        Dominio: <span>$DOMINIO_PRINCIPAL</span><br>
        URL HTTP: <span>http://$ip`:${PNH}</span><br>
        URL HTTPS: <span>https://$ip`:${PNS}</span> (requiere SSL activado)<br>
        Fecha: <span>$f</span>
      </div>
    </div>
  </div>
  <footer>GestorServicios v3.0</footer>
</div>
</body>
</html>
"@
    try{Set-Content (Join-Path $Ruta "index.html") $html -Encoding UTF8; OK "Pagina Nginx: $Ruta"}
    catch{AVI "Pagina Nginx no creada: $($_.Exception.Message)"}
}

function PaginaIISFTP {
    param([string]$Ip="127.0.0.1")
    $wr="C:\inetpub\ftpweb"
    if(-not(Test-Path $wr)){New-Item -ItemType Directory $wr -Force|Out-Null}
    $maq=$env:COMPUTERNAME; $f=Get-Date -f 'dd/MM/yyyy HH:mm'
    $html = @"
<!DOCTYPE html>
<html lang="es">
<head>
<meta charset="UTF-8">
<meta name="viewport" content="width=device-width,initial-scale=1">
<title>IIS - FTP</title>
<style>
$CSS_BASE
.top{background:#e67e22}
.val{color:#e67e22}
.info-box{background:#1a1000;border:1px solid #4a2a00}
.info-box span{color:#e67e22;font-weight:600}
</style>
</head>
<body>
<div class="w">
  <div class="card">
    <div class="top"></div>
    <div class="body">
      <div class="dot-row"><div class="dot"></div><span class="dot-txt">Servidor activo</span></div>
      <h1>IIS - FTP</h1>
      <p class="sub">File Transfer Protocol / Windows Server 2022</p>
      <div class="grid">
        <div class="cell"><div class="lbl">Puerto FTP</div><div class="val">${PIF}</div></div>
        <div class="cell"><div class="lbl">Puerto FTPS</div><div class="val">${PIS}</div></div>
        <div class="cell"><div class="lbl">Maquina</div><div class="val">$maq</div></div>
        <div class="cell"><div class="lbl">IP Local</div><div class="val">$Ip</div></div>
      </div>
      <div class="ok-bar">Servicio FTP funcionando correctamente</div>
      <div class="info-box">
        Cliente recomendado: <span>FileZilla</span> o <span>WinSCP</span><br>
        Host: <span>$Ip</span> &nbsp; Puerto FTP: <span>${PIF}</span><br>
        Puerto FTPS implicito: <span>${PIS}</span> &nbsp; Fecha: <span>$f</span>
      </div>
    </div>
  </div>
  <footer>GestorServicios v3.0</footer>
</div>
</body>
</html>
"@
    try{Set-Content "$wr\index.html" $html -Encoding UTF8; OK "Pagina IIS-FTP: $wr"}
    catch{AVI "Pagina IIS-FTP no creada: $($_.Exception.Message)"}
    Import-Module WebAdministration -EA SilentlyContinue
    $n="IIS-FTP-Status"
    $ex=Get-WebSite -Name $n -EA SilentlyContinue
    if($ex){Remove-WebSite -Name $n -EA SilentlyContinue}
    try{
        New-WebSite -Name $n -Port ${PIW} -PhysicalPath $wr -IPAddress "*" -Force|Out-Null
        Start-WebSite -Name $n -EA SilentlyContinue
        OK "Sitio $n activo -> http://localhost:${PIW}"
    }catch{AVI "Sitio $n no creado: $($_.Exception.Message)"}
}

# CERTIFICADOS
function CertIIS {
    param([string]$Nombre)
    INF "Certificado autofirmado IIS: $Nombre (dominio: $DOMINIO_PRINCIPAL)"
    try{
        Get-ChildItem "Cert:\LocalMachine\My" | Where-Object {$_.FriendlyName -eq $Nombre} |
            Remove-Item -EA SilentlyContinue

        $c=New-SelfSignedCertificate `
            -DnsName $DOMINIO_PRINCIPAL,$DOMINIO_ALT,"localhost",$env:COMPUTERNAME `
            -CertStoreLocation "Cert:\LocalMachine\My" `
            -FriendlyName $Nombre `
            -NotAfter (Get-Date).AddYears(5) `
            -KeyUsage DigitalSignature,KeyEncipherment `
            -KeyAlgorithm RSA -KeyLength 2048
        OK "Certificado generado: $($c.Thumbprint) | DNS: $DOMINIO_PRINCIPAL"
        return $c
    }catch{ERR "CertIIS: $($_.Exception.Message)"; return $null}
}

function CertPEM {
    param([string]$Srv)
    $keyF="$RCE\$Srv.key"; $crtF="$RCE\$Srv.crt"
    INF "Generando certificado PEM para $Srv (dominio: $DOMINIO_PRINCIPAL)..."
    try{
        Get-ChildItem "Cert:\LocalMachine\My" | Where-Object {$_.FriendlyName -eq "GS-$Srv-SSL"} |
            Remove-Item -EA SilentlyContinue

        $cert=New-SelfSignedCertificate `
            -DnsName $DOMINIO_PRINCIPAL,$DOMINIO_ALT,"localhost",$env:COMPUTERNAME `
            -CertStoreLocation "Cert:\LocalMachine\My" `
            -FriendlyName "GS-$Srv-SSL" `
            -NotAfter (Get-Date).AddYears(5) `
            -KeyUsage DigitalSignature,KeyEncipherment `
            -KeyAlgorithm RSA -KeyLength 2048 `
            -KeyExportPolicy Exportable `
            -Provider "Microsoft Enhanced RSA and AES Cryptographic Provider"

        $bytes=$cert.Export([System.Security.Cryptography.X509Certificates.X509ContentType]::Cert)
        $b64=[Convert]::ToBase64String($bytes,[System.Base64FormattingOptions]::InsertLineBreaks)
        Set-Content $crtF "-----BEGIN CERTIFICATE-----`n$b64`n-----END CERTIFICATE-----" -Encoding ASCII
        OK "Certificado PEM: $crtF"

        $pfx="$env:TEMP\gs_${Srv}_$(Get-Random).pfx"
        $pwd=ConvertTo-SecureString "gs_tmp_Pr7!" -AsPlainText -Force
        Export-PfxCertificate -Cert $cert -FilePath $pfx -Password $pwd|Out-Null

        $fl=[System.Security.Cryptography.X509Certificates.X509KeyStorageFlags]::Exportable -bor
            [System.Security.Cryptography.X509Certificates.X509KeyStorageFlags]::MachineKeySet
        $pfxC=New-Object System.Security.Cryptography.X509Certificates.X509Certificate2($pfx,"gs_tmp_Pr7!",$fl)
        $rsa=$pfxC.PrivateKey -as [System.Security.Cryptography.RSACryptoServiceProvider]
        if(-not $rsa){throw "PrivateKey nulo tras importar PFX (requiere proveedor CSP legado)"}

        function DL([int]$n){
            if($n-lt 128){return [byte[]]@($n)}
            $bs=[System.Collections.Generic.List[byte]]::new(); $t=$n
            while($t-gt 0){$bs.Insert(0,[byte]($t-band 0xFF));$t=$t-shr 8}
            return [byte[]](@([byte](0x80-bor $bs.Count))+$bs.ToArray())
        }
        function DI([byte[]]$d){
            $i=0; while($i-lt($d.Length-1)-and $d[$i]-eq 0){$i++}
            if($i-gt 0){$d=$d[$i..($d.Length-1)]}
            if($d[0]-band 0x80){$d=[byte[]]@(0x00)+$d}
            return [byte[]](@([byte]0x02)+(DL $d.Length)+$d)
        }
        $p=$rsa.ExportParameters($true)
        $ver=[byte[]]@(0x02,0x01,0x00)
        $inn=$ver+(DI $p.Modulus)+(DI $p.Exponent)+(DI $p.D)+`
             (DI $p.P)+(DI $p.Q)+(DI $p.DP)+(DI $p.DQ)+(DI $p.InverseQ)
        $seq=[byte[]](@([byte]0x30)+(DL $inn.Length)+$inn)
        $kb64=[Convert]::ToBase64String($seq,[System.Base64FormattingOptions]::InsertLineBreaks)
        Set-Content $keyF "-----BEGIN RSA PRIVATE KEY-----`n$kb64`n-----END RSA PRIVATE KEY-----" -Encoding ASCII
        OK "Clave privada PEM: $keyF"

        Remove-Item $pfx -Force -EA SilentlyContinue
        if((Get-Item $crtF).Length-lt 100 -or (Get-Item $keyF).Length-lt 100){
            throw "Archivos PEM demasiado pequenos (posible error de exportacion)"
        }
        return $true
    }catch{ERR "CertPEM [$Srv]: $($_.Exception.Message)"; return $false}
}

# FTP PRIVADO - Configuracion y utilidades
function ConfFTP {
    Write-Host "`n  == CONFIGURAR SERVIDOR FTP PRIVADO ==" -Fore $CT
    $global:FTP_SERVIDOR=Read-Host "  Servidor FTP (IP o hostname)"
    $p=Read-Host "  Puerto [Enter=21]"
    $global:FTP_PUERTO=if($p -match '^\d+$'){[int]$p}else{21}
    $global:FTP_USUARIO=Read-Host "  Usuario FTP"
    $s=Read-Host "  Contrasena" -AsSecureString
    $global:FTP_CLAVE=[System.Runtime.InteropServices.Marshal]::PtrToStringAuto(
        [System.Runtime.InteropServices.Marshal]::SecureStringToBSTR($s))
    OK "FTP configurado: $($global:FTP_SERVIDOR):$($global:FTP_PUERTO) | usuario: $($global:FTP_USUARIO)"
}

function FTPReq {
    param($u, $m="NLST")
    $r=[System.Net.FtpWebRequest]::Create($u)
    $r.Method=$m
    $r.Credentials=New-Object System.Net.NetworkCredential($global:FTP_USUARIO,$global:FTP_CLAVE)
    $r.UsePassive=$true; $r.UseBinary=$true; $r.EnableSsl=$false; $r.KeepAlive=$false
    $r.Timeout=15000; $r.ReadWriteTimeout=30000
    return $r
}

function FTPList {
    param([string]$ruta)
    try{
        $u="ftp://$($global:FTP_SERVIDOR):$($global:FTP_PUERTO)$ruta"
        $req=FTPReq $u [System.Net.WebRequestMethods+Ftp]::ListDirectory
        $rsp=$req.GetResponse()
        $sr=New-Object System.IO.StreamReader($rsp.GetResponseStream())
        $txt=$sr.ReadToEnd(); $sr.Close(); $rsp.Close()
        $items = $txt -split "[\r\n]+" |
                 ForEach-Object { $_.Trim() } |
                 Where-Object { $_ -ne "" -and $_ -ne "." -and $_ -ne ".." } |
                 ForEach-Object {
                     # FTPList puede devolver rutas completas; quedarse solo con el nombre
                     if($_ -match '[/\\]'){(Split-Path $_ -Leaf)}else{$_}
                 }
        return @($items)
    }catch{ERR "FTPList [$ruta]: $($_.Exception.Message)"; return @()}
}

function FTPListDetailed {
    param([string]$ruta, [switch]$SoloDirs, [switch]$SoloArchivos)
    $resultados = [System.Collections.Generic.List[PSObject]]::new()
    try{
        $u="ftp://$($global:FTP_SERVIDOR):$($global:FTP_PUERTO)$ruta"
        $req=FTPReq $u [System.Net.WebRequestMethods+Ftp]::ListDirectoryDetails
        $rsp=$req.GetResponse()
        $sr=New-Object System.IO.StreamReader($rsp.GetResponseStream())
        $txt=$sr.ReadToEnd(); $sr.Close(); $rsp.Close()

        foreach($linea in ($txt -split "[\r\n]+" | Where-Object {$_.Trim() -ne ""})){
            $l=$linea.Trim(); $nombre=""; $esDir=$false

            if($l -match '^\d{2}-\d{2}-\d{2}\s+\d{1,2}:\d{2}(AM|PM)\s+(<DIR>|\d+)\s+(.+)$'){
                $nombre=$Matches[3].Trim(); $esDir=($Matches[2] -eq '<DIR>')
            }
            elseif($l -match '^([d-])[rwxsStT-]{9}\s+\d+\s+\S+\s+\S+\s+\d+\s+\w{3}\s+[\d:]+\s+(.+)$'){
                $nombre=$Matches[2].Trim(); $esDir=($Matches[1] -eq 'd')
            }
            else{
                $parts=$l -split '\s+'; if($parts.Count -gt 0){$nombre=$parts[-1].Trim()}
                $esDir=$l.StartsWith('d')
            }

            if($nombre -and $nombre -notin '.','..'){
                if($SoloDirs   -and -not $esDir){continue}
                if($SoloArchivos -and $esDir){continue}
                $resultados.Add([PSCustomObject]@{Nombre=$nombre; EsDirectorio=$esDir})
            }
        }
    }catch{
        AVI "LIST no disponible, usando NLST: $($_.Exception.Message)"
        $nombres=FTPList $ruta
        foreach($n in $nombres){
            if($n){$resultados.Add([PSCustomObject]@{Nombre=$n; EsDirectorio=$false})}
        }
    }
    return ,$resultados.ToArray()
}

# Descarga un archivo del FTP al disco local
function FTPGet {
    param([string]$rF, [string]$rL)
    try{
        $u="ftp://$($global:FTP_SERVIDOR):$($global:FTP_PUERTO)$rF"
        $req=FTPReq $u [System.Net.WebRequestMethods+Ftp]::DownloadFile
        $rsp=$req.GetResponse()
        $src=$rsp.GetResponseStream()
        $dst=New-Object System.IO.FileStream($rL,[System.IO.FileMode]::Create)
        $buf=New-Object byte[] 65536
        do{$n=$src.Read($buf,0,$buf.Length);if($n-gt 0){$dst.Write($buf,0,$n)}}while($n-gt 0)
        $dst.Close();$src.Close();$rsp.Close()
        if((Test-Path $rL) -and (Get-Item $rL).Length -gt 0){
            OK "FTP descargado: $rF -> $rL"
            return $true
        }
        throw "Archivo descargado esta vacio"
    }catch{ERR "FTPGet [$rF]: $($_.Exception.Message)"; return $false}
}

# VERIFICACION DE INTEGRIDAD SHA256
function VerificaHash {
    param([string]$Archivo, [string]$ContenidoHashFile)
    INF "Verificando integridad SHA256: $(Split-Path $Archivo -Leaf)"
    try{
        if(-not(Test-Path $Archivo)){ERR "Archivo no encontrado: $Archivo"; return $false}
        $calculado=(Get-FileHash -Path $Archivo -Algorithm SHA256 -EA Stop).Hash.ToUpper()

        $linea=($ContenidoHashFile -split "[\r\n]+" | Where-Object{$_.Trim()-ne""} | Select-Object -First 1).Trim()
        $esperado=""
        if($linea -match '^([A-Fa-f0-9]{64})'){
            $esperado=$Matches[1].ToUpper()
        }else{
            ERR "Formato de hash no reconocido en archivo .sha256: $linea"
            return $false
        }

        if($calculado -eq $esperado){
            OK "INTEGRIDAD OK - SHA256: $calculado"
            return $true
        }else{
            ERR "INTEGRIDAD FALLIDA!"
            ERR "  Calculado : $calculado"
            ERR "  Esperado  : $esperado"
            return $false
        }
    }catch{ERR "VerificaHash: $($_.Exception.Message)"; return $false}
}

# NAVEGACION FTP DINAMICA
function FTPNavegar {
    param([string]$Servicio="")
    if(-not $global:FTP_SERVIDOR){ConfFTP}
    if(-not $global:FTP_SERVIDOR){ERR "Servidor FTP no configurado"; return $null}

    $basePath="/http/Windows/"

    # --- Paso 1: Listar carpetas de servicios disponibles ---
    if($Servicio -eq ""){
        INF "Listando servicios disponibles en FTP: $basePath"
        $carpetas=FTPListDetailed $basePath -SoloDirs
        if($carpetas.Count -eq 0){
            AVI "No se detectaron subdirectorios; listando todo en $basePath"
            $nombres=FTPList $basePath
            $carpetas=$nombres | Where-Object{$_} | ForEach-Object{[PSCustomObject]@{Nombre=$_;EsDirectorio=$true}}
        }
        if($carpetas.Count -eq 0){ERR "No hay servicios en $basePath del servidor FTP"; return $null}

        Write-Host "`n  Servicios disponibles en FTP ($($global:FTP_SERVIDOR)):" -Fore $CT
        for($i=0;$i-lt $carpetas.Count;$i++){
            Write-Host "  [$($i+1)] $($carpetas[$i].Nombre)" -Fore $CM
        }
        do{
            $in=Read-Host "  Seleccione servicio"
            [bool]$valido=[int]::TryParse($in,[ref]$null)
            if($valido){[int]$sel=[int]$in}
        }while(-not $valido -or $sel -lt 1 -or $sel -gt $carpetas.Count)
        $Servicio=$carpetas[$sel-1].Nombre
    }

    # --- Paso 2: Listar instaladores dentro de la carpeta del servicio ---
    $svcPath="$basePath$Servicio/"
    INF "Listando instaladores en: $svcPath"
    $todos=FTPListDetailed $svcPath -SoloArchivos
    if($todos.Count -eq 0){
        $nombres=FTPList $svcPath
        $todos=$nombres | Where-Object{$_} | ForEach-Object{[PSCustomObject]@{Nombre=$_;EsDirectorio=$false}}
    }
    # Filtrar: mostrar solo instaladores
    $instaladores=$todos | Where-Object{$_.Nombre -notmatch '\.(sha256|md5)$'}
    if($instaladores.Count -eq 0){ERR "No hay instaladores en $svcPath"; return $null}

    Write-Host "`n  Versiones disponibles para '$Servicio':" -Fore $CT
    for($i=0;$i-lt $instaladores.Count;$i++){
        Write-Host "  [$($i+1)] $($instaladores[$i].Nombre)" -Fore $CM
    }
    do{
        $in=Read-Host "  Seleccione version"
        [bool]$valido=[int]::TryParse($in,[ref]$null)
        if($valido){[int]$sel=[int]$in}
    }while(-not $valido -or $sel -lt 1 -or $sel -gt $instaladores.Count)

    $elegido=$instaladores[$sel-1].Nombre
    $localFile="$RDE\$elegido"
    $remotePath="$svcPath$elegido"
    $remoteHash="$svcPath$elegido.sha256"
    $localHash="$RDE\$elegido.sha256"

    # --- Paso 3: Descargar instalador ---
    INF "Descargando instalador: $elegido"
    if(-not(FTPGet $remotePath $localFile)){ERR "Error descargando $elegido"; return $null}

    # --- Paso 4: Descargar y verificar hash SHA256 ---
    INF "Buscando hash SHA256: $elegido.sha256"
    if(FTPGet $remoteHash $localHash){
        $contenidoHash=Get-Content $localHash -Raw -EA SilentlyContinue
        if($contenidoHash -and $contenidoHash.Trim() -ne ""){
            if(-not(VerificaHash $localFile $contenidoHash)){
                ERR "Verificacion de integridad FALLIDA. El archivo puede estar corrupto o modificado."
                if(-not(SN "Continuar de todas formas?")){
                    Remove-Item $localFile -Force -EA SilentlyContinue
                    return $null
                }
                AVI "Continuando con archivo sin verificar (bajo su responsabilidad)"
            }
        }else{AVI "Archivo .sha256 vacio; omitiendo verificacion"}
    }else{AVI "Archivo $elegido.sha256 no encontrado en el servidor FTP; omitiendo verificacion de integridad"}

    return $localFile
}

# DESCARGA WEB
function DescWeb {
    param($url,$dst,$desc)
    INF "Descargando: $desc"
    if(Test-Path $dst){Remove-Item $dst -Force -EA SilentlyContinue}
    try{Start-BitsTransfer -Source $url -Destination $dst -TransferType Download -EA Stop
        if((Test-Path $dst)-and(Get-Item $dst).Length-gt 10KB){OK "OK (BITS): $dst"; return $true}}
    catch{AVI "BITS fallo: $($_.Exception.Message)"}
    try{$ProgressPreference='SilentlyContinue'
        Invoke-WebRequest -Uri $url -OutFile $dst -UseBasicParsing -TimeoutSec 300 `
            -Headers @{"User-Agent"="Mozilla/5.0";"Accept"="*/*"} -EA Stop
        if((Test-Path $dst)-and(Get-Item $dst).Length-gt 10KB){OK "OK (IWR): $dst"; return $true}}
    catch{AVI "IWR fallo: $($_.Exception.Message)"}
    try{$wc=New-Object System.Net.WebClient; $wc.Headers["User-Agent"]="Mozilla/5.0"
        $wc.DownloadFile($url,$dst)
        if((Test-Path $dst)-and(Get-Item $dst).Length-gt 10KB){OK "OK (WebClient): $dst"; return $true}}
    catch{AVI "WebClient fallo: $($_.Exception.Message)"}
    ERR "No se pudo descargar: $desc"; return $false
}

function EsZIP {
    param($r)
    try{
        $b=[System.IO.File]::ReadAllBytes($r)|Select-Object -First 4
        return($b[0]-eq 0x50-and $b[1]-eq 0x4B-and $b[2]-eq 0x03-and $b[3]-eq 0x04)
    }catch{return $false}
}

# VERIFICACION DE SERVICIOS
function VerSvc {
    param([string]$s)
    INF "Verificando $s..."
    $act=$false; $res="Sin datos"
    try{
        switch($s){
            "IIS-HTTP"{
                $sv=Get-Service W3SVC -EA SilentlyContinue
                if($sv-and $sv.Status-eq"Running"){$act=$true
                    $h=Test-NetConnection localhost -Port ${PIH} -InformationLevel Quiet -WA SilentlyContinue
                    $hs=Test-NetConnection localhost -Port ${PHL} -InformationLevel Quiet -WA SilentlyContinue
                    $res="W3SVC activo | HTTP:$(if($h){'OK'}else{'X'}) | HTTPS:$(if($hs){'OK'}else{'X'})"
                    if($global:SVC["IIS-HTTP"].SSL -and (Test-Path "$RCE\IIS-HTTP-SSL.crt")){
                        $c=[System.Security.Cryptography.X509Certificates.X509Certificate2]::new("$RCE\IIS-HTTP-SSL.crt")
                        $res+=" | Cert: $($c.Subject.Split(',')[0]) exp:$($c.NotAfter.ToString('dd/MM/yy'))"
                    }
                }else{$res="W3SVC detenido o no instalado"}
            }
            "IIS-FTP"{
                $sv=Get-Service ftpsvc -EA SilentlyContinue
                if($sv-and $sv.Status-eq"Running"){$act=$true
                    $f=Test-NetConnection localhost -Port ${PIF} -InformationLevel Quiet -WA SilentlyContinue
                    $fs=Test-NetConnection localhost -Port ${PIS} -InformationLevel Quiet -WA SilentlyContinue
                    $fw=Test-NetConnection localhost -Port ${PIW} -InformationLevel Quiet -WA SilentlyContinue
                    $res="FTPSVC activo | FTP:$(if($f){'OK'}else{'X'}) | FTPS:$(if($fs){'OK'}else{'X'}) | Web:$(if($fw){'OK'}else{'X'})"
                }else{$res="FTPSVC detenido o no instalado"}
            }
            "Apache"{
                $a=Get-Service Apache2.4 -EA SilentlyContinue
                $b=Get-Service Apache    -EA SilentlyContinue
                $c=Get-Process httpd    -EA SilentlyContinue
                if(($a-and $a.Status-eq"Running")-or($b-and $b.Status-eq"Running")-or $c){$act=$true
                    $h=Test-NetConnection localhost -Port ${PAH} -InformationLevel Quiet -WA SilentlyContinue
                    $hs=Test-NetConnection localhost -Port ${PAS} -InformationLevel Quiet -WA SilentlyContinue
                    $res="Apache activo | HTTP:$(if($h){'OK'}else{'X'}) | HTTPS:$(if($hs){'OK'}else{'X'})"
                    if($global:SVC["Apache"].SSL -and (Test-Path "$RCE\Apache.crt")){
                        $cert=[System.Security.Cryptography.X509Certificates.X509Certificate2]::new("$RCE\Apache.crt")
                        $res+=" | Cert: $($cert.Subject.Split(',')[0]) exp:$($cert.NotAfter.ToString('dd/MM/yy'))"
                    }
                }else{$res="Apache detenido o no instalado"}
            }
            "Nginx"{
                $a=Get-Service nginx -EA SilentlyContinue
                $b=Get-Process nginx -EA SilentlyContinue
                if(($a-and $a.Status-eq"Running")-or $b){$act=$true
                    $h=Test-NetConnection localhost -Port ${PNH} -InformationLevel Quiet -WA SilentlyContinue
                    $hs=Test-NetConnection localhost -Port ${PNS} -InformationLevel Quiet -WA SilentlyContinue
                    $res="Nginx activo | HTTP:$(if($h){'OK'}else{'X'}) | HTTPS:$(if($hs){'OK'}else{'X'})"
                    if($global:SVC["Nginx"].SSL -and (Test-Path "$RCE\Nginx.crt")){
                        $cert=[System.Security.Cryptography.X509Certificates.X509Certificate2]::new("$RCE\Nginx.crt")
                        $res+=" | Cert: $($cert.Subject.Split(',')[0]) exp:$($cert.NotAfter.ToString('dd/MM/yy'))"
                    }
                }else{$res="Nginx detenido o no instalado"}
            }
        }
    }catch{$res="Error: $($_.Exception.Message)"}
    $global:SVC[$s].UV=$res
    if($act){OK "$s : $res"}else{AVI "$s : $res"}
    return $act
}

# INSTALACION: IIS-HTTP
function IISRutaFisica {
    try{
        Import-Module WebAdministration -EA SilentlyContinue
        $raw=(Get-WebSite -Name "Default Web Site" -EA SilentlyContinue).physicalPath
        if(-not $raw){return "C:\inetpub\wwwroot"}
        $raw=$raw -replace '%SystemDrive%','C:' -replace '%SYSTEMDRIVE%','C:'
        return $raw
    }catch{return "C:\inetpub\wwwroot"}
}

function EscribirPaginaIIS {
    $wwwroot="C:\inetpub\wwwroot"
    if(-not(Test-Path $wwwroot)){New-Item -ItemType Directory $wwwroot -Force|Out-Null}
    try{
        Import-Module WebAdministration -EA SilentlyContinue
        Set-ItemProperty "IIS:\Sites\Default Web Site" -Name physicalPath -Value $wwwroot -EA SilentlyContinue
    }catch{}
    PaginaIISHTTP $wwwroot
    OK "Pagina IIS-HTTP escrita en: $wwwroot"
}

function InstIISHTTP {
    Write-Host "`n  == IIS-HTTP (HTTP:${PIH} / HTTPS:${PHL}) ==" -Fore $CT
    try{
        $roles="Web-Server","Web-WebServer","Web-Common-Http","Web-Default-Doc","Web-Dir-Browsing",
               "Web-Http-Errors","Web-Static-Content","Web-Http-Redirect","Web-Http-Logging",
               "Web-Security","Web-Filtering","Web-Basic-Auth","Web-Windows-Auth",
               "Web-Stat-Compression","Web-Mgmt-Console","Web-Scripting-Tools",
               "NET-Framework-45-ASPNET","Web-Asp-Net45"
        foreach($r in $roles){
            if(-not(Get-WindowsFeature -Name $r -EA SilentlyContinue).Installed){
                Install-WindowsFeature $r -IncludeManagementTools|Out-Null; OK "Instalado: $r"
            }
        }
        Start-Service W3SVC -EA SilentlyContinue; Set-Service W3SVC -StartupType Automatic
        Import-Module WebAdministration -EA SilentlyContinue

        $wwwroot="C:\inetpub\wwwroot"
        if(-not(Test-Path $wwwroot)){New-Item -ItemType Directory $wwwroot -Force|Out-Null}
        Set-ItemProperty "IIS:\Sites\Default Web Site" -Name physicalPath -Value $wwwroot -EA SilentlyContinue
        try{
            Set-WebConfiguration -PSPath "IIS:\Sites\Default Web Site" `
                -Filter "system.webServer/httpRedirect" `
                -Value @{enabled="false"} -EA SilentlyContinue
        }catch{}
        OK "Ruta fisica IIS: $wwwroot"

        $bnd=Get-WebBinding -Name "Default Web Site" -Protocol http -EA SilentlyContinue|
             Where-Object{$_.bindingInformation -match ":${PIH}:"}
        if(-not $bnd){
            New-WebBinding -Name "Default Web Site" -Protocol http -Port ${PIH} -IPAddress "*" -EA SilentlyContinue
        }
        Start-WebSite -Name "Default Web Site" -EA SilentlyContinue
        OK "Default Web Site iniciado en puerto ${PIH}"

        iisreset /restart /noforce 2>&1|Out-Null; Start-Sleep 3
        EscribirPaginaIIS
        AbrirPuertos "IIS-HTTP"
        $global:SVC["IIS-HTTP"].Instalado=$true
        VerSvc "IIS-HTTP"
        OK "IIS-HTTP listo | http://localhost | http://$(IPLoc)"
    }catch{ERR "InstIISHTTP: $($_.Exception.Message)"}
}

# INSTALACION: IIS-FTP
function InstIISFTP {
    Write-Host "`n  == IIS-FTP (FTP:${PIF} / FTPS:${PIS} / Web:${PIW}) ==" -Fore $CT
    try{
        $roles="Web-Ftp-Server","Web-Ftp-Service","Web-Ftp-Ext","Web-Mgmt-Console",
               "Web-Server","Web-Common-Http","Web-Static-Content","Web-Mgmt-Service"
        foreach($r in $roles){
            if(-not(Get-WindowsFeature -Name $r -EA SilentlyContinue).Installed){
                Install-WindowsFeature $r -IncludeManagementTools|Out-Null; OK "Instalado: $r"
            }
        }
        Import-Module WebAdministration -EA SilentlyContinue
        $fp="C:\inetpub\ftproot"
        if(-not(Test-Path $fp)){New-Item -ItemType Directory $fp|Out-Null}

        if(-not(Get-WebSite -Name "Sitio FTP Principal" -EA SilentlyContinue)){
            New-WebFtpSite -Name "Sitio FTP Principal" -Port ${PIF} -PhysicalPath $fp -Force|Out-Null
            OK "Sitio FTP creado en puerto ${PIF}"
        }

        Set-ItemProperty "IIS:\Sites\Sitio FTP Principal" `
            -Name ftpServer.security.authentication.basicAuthentication.enabled  -Value $true
        Set-ItemProperty "IIS:\Sites\Sitio FTP Principal" `
            -Name ftpServer.security.authentication.anonymousAuthentication.enabled -Value $false

        Start-Service W3SVC  -EA SilentlyContinue; Set-Service W3SVC  -StartupType Automatic
        Start-Service ftpsvc -EA SilentlyContinue; Set-Service ftpsvc -StartupType Automatic

        PaginaIISFTP (IPLoc)
        AbrirPuertos "IIS-FTP"
        $global:SVC["IIS-FTP"].Instalado=$true
        VerSvc "IIS-FTP"
        OK "IIS-FTP listo | Web: http://localhost:${PIW} | FTP: ftp://$(IPLoc):${PIF}"
    }catch{ERR "InstIISFTP: $($_.Exception.Message)"}
}

# INSTALACION: APACHE
function BuscaHttpd {
    $rutas=@(
        "$env:APPDATA\Apache24\bin\httpd.exe",
        "$env:LOCALAPPDATA\Apache24\bin\httpd.exe",
        "C:\Apache24\bin\httpd.exe",
        "C:\tools\Apache24\bin\httpd.exe",
        "C:\Program Files\Apache Software Foundation\Apache2.4\bin\httpd.exe",
        "C:\ProgramData\chocolatey\lib\apache-httpd\tools\Apache24\bin\httpd.exe"
    )
    foreach($r in $rutas){if($r-and(Test-Path $r)){return Split-Path(Split-Path $r -Parent)-Parent}}
    try{
        $svc=Get-WmiObject Win32_Service -Filter "Name='Apache2.4'" -EA SilentlyContinue
        if($svc -and $svc.PathName){
            $exe=($svc.PathName.Trim('"' ) -split ' ')[0].Trim()
            if(Test-Path $exe){return Split-Path(Split-Path $exe -Parent)-Parent}
        }
    }catch{}
    $f=Get-ChildItem "C:\" -Recurse -Filter "httpd.exe" -EA SilentlyContinue -Depth 8|Select-Object -First 1
    if($f){return Split-Path $f.DirectoryName -Parent}
    return $null
}

function VCRedist {
    $k=Get-ItemProperty "HKLM:\SOFTWARE\Microsoft\VisualStudio\14.0\VC\Runtimes\X64" -EA SilentlyContinue
    if($k-and $k.Installed-eq 1){OK "VC++ Redist ya instalado"; return}
    $d="$RDE\VC_redist.x64.exe"
    if(DescWeb "https://aka.ms/vs/17/release/vc_redist.x64.exe" $d "VC++ Redist"){
        Start-Process $d "/install /quiet /norestart" -Wait -NoNewWindow
        OK "VC++ Redist instalado"
    }
}

function ConfApache {
    param([string]$ra)
    $ra=([string]$ra).Trim()
    if(-not(Test-Path $ra)){ERR "Ruta Apache invalida: $ra"; return}
    INF "Configurando Apache en: $ra (Puerto HTTP=${PAH})"
    $conf="$ra\conf\httpd.conf"
    if(Test-Path $conf){
        $c=Get-Content $conf -Raw
        $c=$c -replace 'Define SRVROOT "[^"]*"',"Define SRVROOT `"$ra`""
        $c=$c -replace '(?m)^Listen 80\s*$',"Listen ${PAH}"
        $c=$c -replace '(?m)^Listen 0\.0\.0\.0:80\s*$',"Listen 0.0.0.0:${PAH}"
        if($c -notmatch "Listen ${PAH}"){$c="Listen ${PAH}`n"+$c}
        $c=$c -replace '#ServerName www\.example\.com:80',"ServerName $DOMINIO_PRINCIPAL`:${PAH}"
        $c=$c -replace '(?m)^ServerName www\.example\.com:80',"ServerName $DOMINIO_PRINCIPAL`:${PAH}"
        Set-Content $conf $c -Encoding UTF8
        OK "httpd.conf actualizado: Listen=${PAH}, ServerName=$DOMINIO_PRINCIPAL"
    }
    $exe="$ra\bin\httpd.exe"
    if(-not(Test-Path $exe)){ERR "httpd.exe no encontrado en $ra\bin\"; return}

    foreach($n in "Apache","Apache2.4"){
        $sv=Get-Service $n -EA SilentlyContinue
        if($sv){
            Stop-Service $n -Force -EA SilentlyContinue; Start-Sleep 1
            sc.exe delete $n|Out-Null; Start-Sleep 2
        }
    }
    $so="$RLO\httpd_out.txt"; $se="$RLO\httpd_err.txt"
    $pr=Start-Process $exe "-k install -n Apache2.4" `
        -RedirectStandardOutput $so -RedirectStandardError $se -NoNewWindow -Wait -PassThru
    if(Test-Path $so){Get-Content $so|ForEach-Object{INF $_}}
    if(Test-Path $se){Get-Content $se|ForEach-Object{INF $_}}
    INF "httpd -k install: codigo=$($pr.ExitCode)"
    Start-Sleep 2

    $sv=Get-Service Apache2.4 -EA SilentlyContinue
    if($sv){
        try{Start-Service Apache2.4 -EA Stop}catch{sc.exe start Apache2.4|Out-Null}
        Set-Service Apache2.4 -StartupType Automatic -EA SilentlyContinue
    }else{
        sc.exe create Apache2.4 binPath= "`"$exe`" -k runservice" start= auto DisplayName= "Apache2.4"|Out-Null
        sc.exe start Apache2.4|Out-Null; Start-Sleep 2
    }
    $sv=Get-Service Apache2.4 -EA SilentlyContinue
    if($sv-and $sv.Status-eq"Running"){OK "Apache2.4 corriendo"}
    else{AVI "Estado Apache: $($sv.Status)"}
}

function ExtraerApache {
    param($zip,$rf)
    if(Test-Path $rf){Remove-Item $rf -Recurse -Force}
    Add-Type -AssemblyName System.IO.Compression.FileSystem
    [System.IO.Compression.ZipFile]::ExtractToDirectory($zip,"C:\")
    $sub=Get-ChildItem "C:\" -Directory|Where-Object{$_.Name-match"(?i)Apache|httpd"}|Select-Object -First 1
    if($sub -and -not(Test-Path $rf)){Rename-Item $sub.FullName $rf; OK "Renombrado -> $rf"}
}

function InstApache {
    param([string]$fuente)
    Write-Host "`n  == APACHE (HTTP:${PAH} / HTTPS:${PAS}) ==" -Fore $CT
    $rf="C:\Apache24"; $instalado=$false

    if($fuente-eq"2"){
        INF "Origen: Repositorio FTP privado | Estructura: /http/Windows/Apache/"
        $localFile=FTPNavegar -Servicio "Apache"
        if(-not $localFile -or -not(Test-Path $localFile)){
            ERR "No se pudo obtener instalador de Apache por FTP"; return
        }
        if(-not(EsZIP $localFile)){ERR "El archivo descargado no es un ZIP valido"; return}
        ExtraerApache $localFile $rf
        if(Test-Path "$rf\bin\httpd.exe"){ConfApache $rf; $instalado=$true}
        else{ERR "httpd.exe no encontrado tras extraer ZIP de Apache"}
    }else{
        INF "[1/3] Intentando instalar Apache via winget..."
        $wg=Get-Command winget -EA SilentlyContinue
        if($wg){
            & winget install --id Apache.ApacheHTTPServer --silent `
                --accept-package-agreements --accept-source-agreements 2>&1|ForEach-Object{INF $_}
            Start-Sleep 3
            foreach($p in "C:\Apache24","C:\Program Files\Apache Software Foundation\Apache2.4"){
                if(Test-Path "$p\bin\httpd.exe"){$rf=$p;$instalado=$true;OK "Apache via winget: $rf"; break}
            }
        }
        if(-not $instalado){
            INF "[2/3] Intentando instalar Apache via Chocolatey..."
            $choco="C:\ProgramData\chocolatey\bin\choco.exe"
            if(-not(Test-Path $choco)){
                $null=Invoke-Expression(
                    (New-Object System.Net.WebClient).DownloadString(
                    'https://community.chocolatey.org/install.ps1')) 2>&1
                Start-Sleep 5
                $env:PATH=[System.Environment]::GetEnvironmentVariable("Path","Machine")+";"+
                          [System.Environment]::GetEnvironmentVariable("Path","User")
            }
            if(Test-Path $choco){
                VCRedist
                & $choco install apache-httpd --yes --no-progress --ignore-dependencies 2>&1|
                    ForEach-Object{INF([string]$_)}
                Start-Sleep 3
                $r=BuscaHttpd
                if($r){$rf=([string]$r).Trim();$instalado=$true}
            }
        }
        if(-not $instalado){
            INF "[3/3] Descargando Apache ZIP directo desde apachelounge.com..."
            $z="$RDE\apache-httpd-win64.zip"
            $urls=@(
                "https://home.apache.org/~trawick/release/httpd-2.4.63-win64-VS17.zip",
                "https://archive.apache.org/dist/httpd/binaries/win32/httpd-2.4.62-win64-VS17.zip"
            )
            foreach($u in $urls){
                if(Test-Path $z){Remove-Item $z -Force -EA SilentlyContinue}
                try{Start-BitsTransfer -Source $u -Destination $z -TransferType Download -EA Stop}catch{continue}
                if((Test-Path $z)-and(EsZIP $z)){OK "ZIP Apache descargado desde $u"; break}
            }
            if((Test-Path $z)-and(EsZIP $z)){
                ExtraerApache $z $rf
                if(Test-Path "$rf\bin\httpd.exe"){$instalado=$true}
            }
        }
        if(-not $instalado){
            ERR "No se pudo instalar Apache automaticamente."
            AVI "Descargue manualmente desde: https://www.apachelounge.com/download/"
            return
        }
        ConfApache $rf
    }
    PaginaApache "$rf\htdocs"
    AbrirPuertos "Apache"
    $global:SVC["Apache"].Instalado=$true
    VerSvc "Apache"
    OK "Apache listo | http://localhost:${PAH} | http://$(IPLoc):${PAH}"
}

# INSTALACION: NGINX
function InstNginx {
    param([string]$fuente)
    Write-Host "`n  == NGINX (HTTP:${PNH} / HTTPS:${PNS}) ==" -Fore $CT
    $rn="C:\nginx"; $instalador=""

    if($fuente-eq"1"){
        $vers=@(
            @{V="1.26.2";U="https://nginx.org/download/nginx-1.26.2.zip"},
            @{V="1.26.1";U="https://nginx.org/download/nginx-1.26.1.zip"},
            @{V="1.25.5";U="https://nginx.org/download/nginx-1.25.5.zip"},
            @{V="1.24.0";U="https://nginx.org/download/nginx-1.24.0.zip"}
        )
        for($i=0;$i-lt $vers.Count;$i++){Write-Host "  [$($i+1)] Nginx $($vers[$i].V)" -Fore $CM}
        do{
            $in=Read-Host "  Version"
            [bool]$vok=[int]::TryParse($in,[ref]$null)
            if($vok){[int]$sel=[int]$in}
        }while(-not $vok -or $sel -lt 1 -or $sel -gt $vers.Count)
        $v=$vers[$sel-1]
        $dst="$RDE\nginx-$($v.V).zip"; $ok=$false
        if(DescWeb $v.U $dst "Nginx $($v.V)" -and (EsZIP $dst)){$ok=$true}
        if(-not $ok){
            try{Start-BitsTransfer -Source $v.U -Destination $dst -TransferType Download -EA Stop}catch{}
            if((Test-Path $dst)-and(EsZIP $dst)){$ok=$true}
        }
        if(-not $ok){
            AVI "Descarga fallida. Descargue manualmente desde https://nginx.org/en/download.html"
            AVI "Coloque el ZIP en: $dst"
            if(-not(SN "Tienes el ZIP en ${dst}?")-or-not(Test-Path $dst)-or-not(EsZIP $dst)){return}
        }
        $instalador=$dst
    }else{
        INF "Origen: Repositorio FTP privado | Estructura: /http/Windows/Nginx/"
        $localFile=FTPNavegar -Servicio "Nginx"
        if(-not $localFile -or -not(Test-Path $localFile)){
            ERR "No se pudo obtener instalador de Nginx por FTP"; return
        }
        if(-not(EsZIP $localFile)){ERR "El archivo descargado no es un ZIP valido"; return}
        $instalador=$localFile
    }

    try{
        INF "Descomprimiendo Nginx en C:\nginx..."
        if(Test-Path $rn){Remove-Item $rn -Recurse -Force}
        Add-Type -AssemblyName System.IO.Compression.FileSystem
        [System.IO.Compression.ZipFile]::ExtractToDirectory($instalador,"C:\")
        $sub=Get-ChildItem "C:\" -Directory|Where-Object{$_.Name-match"^nginx-"}|Select-Object -First 1
        if($sub){Rename-Item $sub.FullName $rn; OK "Nginx extraido -> C:\nginx"}
        $exe=Join-Path $rn "nginx.exe"
        if(-not(Test-Path $exe)){ERR "nginx.exe no encontrado tras extraer ZIP"; return}

        PaginaNginx "$rn\html"

        $rnf=$rn.Replace("\","/"); $nl=[Environment]::NewLine
        $ng ="worker_processes 1;${nl}events { worker_connections 1024; }${nl}http {${nl}"
        $ng+="    include mime.types;${nl}    default_type application/octet-stream;${nl}"
        $ng+="    sendfile on;${nl}    keepalive_timeout 65;${nl}"
        $ng+="    server {${nl}        listen ${PNH};${nl}        server_name $DOMINIO_PRINCIPAL localhost;${nl}"
        $ng+="        root `"$rnf/html`";${nl}        index index.html index.htm;${nl}"
        $ng+="        location / { try_files `$uri `$uri/ =404; }${nl}"
        $ng+="        error_log `"$rnf/logs/error.log`";${nl}    }${nl}}${nl}"
        Set-Content "$rn\conf\nginx.conf" $ng -Encoding ASCII
        OK "nginx.conf configurado -> puerto ${PNH}"

        $nssm="$RT\nssm.exe"
        if(-not(Test-Path $nssm)){
            $nz="$RDE\nssm.zip"
            try{Start-BitsTransfer "https://nssm.cc/release/nssm-2.24.zip" $nz -TransferType Download -EA Stop}catch{}
            if((Test-Path $nz)-and(Get-Item $nz).Length-gt 10KB){
                try{
                    [System.IO.Compression.ZipFile]::ExtractToDirectory($nz,$RDE)
                    $nd=Get-ChildItem $RDE -Directory|Where-Object{$_.Name-match"nssm"}|Select-Object -First 1
                    if($nd){
                        $ne=Get-ChildItem "$($nd.FullName)\win64" -Filter "nssm.exe" -EA SilentlyContinue|
                           Select-Object -First 1
                        if($ne){Copy-Item $ne.FullName $nssm; OK "NSSM copiado a $nssm"}
                    }
                }catch{}
            }
        }
        $sv=Get-Service nginx -EA SilentlyContinue
        if(Test-Path $nssm){
            if($sv){& $nssm remove nginx confirm 2>&1|Out-Null; Start-Sleep 2}
            & $nssm install nginx $exe 2>&1|Out-Null
            & $nssm set nginx AppDirectory $rn 2>&1|Out-Null
        }else{
            if($sv){sc.exe delete nginx|Out-Null; Start-Sleep 2}
            sc.exe create nginx binPath= "`"$exe`"" start= auto DisplayName= "Nginx Web Server"|Out-Null
        }
        Start-Service nginx -EA SilentlyContinue
        Set-Service nginx -StartupType Automatic -EA SilentlyContinue
        $sv=Get-Service nginx -EA SilentlyContinue
        if(-not($sv-and $sv.Status-eq"Running")){
            Get-Process nginx -EA SilentlyContinue|Stop-Process -Force -EA SilentlyContinue
            Start-Sleep 1
            Start-Process $exe -WorkingDirectory $rn -WindowStyle Hidden
            AVI "Nginx iniciado como proceso (sin servicio)"
        }
        AbrirPuertos "Nginx"
        $global:SVC["Nginx"].Instalado=$true
        VerSvc "Nginx"
        OK "Nginx listo | http://localhost:${PNH} | http://$(IPLoc):${PNH}"
    }catch{ERR "InstNginx: $($_.Exception.Message)"}
}

# SSL: IIS-HTTP
function SSLIISHTTP {
    INF "Activando SSL en IIS-HTTP (puerto ${PHL}, dominio $DOMINIO_PRINCIPAL)..."
    Import-Module WebAdministration -EA SilentlyContinue
    $cert=CertIIS "IIS-HTTP-SSL"
    if(-not $cert){return}
    try{
        $si="Default Web Site"
        $wwwroot="C:\inetpub\wwwroot"

        if(-not(Test-Path $wwwroot)){New-Item -ItemType Directory $wwwroot -Force|Out-Null}
        Set-ItemProperty "IIS:\Sites\$si" -Name physicalPath -Value $wwwroot -EA SilentlyContinue
        OK "Ruta fisica IIS asegurada: $wwwroot"

        try{
            Set-WebConfiguration -PSPath "IIS:\Sites\$si" `
                -Filter "system.webServer/httpRedirect" `
                -Value @{enabled="false"} -EA SilentlyContinue
        }catch{}

        if(-not(Get-WebBinding -Name $si -Protocol https -Port ${PHL} -EA SilentlyContinue)){
            New-WebBinding -Name $si -Protocol https -Port ${PHL} -IPAddress "*"
            OK "Binding HTTPS:${PHL} creado"
        }

        $thumb=$cert.Thumbprint
        netsh http delete sslcert ipport=0.0.0.0:${PHL} 2>&1|Out-Null
        $r=netsh http add sslcert ipport=0.0.0.0:${PHL} certhash=$thumb `
            appid="{4dc3e181-e14b-4a21-b022-59fc669b0914}" 2>&1
        if($r -match "completado|successfully|SSL Certificate|added"){
            OK "Certificado SSL vinculado al puerto ${PHL}"
        }else{AVI "netsh info: $r"}

        $global:SVC["IIS-HTTP"].SSL=$true
        AbrirPuerto ${PHL} "IIS-HTTPS"

        try{
            $rdDir="C:\inetpub\redirect80"
            if(-not(Test-Path $rdDir)){New-Item -ItemType Directory $rdDir -Force|Out-Null}
            $rdCfg=@"
<?xml version="1.0" encoding="UTF-8"?>
<configuration>
  <system.webServer>
    <httpRedirect enabled="true" destination="https://$DOMINIO_PRINCIPAL" httpResponseStatus="Permanent" />
  </system.webServer>
</configuration>
"@
            Set-Content "$rdDir\web.config" $rdCfg -Encoding UTF8

            $rdSite=Get-WebSite -Name "HTTP-Redirect" -EA SilentlyContinue
            if($rdSite){Remove-WebSite -Name "HTTP-Redirect" -EA SilentlyContinue}
            New-WebSite -Name "HTTP-Redirect" -Port ${PIH} -PhysicalPath $rdDir -IPAddress "*" -Force|Out-Null
            Start-WebSite -Name "HTTP-Redirect" -EA SilentlyContinue
            OK "Sitio HTTP-Redirect activo: http://${PIH} -> https://$DOMINIO_PRINCIPAL"
        }catch{AVI "Sitio redirect: $($_.Exception.Message)"}

        $wcHSTS=@"
<?xml version="1.0" encoding="UTF-8"?>
<configuration>
  <system.webServer>
    <httpProtocol>
      <customHeaders>
        <add name="Strict-Transport-Security" value="max-age=31536000; includeSubDomains" />
        <add name="X-Frame-Options" value="DENY" />
      </customHeaders>
    </httpProtocol>
  </system.webServer>
</configuration>
"@
        Set-Content "$wwwroot\web.config" $wcHSTS -Encoding UTF8
        OK "Cabecera HSTS configurada en sitio HTTPS"

        EscribirPaginaIIS

        iisreset /restart /noforce 2>&1|Out-Null; Start-Sleep 4
        $p=Test-NetConnection localhost -Port ${PHL} -InformationLevel Quiet -WA SilentlyContinue
        if($p){
            OK "SSL IIS verificado | https://localhost"
            OK "https://192.168.100.49 debe mostrar pagina IIS en azul"
        }else{AVI "Puerto ${PHL} no responde aun. Verifique con Opcion 3."}
        AVI "El navegador mostrara advertencia de certificado autofirmado - es comportamiento esperado"
        INF "Dominio del certificado: $DOMINIO_PRINCIPAL, $DOMINIO_ALT"
    }catch{ERR "SSLIISHTTP: $($_.Exception.Message)"}
}

# SSL: IIS-FTP (FTPS)
function SSLIISFTP {
    INF "Activando FTPS en IIS-FTP (puerto implicito ${PIS}, dominio $DOMINIO_PRINCIPAL)..."
    Import-Module WebAdministration -EA SilentlyContinue
    $cert=CertIIS "IIS-FTP-SSL"
    if(-not $cert){return}
    try{
        $si="Sitio FTP Principal"
        if(-not(Get-WebSite -Name $si -EA SilentlyContinue)){
            ERR "Sitio '$si' no encontrado. Instale IIS-FTP primero."; return
        }

        Set-ItemProperty "IIS:\Sites\$si" `
            -Name ftpServer.security.ssl.serverCertHash -Value $cert.Thumbprint
        OK "Certificado FTPS asignado: $($cert.Thumbprint)"

        Set-ItemProperty "IIS:\Sites\$si" `
            -Name ftpServer.security.ssl.controlChannelPolicy -Value 2
        Set-ItemProperty "IIS:\Sites\$si" `
            -Name ftpServer.security.ssl.dataChannelPolicy    -Value 2
        OK "Politica SSL: canal control=Require (2), canal datos=Require (2)"

        if(-not(Get-WebBinding -Name $si -Port ${PIS} -EA SilentlyContinue)){
            New-WebBinding -Name $si -Protocol ftp -Port ${PIS} -IPAddress "*"
            OK "Binding FTPS implicito:${PIS} creado"
        }

        Restart-WebItem "IIS:\Sites\$si" -EA SilentlyContinue; Start-Sleep 3
        $p=Test-NetConnection localhost -Port ${PIS} -InformationLevel Quiet -WA SilentlyContinue
        if($p){
            $global:SVC["IIS-FTP"].SSL=$true
            AbrirPuerto ${PIS} "IIS-FTPS"
            OK "FTPS verificado | Conecte con FileZilla: host=$env:COMPUTERNAME, puerto=${PIS}, protocolo=FTPS-Implicito"
            AVI "Para FTPS explicito (AUTH TLS) use puerto ${PIF} con opcion FTPS en FileZilla"
        }else{AVI "Puerto ${PIS} no responde. Verifique con Opcion 3."}
        INF "Dominio del certificado: $DOMINIO_PRINCIPAL, $DOMINIO_ALT"
    }catch{ERR "SSLIISFTP: $($_.Exception.Message)"}
}

# SSL: APACHE
function SSLApache {
    INF "Activando SSL en Apache (puerto ${PAS}, dominio $DOMINIO_PRINCIPAL)..."
    $ra=$null
    foreach($p in "C:\Apache24","C:\Program Files\Apache Software Foundation\Apache2.4"){
        if(Test-Path "$p\bin\httpd.exe"){$ra=$p; break}
    }
    if(-not $ra){$ra=BuscaHttpd}
    if(-not $ra -or -not(Test-Path "$ra\bin\httpd.exe")){
        ERR "Apache no encontrado. Instale Apache primero."; return
    }
    INF "Apache encontrado en: $ra"
    if(-not(CertPEM "Apache")){return}

    try{
        $conf="$ra\conf\httpd.conf"
        $c=Get-Content $conf -Raw

        $c=$c -replace '#LoadModule ssl_module',        'LoadModule ssl_module'
        $c=$c -replace '#LoadModule socache_shmcb_module','LoadModule socache_shmcb_module'
        $c=$c -replace '#LoadModule headers_module',    'LoadModule headers_module'
        $c=$c -replace '#LoadModule rewrite_module',    'LoadModule rewrite_module'
        $c=$c -replace '#Include conf/extra/httpd-ssl.conf','Include conf/extra/httpd-ssl.conf'

        $redir=@"

# Redireccion HTTP -> HTTPS (generado por GestorServicios v3.0)
<VirtualHost *:${PAH}>
    ServerName $DOMINIO_PRINCIPAL
    ServerAlias $DOMINIO_ALT localhost
    RewriteEngine On
    RewriteRule ^(.*)$ https://%{HTTP_HOST}:${PAS}`$1 [R=301,L]
</VirtualHost>

"@
        if($c -notmatch "Redireccion HTTP -> HTTPS"){$c+=$redir}
        Set-Content $conf $c -Encoding UTF8
        OK "httpd.conf actualizado (SSL modules, HSTS, HTTP->HTTPS redirect)"

        $crtF=(Join-Path $RCE "Apache.crt").Replace("\","/")
        $keyF=(Join-Path $RCE "Apache.key").Replace("\","/")
        $logD=(Join-Path $ra "logs").Replace("\","/")
        $raF=$ra.Replace("\","/")
        $nl=[Environment]::NewLine

        if(-not(Test-Path "$ra\logs")) {New-Item -ItemType Directory "$ra\logs"  -Force|Out-Null; OK "Carpeta logs creada"}
        if(-not(Test-Path "$ra\htdocs")){New-Item -ItemType Directory "$ra\htdocs" -Force|Out-Null; OK "Carpeta htdocs creada"}

        $ssl="SSLRandomSeed startup builtin${nl}SSLRandomSeed connect builtin${nl}"
        $ssl+="Listen ${PAS}${nl}"
        $ssl+="SSLCipherSuite HIGH:MEDIUM:!MD5:!RC4:!3DES${nl}"
        $ssl+="SSLProtocol all -SSLv3 -TLSv1 -TLSv1.1${nl}"
        $ssl+="SSLHonorCipherOrder on${nl}SSLPassPhraseDialog builtin${nl}"
        $ssl+="SSLSessionCacheTimeout 300${nl}"
        $ssl+="${nl}<VirtualHost _default_:${PAS}>${nl}"
        $ssl+="    DocumentRoot `"$raF/htdocs`"${nl}"
        $ssl+="    ServerName $DOMINIO_PRINCIPAL`:${PAS}${nl}"
        $ssl+="    ServerAlias $DOMINIO_ALT localhost${nl}"
        $ssl+="    SSLEngine on${nl}"
        $ssl+="    SSLCertificateFile    `"$crtF`"${nl}"
        $ssl+="    SSLCertificateKeyFile `"$keyF`"${nl}"
        $ssl+="    ErrorLog  `"$logD/error_ssl.log`"${nl}"
        $ssl+="    CustomLog `"$logD/access_ssl.log`" common${nl}"
        $ssl+="    Header always set Strict-Transport-Security `"max-age=31536000; includeSubDomains`"${nl}"
        $ssl+="    Header always set X-Frame-Options DENY${nl}"
        $ssl+="    <Directory `"$raF/htdocs`">${nl}"
        $ssl+="        Options Indexes FollowSymLinks${nl}"
        $ssl+="        AllowOverride None${nl}"
        $ssl+="        Require all granted${nl}"
        $ssl+="    </Directory>${nl}"
        $ssl+="</VirtualHost>${nl}"
        Set-Content "$ra\conf\extra\httpd-ssl.conf" $ssl -Encoding UTF8
        OK "httpd-ssl.conf escrito sin shmcb (compatible Windows)"

        PaginaApache "$ra\htdocs"

        $te="$RLO\apache_ssl_test.txt"
        if(Test-Path $te){Remove-Item $te -Force}
        $pr=Start-Process "$ra\bin\httpd.exe" "-t" `
            -RedirectStandardError $te -NoNewWindow -Wait -PassThru
        if(Test-Path $te){
            $out=Get-Content $te -Raw -EA SilentlyContinue
            if($out -match "Syntax OK"){OK "Sintaxis Apache: OK"}
            elseif($out -match "[Ee]rror"){
                Get-Content $te|ForEach-Object{ERR "  $_"}
                ERR "Error de sintaxis en Apache. Abortando SSL."; return
            }
        }

        INF "Reiniciando Apache..."
        Get-Process httpd -EA SilentlyContinue|Stop-Process -Force -EA SilentlyContinue
        Start-Sleep 2
        foreach($n in "Apache2.4","Apache"){
            $sv=Get-Service $n -EA SilentlyContinue
            if($sv){
                try{Start-Service $n -EA Stop; Start-Sleep 4; break}
                catch{AVI "Servicio $n no arranco: $($_.Exception.Message)"}
            }
        }
        if(-not(Get-Process httpd -EA SilentlyContinue)){
            AVI "Iniciando Apache como proceso directo..."
            Start-Process "$ra\bin\httpd.exe" -WorkingDirectory $ra -WindowStyle Hidden
            Start-Sleep 4
        }

        AbrirPuerto ${PAS} "Apache-HTTPS"
        AbrirPuerto ${PAH} "Apache-HTTP"
        $p=Test-NetConnection localhost -Port ${PAS} -InformationLevel Quiet -WA SilentlyContinue
        if($p){
            $global:SVC["Apache"].SSL=$true
            $global:SVC["Apache"].Instalado=$true
            OK "SSL Apache verificado | https://localhost:${PAS}"
            OK "Redireccion HTTP->HTTPS | http://localhost:${PAH} -> https://localhost:${PAS}"
            OK "HSTS habilitado | max-age=31536000"
        }else{
            $errLog="$ra\logs\error_ssl.log"
            if(-not(Test-Path $errLog)){$errLog="$ra\logs\error.log"}
            if(Test-Path $errLog){
                AVI "Ultimas lineas del log de Apache:"
                Get-Content $errLog -Tail 5 -EA SilentlyContinue|ForEach-Object{AVI "  $_"}
            }
            ERR "Apache no responde en ${PAS}"
        }
        AVI "Navegador mostrara advertencia por certificado autofirmado - es comportamiento esperado"
        INF "Dominio del certificado: $DOMINIO_PRINCIPAL, $DOMINIO_ALT"
    }catch{ERR "SSLApache: $($_.Exception.Message)"}
}

# SSL: NGINX
function SSLNginx {
    INF "Activando SSL en Nginx (puerto ${PNS}, dominio $DOMINIO_PRINCIPAL)..."
    $rn="C:\nginx"
    if(-not(Test-Path "$rn\nginx.exe")){
        $f=Get-ChildItem "C:\" -Recurse -Filter "nginx.exe" -EA SilentlyContinue|Select-Object -First 1
        if($f){$rn=$f.DirectoryName}else{ERR "Nginx no encontrado. Instale Nginx primero."; return}
    }
    INF "Nginx encontrado en: $rn"
    if(-not(CertPEM "Nginx")){return}

    try{
        $crtF=(Join-Path $RCE "Nginx.crt").Replace("\","/")
        $keyF=(Join-Path $RCE "Nginx.key").Replace("\","/")
        $rnf=$rn.Replace("\","/"); $nl=[Environment]::NewLine
        $exe=Join-Path $rn "nginx.exe"

        $ng ="worker_processes 1;${nl}"
        $ng+="error_log `"$rnf/logs/error.log`";${nl}"
        $ng+="events { worker_connections 1024; }${nl}"
        $ng+="http {${nl}"
        $ng+="    include mime.types;${nl}"
        $ng+="    default_type application/octet-stream;${nl}"
        $ng+="    sendfile on;${nl}"
        $ng+="    keepalive_timeout 65;${nl}"
        $ng+="    server {${nl}"
        $ng+="        listen ${PNH};${nl}"
        $ng+="        server_name $DOMINIO_PRINCIPAL $DOMINIO_ALT localhost;${nl}"
        $ng+='        return 301 https://$host:'+${PNS}+'$request_uri;'+$nl
        $ng+="    }${nl}"
        $ng+="    server {${nl}"
        $ng+="        listen ${PNS} ssl;${nl}"
        $ng+="        server_name $DOMINIO_PRINCIPAL $DOMINIO_ALT localhost;${nl}"
        $ng+="        ssl_certificate     `"$crtF`";${nl}"
        $ng+="        ssl_certificate_key `"$keyF`";${nl}"
        $ng+="        ssl_protocols       TLSv1.2 TLSv1.3;${nl}"
        $ng+="        ssl_ciphers         HIGH:!aNULL:!MD5;${nl}"
        $ng+="        ssl_session_cache   builtin:1000;${nl}"
        $ng+="        ssl_session_timeout 5m;${nl}"
        $ng+="        add_header Strict-Transport-Security `"max-age=31536000; includeSubDomains`" always;${nl}"
        $ng+="        add_header X-Frame-Options DENY always;${nl}"
        $ng+="        root  `"$rnf/html`";${nl}"
        $ng+="        index index.html index.htm;${nl}"
        $ng+="        location / { try_files `$uri `$uri/ =404; }${nl}"
        $ng+="        access_log `"$rnf/logs/access_ssl.log`";${nl}"
        $ng+="        error_log  `"$rnf/logs/error_ssl.log`";${nl}"
        $ng+="    }${nl}"
        $ng+="}${nl}"
        Set-Content "$rn\conf\nginx.conf" $ng -Encoding ASCII
        OK "nginx.conf escrito con SSL, HTTP->HTTPS y HSTS"

        $te="$RLO\nginx_ssl_test.txt"
        if(Test-Path $te){Remove-Item $te -Force}
        $pr=Start-Process $exe "-t" -WorkingDirectory $rn `
            -RedirectStandardError $te -NoNewWindow -Wait -PassThru
        $out=""
        if(Test-Path $te){$out=Get-Content $te -Raw -EA SilentlyContinue}
        if($out -match "successful"){
            OK "Sintaxis Nginx: OK"
        }else{
            if($out){Get-Content $te|ForEach-Object{ERR "  nginx: $_"}}
            ERR "Error de sintaxis en nginx.conf. Abortando SSL."
            return
        }

        INF "Deteniendo Nginx para aplicar nueva configuracion SSL..."
        $sv=Get-Service nginx -EA SilentlyContinue
        if($sv -and $sv.Status -eq "Running"){
            Start-Process $exe "-s quit" -WorkingDirectory $rn -NoNewWindow -Wait -EA SilentlyContinue
            Start-Sleep 2
        }
        Get-Process nginx -EA SilentlyContinue|Stop-Process -Force -EA SilentlyContinue
        Start-Sleep 2

        INF "Iniciando Nginx con SSL..."
        if($sv){
            Start-Service nginx -EA SilentlyContinue
            Start-Sleep 4
            $sv=Get-Service nginx -EA SilentlyContinue
            if(-not($sv -and $sv.Status -eq "Running")){
                AVI "Servicio nginx no arranco; iniciando como proceso..."
                Start-Process $exe -WorkingDirectory $rn -WindowStyle Hidden
                Start-Sleep 3
            }
        }else{
            Start-Process $exe -WorkingDirectory $rn -WindowStyle Hidden
            Start-Sleep 3
        }

        $errLog="$rn\logs\error_ssl.log"
        if(Test-Path $errLog){
            $errContent=Get-Content $errLog -Tail 5 -EA SilentlyContinue
            if($errContent){
                AVI "Ultimas lineas de error_ssl.log:"
                $errContent|ForEach-Object{AVI "  $_"}
            }
        }

        AbrirPuerto ${PNS} "Nginx-HTTPS"
        AbrirPuerto ${PNH} "Nginx-HTTP"
        Start-Sleep 1
        $p=Test-NetConnection localhost -Port ${PNS} -InformationLevel Quiet -WA SilentlyContinue
        if($p){
            $global:SVC["Nginx"].SSL=$true
            $global:SVC["Nginx"].Instalado=$true
            OK "SSL Nginx verificado | https://localhost:${PNS}"
            OK "Redireccion HTTP->HTTPS | http://localhost:${PNH} -> https://localhost:${PNS}"
            OK "HSTS habilitado | max-age=31536000"
        }else{
            AVI "Puerto ${PNS} cerrado. Reintentando arranque..."
            Get-Process nginx -EA SilentlyContinue|Stop-Process -Force -EA SilentlyContinue
            Start-Sleep 1
            Start-Process $exe -WorkingDirectory $rn -WindowStyle Hidden
            Start-Sleep 4
            $p2=Test-NetConnection localhost -Port ${PNS} -InformationLevel Quiet -WA SilentlyContinue
            if($p2){
                $global:SVC["Nginx"].SSL=$true
                $global:SVC["Nginx"].Instalado=$true
                OK "SSL Nginx verificado en segundo intento | https://localhost:${PNS}"
            }else{
                ERR "Nginx sigue sin responder en ${PNS}."
                INF "Revise manualmente: $rn\logs\error_ssl.log"
                INF "Puede abrir el archivo con: notepad $rn\logs\error_ssl.log"
                Copy-Item "$rn\logs\error_ssl.log" "$RLO\nginx_error_ssl_$(Get-Date -f 'HHmmss').log" -EA SilentlyContinue
                INF "Log copiado a: $RLO"
            }
        }
        AVI "El navegador mostrara advertencia por certificado autofirmado - es comportamiento esperado"
        INF "Dominio del certificado: $DOMINIO_PRINCIPAL, $DOMINIO_ALT"
    }catch{ERR "SSLNginx: $($_.Exception.Message)"}
}

# MENUS DE INSTALACION Y SSL
function MenuInst {
    while($true){
        CLS2
        Write-Host "  == INSTALAR SERVICIOS ==" -Fore $CT
        Write-Host "  [1] IIS-FTP   (FTP:${PIF} / FTPS:${PIS} / Web:${PIW})" -Fore $CM
        Write-Host "  [2] IIS-HTTP  (HTTP:${PIH} / HTTPS:${PHL})"           -Fore $CM
        Write-Host "  [3] Apache    (HTTP:${PAH} / HTTPS:${PAS})"           -Fore $CM
        Write-Host "  [4] Nginx     (HTTP:${PNH} / HTTPS:${PNS})"           -Fore $CR
        Write-Host "  [0] Volver"                                         -Fore $CA
        do{$op=Read-Host "`n  Opcion"}while($op -notin "0","1","2","3","4")
        if($op-eq"0"){return}
        $fuente="1"
        if($op -in "3","4"){
            Write-Host "`n  ORIGEN DE INSTALACION:" -Fore $CT
            Write-Host "  [1] Web  (repositorio oficial / gestor de paquetes)" -Fore $CM
            Write-Host "  [2] FTP  (repositorio privado con verificacion hash)" -Fore $CM
            do{$fuente=Read-Host "  Fuente"}while($fuente -notin "1","2")
        }
        switch($op){
            "1"{InstIISFTP}
            "2"{InstIISHTTP}
            "3"{InstApache $fuente}
            "4"{InstNginx  $fuente}
        }
        Write-Host ""; [Console]::Out.Flush(); Read-Host "  ENTER para continuar"
    }
}

function MenuSSL {
    while($true){
        CLS2
        Write-Host "  == ACTIVAR SSL/TLS ==" -Fore $CT
        Write-Host "  [1] IIS-FTP   (FTPS implicito:${PIS}, RequireSSL en ctrl+datos)" -Fore $CM
        Write-Host "  [2] IIS-HTTP  (HTTPS:${PHL}, HTTP->HTTPS redirect, HSTS)"         -Fore $CM
        Write-Host "  [3] Apache    (HTTPS:${PAS}, HTTP->HTTPS redirect, HSTS)"         -Fore $CM
        Write-Host "  [4] Nginx     (HTTPS:${PNS}, HTTP->HTTPS redirect, HSTS)"         -Fore $CM
        Write-Host "  [5] Todos los servicios instalados"                               -Fore $CR
        Write-Host "  [0] Volver"                                                       -Fore $CA
        do{$op=Read-Host "`n  Opcion"}while($op -notin "0","1","2","3","4","5")
        if($op-eq"0"){return}
        switch($op){
            "1"{if(SN "Activar FTPS en IIS-FTP?") {SSLIISFTP}}
            "2"{if(SN "Activar SSL en IIS-HTTP?") {SSLIISHTTP}}
            "3"{if(SN "Activar SSL en Apache?")   {SSLApache}}
            "4"{if(SN "Activar SSL en Nginx?")    {SSLNginx}}
            "5"{
                foreach($sn in "IIS-FTP","IIS-HTTP","Apache","Nginx"){
                    if($global:SVC[$sn].Instalado){
                        Write-Host ""
                        if(SN "Activar SSL en ${sn}?"){
                            switch($sn){
                                "IIS-FTP" {SSLIISFTP}
                                "IIS-HTTP"{SSLIISHTTP}
                                "Apache"  {SSLApache}
                                "Nginx"   {SSLNginx}
                            }
                        }
                    }else{AVI "$sn no esta instalado; omitiendo."}
                }
            }
        }
        Write-Host ""; [Console]::Out.Flush(); Read-Host "  ENTER para continuar"
    }
}

# RESUMEN DE ESTADO
function Resumen {
    CLS2
    Write-Host "  == RESUMEN DE ESTADO DE SERVICIOS ==" -Fore $CT
    Write-Host ""
    foreach($s in "IIS-FTP","IIS-HTTP","Apache","Nginx"){VerSvc $s|Out-Null}
    Write-Host ""
    Write-Host "  +---------------+-----------+--------------+------+------------------------------------------+" -Fore $CT
    Write-Host "  | Servicio      | Puertos   | Estado       | SSL  | Ultima verificacion                      |" -Fore $CT
    Write-Host "  +---------------+-----------+--------------+------+------------------------------------------+" -Fore $CT
    $mp=@{
        "IIS-FTP" ="21/990/8082"
        "IIS-HTTP"="80/443"
        "Apache"  ="8080/8443"
        "Nginx"   ="8081/8444"
    }
    foreach($s in "IIS-FTP","IIS-HTTP","Apache","Nginx"){
        $e=$global:SVC[$s]
        $act=$e.UV -notmatch "detenido|Nunca|Error|no instalado"
        $cc=if($act){$CK}else{$CE}; $cs=if($e.SSL){$CK}else{$CA}
        $est=if($act){"ACTIVO      "}else{"INACTIVO    "}
        $ssl=if($e.SSL){"SI   "}else{"NO   "}
        $ver=$e.UV; if($ver.Length-gt 40){$ver=$ver.Substring(0,37)+"..."}
        Write-Host "  | $($s.PadRight(13)) | $($mp[$s].PadRight(9)) | " -NoNewline -Fore $CT
        Write-Host $est -NoNewline -Fore $cc
        Write-Host " | " -NoNewline -Fore $CT
        Write-Host $ssl -NoNewline -Fore $cs
        Write-Host " | $($ver.PadRight(40)) |" -Fore $CT
    }
    Write-Host "  +---------------+-----------+--------------+------+------------------------------------------+" -Fore $CT

    # Informacion de certificados SSL generados
    Write-Host ""
    Write-Host "  == CERTIFICADOS SSL (PKI) ==" -Fore $CT
    $certs=@(
        @{Nombre="IIS-HTTP";  Archivo="";          Thumbprint="IIS Store"},
        @{Nombre="IIS-FTP";   Archivo="";          Thumbprint="IIS Store"},
        @{Nombre="Apache";    Archivo="Apache.crt"; Thumbprint="PEM"},
        @{Nombre="Nginx";     Archivo="Nginx.crt";  Thumbprint="PEM"}
    )
    foreach($certItem in $certs){
        if($global:SVC[$certItem.Nombre].SSL){
            if($certItem.Archivo -and (Test-Path "$RCE\$($certItem.Archivo)")){
                try{
                    $cx=[System.Security.Cryptography.X509Certificates.X509Certificate2]::new("$RCE\$($certItem.Archivo)")
                    $san=($cx.DnsNameList -join ", ")
                    Write-Host "  [$($certItem.Nombre)] Subj: $($cx.Subject)" -Fore $CK
                    Write-Host "        SAN : $san" -ForegroundColor Gray
                    Write-Host "        Exp : $($cx.NotAfter.ToString('dd/MM/yyyy HH:mm'))" -ForegroundColor Gray
                }catch{Write-Host "  [$($certItem.Nombre)] Certificado PEM en $RCE\$($certItem.Archivo)" -Fore $CK}
            }else{
                $cx=Get-ChildItem "Cert:\LocalMachine\My" | Where-Object{$_.FriendlyName -match $certItem.Nombre} | Select-Object -First 1
                if($cx){
                    Write-Host "  [$($certItem.Nombre)] Subj: $($cx.Subject)" -Fore $CK
                    Write-Host "        Thumb: $($cx.Thumbprint)" -ForegroundColor Gray
                    Write-Host "        Exp  : $($cx.NotAfter.ToString('dd/MM/yyyy HH:mm'))" -ForegroundColor Gray
                }else{Write-Host "  [$($certItem.Nombre)] Certificado no encontrado en store" -Fore $CA}
            }
        }else{Write-Host "  [$($certItem.Nombre)] SSL no activado" -Fore $CA}
    }

    # Reglas de firewall
    Write-Host ""
    $rf=Get-NetFirewallRule -DisplayName "GS_*" -EA SilentlyContinue
    if($rf){
        Write-Host "  == REGLAS DE FIREWALL (GS_*) ==" -Fore $CT
        foreach($r in $rf){
            $pt=($r|Get-NetFirewallPortFilter -EA SilentlyContinue).LocalPort
            $col=if($r.Enabled -eq "True"){$CK}else{$CA}
            Write-Host "    $($r.DisplayName) | Puerto: $pt | $($r.Action)" -Fore $col
        }
    }
    Write-Host ""
    Write-Host "  Log actual: $LOG" -Fore $CI
    Write-Host "  Directorio certificados: $RCE" -Fore $CI
    Write-Host ""
    Read-Host "  ENTER para continuar"
}

# VERIFICAR URLs Y CONECTIVIDAD
function VerURLs {
    CLS2
    Write-Host "  == URLs Y VERIFICACION DE CONECTIVIDAD ==" -Fore $CT
    Write-Host ""
    $ip=IPLoc
    Write-Host "  Maquina: $env:COMPUTERNAME  |  IP: $ip  |  Dominio: $DOMINIO_PRINCIPAL" -Fore $CI
    Write-Host ""
    Write-Host "  +--------------------+-------------------------------------------------------+" -Fore $CT
    Write-Host "  | Servicio           | URL (abrir en navegador)                              |" -Fore $CT
    Write-Host "  +--------------------+-------------------------------------------------------+" -Fore $CT

    function FilaURL {
        param($n,$urls,$act)
        $col=if($act){$CK}else{$CE}; $est=if($act){"[OK]  "}else{"[OFF] "}; $prim=$true
        foreach($u in $urls){
            if($prim){
                Write-Host "  | " -NoNewline -Fore $CT
                Write-Host "$est $n".PadRight(18) -NoNewline -Fore $col
                Write-Host " | " -NoNewline -Fore $CT
                Write-Host $u.PadRight(53) -NoNewline -Fore $CR
                Write-Host " |" -Fore $CT; $prim=$false
            }else{
                Write-Host "  | " -NoNewline -Fore $CT
                Write-Host "".PadRight(18) -NoNewline
                Write-Host " | " -NoNewline -Fore $CT
                Write-Host $u.PadRight(53) -NoNewline -Fore $CR
                Write-Host " |" -Fore $CT
            }
        }
        Write-Host "  +--------------------+-------------------------------------------------------+" -Fore $CT
    }
    $e=$global:SVC

    $uFTP=@("http://localhost:${PIW}","http://${ip}:${PIW}")
    if($e["IIS-FTP"].SSL){$uFTP+="ftps://${ip}:${PIS} (FTPS implicito)"; $uFTP+="ftp://${ip}:${PIF} (FTPS explicito AUTH-TLS)"}
    FilaURL "IIS-FTP" $uFTP $e["IIS-FTP"].Instalado

    $uIIS=@("http://localhost","http://${ip}")
    if($e["IIS-HTTP"].SSL){$uIIS+="https://$DOMINIO_PRINCIPAL"; $uIIS+="https://localhost"; $uIIS+="https://${ip}"}
    FilaURL "IIS-HTTP" $uIIS $e["IIS-HTTP"].Instalado

    $uAPA=@("http://localhost:${PAH}","http://${ip}:${PAH}")
    if($e["Apache"].SSL){$uAPA+="https://$DOMINIO_PRINCIPAL`:${PAS}"; $uAPA+="https://localhost:${PAS}"; $uAPA+="https://${ip}:${PAS}"}
    FilaURL "Apache" $uAPA $e["Apache"].Instalado

    $uNGX=@("http://localhost:${PNH}","http://${ip}:${PNH}")
    if($e["Nginx"].SSL){$uNGX+="https://$DOMINIO_PRINCIPAL`:${PNS}"; $uNGX+="https://localhost:${PNS}"; $uNGX+="https://${ip}:${PNS}"}
    FilaURL "Nginx" $uNGX $e["Nginx"].Instalado

    Write-Host "`n  Comprobando puertos..." -Fore $CI
    Write-Host ""
    $checks=@(
        @{P=${PIH};N="IIS-HTTP   :${PIH}  (HTTP)"}
        @{P=${PHL};N="IIS-HTTP   :${PHL}  (HTTPS)"}
        @{P=${PIW};N="IIS-FTP    :${PIW}  (Web-Status)"}
        @{P=${PIF};N="IIS-FTP    :${PIF}  (FTP-ctrl)"}
        @{P=${PIS};N="IIS-FTP    :${PIS}  (FTPS-implicit)"}
        @{P=${PAH};N="Apache     :${PAH}  (HTTP)"}
        @{P=${PAS};N="Apache     :${PAS}  (HTTPS)"}
        @{P=${PNH};N="Nginx      :${PNH}  (HTTP)"}
        @{P=${PNS};N="Nginx      :${PNS}  (HTTPS)"}
    )
    foreach($c in $checks){
        $ok=Test-NetConnection localhost -Port $c.P -InformationLevel Quiet -WA SilentlyContinue -EA SilentlyContinue
        if($ok){$txt="[ABIERTO]";$col=$CK}else{$txt="[CERRADO]";$col=$CE}
        Write-Host "    $($c.N.PadRight(30)) -> " -NoNewline -Fore $CI
        Write-Host $txt -Fore $col
    }
    Write-Host ""; Read-Host "`n  ENTER para continuar"
}

# MENU PRINCIPAL
function MenuPrincipal {
    while($true){
        CLS2
        Write-Host "  MENU PRINCIPAL" -Fore $CT
        Write-Host "  ------------------------------------------------" -Fore $CT
        Write-Host ""
        Write-Host "  [1]  Instalar servicios (Web o FTP privado)"      -Fore $CM
        Write-Host "  [2]  Activar SSL/TLS (con HSTS y redireccion)"    -Fore $CM
        Write-Host "  [3]  Resumen de estado y certificados"             -Fore $CM
        Write-Host "  [4]  URLs y verificar conectividad"                -Fore $CR
        Write-Host "  [5]  Configurar servidor FTP privado"              -Fore $CM
        Write-Host "  [0]  Salir"                                         -Fore $CA
        Write-Host ""
        Write-Host "  Estado actual:" -Fore $CI
        foreach($s in "IIS-FTP","IIS-HTTP","Apache","Nginx"){
            $e=$global:SVC[$s]; $c=if($e.Instalado){$CK}else{$CA}
            $ssl=if($e.SSL){"[SSL/TLS]"}else{""}
            Write-Host "    $($s.PadRight(10)) : $(if($e.Instalado){'Instalado'}else{'No instalado'}) $ssl" -Fore $c
        }
        Write-Host ""
        Write-Host "  Puertos: IIS=${PIH}/${PHL} | FTP=${PIF}/${PIS} | Apache=${PAH}/${PAS} | Nginx=${PNH}/${PNS}" -Fore $CI
        Write-Host "  Certificados para: $DOMINIO_PRINCIPAL ($DOMINIO_ALT)" -Fore $CI
        Write-Host ""
        $op=Read-Host "  Seleccione opcion"
        switch($op){
            "1"{MenuInst}
            "2"{MenuSSL}
            "3"{Resumen}
            "4"{VerURLs}
            "5"{CLS2; ConfFTP; Write-Host ""; Read-Host "  ENTER para continuar"}
            "0"{Write-Host "`n  Saliendo. Log guardado en: $LOG" -Fore $CA; exit 0}
            default{Write-Host "  Opcion no valida. Use 0-5." -Fore $CE; Start-Sleep 1}
        }
    }
}

# INICIO DEL SCRIPT
Init
ILog "=== INICIO GestorServicios v3.0 | Usuario: $env:USERNAME | Maquina: $env:COMPUTERNAME ==="
ILog "Dominio certificados: $DOMINIO_PRINCIPAL / $DOMINIO_ALT"

$adm=([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole(
      [Security.Principal.WindowsBuiltInRole]::Administrator)
if(-not $adm){
    Write-Host "`n  [ERR] Debe ejecutar este script como Administrador." -Fore $CE
    Write-Host "        Clic derecho -> 'Ejecutar como administrador'" -Fore $CA
    Read-Host "  ENTER para salir"
    exit 1
}

[System.Net.ServicePointManager]::SecurityProtocol=
    [System.Net.SecurityProtocolType]::Tls12 -bor
    [System.Net.SecurityProtocolType]::Tls13

try{
    $sv=Get-Service W3SVC   -EA SilentlyContinue
    if($sv -and $sv.Status-eq"Running"){$global:SVC["IIS-HTTP"].Instalado=$true}

    $sv=Get-Service ftpsvc  -EA SilentlyContinue
    if($sv -and $sv.Status-eq"Running"){$global:SVC["IIS-FTP"].Instalado=$true}

    $sa=Get-Service Apache2.4 -EA SilentlyContinue
    $sb=Get-Service Apache    -EA SilentlyContinue
    $pc=Get-Process httpd      -EA SilentlyContinue
    if(($sa -and $sa.Status-eq"Running") -or ($sb -and $sb.Status-eq"Running") -or $pc){
        $global:SVC["Apache"].Instalado=$true
    }

    $sn=Get-Service nginx -EA SilentlyContinue
    $pn=Get-Process nginx -EA SilentlyContinue
    if(($sn -and $sn.Status-eq"Running") -or $pn){$global:SVC["Nginx"].Instalado=$true}

    if(Get-ChildItem "Cert:\LocalMachine\My" | Where-Object{$_.FriendlyName -eq "IIS-HTTP-SSL"} -EA SilentlyContinue){
        $global:SVC["IIS-HTTP"].SSL=$true
    }
    if(Get-ChildItem "Cert:\LocalMachine\My" | Where-Object{$_.FriendlyName -eq "IIS-FTP-SSL"} -EA SilentlyContinue){
        $global:SVC["IIS-FTP"].SSL=$true
    }
    if(Test-Path "$RCE\Apache.crt"){$global:SVC["Apache"].SSL=$true}
    if(Test-Path "$RCE\Nginx.crt") {$global:SVC["Nginx"].SSL=$true}
}catch{
    ILog "Advertencia en deteccion inicial: $($_.Exception.Message)" "AVI"
}

MenuPrincipal
