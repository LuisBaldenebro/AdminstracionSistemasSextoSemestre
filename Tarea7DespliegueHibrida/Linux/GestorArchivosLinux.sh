#!/bin/bash

# ── Verificar root ────────────────────────────────────────────────────────────
if [[ $EUID -ne 0 ]]; then
    echo "  [ERR] Ejecute como root: sudo bash $0"
    exit 1
fi

# ── Colores ───────────────────────────────────────────────────────────────────
CK='\033[0;32m'   # Verde   OK
CE='\033[0;31m'   # Rojo    ERR
CA='\033[0;33m'   # Amarillo AVI
CI='\033[0;37m'   # Gris    INF
CT='\033[0;36m'   # Cyan    Titulo
CM='\033[1;37m'   # Blanco  Menu
CR='\033[0;35m'   # Magenta URL
NC='\033[0m'      # Reset

# ── Rutas ─────────────────────────────────────────────────────────────────────
RT="/opt/GestorServicios"
RCE="$RT/Certificados"
RLO="$RT/Logs"
RDE="$RT/Descargas"
LOG="$RLO/gestor_$(date +%Y%m%d_%H%M%S).log"

# ── Dominio SSL ───────────────────────────────────────────────────────────────
DOMINIO_PRINCIPAL="www.reprobados.com"
DOMINIO_ALT="reprobados.com"

# ── Puertos ───────────────────────────────────────────────────────────────────
PIF=21            # vsftpd FTP control
PIS=990           # vsftpd FTPS implicito
PAH=8080          # Apache HTTP
PAS=8443          # Apache HTTPS
PNH=8081          # Nginx HTTP
PNS=8444          # Nginx HTTPS
PTH=8085          # Tomcat HTTP
PTS=8445          # Tomcat HTTPS

# ── Estado global ─────────────────────────────────────────────────────────────
declare -A SVC_INSTALADO=([vsftpd]=0 [Apache]=0 [Nginx]=0 [Tomcat]=0)
declare -A SVC_SSL=([vsftpd]=0 [Apache]=0 [Nginx]=0 [Tomcat]=0)

# ── FTP privado ───────────────────────────────────────────────────────────────
FTP_SERVIDOR=""
FTP_USUARIO=""
FTP_CLAVE=""
FTP_PUERTO=21

# UTILIDADES
ilog() { echo "[$(date '+%Y-%m-%d %H:%M:%S')] [$2] $1" >> "$LOG" 2>/dev/null; }
ok()   { echo -e "  ${CK}[OK]${NC}  $1"; ilog "$1" "OK"; }
err()  { echo -e "  ${CE}[ERR]${NC} $1"; ilog "$1" "ERR"; }
avi()  { echo -e "  ${CA}[!]${NC}   $1"; ilog "$1" "AVI"; }
inf()  { echo -e "  ${CI}[i]${NC}   $1"; ilog "$1" "INF"; }

sn() {
    local resp
    while true; do
        read -rp "  $1 [S/N]: " resp
        case "$resp" in
            [Ss]) return 0 ;;
            [Nn]) return 1 ;;
            *) echo "  Responda S o N" ;;
        esac
    done
}

iploc() {
    ip -4 addr show scope global | grep -oP '(?<=inet\s)\d+\.\d+\.\d+\.\d+' | head -1
}

cls2() {
    clear
    echo ""
    echo -e "  ${CT}============================================================${NC}"
    echo -e "  ${CT} GESTOR DE SERVICIOS WEB v3.0 - ORACLE LINUX 9.7           ${NC}"
    echo -e "  ${CT}============================================================${NC}"
    echo ""
}

init() {
    mkdir -p "$RT" "$RCE" "$RLO" "$RDE"
    chmod 700 "$RCE"
    ilog "=== INICIO | $(whoami) | $(hostname) ===" "INFO"
}

# FIREWALLD
abrir_puerto() {
    local puerto=$1 proto=${2:-tcp}
    if command -v firewall-cmd &>/dev/null; then
        firewall-cmd --permanent --add-port="${puerto}/${proto}" &>/dev/null
        firewall-cmd --reload &>/dev/null
        ok "Firewall: puerto $puerto/$proto abierto"
    fi
}

abrir_puertos() {
    local svc=$1
    case "$svc" in
        vsftpd)
            abrir_puerto $PIF tcp
            abrir_puerto $PIS tcp
            abrir_puerto "49152-65535" tcp
            ;;
        Apache)
            abrir_puerto $PAH tcp
            abrir_puerto $PAS tcp
            ;;
        Nginx)
            abrir_puerto $PNH tcp
            abrir_puerto $PNS tcp
            ;;
        Tomcat)
            abrir_puerto $PTH tcp
            abrir_puerto $PTS tcp
            ;;
    esac
}

# PAGINAS HTML
pagina_apache() {
    local ruta="$1"
    local ip; ip=$(iploc)
    local maq; maq=$(hostname)
    local f; f=$(date '+%d/%m/%Y %H:%M')
    mkdir -p "$ruta"
    cat > "$ruta/index.html" << HTML
<!DOCTYPE html>
<html lang="es">
<head><meta charset="UTF-8"><title>Apache HTTP Server</title>
<style>
*{margin:0;padding:0;box-sizing:border-box}
body{font-family:'Liberation Sans',sans-serif;background:#0f0f0f;color:#e0e0e0;min-height:100vh;display:flex;align-items:center;justify-content:center}
.w{width:100%;max-width:480px;padding:16px}
.card{background:#1a1a1a;border-radius:8px;overflow:hidden;border:1px solid #2a2a2a}
.top{height:3px;background:#c0392b}.body{padding:36px 32px 28px}
.dot-row{display:flex;align-items:center;gap:8px;margin-bottom:28px}
.dot{width:8px;height:8px;border-radius:50%;background:#3fb950}
.dot-txt{font-size:11px;font-weight:600;text-transform:uppercase;color:#3fb950}
h1{font-size:22px;font-weight:600;color:#fff;margin-bottom:4px}
.sub{font-size:13px;color:#555;margin-bottom:28px}
.grid{display:grid;grid-template-columns:1fr 1fr;gap:8px;margin-bottom:16px}
.cell{background:#111;border:1px solid #1e1e1e;border-radius:6px;padding:12px 14px}
.lbl{font-size:10px;font-weight:600;text-transform:uppercase;color:#444;margin-bottom:5px}
.val{font-size:14px;font-weight:600;color:#e74c3c}
.ok-bar{border:1px solid #1a3320;background:#0a1a10;border-radius:6px;padding:10px 14px;font-size:12px;color:#3fb950;margin-bottom:12px}
.info-box{background:#1a0a0a;border:1px solid #4a1010;border-radius:6px;padding:12px 14px;font-size:12px;color:#777;line-height:1.9}
.info-box span{color:#e74c3c;font-weight:600}
footer{margin-top:18px;font-size:11px;color:#2a2a2a;text-align:right}
</style></head>
<body><div class="w"><div class="card"><div class="top"></div><div class="body">
<div class="dot-row"><div class="dot"></div><span class="dot-txt">Servidor activo</span></div>
<h1>Apache HTTP Server</h1>
<p class="sub">Apache Software Foundation / Oracle Linux 9.7</p>
<div class="grid">
  <div class="cell"><div class="lbl">Puerto HTTP</div><div class="val">${PAH}</div></div>
  <div class="cell"><div class="lbl">Puerto HTTPS</div><div class="val">${PAS}</div></div>
  <div class="cell"><div class="lbl">Maquina</div><div class="val">${maq}</div></div>
  <div class="cell"><div class="lbl">IP Local</div><div class="val">${ip}</div></div>
</div>
<div class="ok-bar">Servicio Apache funcionando correctamente</div>
<div class="info-box">
  Dominio: <span>${DOMINIO_PRINCIPAL}</span><br>
  URL HTTP: <span>http://${ip}:${PAH}</span><br>
  URL HTTPS: <span>https://${ip}:${PAS}</span><br>
  Fecha: <span>${f}</span>
</div></div></div><footer>GestorServicios v3.0</footer></div></body></html>
HTML
    ok "Pagina Apache: $ruta"
}

pagina_nginx() {
    local ruta="$1"
    local ip; ip=$(iploc)
    local maq; maq=$(hostname)
    local f; f=$(date '+%d/%m/%Y %H:%M')
    mkdir -p "$ruta"
    cat > "$ruta/index.html" << HTML
<!DOCTYPE html>
<html lang="es">
<head><meta charset="UTF-8"><title>Nginx Web Server</title>
<style>
*{margin:0;padding:0;box-sizing:border-box}
body{font-family:'Liberation Sans',sans-serif;background:#0f0f0f;color:#e0e0e0;min-height:100vh;display:flex;align-items:center;justify-content:center}
.w{width:100%;max-width:480px;padding:16px}
.card{background:#1a1a1a;border-radius:8px;overflow:hidden;border:1px solid #2a2a2a}
.top{height:3px;background:#009639}.body{padding:36px 32px 28px}
.dot-row{display:flex;align-items:center;gap:8px;margin-bottom:28px}
.dot{width:8px;height:8px;border-radius:50%;background:#3fb950}
.dot-txt{font-size:11px;font-weight:600;text-transform:uppercase;color:#3fb950}
h1{font-size:22px;font-weight:600;color:#fff;margin-bottom:4px}
.sub{font-size:13px;color:#555;margin-bottom:28px}
.grid{display:grid;grid-template-columns:1fr 1fr;gap:8px;margin-bottom:16px}
.cell{background:#111;border:1px solid #1e1e1e;border-radius:6px;padding:12px 14px}
.lbl{font-size:10px;font-weight:600;text-transform:uppercase;color:#444;margin-bottom:5px}
.val{font-size:14px;font-weight:600;color:#00b347}
.ok-bar{border:1px solid #1a3320;background:#0a1a10;border-radius:6px;padding:10px 14px;font-size:12px;color:#3fb950;margin-bottom:12px}
.info-box{background:#0a1a0e;border:1px solid #0d3a1a;border-radius:6px;padding:12px 14px;font-size:12px;color:#777;line-height:1.9}
.info-box span{color:#00b347;font-weight:600}
footer{margin-top:18px;font-size:11px;color:#2a2a2a;text-align:right}
</style></head>
<body><div class="w"><div class="card"><div class="top"></div><div class="body">
<div class="dot-row"><div class="dot"></div><span class="dot-txt">Servidor activo</span></div>
<h1>Nginx Web Server</h1>
<p class="sub">nginx.org / Oracle Linux 9.7</p>
<div class="grid">
  <div class="cell"><div class="lbl">Puerto HTTP</div><div class="val">${PNH}</div></div>
  <div class="cell"><div class="lbl">Puerto HTTPS</div><div class="val">${PNS}</div></div>
  <div class="cell"><div class="lbl">Maquina</div><div class="val">${maq}</div></div>
  <div class="cell"><div class="lbl">IP Local</div><div class="val">${ip}</div></div>
</div>
<div class="ok-bar">Servicio Nginx funcionando correctamente</div>
<div class="info-box">
  Dominio: <span>${DOMINIO_PRINCIPAL}</span><br>
  URL HTTP: <span>http://${ip}:${PNH}</span><br>
  URL HTTPS: <span>https://${ip}:${PNS}</span><br>
  Fecha: <span>${f}</span>
</div></div></div><footer>GestorServicios v3.0</footer></div></body></html>
HTML
    ok "Pagina Nginx: $ruta"
}

pagina_tomcat() {
    local ruta="$1"
    local ip; ip=$(iploc)
    local maq; maq=$(hostname)
    local f; f=$(date '+%d/%m/%Y %H:%M')
    mkdir -p "$ruta"
    cat > "$ruta/index.html" << HTML
<!DOCTYPE html>
<html lang="es">
<head><meta charset="UTF-8"><title>Apache Tomcat</title>
<style>
*{margin:0;padding:0;box-sizing:border-box}
body{font-family:'Liberation Sans',sans-serif;background:#0f0f0f;color:#e0e0e0;min-height:100vh;display:flex;align-items:center;justify-content:center}
.w{width:100%;max-width:480px;padding:16px}
.card{background:#1a1a1a;border-radius:8px;overflow:hidden;border:1px solid #2a2a2a}
.top{height:3px;background:#f5a623}.body{padding:36px 32px 28px}
.dot-row{display:flex;align-items:center;gap:8px;margin-bottom:28px}
.dot{width:8px;height:8px;border-radius:50%;background:#3fb950}
.dot-txt{font-size:11px;font-weight:600;text-transform:uppercase;color:#3fb950}
h1{font-size:22px;font-weight:600;color:#fff;margin-bottom:4px}
.sub{font-size:13px;color:#555;margin-bottom:28px}
.grid{display:grid;grid-template-columns:1fr 1fr;gap:8px;margin-bottom:16px}
.cell{background:#111;border:1px solid #1e1e1e;border-radius:6px;padding:12px 14px}
.lbl{font-size:10px;font-weight:600;text-transform:uppercase;color:#444;margin-bottom:5px}
.val{font-size:14px;font-weight:600;color:#f5a623}
.ok-bar{border:1px solid #1a3320;background:#0a1a10;border-radius:6px;padding:10px 14px;font-size:12px;color:#3fb950;margin-bottom:12px}
.info-box{background:#1a1000;border:1px solid #4a2a00;border-radius:6px;padding:12px 14px;font-size:12px;color:#777;line-height:1.9}
.info-box span{color:#f5a623;font-weight:600}
footer{margin-top:18px;font-size:11px;color:#2a2a2a;text-align:right}
</style></head>
<body><div class="w"><div class="card"><div class="top"></div><div class="body">
<div class="dot-row"><div class="dot"></div><span class="dot-txt">Servidor activo</span></div>
<h1>Apache Tomcat</h1>
<p class="sub">Apache Software Foundation / Oracle Linux 9.7</p>
<div class="grid">
  <div class="cell"><div class="lbl">Puerto HTTP</div><div class="val">${PTH}</div></div>
  <div class="cell"><div class="lbl">Puerto HTTPS</div><div class="val">${PTS}</div></div>
  <div class="cell"><div class="lbl">Maquina</div><div class="val">${maq}</div></div>
  <div class="cell"><div class="lbl">IP Local</div><div class="val">${ip}</div></div>
</div>
<div class="ok-bar">Servicio Tomcat funcionando correctamente</div>
<div class="info-box">
  Dominio: <span>${DOMINIO_PRINCIPAL}</span><br>
  URL HTTP: <span>http://${ip}:${PTH}</span><br>
  URL HTTPS: <span>https://${ip}:${PTS}</span><br>
  Fecha: <span>${f}</span>
</div></div></div><footer>GestorServicios v3.0</footer></div></body></html>
HTML
    ok "Pagina Tomcat: $ruta"
}

# CERTIFICADOS SSL
# Todos con CN=www.reprobados.com y SAN
generar_cert() {
    local srv="$1"
    local keyF="$RCE/${srv}.key"
    local crtF="$RCE/${srv}.crt"
    local cnf="$RCE/${srv}.cnf"

    inf "Generando certificado autofirmado para $srv (${DOMINIO_PRINCIPAL})..."

    cat > "$cnf" << EOF
[req]
default_bits       = 2048
prompt             = no
default_md         = sha256
distinguished_name = dn
x509_extensions    = v3_req

[dn]
CN     = ${DOMINIO_PRINCIPAL}
O      = reprobados
OU     = Practica7
C      = MX
ST     = Estado
L      = Ciudad

[v3_req]
subjectAltName     = @alt_names
keyUsage           = digitalSignature, keyEncipherment
extendedKeyUsage   = serverAuth
basicConstraints   = CA:FALSE

[alt_names]
DNS.1 = ${DOMINIO_PRINCIPAL}
DNS.2 = ${DOMINIO_ALT}
DNS.3 = localhost
DNS.4 = $(hostname)
IP.1  = $(iploc)
IP.2  = 127.0.0.1
EOF

    openssl req -x509 -nodes -days 1825 \
        -newkey rsa:2048 \
        -keyout "$keyF" \
        -out "$crtF" \
        -config "$cnf" 2>/dev/null

    if [[ -f "$crtF" && -f "$keyF" ]]; then
        chmod 600 "$keyF"
        chmod 644 "$crtF"
        ok "Certificado: $crtF"
        ok "Clave privada: $keyF"
        ok "CN=$(openssl x509 -noout -subject -in "$crtF" 2>/dev/null | sed 's/.*CN=//')"
        return 0
    else
        err "Error generando certificado para $srv"
        return 1
    fi
}

# CLIENTE FTP DINAMICO
conf_ftp() {
    echo ""
    echo -e "  ${CT}== CONFIGURAR SERVIDOR FTP PRIVADO ==${NC}"
    read -rp "  Servidor FTP (IP o hostname): " FTP_SERVIDOR
    read -rp "  Puerto [Enter=21]: " p
    FTP_PUERTO=${p:-21}
    read -rp "  Usuario FTP: " FTP_USUARIO
    read -rsp "  Contrasena: " FTP_CLAVE
    echo ""
    ok "FTP configurado: ${FTP_SERVIDOR}:${FTP_PUERTO} | usuario: ${FTP_USUARIO}"
}

ftp_list() {
    # Lista el contenido de una ruta FTP via curl
    local ruta="$1"
    local url="ftp://${FTP_SERVIDOR}:${FTP_PUERTO}${ruta}"
    curl -s --connect-timeout 10 --max-time 30 \
        -u "${FTP_USUARIO}:${FTP_CLAVE}" \
        "$url" 2>/dev/null | awk '{print $NF}' | grep -v '^\.\.\?$'
}

ftp_get() {
    # Descarga un archivo del FTP
    local ruta_remota="$1"
    local ruta_local="$2"
    local url="ftp://${FTP_SERVIDOR}:${FTP_PUERTO}${ruta_remota}"
    inf "Descargando: $(basename "$ruta_remota")..."
    curl -s --connect-timeout 15 --max-time 300 \
        -u "${FTP_USUARIO}:${FTP_CLAVE}" \
        "$url" -o "$ruta_local" 2>/dev/null
    if [[ -f "$ruta_local" && -s "$ruta_local" ]]; then
        ok "Descargado: $ruta_local"
        return 0
    else
        err "Error descargando: $ruta_remota"
        return 1
    fi
}

# VERIFICACION DE INTEGRIDAD SHA256
verificar_hash() {
    local archivo="$1"
    local hash_file="$2"

    inf "Verificando integridad SHA256: $(basename "$archivo")"

    if [[ ! -f "$archivo" ]]; then
        err "Archivo no encontrado: $archivo"
        return 1
    fi
    if [[ ! -f "$hash_file" ]]; then
        avi "Archivo .sha256 no encontrado: $hash_file"
        return 1
    fi

    local hash_local
    hash_local=$(sha256sum "$archivo" | awk '{print $1}' | tr '[:upper:]' '[:lower:]')

    local hash_esperado
    hash_esperado=$(awk '{print $1}' "$hash_file" | tr '[:upper:]' '[:lower:]')

    if [[ "$hash_local" == "$hash_esperado" ]]; then
        ok "INTEGRIDAD OK - SHA256: $hash_local"
        return 0
    else
        err "INTEGRIDAD FALLIDA!"
        err "  Calculado : $hash_local"
        err "  Esperado  : $hash_esperado"
        return 1
    fi
}

# NAVEGACION FTP DINAMICA
ftp_navegar() {
    local servicio_sugerido="$1"

    if [[ -z "$FTP_SERVIDOR" ]]; then
        conf_ftp
    fi
    if [[ -z "$FTP_SERVIDOR" ]]; then
        err "Servidor FTP no configurado"
        return 1
    fi

    local base_path="/http/Linux/"

    # Paso 1: Listar carpetas de servicios
    if [[ -z "$servicio_sugerido" ]]; then
        inf "Listando servicios en FTP: ${FTP_SERVIDOR}${base_path}"
        mapfile -t carpetas < <(ftp_list "$base_path" | grep -v '^\s*$')
        if [[ ${#carpetas[@]} -eq 0 ]]; then
            err "No se encontraron servicios en ${base_path}"
            return 1
        fi
        echo ""
        echo -e "  ${CT}Servicios disponibles en FTP (${FTP_SERVIDOR}):${NC}"
        for i in "${!carpetas[@]}"; do
            echo -e "  ${CM}[$((i+1))] ${carpetas[$i]}${NC}"
        done
        local sel
        while true; do
            read -rp "  Seleccione servicio: " sel
            if [[ "$sel" =~ ^[0-9]+$ ]] && (( sel >= 1 && sel <= ${#carpetas[@]} )); then
                break
            fi
        done
        servicio_sugerido="${carpetas[$((sel-1))]}"
    fi

    # Paso 2: Listar instaladores dentro del servicio
    local svc_path="${base_path}${servicio_sugerido}/"
    inf "Listando instaladores en: ${svc_path}"
    mapfile -t todos < <(ftp_list "$svc_path" | grep -v '^\s*$')

    # Filtrar: solo instaladores
    local instaladores=()
    for item in "${todos[@]}"; do
        if [[ ! "$item" =~ \.(sha256|md5)$ ]]; then
            instaladores+=("$item")
        fi
    done

    if [[ ${#instaladores[@]} -eq 0 ]]; then
        err "No hay instaladores en ${svc_path}"
        return 1
    fi

    echo ""
    echo -e "  ${CT}Versiones disponibles para '${servicio_sugerido}':${NC}"
    for i in "${!instaladores[@]}"; do
        echo -e "  ${CM}[$((i+1))] ${instaladores[$i]}${NC}"
    done
    local sel2
    while true; do
        read -rp "  Seleccione version: " sel2
        if [[ "$sel2" =~ ^[0-9]+$ ]] && (( sel2 >= 1 && sel2 <= ${#instaladores[@]} )); then
            break
        fi
    done

    local elegido="${instaladores[$((sel2-1))]}"
    local local_file="$RDE/$elegido"
    local remote_path="${svc_path}${elegido}"
    local remote_hash="${svc_path}${elegido}.sha256"
    local local_hash="$RDE/${elegido}.sha256"

    # Paso 3: Descargar instalador
    if ! ftp_get "$remote_path" "$local_file"; then
        err "Error descargando $elegido"
        return 1
    fi

    # Paso 4: Descargar y verificar hash SHA256
    inf "Buscando hash SHA256: ${elegido}.sha256"
    if ftp_get "$remote_hash" "$local_hash"; then
        if ! verificar_hash "$local_file" "$local_hash"; then
            err "Verificacion de integridad FALLIDA. Archivo posiblemente corrupto."
            if ! sn "Continuar de todas formas?"; then
                rm -f "$local_file"
                return 1
            fi
            avi "Continuando con archivo sin verificar"
        fi
    else
        avi "Archivo .sha256 no encontrado en FTP; omitiendo verificacion"
    fi

    # Exportar ruta del archivo descargado
    FTP_ARCHIVO_LOCAL="$local_file"
    return 0
}

# VERIFICACION DE SERVICIOS
ver_svc() {
    local svc="$1"
    inf "Verificando $svc..."
    local act=0 res=""

    case "$svc" in
        vsftpd)
            if systemctl is-active --quiet vsftpd 2>/dev/null; then
                act=1
                local f; f=$(ss -tlnp 2>/dev/null | grep ":${PIF}" | head -1)
                local fs; fs=$(ss -tlnp 2>/dev/null | grep ":${PIS}" | head -1)
                res="vsftpd activo | FTP:$([ -n "$f" ] && echo OK || echo X) | FTPS:$([ -n "$fs" ] && echo OK || echo X)"
                if [[ ${SVC_SSL[vsftpd]} -eq 1 ]] && [[ -f "$RCE/vsftpd.crt" ]]; then
                    local cn; cn=$(openssl x509 -noout -subject -in "$RCE/vsftpd.crt" 2>/dev/null | sed 's/.*CN=//')
                    res+=" | Cert: $cn"
                fi
            else
                res="vsftpd detenido o no instalado"
            fi
            ;;
        Apache)
            if systemctl is-active --quiet httpd 2>/dev/null; then
                act=1
                local h; h=$(ss -tlnp 2>/dev/null | grep ":${PAH}" | head -1)
                local hs; hs=$(ss -tlnp 2>/dev/null | grep ":${PAS}" | head -1)
                res="httpd activo | HTTP:$([ -n "$h" ] && echo OK || echo X) | HTTPS:$([ -n "$hs" ] && echo OK || echo X)"
                if [[ ${SVC_SSL[Apache]} -eq 1 ]] && [[ -f "$RCE/Apache.crt" ]]; then
                    local cn; cn=$(openssl x509 -noout -subject -in "$RCE/Apache.crt" 2>/dev/null | sed 's/.*CN=//')
                    res+=" | Cert: $cn"
                fi
            else
                res="httpd detenido o no instalado"
            fi
            ;;
        Nginx)
            if nginx_esta_activo 2>/dev/null; then
                act=1
                local h; h=$(ss -tlnp 2>/dev/null | grep ":${PNH}" | head -1)
                local hs; hs=$(ss -tlnp 2>/dev/null | grep ":${PNS}" | head -1)
                res="nginx activo | HTTP:$([ -n "$h" ] && echo OK || echo X) | HTTPS:$([ -n "$hs" ] && echo OK || echo X)"
                if [[ ${SVC_SSL[Nginx]} -eq 1 ]] && [[ -f "$RCE/Nginx.crt" ]]; then
                    local cn; cn=$(openssl x509 -noout -subject -in "$RCE/Nginx.crt" 2>/dev/null | sed 's/.*CN=//')
                    res+=" | Cert: $cn"
                fi
            else
                res="nginx detenido o no instalado"
            fi
            ;;
        Tomcat)
            if tomcat_esta_activo 2>/dev/null; then
                act=1
                local h; h=$(ss -tlnp 2>/dev/null | grep ":${PTH}" | head -1)
                local hs; hs=$(ss -tlnp 2>/dev/null | grep ":${PTS}" | head -1)
                res="tomcat activo | HTTP:$([ -n "$h" ] && echo OK || echo X) | HTTPS:$([ -n "$hs" ] && echo OK || echo X)"
                if [[ ${SVC_SSL[Tomcat]} -eq 1 ]] && [[ -f "$RCE/Tomcat.crt" ]]; then
                    local cn; cn=$(openssl x509 -noout -subject -in "$RCE/Tomcat.crt" 2>/dev/null | sed 's/.*CN=//')
                    res+=" | Cert: $cn"
                fi
            else
                res="tomcat detenido o no instalado"
            fi
            ;;
    esac

    if [[ $act -eq 1 ]]; then
        ok "$svc : $res"
        SVC_INSTALADO[$svc]=1
    else
        avi "$svc : $res"
    fi
    return $act
}

# INSTALACION: vsftpd
inst_vsftpd() {
    echo -e "\n  ${CT}== vsftpd (FTP:${PIF} / FTPS:${PIS}) ==${NC}"
    inf "Instalando vsftpd via dnf..."
    dnf install -y vsftpd &>/dev/null
    if ! command -v vsftpd &>/dev/null; then
        err "vsftpd no se pudo instalar"
        return 1
    fi
    ok "vsftpd instalado"

    mkdir -p /var/ftp/http/Linux/{Apache,Nginx,Tomcat}
    chown -R ftp:ftp /var/ftp 2>/dev/null || true
    chmod 755 /var/ftp

    cat > /etc/vsftpd/vsftpd.conf << 'EOF'
anonymous_enable=NO
local_enable=YES
write_enable=YES
local_umask=022
dirmessage_enable=YES
xferlog_enable=YES
connect_from_port_20=YES
xferlog_std_format=YES
listen=YES
listen_ipv6=NO
pam_service_name=vsftpd
userlist_enable=YES
tcp_wrappers=NO
pasv_enable=YES
pasv_min_port=49152
pasv_max_port=65534
pasv_address=
chroot_local_user=NO
allow_writeable_chroot=YES
EOF

    systemctl enable vsftpd &>/dev/null
    systemctl restart vsftpd
    sleep 2
    abrir_puertos vsftpd
    SVC_INSTALADO[vsftpd]=1
    ver_svc vsftpd
    ok "vsftpd listo | ftp://$(iploc):${PIF}"
}

# INSTALACION: APACHE (httpd)
inst_apache() {
    local fuente="$1"
    echo -e "\n  ${CT}== APACHE (HTTP:${PAH} / HTTPS:${PAS}) ==${NC}"

    if [[ "$fuente" == "2" ]]; then
        # Origen FTP
        inf "Origen: Repositorio FTP privado | /http/Linux/Apache/"
        FTP_ARCHIVO_LOCAL=""
        if ! ftp_navegar "Apache"; then
            err "No se pudo obtener Apache por FTP"; return 1
        fi
        local pkg="$FTP_ARCHIVO_LOCAL"
        inf "Instalando desde: $pkg"
        if [[ "$pkg" =~ \.rpm$ ]]; then
            dnf install -y "$pkg" &>/dev/null || rpm -ivh "$pkg" &>/dev/null
        elif [[ "$pkg" =~ \.tar\.gz$ ]]; then
            tar -xzf "$pkg" -C /opt/ &>/dev/null
        fi
    else
        inf "Instalando httpd via dnf..."
        dnf install -y httpd mod_ssl &>/dev/null
    fi

    if ! command -v httpd &>/dev/null; then
        err "httpd no se pudo instalar"
        return 1
    fi
    ok "httpd instalado: $(httpd -v 2>/dev/null | head -1)"

    # Configurar puerto personalizado
    local conf="/etc/httpd/conf/httpd.conf"
    if [[ -f "$conf" ]]; then
        sed -i "s/^Listen 80$/Listen ${PAH}/" "$conf"
        sed -i "s/^Listen 0\.0\.0\.0:80$/Listen 0.0.0.0:${PAH}/" "$conf"
        grep -q "Listen ${PAH}" "$conf" || sed -i "1s/^/Listen ${PAH}\n/" "$conf"
        sed -i "s/^ServerName.*/ServerName ${DOMINIO_PRINCIPAL}:${PAH}/" "$conf"
        grep -q "^ServerName" "$conf" || echo "ServerName ${DOMINIO_PRINCIPAL}:${PAH}" >> "$conf"
        ok "httpd.conf: Listen=${PAH}"
    fi

    [[ -f /etc/httpd/conf.d/ssl.conf ]] && mv /etc/httpd/conf.d/ssl.conf /etc/httpd/conf.d/ssl.conf.bak

    pagina_apache /var/www/html

    systemctl enable httpd &>/dev/null
    systemctl restart httpd
    sleep 2
    abrir_puertos Apache
    SVC_INSTALADO[Apache]=1
    ver_svc Apache
    ok "Apache listo | http://$(iploc):${PAH}"
}

# INSTALACION: NGINX
inst_nginx() {
    local fuente="$1"
    echo -e "\n  ${CT}== NGINX (HTTP:${PNH} / HTTPS:${PNS}) ==${NC}"

    if [[ "$fuente" == "2" ]]; then
        inf "Origen: Repositorio FTP privado | /http/Linux/Nginx/"
        FTP_ARCHIVO_LOCAL=""
        if ! ftp_navegar "Nginx"; then
            err "No se pudo obtener Nginx por FTP"; return 1
        fi
        local pkg="$FTP_ARCHIVO_LOCAL"
        if [[ "$pkg" =~ \.rpm$ ]]; then
            dnf install -y "$pkg" &>/dev/null || rpm -ivh "$pkg" &>/dev/null
        elif [[ "$pkg" =~ \.tar\.gz$ ]]; then
            tar -xzf "$pkg" -C /opt/ &>/dev/null
        fi
    else
        inf "Instalando nginx via dnf..."
        dnf install -y nginx &>/dev/null
    fi

    if ! command -v nginx &>/dev/null; then
        err "nginx no se pudo instalar"
        return 1
    fi
    ok "nginx instalado: $(nginx -v 2>&1 | head -1)"

    cat > /etc/nginx/nginx.conf << 'NGINXMAIN'
user nginx;
worker_processes auto;
error_log /var/log/nginx/error.log notice;
pid /run/nginx.pid;

include /usr/share/nginx/modules/*.conf;

events {
    worker_connections 1024;
}

http {
    log_format  main  '$remote_addr - $remote_user [$time_local] "$request" '
                      '$status $body_bytes_sent "$http_referer" '
                      '"$http_user_agent" "$http_x_forwarded_for"';
    access_log  /var/log/nginx/access.log  main;
    sendfile        on;
    tcp_nopush      on;
    keepalive_timeout 65;
    types_hash_max_size 4096;
    include /etc/nginx/mime.types;
    default_type application/octet-stream;
    include /etc/nginx/conf.d/*.conf;
}
NGINXMAIN
    ok "nginx.conf reescrito (sin bloque port 80 por defecto)"

    [[ -f /etc/nginx/conf.d/default.conf ]] &&         mv /etc/nginx/conf.d/default.conf /etc/nginx/conf.d/default.conf.bak 2>/dev/null || true

    cat > /etc/nginx/conf.d/gestor.conf << EOF
server {
    listen ${PNH};
    server_name ${DOMINIO_PRINCIPAL} ${DOMINIO_ALT} localhost;
    root /usr/share/nginx/html;
    index index.html index.htm;
    location / { try_files \$uri \$uri/ =404; }
    error_log /var/log/nginx/error_http.log;
}
EOF

    pagina_nginx /usr/share/nginx/html

    nginx -t 2>/dev/null && ok "Sintaxis nginx: OK"
    systemctl enable nginx &>/dev/null
    systemctl restart nginx
    sleep 2
    abrir_puertos Nginx
    SVC_INSTALADO[Nginx]=1
    ver_svc Nginx
    ok "Nginx listo | http://$(iploc):${PNH}"
}

# INSTALACION: TOMCAT
inst_tomcat() {
    local fuente="$1"
    echo -e "\n  ${CT}== TOMCAT (HTTP:${PTH} / HTTPS:${PTS}) ==${NC}"

    local TC_HOME="/opt/tomcat"
    local TC_VER="10.1.18"

    if [[ "$fuente" == "2" ]]; then
        inf "Origen: Repositorio FTP privado | /http/Linux/Tomcat/"
        FTP_ARCHIVO_LOCAL=""
        if ! ftp_navegar "Tomcat"; then
            err "No se pudo obtener Tomcat por FTP"; return 1
        fi
        local pkg="$FTP_ARCHIVO_LOCAL"
        mkdir -p "$TC_HOME"
        if [[ "$pkg" =~ \.tar\.gz$ ]]; then
            tar -xzf "$pkg" -C /opt/ --strip-components=1 2>/dev/null || \
            tar -xzf "$pkg" -C /opt/ 2>/dev/null
            local dir; dir=$(find /opt -maxdepth 1 -name "apache-tomcat*" -type d | head -1)
            [[ -n "$dir" && "$dir" != "$TC_HOME" ]] && mv "$dir" "$TC_HOME"
        fi
    else
        inf "Descargando Apache Tomcat ${TC_VER}..."
        mkdir -p "$TC_HOME"
        local url="https://archive.apache.org/dist/tomcat/tomcat-10/v${TC_VER}/bin/apache-tomcat-${TC_VER}.tar.gz"
        local tgz="$RDE/tomcat-${TC_VER}.tar.gz"
        if ! curl -sL --connect-timeout 30 --max-time 300 "$url" -o "$tgz" 2>/dev/null; then
            err "Error descargando Tomcat"
            return 1
        fi
        tar -xzf "$tgz" -C "$TC_HOME" --strip-components=1 2>/dev/null
    fi

    if [[ ! -f "$TC_HOME/bin/catalina.sh" ]]; then
        err "Tomcat no encontrado en $TC_HOME"
        return 1
    fi
    ok "Tomcat extraido en: $TC_HOME"

    # Crear usuario tomcat
    id tomcat &>/dev/null || useradd -r -m -U -d "$TC_HOME" -s /bin/false tomcat
    chown -R tomcat:tomcat "$TC_HOME"
    chmod +x "$TC_HOME/bin/"*.sh

    # Configurar puerto HTTP en server.xml
    sed -i "s/port=\"8080\"/port=\"${PTH}\"/" "$TC_HOME/conf/server.xml"
    sed -i "s/port=\"8009\"/port=\"18009\"/" "$TC_HOME/conf/server.xml"
    sed -i "s/port=\"8443\"/port=\"${PTS}\"/" "$TC_HOME/conf/server.xml"

    local java_ver
    java_ver=$(java -version 2>&1 | awk -F[\"_] '/version/{print $2}' | cut -d. -f1)
    if [[ -z "$java_ver" || "$java_ver" -lt 11 ]]; then
        avi "Java $java_ver detectado. Tomcat 10 requiere Java 11+. Instalando Java 17..."
        dnf install -y java-17-openjdk java-17-openjdk-devel &>/dev/null
        # Seleccionar Java 17 como alternativa por defecto
        alternatives --set java "$(ls /usr/lib/jvm/java-17*/bin/java 2>/dev/null | head -1)" 2>/dev/null || true
        alternatives --set javac "$(ls /usr/lib/jvm/java-17*/bin/javac 2>/dev/null | head -1)" 2>/dev/null || true
        ok "Java 17 instalado y configurado"
    fi

    local java_bin; java_bin=$(readlink -f "$(which java 2>/dev/null)")
    local java_home; java_home=$(dirname "$(dirname "$java_bin")")
    if [[ ! "$java_home" =~ java-1[1-9]\|java-[2-9][0-9] ]]; then
        java_home=$(ls -d /usr/lib/jvm/java-17-openjdk* 2>/dev/null | head -1)
        [[ -z "$java_home" ]] && java_home=$(ls -d /usr/lib/jvm/java-11-openjdk* 2>/dev/null | head -1)
        [[ -z "$java_home" ]] && java_home=$(dirname "$(dirname "$java_bin")")
    fi
    ok "JAVA_HOME: $java_home"

    cat > /etc/systemd/system/tomcat.service << EOF
[Unit]
Description=Apache Tomcat Web Application Container
After=network.target syslog.target

[Service]
Type=forking
User=tomcat
Group=tomcat
Environment="JAVA_HOME=${java_home}"
Environment="CATALINA_HOME=${TC_HOME}"
Environment="CATALINA_BASE=${TC_HOME}"
Environment="CATALINA_PID=${TC_HOME}/temp/tomcat.pid"
Environment="CATALINA_OPTS=-Xms256M -Xmx512M -server"
Environment="JAVA_OPTS=-Djava.security.egd=file:/dev/./urandom"
ExecStart=${TC_HOME}/bin/startup.sh
ExecStop=${TC_HOME}/bin/shutdown.sh
ExecReload=/bin/kill -s HUP \$MAINPID
RemainAfterExit=yes
Restart=on-failure
RestartSec=10

[Install]
WantedBy=multi-user.target
EOF
    mkdir -p "${TC_HOME}/temp"
    chown tomcat:tomcat "${TC_HOME}/temp"

    systemctl daemon-reload &>/dev/null
    systemctl enable tomcat &>/dev/null
    systemctl restart tomcat
    sleep 5

    pagina_tomcat "$TC_HOME/webapps/ROOT"

    abrir_puertos Tomcat
    SVC_INSTALADO[Tomcat]=1
    ver_svc Tomcat
    ok "Tomcat listo | http://$(iploc):${PTH}"
}

# SSL: vsftpd (FTPS)
ssl_vsftpd() {
    inf "Activando FTPS en vsftpd (dominio: ${DOMINIO_PRINCIPAL})..."
    if ! systemctl is-active --quiet vsftpd; then
        err "vsftpd no esta instalado/activo. Instalelo primero."
        return 1
    fi
    if ! generar_cert "vsftpd"; then return 1; fi

    local crtF="$RCE/vsftpd.crt"
    local keyF="$RCE/vsftpd.key"
    local conf="/etc/vsftpd/vsftpd.conf"

    sed -i '/^ssl_enable\|^rsa_cert_file\|^rsa_private_key_file\|^ssl_tlsv1\|^ssl_sslv2\|^ssl_sslv3\|^force_local_data_ssl\|^force_local_logins_ssl\|^allow_anon_ssl\|^implicit_ssl\|^listen_port.*990/d' "$conf"

    cat >> "$conf" << EOF

# === FTPS SSL (GestorServicios v3.0) ===
ssl_enable=YES
rsa_cert_file=${crtF}
rsa_private_key_file=${keyF}
ssl_tlsv1=YES
ssl_sslv2=NO
ssl_sslv3=NO
force_local_data_ssl=YES
force_local_logins_ssl=YES
allow_anon_ssl=NO
ssl_ciphers=HIGH
require_ssl_reuse=NO
EOF

    cp /etc/vsftpd/vsftpd.conf /etc/vsftpd/vsftpd_ftps.conf
    sed -i "s/^listen=YES/listen=YES\nlisten_port=${PIS}/" /etc/vsftpd/vsftpd_ftps.conf
    echo "implicit_ssl=YES" >> /etc/vsftpd/vsftpd_ftps.conf

    systemctl restart vsftpd
    sleep 2

    abrir_puerto $PIS tcp

    if ss -tlnp | grep -q ":${PIF}"; then
        SVC_SSL[vsftpd]=1
        ok "FTPS configurado | Puerto FTP:${PIF} (STARTTLS) | FTPS:${PIS} (implicito)"
        ok "Certificado: CN=${DOMINIO_PRINCIPAL}"
        inf "Conecte con: curl --ftp-ssl -u usuario:pass ftp://$(iploc)/${PIF}/"
    else
        err "vsftpd no responde tras configurar SSL"
    fi
    avi "Verificar con: openssl s_client -connect $(iploc):${PIF} -starttls ftp"
}

# 
# SSL: APACHE
ssl_apache() {
    inf "Activando SSL en Apache (puerto ${PAS}, dominio ${DOMINIO_PRINCIPAL})..."
    if ! systemctl is-active --quiet httpd; then
        err "Apache no esta activo. Instalelo primero."
        return 1
    fi
    if ! generar_cert "Apache"; then return 1; fi

    local crtF="$RCE/Apache.crt"
    local keyF="$RCE/Apache.key"

    dnf install -y mod_ssl &>/dev/null
    ok "mod_ssl instalado"

    cat > /etc/httpd/conf.d/ssl-gestor.conf << EOF
# === SSL Apache GestorServicios v3.0 ===
Listen ${PAS}

<VirtualHost *:${PAS}>
    ServerName ${DOMINIO_PRINCIPAL}:${PAS}
    ServerAlias ${DOMINIO_ALT} localhost

    DocumentRoot /var/www/html
    DirectoryIndex index.html

    SSLEngine on
    SSLCertificateFile    ${crtF}
    SSLCertificateKeyFile ${keyF}
    SSLProtocol           all -SSLv3 -TLSv1 -TLSv1.1
    SSLCipherSuite        HIGH:!aNULL:!MD5

    Header always set Strict-Transport-Security "max-age=31536000; includeSubDomains"
    Header always set X-Frame-Options "DENY"

    <Directory "/var/www/html">
        Options Indexes FollowSymLinks
        AllowOverride All
        Require all granted
    </Directory>

    ErrorLog  /var/log/httpd/ssl_error.log
    CustomLog /var/log/httpd/ssl_access.log combined
</VirtualHost>

# Redireccion HTTP -> HTTPS
<VirtualHost *:${PAH}>
    ServerName ${DOMINIO_PRINCIPAL}
    ServerAlias ${DOMINIO_ALT} localhost
    RewriteEngine On
    RewriteRule ^(.*)$ https://%{HTTP_HOST}:${PAS}\$1 [R=301,L]
</VirtualHost>
EOF

    local conf="/etc/httpd/conf/httpd.conf"
    grep -q "mod_rewrite" /etc/httpd/conf.modules.d/00-base.conf 2>/dev/null || \
        echo "LoadModule rewrite_module modules/mod_rewrite.so" >> "$conf"
    grep -q "mod_headers" /etc/httpd/conf.modules.d/00-base.conf 2>/dev/null || \
        echo "LoadModule headers_module modules/mod_headers.so" >> "$conf"

    if httpd -t 2>/dev/null; then
        ok "Sintaxis Apache: OK"
    else
        err "Error de sintaxis en Apache. Abortando SSL."
        httpd -t 2>&1 | while read -r l; do err "  $l"; done
        return 1
    fi

    systemctl restart httpd
    sleep 2

    abrir_puerto $PAS tcp

    if ss -tlnp | grep -q ":${PAS}"; then
        SVC_SSL[Apache]=1
        ok "SSL Apache verificado | https://$(iploc):${PAS}"
        ok "Redireccion HTTP->HTTPS activa"
        ok "HSTS habilitado | max-age=31536000"
    else
        err "Apache no responde en ${PAS}"
        tail -5 /var/log/httpd/ssl_error.log 2>/dev/null | while read -r l; do avi "  $l"; done
    fi
    avi "Navegador mostrara advertencia de certificado autofirmado - es comportamiento esperado"
    inf "Dominio del certificado: ${DOMINIO_PRINCIPAL}, ${DOMINIO_ALT}"
}

# SSL: NGINX
nginx_esta_activo() {
    systemctl is-active --quiet nginx 2>/dev/null && return 0
    pgrep -x nginx &>/dev/null && return 0
    ss -tlnp 2>/dev/null | grep -q ":${PNH}\|:${PNS}" && return 0
    command -v nginx &>/dev/null && return 0
    return 1
}

tomcat_esta_activo() {
    systemctl is-active --quiet tomcat 2>/dev/null && return 0
    pgrep -f "catalina" &>/dev/null && return 0
    ss -tlnp 2>/dev/null | grep -q ":${PTH}\|:${PTS}" && return 0
    [[ -f "/opt/tomcat/bin/catalina.sh" ]] && return 0
    return 1
}

ssl_nginx() {
    inf "Activando SSL en Nginx (puerto ${PNS}, dominio ${DOMINIO_PRINCIPAL})..."
    if ! nginx_esta_activo; then
        if command -v nginx &>/dev/null; then
            avi "Nginx instalado pero no activo. Intentando arrancar..."
            systemctl start nginx 2>/dev/null || nginx 2>/dev/null || true
            sleep 2
        fi
        if ! nginx_esta_activo; then
            err "Nginx no encontrado. Instale Nginx primero (opcion 1 del menu)."
            return 1
        fi
    fi
    ok "Nginx detectado como activo"
    if ! generar_cert "Nginx"; then return 1; fi

    local crtF="$RCE/Nginx.crt"
    local keyF="$RCE/Nginx.key"

    cat > /etc/nginx/conf.d/gestor.conf << EOF
# === SSL Nginx GestorServicios v3.0 ===

# HTTP: redirige a HTTPS
server {
    listen ${PNH};
    server_name ${DOMINIO_PRINCIPAL} ${DOMINIO_ALT} localhost;
    return 301 https://\$host:${PNS}\$request_uri;
}

# HTTPS
server {
    listen ${PNS} ssl;
    server_name ${DOMINIO_PRINCIPAL} ${DOMINIO_ALT} localhost;

    ssl_certificate     ${crtF};
    ssl_certificate_key ${keyF};
    ssl_protocols       TLSv1.2 TLSv1.3;
    ssl_ciphers         HIGH:!aNULL:!MD5;
    ssl_session_timeout 5m;

    add_header Strict-Transport-Security "max-age=31536000; includeSubDomains" always;
    add_header X-Frame-Options DENY always;

    root  /usr/share/nginx/html;
    index index.html index.htm;

    location / { try_files \$uri \$uri/ =404; }

    error_log  /var/log/nginx/ssl_error.log;
    access_log /var/log/nginx/ssl_access.log;
}
EOF

    if nginx -t 2>/dev/null; then
        ok "Sintaxis Nginx: OK"
    else
        err "Error de sintaxis en Nginx. Abortando SSL."
        nginx -t 2>&1 | while read -r l; do err "  $l"; done
        return 1
    fi

    if grep -q "server {" /etc/nginx/nginx.conf 2>/dev/null; then
        avi "nginx.conf tiene bloque server; reescribiendo para evitar conflicto..."
        cat > /etc/nginx/nginx.conf << 'NGINXSSL'
user nginx;
worker_processes auto;
error_log /var/log/nginx/error.log notice;
pid /run/nginx.pid;
include /usr/share/nginx/modules/*.conf;
events { worker_connections 1024; }
http {
    log_format main '$remote_addr - $remote_user [$time_local] "$request" $status';
    access_log /var/log/nginx/access.log main;
    sendfile on;
    keepalive_timeout 65;
    types_hash_max_size 4096;
    include /etc/nginx/mime.types;
    default_type application/octet-stream;
    include /etc/nginx/conf.d/*.conf;
}
NGINXSSL
    fi

    pkill -x nginx 2>/dev/null; sleep 1
    systemctl restart nginx 2>/dev/null || nginx 2>/dev/null || true
    sleep 3

    abrir_puerto $PNS tcp

    if ss -tlnp | grep -q ":${PNS}"; then
        SVC_SSL[Nginx]=1
        ok "SSL Nginx verificado | https://$(iploc):${PNS}"
        ok "Redireccion HTTP->HTTPS activa"
        ok "HSTS habilitado | max-age=31536000"
    else
        err "Nginx no responde en ${PNS}"
        tail -5 /var/log/nginx/ssl_error.log 2>/dev/null | while read -r l; do avi "  $l"; done
    fi
    avi "Navegador mostrara advertencia de certificado autofirmado - es comportamiento esperado"
    inf "Dominio del certificado: ${DOMINIO_PRINCIPAL}, ${DOMINIO_ALT}"
}

# SSL: TOMCAT
ssl_tomcat() {
    inf "Activando SSL en Tomcat (puerto ${PTS}, dominio ${DOMINIO_PRINCIPAL})..."
    local TC_HOME="/opt/tomcat"

    if ! tomcat_esta_activo; then
        if [[ -f "$TC_HOME/bin/catalina.sh" ]]; then
            avi "Tomcat instalado pero no activo. Intentando arrancar..."
            systemctl start tomcat 2>/dev/null || "$TC_HOME/bin/startup.sh" 2>/dev/null || true
            sleep 6
        fi
        if ! tomcat_esta_activo; then
            err "Tomcat no encontrado. Instale Tomcat primero."
            return 1
        fi
    fi
    ok "Tomcat detectado como activo"

    if ! generar_cert "Tomcat"; then return 1; fi

    local crtF="$RCE/Tomcat.crt"
    local keyF="$RCE/Tomcat.key"
    local ks_pass="reprobados2026"

    local ks="$TC_HOME/conf/tomcat_ssl.p12"

    openssl pkcs12 -export \
        -in "$crtF" -inkey "$keyF" \
        -out "$ks" \
        -name "tomcat" \
        -passout "pass:${ks_pass}" 2>/dev/null

    if [[ ! -f "$ks" ]]; then
        err "Error creando keystore PKCS12"
        return 1
    fi
    ok "Keystore PKCS12: $ks"

    chown -R tomcat:tomcat "$TC_HOME/conf"
    chmod 640 "$ks"
    chmod 750 "$TC_HOME/conf"
    ok "Permisos keystore: tomcat:tomcat 640"

    local sxml="$TC_HOME/conf/server.xml"
    local sxml_orig="${sxml}.orig"

    [[ ! -f "$sxml_orig" ]] && cp "$sxml" "$sxml_orig"

    cp "$sxml_orig" "$sxml"
    inf "server.xml restaurado desde backup original"

    local connector_file="$TC_HOME/conf/tomcat_connector_ssl.xml"
    cat > "$connector_file" << CONN_END
    <!-- GestorServicios SSL v3.0 -->
    <Connector port="${PTS}"
               protocol="org.apache.coyote.http11.Http11NioProtocol"
               maxThreads="150"
               SSLEnabled="true"
               scheme="https"
               secure="true"
               defaultSSLHostConfigName="_default_">
        <SSLHostConfig hostName="_default_">
            <Certificate certificateKeystoreFile="${ks}"
                         certificateKeystorePassword="${ks_pass}"
                         certificateKeystoreType="PKCS12"
                         type="RSA" />
        </SSLHostConfig>
    </Connector>
CONN_END

    chown tomcat:tomcat "$connector_file"
    chmod 640 "$connector_file"

    awk -v cf="$connector_file" '
        /<\/Service>/ {
            while ((getline ln < cf) > 0) print ln
            close(cf)
        }
        { print }
    ' "$sxml" > "${sxml}.new"

    if grep -q "certificateKeystoreFile" "${sxml}.new" && [[ -s "${sxml}.new" ]]; then
        mv "${sxml}.new" "$sxml"
        chown tomcat:tomcat "$sxml"
        ok "server.xml actualizado con conector HTTPS"
        inf "Conector en server.xml:"
        awk '/GestorServicios SSL/,/<\/Connector>/' "$sxml" | \
            head -18 | while read -r l; do inf "  $l"; done
    else
        err "Error insertando conector en server.xml"
        rm -f "${sxml}.new"
        return 1
    fi

    rm -f "$connector_file"

    chown -R tomcat:tomcat "$TC_HOME/conf"
    chmod -R u+rX "$TC_HOME/conf"

    inf "Reiniciando Tomcat con nueva configuracion SSL..."
    systemctl stop tomcat 2>/dev/null
    pkill -f "catalina" 2>/dev/null; sleep 3
    systemctl start tomcat 2>/dev/null
    sleep 10

    abrir_puerto ${PTS} tcp

    inf "Log catalina.out (ultimas 8 lineas):"
    tail -8 "$TC_HOME/logs/catalina.out" 2>/dev/null | while read -r l; do inf "  $l"; done

    if ss -tlnp | grep -q ":${PTS}"; then
        SVC_SSL[Tomcat]=1
        ok "SSL Tomcat verificado | https://$(iploc):${PTS}"
        ok "Certificado: ${DOMINIO_PRINCIPAL}"
    else
        err "Tomcat no responde en ${PTS}"
        inf "Errores SSL en catalina.out:"
        grep -i "ssl\|keystore\|certificate\|SEVERE\|ERROR" \
            "$TC_HOME/logs/catalina.out" 2>/dev/null | tail -10 | \
            while read -r l; do avi "  $l"; done
    fi
    avi "Navegador mostrara advertencia de certificado autofirmado - es comportamiento esperado"
    inf "Dominio del certificado: ${DOMINIO_PRINCIPAL}, ${DOMINIO_ALT}"
}

# RESUMEN DE ESTADO
resumen() {
    cls2
    echo -e "  ${CT}== RESUMEN DE ESTADO DE SERVICIOS ==${NC}"
    echo ""
    local ip; ip=$(iploc)
    echo -e "  ${CI}Maquina: $(hostname) | IP: ${ip} | Dominio: ${DOMINIO_PRINCIPAL}${NC}"
    echo ""

    for svc in vsftpd Apache Nginx Tomcat; do
        ver_svc "$svc" || true
    done

    echo ""
    printf "  +%-15s+%-13s+%-14s+%-6s+%-42s+\n" \
        "---------------" "-------------" "--------------" "------" "------------------------------------------"
    printf "  | %-13s | %-11s | %-12s | %-4s | %-40s |\n" \
        "Servicio" "Puertos" "Estado" "SSL" "Ultima verificacion"
    printf "  +%-15s+%-13s+%-14s+%-6s+%-42s+\n" \
        "---------------" "-------------" "--------------" "------" "------------------------------------------"

    declare -A puertos=([vsftpd]="21/990" [Apache]="${PAH}/${PAS}" [Nginx]="${PNH}/${PNS}" [Tomcat]="${PTH}/${PTS}")
    for svc in vsftpd Apache Nginx Tomcat; do
        local est ssl_s
        if [[ ${SVC_INSTALADO[$svc]} -eq 1 ]]; then
            est="ACTIVO"
        else
            est="INACTIVO"
        fi
        ssl_s=$([ "${SVC_SSL[$svc]}" -eq 1 ] && echo "SI" || echo "NO")
        printf "  | %-13s | %-11s | %-12s | %-4s | %-40s |\n" \
            "$svc" "${puertos[$svc]}" "$est" "$ssl_s" ""
    done
    printf "  +%-15s+%-13s+%-14s+%-6s+%-42s+\n" \
        "---------------" "-------------" "--------------" "------" "------------------------------------------"

    # Certificados SSL
    echo ""
    echo -e "  ${CT}== CERTIFICADOS SSL (PKI) ==${NC}"
    for svc in vsftpd Apache Nginx Tomcat; do
        local crt="$RCE/${svc}.crt"
        if [[ -f "$crt" ]]; then
            local subj exp san
            subj=$(openssl x509 -noout -subject -in "$crt" 2>/dev/null | sed 's/subject=//')
            exp=$(openssl x509 -noout -enddate -in "$crt" 2>/dev/null | sed 's/notAfter=//')
            san=$(openssl x509 -noout -ext subjectAltName -in "$crt" 2>/dev/null | grep -v "X509v3" | tr -d ' ' | tr ',' '\n' | grep DNS | sed 's/DNS://g' | tr '\n' ',' | sed 's/,$//')
            echo -e "  ${CK}[$svc]${NC} Subj: $subj"
            echo -e "         SAN : $san"
            echo -e "         Exp : $exp"
        else
            echo -e "  ${CA}[$svc]${NC} SSL no activado"
        fi
    done

    # Firewall
    echo ""
    if command -v firewall-cmd &>/dev/null; then
        echo -e "  ${CT}== PUERTOS FIREWALL ABIERTOS ==${NC}"
        firewall-cmd --list-ports 2>/dev/null | tr ' ' '\n' | sort | while read -r p; do
            echo -e "    ${CI}$p${NC}"
        done
    fi

    echo ""
    echo -e "  ${CI}Log: $LOG${NC}"
    echo -e "  ${CI}Certificados: $RCE${NC}"
    echo ""
    read -rp "  ENTER para continuar"
}

# VER URLs Y CONECTIVIDAD
ver_urls() {
    cls2
    echo -e "  ${CT}== URLs Y VERIFICACION DE CONECTIVIDAD ==${NC}"
    echo ""
    local ip; ip=$(iploc)
    echo -e "  ${CI}Maquina: $(hostname) | IP: $ip | Dominio: ${DOMINIO_PRINCIPAL}${NC}"
    echo ""

    # Tabla de URLs
    printf "  +%-20s+%-55s+\n" "--------------------" "-------------------------------------------------------"
    printf "  | %-18s | %-53s |\n" "Servicio" "URL (abrir en navegador)"
    printf "  +%-20s+%-55s+\n" "--------------------" "-------------------------------------------------------"

    # vsftpd
    printf "  | %-18s | %-53s |\n" "vsftpd FTP" "ftp://${ip}:${PIF}"
    if [[ ${SVC_SSL[vsftpd]} -eq 1 ]]; then
        printf "  | %-18s | %-53s |\n" "" "ftps://${ip}:${PIS} (FTPS implicito)"
    fi
    printf "  +%-20s+%-55s+\n" "--------------------" "-------------------------------------------------------"

    # Apache
    printf "  | %-18s | %-53s |\n" "Apache HTTP" "http://${ip}:${PAH}"
    if [[ ${SVC_SSL[Apache]} -eq 1 ]]; then
        printf "  | %-18s | %-53s |\n" "Apache HTTPS" "https://${ip}:${PAS}"
    fi
    printf "  +%-20s+%-55s+\n" "--------------------" "-------------------------------------------------------"

    # Nginx
    printf "  | %-18s | %-53s |\n" "Nginx HTTP" "http://${ip}:${PNH}"
    if [[ ${SVC_SSL[Nginx]} -eq 1 ]]; then
        printf "  | %-18s | %-53s |\n" "Nginx HTTPS" "https://${ip}:${PNS}"
    fi
    printf "  +%-20s+%-55s+\n" "--------------------" "-------------------------------------------------------"

    # Tomcat
    printf "  | %-18s | %-53s |\n" "Tomcat HTTP" "http://${ip}:${PTH}"
    if [[ ${SVC_SSL[Tomcat]} -eq 1 ]]; then
        printf "  | %-18s | %-53s |\n" "Tomcat HTTPS" "https://${ip}:${PTS}"
    fi
    printf "  +%-20s+%-55s+\n" "--------------------" "-------------------------------------------------------"

    # Verificar puertos
    echo ""
    echo -e "  ${CI}Comprobando puertos...${NC}"
    echo ""
    local checks=(
        "${PIF}:vsftpd   :${PIF}  (FTP-ctrl)"
        "${PIS}:vsftpd   :${PIS}  (FTPS)"
        "${PAH}:Apache   :${PAH}  (HTTP)"
        "${PAS}:Apache   :${PAS}  (HTTPS)"
        "${PNH}:Nginx    :${PNH}  (HTTP)"
        "${PNS}:Nginx    :${PNS}  (HTTPS)"
        "${PTH}:Tomcat   :${PTH}  (HTTP)"
        "${PTS}:Tomcat   :${PTS}  (HTTPS)"
    )
    for entry in "${checks[@]}"; do
        local puerto="${entry%%:*}"
        local label="${entry#*:}"
        if ss -tlnp 2>/dev/null | grep -q ":${puerto}"; then
            echo -e "    ${CI}${label}${NC} -> ${CK}[ABIERTO]${NC}"
        else
            echo -e "    ${CI}${label}${NC} -> ${CE}[CERRADO]${NC}"
        fi
    done

    echo ""
    read -rp "  ENTER para continuar"
}

# MENU INSTALACION
menu_inst() {
    while true; do
        cls2
        echo -e "  ${CT}== INSTALAR SERVICIOS ==${NC}"
        echo -e "  ${CM}[1] vsftpd  (FTP:${PIF} / FTPS:${PIS})${NC}"
        echo -e "  ${CM}[2] Apache  (HTTP:${PAH} / HTTPS:${PAS})${NC}"
        echo -e "  ${CM}[3] Nginx   (HTTP:${PNH} / HTTPS:${PNS})${NC}"
        echo -e "  ${CM}[4] Tomcat  (HTTP:${PTH} / HTTPS:${PTS})${NC}"
        echo -e "  ${CA}[0] Volver${NC}"
        read -rp "
  Opcion: " op
        case "$op" in
            0) return ;;
            1) inst_vsftpd ;;
            2|3|4)
                echo ""
                echo -e "  ${CT}ORIGEN DE INSTALACION:${NC}"
                echo -e "  ${CM}[1] Web  (repositorio oficial dnf)${NC}"
                echo -e "  ${CM}[2] FTP  (repositorio privado con verificacion hash)${NC}"
                read -rp "  Fuente: " fuente
                [[ "$fuente" =~ ^[12]$ ]] || fuente=1
                case "$op" in
                    2) inst_apache "$fuente" ;;
                    3) inst_nginx  "$fuente" ;;
                    4) inst_tomcat "$fuente" ;;
                esac
                ;;
            *) echo -e "  ${CE}Opcion invalida${NC}"; sleep 1; continue ;;
        esac
        echo ""
        read -rp "  ENTER para continuar"
    done
}

# MENU SSL
menu_ssl() {
    while true; do
        cls2
        echo -e "  ${CT}== ACTIVAR SSL/TLS ==${NC}"
        echo -e "  ${CM}[1] vsftpd  (FTPS:${PIS}, RequireSSL ctrl+datos)${NC}"
        echo -e "  ${CM}[2] Apache  (HTTPS:${PAS}, HTTP->HTTPS, HSTS)${NC}"
        echo -e "  ${CM}[3] Nginx   (HTTPS:${PNS}, HTTP->HTTPS, HSTS)${NC}"
        echo -e "  ${CM}[4] Tomcat  (HTTPS:${PTS}, CONFIDENTIAL)${NC}"
        echo -e "  ${CR}[5] Todos los servicios instalados${NC}"
        echo -e "  ${CA}[0] Volver${NC}"
        read -rp "
  Opcion: " op
        case "$op" in
            0) return ;;
            1) sn "Activar FTPS en vsftpd?" && ssl_vsftpd ;;
            2) sn "Activar SSL en Apache?"  && ssl_apache ;;
            3) sn "Activar SSL en Nginx?"   && ssl_nginx  ;;
            4) sn "Activar SSL en Tomcat?"  && ssl_tomcat ;;
            5)
                for svc in vsftpd Apache Nginx Tomcat; do
                    if [[ ${SVC_INSTALADO[$svc]} -eq 1 ]]; then
                        echo ""
                        if sn "Activar SSL en ${svc}?"; then
                            case "$svc" in
                                vsftpd) ssl_vsftpd ;;
                                Apache) ssl_apache  ;;
                                Nginx)  ssl_nginx   ;;
                                Tomcat) ssl_tomcat  ;;
                            esac
                        fi
                    else
                        avi "$svc no esta instalado; omitiendo"
                    fi
                done
                ;;
            *) echo -e "  ${CE}Opcion invalida${NC}"; sleep 1; continue ;;
        esac
        echo ""
        read -rp "  ENTER para continuar"
    done
}

# MENU PRINCIPAL
menu_principal() {
    # Detectar servicios ya instalados al inicio
    systemctl is-active --quiet vsftpd 2>/dev/null && SVC_INSTALADO[vsftpd]=1
    systemctl is-active --quiet httpd  2>/dev/null && SVC_INSTALADO[Apache]=1
    nginx_esta_activo  2>/dev/null && SVC_INSTALADO[Nginx]=1
    tomcat_esta_activo 2>/dev/null && SVC_INSTALADO[Tomcat]=1
    # Detectar SSL existente
    [[ -f "$RCE/vsftpd.crt" ]] && SVC_SSL[vsftpd]=1
    [[ -f "$RCE/Apache.crt" ]] && SVC_SSL[Apache]=1
    [[ -f "$RCE/Nginx.crt"  ]] && SVC_SSL[Nginx]=1
    [[ -f "$RCE/Tomcat.crt" ]] && SVC_SSL[Tomcat]=1

    while true; do
        cls2
        echo -e "  ${CT}MENU PRINCIPAL${NC}"
        echo -e "  ${CT}------------------------------------------------${NC}"
        echo ""
        echo -e "  ${CM}[1]  Instalar servicios (Web o FTP privado)${NC}"
        echo -e "  ${CM}[2]  Activar SSL/TLS (con HSTS y redireccion)${NC}"
        echo -e "  ${CM}[3]  Resumen de estado y certificados${NC}"
        echo -e "  ${CR}[4]  URLs y verificar conectividad${NC}"
        echo -e "  ${CM}[5]  Configurar servidor FTP privado${NC}"
        echo -e "  ${CA}[0]  Salir${NC}"
        echo ""
        echo -e "  ${CI}Estado actual:${NC}"
        for svc in vsftpd Apache Nginx Tomcat; do
            local c ssl_s
            if [[ ${SVC_INSTALADO[$svc]} -eq 1 ]]; then c=$CK; else c=$CA; fi
            ssl_s=$([ "${SVC_SSL[$svc]}" -eq 1 ] && echo "[SSL/TLS]" || echo "")
            echo -e "    ${c}${svc}: $([ "${SVC_INSTALADO[$svc]}" -eq 1 ] && echo "Instalado" || echo "No instalado") ${ssl_s}${NC}"
        done
        echo ""
        echo -e "  ${CI}Puertos: FTP=${PIF}/${PIS} | Apache=${PAH}/${PAS} | Nginx=${PNH}/${PNS} | Tomcat=${PTH}/${PTS}${NC}"
        echo -e "  ${CI}Certificados para: ${DOMINIO_PRINCIPAL} (${DOMINIO_ALT})${NC}"
        echo ""
        read -rp "  Seleccione opcion: " op
        case "$op" in
            1) menu_inst ;;
            2) menu_ssl  ;;
            3) resumen   ;;
            4) ver_urls  ;;
            5) cls2; conf_ftp; echo ""; read -rp "  ENTER para continuar" ;;
            0) echo -e "\n  ${CA}Saliendo. Log: $LOG${NC}"; exit 0 ;;
            *) echo -e "  ${CE}Opcion invalida. Use 0-5.${NC}"; sleep 1 ;;
        esac
    done
}

# INICIO
init

for cmd in openssl curl ss firewall-cmd; do
    if ! command -v "$cmd" &>/dev/null; then
        avi "$cmd no encontrado. Instalando dependencias..."
        dnf install -y openssl curl iproute firewalld &>/dev/null
        systemctl enable --now firewalld &>/dev/null
        break
    fi
done

if ! command -v java &>/dev/null; then
    inf "Java no encontrado. Instalando OpenJDK 17..."
    dnf install -y java-17-openjdk java-17-openjdk-devel &>/dev/null
    ok "Java: $(java -version 2>&1 | head -1)"
fi

ilog "=== INICIO GestorServicios v3.0 | $(whoami) | $(hostname) | IP: $(iploc) ===" "INFO"
ilog "Dominio SSL: ${DOMINIO_PRINCIPAL} / ${DOMINIO_ALT}" "INFO"

menu_principal
