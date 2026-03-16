#!/usr/bin/env bash

SERVICIO=""
VERSION=""
PUERTO=0
DIR_WEB=""
CONF_FILE=""
GESTOR=""
USR_SERVICIO=""
TOMCAT_DIR=""

R='\033[0;31m'
G='\033[0;32m'
Y='\033[1;33m'
C='\033[0;36m'
W='\033[1;37m'
D='\033[2;37m'
N='\033[0m'

ok()    { echo -e "  ${G}[OK]${N}    $1"; }
info()  { echo -e "  ${C}[INFO]${N}  $1"; }
aviso() { echo -e "  ${Y}[AVISO]${N} $1"; }
err()   { echo -e "  ${R}[ERROR]${N} $1"; }

sep() { echo -e "  ${D}$(printf -- '-%.0s' {1..52})${N}"; }

limpiar() {
    clear; echo ""; sep
    echo -e "  ${C}SISTEMA DE APROVISIONAMIENTO WEB - LINUX${N}"
    sep; echo ""
}

pausar() {
    echo ""
    read -rp "  Presione ENTER para continuar..." _
}

verificar_root() {
    if [[ $EUID -ne 0 ]]; then
        err "Ejecute como root:  sudo su -"
        exit 1
    fi
    ok "Ejecutando como root."
}

detectar_gestor() {
    if   command -v dnf     &>/dev/null; then GESTOR="dnf"
    elif command -v yum     &>/dev/null; then GESTOR="yum"
    elif command -v apt-get &>/dev/null; then GESTOR="apt"
    else err "Gestor de paquetes no compatible."; exit 1
    fi
    ok "Gestor: ${GESTOR}"
}

validar_puerto() {
    local p="$1"
    local reservados=(21 22 23 25 53 110 143 443 465 587 993 995 1433 3306 3389 5432)
    if ! [[ "$p" =~ ^[0-9]+$ ]] || (( p < 1 || p > 65535 )); then
        err "Puerto invalido (1-65535)."; return 1
    fi
    for r in "${reservados[@]}"; do
        (( p == r )) && { err "Puerto $p reservado para otro servicio."; return 1; }
    done
    # Aviso informativo para puertos privilegiados (no bloquea)
    if (( p < 1024 )) && [[ "$SERVICIO" == "tomcat" ]]; then
        aviso "Puerto ${p} < 1024: se aplicara CAP_NET_BIND_SERVICE automaticamente."
    fi
    return 0
}

puerto_en_uso() {
    ss -tlnp 2>/dev/null | grep -q ":${1}[ \t]" || \
    netstat -tlnp 2>/dev/null | grep -q ":${1}[ \t]"
}

esperar_puerto() {
    # Espera hasta 20 s a que el servicio arranque en el puerto
    local p="$1" i=0
    info "Esperando que el servicio escuche en el puerto ${p}..."
    while (( i < 20 )); do
        ss -tlnp 2>/dev/null | grep -q ":${p}" && { ok "Servicio escuchando en puerto ${p}."; return 0; }
        sleep 1; (( i++ ))
    done
    aviso "Servicio aun no responde en el puerto ${p}."
    return 1
}

esperar_puerto_tomcat() {
    # Espera hasta 90 s especificamente para Tomcat (JVM lenta al iniciar)
    local p="$1" i=0 max="${2:-90}"
    info "Esperando Tomcat en puerto ${p} (hasta ${max} s)..."
    while (( i < max )); do
        if ss -tlnp 2>/dev/null | grep -q ":${p}"; then
            ok "Tomcat escuchando en puerto ${p}."; return 0
        fi
        sleep 3; (( i += 3 ))
        (( i % 15 == 0 )) && info "  ... ${i}s / ${max}s"
    done
    aviso "Tomcat aun no responde en el puerto ${p} tras ${max}s."
    return 1
}

# SELINUX
configurar_selinux() {
    local p="$1"

    command -v getenforce &>/dev/null || return 0
    local estado
    estado=$(getenforce 2>/dev/null)
    [[ "$estado" == "Disabled" ]] && { ok "SELinux desactivado."; return 0; }

    info "SELinux ${estado}. Habilitando puerto ${p} para HTTP..."

    # Instalar semanage si no existe
    if ! command -v semanage &>/dev/null; then
        info "Instalando policycoreutils-python-utils..."
        $GESTOR install -y policycoreutils-python-utils 2>/dev/null | tail -2
    fi

    if command -v semanage &>/dev/null; then
        # Verificar si ya esta registrado
        if semanage port -l 2>/dev/null | awk '{print $3}' | tr ',' '\n' | grep -qx "$p"; then
            ok "Puerto ${p} ya permitido en SELinux."
        else
            semanage port -a -t http_port_t -p tcp "$p" 2>/dev/null \
            || semanage port -m -t http_port_t -p tcp "$p" 2>/dev/null
            ok "Puerto ${p} registrado en SELinux (http_port_t)."
        fi
    else
        aviso "semanage no disponible. Activando httpd_can_network_connect..."
        setsebool -P httpd_can_network_connect 1 2>/dev/null || true
    fi

    # Restaurar contexto del directorio web
    [[ -d /var/www/html ]]  && restorecon -rv /var/www/html  2>/dev/null || true
    [[ -d /opt/tomcat ]]    && restorecon -rv /opt/tomcat  2>/dev/null || true
    [[ -n "$TOMCAT_DIR" && -d "$TOMCAT_DIR" ]] && restorecon -rv "$TOMCAT_DIR" 2>/dev/null || true
    ok "SELinux configurado."
}

# MENU
mostrar_menu() {
    limpiar
    echo -e "  ${W}MENU PRINCIPAL${N}"; echo ""
    echo -e "  ${G}[1]${N} Instalar y configurar servidor HTTP"
    echo -e "  ${G}[2]${N} Consultar versiones disponibles"
    echo -e "  ${G}[3]${N} Gestionar firewall"
    echo -e "  ${G}[4]${N} Aplicar seguridad"
    echo -e "  ${G}[5]${N} Crear pagina de inicio"
    echo -e "  ${R}[0]${N} Salir"
    echo ""; sep
}

seleccionar_servidor() {
    limpiar
    echo -e "  ${W}SELECCION DE SERVIDOR${N}"; echo ""
    echo -e "  ${G}[1]${N} Apache2  - Servidor HTTP clasico"
    echo -e "  ${G}[2]${N} Nginx    - Servidor de alto rendimiento"
    echo -e "  ${G}[3]${N} Tomcat   - Contenedor Java"
    echo -e "  ${R}[0]${N} Volver"
    echo ""; sep
    while true; do
        read -rp "  Seleccione [0-3]: " op
        case "$op" in
            1) SERVICIO="apache2"; return 0 ;;
            2) SERVICIO="nginx";   return 0 ;;
            3) SERVICIO="tomcat";  return 0 ;;
            0) SERVICIO="";        return 1 ;;
            *) err "Opcion invalida." ;;
        esac
    done
}

solicitar_puerto() {
    local default="${1:-80}"
    echo ""; echo -e "  ${W}CONFIGURACION DE PUERTO${N}"
    echo -e "  Puerto sugerido: ${G}${default}${N}"; echo ""
    while true; do
        read -rp "  Puerto de escucha [${default}]: " entrada
        [[ -z "$entrada" ]] && entrada="$default"
        validar_puerto "$entrada" || continue
        if puerto_en_uso "$entrada"; then
            aviso "El puerto $entrada ya esta en uso."
            read -rp "  Usar de todas formas? [s/N]: " conf
            [[ "${conf,,}" != "s" ]] && continue
        fi
        PUERTO="$entrada"
        ok "Puerto seleccionado: $PUERTO"
        break
    done
}

# MODULO 1
_vers_apt() { apt-cache madison "$1" 2>/dev/null | awk '{print $3}' | sort -uV; }
_vers_dnf() { $GESTOR list --available "$1" 2>/dev/null \
              | grep -v "^Available\|^Last\|^Loaded" | awk '{print $2}' | sort -uV; }

tres_versiones() {
    local paq_apt="$1" paq_dnf="$2" vmin="$3" vlts="$4" vlat="$5"
    local todas=()
    if [[ "$GESTOR" == "apt" ]]; then mapfile -t todas < <(_vers_apt "$paq_apt")
    else                              mapfile -t todas < <(_vers_dnf "$paq_dnf")
    fi
    local n=${#todas[@]}
    if   (( n == 0 )); then VERS=("$vmin" "$vlts" "$vlat")
    elif (( n == 1 )); then VERS=("${todas[0]}" "${todas[0]}" "${todas[0]}")
    elif (( n == 2 )); then VERS=("${todas[0]}" "${todas[0]}" "${todas[1]}")
    else
        local mid=$(( n/2 ))
        VERS=("${todas[0]}" "${todas[$mid]}" "${todas[$((n-1))]}")
    fi
}

mostrar_vers() {
    local nombre="$1"
    echo -e "  ${W}Versiones disponibles de ${nombre}:${N}"; echo ""
    echo -e "  ${G}[1]${N} ${VERS[0]}  ${D}(Minima - mas probada)${N}"
    echo -e "  ${Y}[2]${N} ${VERS[1]}  ${D}(Estable - LTS recomendada)${N}"
    echo -e "  ${C}[3]${N} ${VERS[2]}  ${D}(Ultima - Latest)${N}"
    echo ""; sep
    while true; do
        read -rp "  Seleccione version [1-3]: " op
        case "$op" in
            1) VERSION="${VERS[0]}"; ok "Version: $VERSION"; break ;;
            2) VERSION="${VERS[1]}"; ok "Version: $VERSION"; break ;;
            3) VERSION="${VERS[2]}"; ok "Version: $VERSION"; break ;;
            *) err "Ingrese 1, 2 o 3." ;;
        esac
    done
}

consultar_versiones_apache() {
    info "Consultando versiones de Apache..."; echo ""
    if [[ "$GESTOR" == "apt" ]]; then tres_versiones "apache2" "httpd" "2.4.52" "2.4.57" "2.4.62"
    else                              tres_versiones "httpd"   "httpd" "2.4.53" "2.4.57" "2.4.62"
    fi
    mostrar_vers "Apache"
}

consultar_versiones_nginx() {
    info "Consultando versiones de Nginx..."; echo ""
    tres_versiones "nginx" "nginx" "1.22.0" "1.24.0" "1.26.2"
    mostrar_vers "Nginx"
}

consultar_versiones_tomcat() {
    info "Versiones de Tomcat disponibles para descarga:"; echo ""
    VERS=("9.0.89" "10.1.24" "11.0.2")
    mostrar_vers "Tomcat"
}

# =============================================================================
# MODULO 2 - INSTALACION
# =============================================================================
instalar_servidor() {
    info "Instalando ${SERVICIO}..."; echo ""
    case "$SERVICIO" in
        apache2) _instalar_apache ;;
        nginx)   _instalar_nginx  ;;
        tomcat)  _instalar_tomcat ;;
    esac
}

# --- APACHE ------------------------------------------------------------------
_instalar_apache() {
    if [[ "$GESTOR" == "apt" ]]; then
        DEBIAN_FRONTEND=noninteractive apt-get install -y apache2 2>&1 | \
            grep -E "^(Get|Setting|Unpacking|Selecting)" || true
        USR_SERVICIO="www-data"
        # Detener apache antes de cambiar el puerto
        systemctl stop apache2 2>/dev/null || true
    else
        $GESTOR install -y httpd 2>&1 | grep -E "^(Installing|Installed)" || true
        USR_SERVICIO="apache"
        systemctl stop httpd 2>/dev/null || true
    fi
    DIR_WEB="/var/www/html"
    mkdir -p "$DIR_WEB"
    command -v a2enmod &>/dev/null && a2enmod headers 2>/dev/null || true
    ok "Apache instalado."

    # Configurar puerto -> SELinux -> Iniciar
    _conf_puerto_apache
    configurar_selinux "$PUERTO"
    _iniciar_apache
}

_conf_puerto_apache() {
    info "Configurando puerto ${PUERTO} en Apache..."

    if [[ "$GESTOR" == "apt" ]]; then
        if [[ -f /etc/apache2/ports.conf ]]; then
            cp /etc/apache2/ports.conf /etc/apache2/ports.conf.bak
            grep -v "^Listen" /etc/apache2/ports.conf.bak > /etc/apache2/ports.conf
            echo "Listen ${PUERTO}" >> /etc/apache2/ports.conf
            ok "ports.conf: Listen ${PUERTO}"
        fi
        local vhost="/etc/apache2/sites-enabled/000-default.conf"
        [[ -f "$vhost" ]] && sed -i \
            "s|<VirtualHost \*:[0-9]*>|<VirtualHost *:${PUERTO}>|" "$vhost" \
            && ok "VirtualHost actualizado."

    else
        local conf="/etc/httpd/conf/httpd.conf"
        if [[ -f "$conf" ]]; then
            cp "$conf" "${conf}.bak"
            grep -v "^Listen" "${conf}.bak" > "$conf"
            echo "Listen ${PUERTO}" >> "$conf"
            ok "httpd.conf: Listen ${PUERTO}"
        fi
        for f in /etc/httpd/conf.d/welcome.conf \
                 /etc/httpd/conf.d/ssl.conf \
                 /etc/httpd/conf.modules.d/*.conf; do
            [[ -f "$f" ]] && sed -i "s/^Listen/#Listen/" "$f" 2>/dev/null || true
        done
    fi
    ok "Puerto Apache configurado a ${PUERTO}."
}

_iniciar_apache() {
    if [[ "$GESTOR" == "apt" ]]; then
        systemctl enable apache2 2>/dev/null
        systemctl restart apache2 2>/dev/null
        esperar_puerto "$PUERTO" || \
            { err "Apache no arranco. Logs:"; journalctl -u apache2 --no-pager -n 15; }
    else
        systemctl enable httpd 2>/dev/null
        systemctl restart httpd 2>/dev/null
        esperar_puerto "$PUERTO" || \
            { err "Apache no arranco. Logs:"; journalctl -u httpd --no-pager -n 15; }
    fi
}

_instalar_nginx() {
    if [[ "$GESTOR" == "apt" ]]; then
        DEBIAN_FRONTEND=noninteractive apt-get install -y nginx 2>&1 | \
            grep -E "^(Get|Setting|Unpacking)" || true
        USR_SERVICIO="www-data"
        systemctl stop nginx 2>/dev/null || true
    else
        $GESTOR install -y nginx 2>&1 | grep -E "^(Installing|Installed)" || true
        USR_SERVICIO="nginx"
        systemctl stop nginx 2>/dev/null || true
    fi
    DIR_WEB="/var/www/html"
    mkdir -p "$DIR_WEB"
    ok "Nginx instalado."

    _conf_puerto_nginx
    configurar_selinux "$PUERTO"

    systemctl enable nginx 2>/dev/null
    systemctl restart nginx 2>/dev/null
    esperar_puerto "$PUERTO" || \
        { err "Nginx no arranco. Logs:"; journalctl -u nginx --no-pager -n 15; }
}

_conf_puerto_nginx() {
    info "Configurando puerto ${PUERTO} en Nginx..."

    local candidatos=(
        /etc/nginx/sites-enabled/default
        /etc/nginx/conf.d/default.conf
        /etc/nginx/nginx.conf
    )
    CONF_FILE=""
    for c in "${candidatos[@]}"; do
        [[ -f "$c" ]] && { CONF_FILE="$c"; break; }
    done
    [[ -z "$CONF_FILE" ]] && { err "No se encontro config de Nginx."; return; }

    cp "$CONF_FILE" "${CONF_FILE}.bak"

    sed -i -E \
        "s/listen[[:space:]]+[0-9]+(.[[:space:]]|;)/listen ${PUERTO}\1/g" \
        "$CONF_FILE"
    sed -i -E \
        "s/listen[[:space:]]+\[::\]:[0-9]+/listen [::]:${PUERTO}/g" \
        "$CONF_FILE"

    ok "Nginx: ${CONF_FILE} -> listen ${PUERTO}"

    # Validar sintaxis
    nginx -t 2>/dev/null && ok "Config Nginx valida." || \
        aviso "Error de sintaxis en Nginx, revise ${CONF_FILE}."
}

_java_home() {
    local jbin jdir
    jbin=$(readlink -f "$(command -v java)" 2>/dev/null) || return 1
    jdir="$jbin"
    while [[ "$jdir" != "/" ]]; do
        jdir=$(dirname "$jdir")
        [[ -f "${jdir}/bin/java" ]] && { echo "$jdir"; return 0; }
    done
    for d in /usr/lib/jvm/java-{17,11,8,1.8.0}-openjdk* \
              /usr/lib/jvm/java-{17,11,8}-openjdk \
              /usr/lib/jvm/default-java /usr/lib/jvm/jre /usr; do
        [[ -f "${d}/bin/java" ]] && { echo "$d"; return 0; }
    done
    echo "/usr"
}

_instalar_tomcat() {
    info "Instalando Tomcat ${VERSION}..."

    if ! command -v java &>/dev/null; then
        info "Instalando Java..."
        if [[ "$GESTOR" == "apt" ]]; then
            DEBIAN_FRONTEND=noninteractive apt-get install -y default-jre-headless 2>&1 | tail -3
        else
            $GESTOR install -y java-17-openjdk-headless 2>&1 | tail -3
        fi
    fi
    command -v java &>/dev/null || { err "Java no disponible."; return 1; }
    ok "Java: $(java -version 2>&1 | head -1)"

    local JH; JH=$(_java_home)
    ok "JAVA_HOME: ${JH}"

    local RAMA; RAMA=$(echo "$VERSION" | grep -oP '^\d+'); [[ -z "$RAMA" ]] && RAMA="10"
    local REAL_DIR="/opt/apache-tomcat-${VERSION}"
    local TMP="/tmp/tomcat-${VERSION}.tar.gz"
    TOMCAT_DIR="$REAL_DIR"

    systemctl stop    tomcat 2>/dev/null || true
    systemctl disable tomcat 2>/dev/null || true
    rm -f /etc/systemd/system/tomcat.service
    systemctl daemon-reload 2>/dev/null || true
    rm -rf "$REAL_DIR" 2>/dev/null || true
    rm -rf /opt/tomcat 2>/dev/null || true

    id tomcat &>/dev/null || useradd -r -s /bin/false -d "$REAL_DIR" tomcat
    ok "Usuario 'tomcat' listo."

    info "Descargando Tomcat ${VERSION}..."
    local urls=(
        "https://dlcdn.apache.org/tomcat/tomcat-${RAMA}/v${VERSION}/bin/apache-tomcat-${VERSION}.tar.gz"
        "https://archive.apache.org/dist/tomcat/tomcat-${RAMA}/v${VERSION}/bin/apache-tomcat-${VERSION}.tar.gz"
    )
    local ok_dl=0
    for url in "${urls[@]}"; do
        info "Probando: ${url}"
        if command -v wget &>/dev/null; then
            wget -q --show-progress --tries=3 --timeout=90 "$url" -O "$TMP" 2>&1 \
                && [[ -s "$TMP" ]] && { ok_dl=1; break; }
        else
            curl -fL --progress-bar --retry 3 --connect-timeout 90 "$url" -o "$TMP" \
                && [[ -s "$TMP" ]] && { ok_dl=1; break; }
        fi
        rm -f "$TMP"
    done
    (( ok_dl )) || { err "No se pudo descargar Tomcat ${VERSION}."; return 1; }

    info "Extrayendo..."
    tar -xzf "$TMP" -C /opt/ || { err "Error al extraer."; return 1; }
    rm -f "$TMP"
    [[ -d "$REAL_DIR" ]] || { err "No se encontro: $REAL_DIR"; return 1; }
    ok "Extraido en: ${REAL_DIR}"

    chown -R tomcat:tomcat "$REAL_DIR"
    find "$REAL_DIR" -type d -exec chmod 755 {} \;
    find "$REAL_DIR" -type f -exec chmod 644 {} \;
    chmod 755 "$REAL_DIR"/bin/*.sh
    ok "Permisos establecidos."

    local xml="${REAL_DIR}/conf/server.xml"
    cp "$xml" "${xml}.bak"
    sed -i "s/port=\"8080\"/port=\"${PUERTO}\"/g" "$xml"
    CONF_FILE="$xml"
    ok "server.xml: puerto ${PUERTO}"

    DIR_WEB="${REAL_DIR}/webapps/ROOT"
    mkdir -p "$DIR_WEB"
    chown tomcat:tomcat "$DIR_WEB"

    configurar_selinux "$PUERTO"

    local cap_lineas=""
    if (( PUERTO < 1024 )); then
        info "Puerto ${PUERTO} < 1024: agregando CAP_NET_BIND_SERVICE al servicio..."
        cap_lineas="AmbientCapabilities=CAP_NET_BIND_SERVICE
CapabilityBoundingSet=CAP_NET_BIND_SERVICE"
    fi

    cat > /etc/systemd/system/tomcat.service << SYSD
[Unit]
Description=Apache Tomcat ${VERSION}
After=network.target

[Service]
Type=forking
User=tomcat
Group=tomcat
Environment="JAVA_HOME=${JH}"
Environment="CATALINA_HOME=${REAL_DIR}"
Environment="CATALINA_BASE=${REAL_DIR}"
Environment="CATALINA_PID=${REAL_DIR}/tomcat.pid"
${cap_lineas}
ExecStart=${REAL_DIR}/bin/startup.sh
ExecStop=${REAL_DIR}/bin/shutdown.sh
SuccessExitStatus=143
TimeoutStartSec=180
TimeoutStopSec=60
Restart=on-failure
RestartSec=10

[Install]
WantedBy=multi-user.target
SYSD

    systemctl daemon-reload
    systemctl enable tomcat 2>/dev/null
    systemctl start tomcat

    info "Esperando que Tomcat abra el puerto ${PUERTO} (hasta 120 s)..."
    local i=0
    while (( i < 120 )); do
        ss -tlnp 2>/dev/null | grep -q ":${PUERTO}" && break
        sleep 3; (( i += 3 ))
        (( i % 18 == 0 )) && info "  ... ${i}s / 120s"
    done

    if ss -tlnp 2>/dev/null | grep -q ":${PUERTO}"; then
        ok "Tomcat escuchando en puerto ${PUERTO}."
    else
        err "Tomcat no abrio el puerto ${PUERTO}. Diagnostico:"
        systemctl status tomcat --no-pager -l | head -25
        journalctl -u tomcat --no-pager -n 25
        return 1
    fi

    sleep 1
    rm -f "${REAL_DIR}/webapps/ROOT/index.jsp"  2>/dev/null || true
    rm -f "${REAL_DIR}/webapps/ROOT/index.html" 2>/dev/null || true
    chown -R tomcat:tomcat "${REAL_DIR}/webapps/ROOT"
    ok "Tomcat instalado y funcionando correctamente."
}

_conf_puerto_tomcat_real() { :; }
_conf_puerto_tomcat()      { :; }

# MODULO 3 - FIREWALL
configurar_firewall() {
    info "Configurando firewall para puerto ${PUERTO}..."; echo ""

    if [[ "$GESTOR" != "apt" ]] && command -v firewall-cmd &>/dev/null; then
        if ! systemctl is-active firewalld &>/dev/null; then
            info "Arrancando firewalld..."
            systemctl enable firewalld 2>/dev/null
            systemctl start  firewalld 2>/dev/null
            sleep 2
        fi
        if systemctl is-active firewalld &>/dev/null; then
            firewall-cmd --permanent --add-port="${PUERTO}/tcp" 2>/dev/null
            firewall-cmd --reload 2>/dev/null
            ok "Puerto ${PUERTO}/tcp abierto en firewalld."
            for p in 80 8080 8009; do
                [[ "$p" != "$PUERTO" ]] && ! puerto_en_uso "$p" && \
                    firewall-cmd --permanent --remove-port="${p}/tcp" &>/dev/null || true
            done
            firewall-cmd --reload 2>/dev/null
        else
            aviso "firewalld no disponible. Usando nftables directamente..."
            if command -v nft &>/dev/null; then
                nft add rule inet filter input tcp dport "$PUERTO" accept 2>/dev/null \
                    && ok "Puerto ${PUERTO}/tcp abierto en nftables." \
                    || aviso "nft: no se pudo abrir el puerto. Verifique manualmente."
            else
                aviso "Ni firewalld ni nft disponibles. Abra el puerto manualmente."
            fi
        fi

    elif command -v ufw &>/dev/null && \
         ufw status 2>/dev/null | grep -q "active"; then

        ufw allow "${PUERTO}/tcp" comment "HTTP-${SERVICIO}" 2>/dev/null
        ok "Puerto ${PUERTO}/tcp abierto en UFW."
        for p in 80 8080; do
            [[ "$p" != "$PUERTO" ]] && ! puerto_en_uso "$p" && \
                ufw deny "${p}/tcp" &>/dev/null && info "Puerto $p bloqueado." || true
        done

    elif command -v iptables &>/dev/null; then
        iptables -C INPUT -p tcp --dport "$PUERTO" -j ACCEPT 2>/dev/null \
        || iptables -A INPUT -p tcp --dport "$PUERTO" -j ACCEPT
        ok "Puerto ${PUERTO}/tcp abierto en iptables."

    else
        aviso "No se detecto firewall activo. Verifique manualmente."
    fi

    ok "Firewall configurado."
}

# MODULO 4 - SEGURIDAD
aplicar_seguridad() {
    info "Aplicando seguridad..."; echo ""
    case "$SERVICIO" in
        apache2) _seg_apache ;;
        nginx)   _seg_nginx  ;;
        tomcat)  _seg_tomcat ;;
    esac
}

_seg_apache() {
    local sec
    if [[ "$GESTOR" == "apt" ]]; then sec="/etc/apache2/conf-available/seguridad.conf"
    else                              sec="/etc/httpd/conf.d/seguridad.conf"
    fi

    cat > "$sec" << 'CONF'
ServerTokens Prod
ServerSignature Off
TraceEnable Off
<IfModule mod_headers.c>
    Header always set X-Frame-Options "SAMEORIGIN"
    Header always set X-Content-Type-Options "nosniff"
    Header always unset X-Powered-By
</IfModule>
<Location />
    <LimitExcept GET POST HEAD OPTIONS>
        Require all denied
    </LimitExcept>
</Location>
CONF

    if [[ "$GESTOR" == "apt" ]]; then
        a2enmod headers 2>/dev/null || true
        a2enconf seguridad 2>/dev/null || true
        systemctl restart apache2 2>/dev/null
    else
        systemctl restart httpd 2>/dev/null
    fi

    chown -R "${USR_SERVICIO}:${USR_SERVICIO}" /var/www/html 2>/dev/null
    find /var/www/html -type d -exec chmod 755 {} \;
    find /var/www/html -type f -exec chmod 644 {} \;
    ok "Seguridad Apache aplicada."
}

_seg_nginx() {
    mkdir -p /etc/nginx/conf.d
    cat > /etc/nginx/conf.d/seguridad.conf << 'CONF'
server_tokens off;
add_header X-Frame-Options "SAMEORIGIN" always;
add_header X-Content-Type-Options "nosniff" always;
CONF
    chown -R "${USR_SERVICIO}:${USR_SERVICIO}" /var/www/html 2>/dev/null
    find /var/www/html -type d -exec chmod 755 {} \;
    find /var/www/html -type f -exec chmod 644 {} \;
    nginx -t 2>/dev/null && systemctl restart nginx 2>/dev/null
    ok "Seguridad Nginx aplicada."
}

_seg_tomcat() {
    local td="${TOMCAT_DIR:-/opt/apache-tomcat-${VERSION}}"
    local wx="${td}/conf/web.xml"
    [[ ! -f "$wx" ]] && { aviso "No se encontro web.xml en ${td}"; return; }
    cp "$wx" "${wx}.bak"
    sed -i 's|</web-app>||' "$wx"
    cat >> "$wx" << 'CONF'
  <filter>
    <filter-name>httpHeaderSecurity</filter-name>
    <filter-class>org.apache.catalina.filters.HttpHeaderSecurityFilter</filter-class>
    <init-param>
      <param-name>antiClickJackingOption</param-name>
      <param-value>SAMEORIGIN</param-value>
    </init-param>
  </filter>
  <filter-mapping>
    <filter-name>httpHeaderSecurity</filter-name>
    <url-pattern>/*</url-pattern>
  </filter-mapping>
</web-app>
CONF
    chown tomcat:tomcat "$wx"; chmod 640 "$wx"
    systemctl restart tomcat 2>/dev/null || true
    esperar_puerto_tomcat "$PUERTO" 90 || aviso "Tomcat tardando en reiniciar tras aplicar seguridad."
    ok "Seguridad Tomcat aplicada."
}

# MODULO 5 - PAGINA INDEX
crear_pagina_index() {
    info "Creando pagina de inicio..."; echo ""

    case "$SERVICIO" in
        apache2) DIR_WEB="/var/www/html" ;;

        nginx)
            local nginx_root=""
            for cfg in /etc/nginx/sites-enabled/default \
                       /etc/nginx/conf.d/default.conf \
                       /etc/nginx/nginx.conf; do
                [[ -f "$cfg" ]] || continue
                nginx_root=$(grep -m1 '^\s*root\s' "$cfg" \
                             | awk '{print $2}' | tr -d ';' | xargs)
                [[ -n "$nginx_root" ]] && break
            done
            if [[ -z "$nginx_root" ]]; then
                [[ -d /usr/share/nginx/html ]] \
                    && nginx_root="/usr/share/nginx/html" \
                    || nginx_root="/var/www/html"
            fi
            DIR_WEB="$nginx_root"
            ;;

        tomcat)
            local td="${TOMCAT_DIR:-/opt/apache-tomcat-${VERSION}}"
            DIR_WEB="${td}/webapps/ROOT"

            local wx="${td}/conf/web.xml"
            if [[ -f "$wx" ]]; then
                python3 - "$wx" << 'PYEOF'
import re, sys
path = sys.argv[1]
with open(path) as f: c = f.read()
nuevo = """<welcome-file-list>
    <welcome-file>index.html</welcome-file>
    <welcome-file>index.htm</welcome-file>
    <welcome-file>index.jsp</welcome-file>
</welcome-file-list>"""
c = re.sub(r'<welcome-file-list>.*?</welcome-file-list>', nuevo, c, flags=re.S)
with open(path, 'w') as f: f.write(c)
print("web.xml welcome-files actualizado.")
PYEOF
            fi

            rm -f "${td}/webapps/ROOT/index.jsp"  2>/dev/null || true
            rm -f "${td}/webapps/ROOT/index.html" 2>/dev/null || true
            ;;
    esac
    mkdir -p "$DIR_WEB"

    local nombre
    case "$SERVICIO" in
        apache2) nombre="Apache HTTP Server" ;;
        nginx)   nombre="Nginx"              ;;
        tomcat)  nombre="Apache Tomcat"      ;;
    esac

    local fecha ip so
    fecha=$(date "+%d/%m/%Y %H:%M:%S")
    ip=$(hostname -I 2>/dev/null | awk '{print $1}')
    [[ -z "$ip" ]] && ip="127.0.0.1"
    so=$(grep -oP '(?<=^PRETTY_NAME=").*(?=")' /etc/os-release 2>/dev/null || echo "Linux")

    cat > "${DIR_WEB}/index.html" << HTML
<!DOCTYPE html>
<html lang="es">
<head>
  <meta charset="UTF-8">
  <meta name="viewport" content="width=device-width, initial-scale=1.0">
  <title>${nombre}</title>
  <style>
    *{box-sizing:border-box;margin:0;padding:0}
    body{font-family:Arial,sans-serif;background:#f5f5f5;display:flex;
         align-items:center;justify-content:center;min-height:100vh}
    .card{background:#fff;border:1px solid #e0e0e0;border-radius:6px;
          padding:32px 36px;max-width:460px;width:90%}
    h1{font-size:1.3rem;color:#222;margin-bottom:6px}
    .badge{display:inline-block;background:#e6f4ea;color:#2e7d32;
           border:1px solid #c8e6c9;padding:2px 12px;border-radius:20px;
           font-size:.8rem;margin-bottom:22px}
    table{width:100%;border-collapse:collapse;font-size:.88rem}
    tr{border-bottom:1px solid #f0f0f0}
    tr:last-child{border-bottom:none}
    td{padding:8px 4px;color:#333}
    td:first-child{color:#666;font-weight:bold;width:36%}
    .pie{margin-top:20px;font-size:.75rem;color:#bbb;text-align:center}
  </style>
</head>
<body>
  <div class="card">
    <h1>${nombre}</h1>
    <span class="badge">Servidor activo</span>
    <table>
      <tr><td>Servidor</td><td>${nombre}</td></tr>
      <tr><td>Version</td><td>${VERSION}</td></tr>
      <tr><td>Puerto</td><td>${PUERTO}</td></tr>
      <tr><td>Sistema</td><td>${so}</td></tr>
      <tr><td>IP</td><td>${ip}</td></tr>
    </table>
    <p class="pie">Instalado el ${fecha}</p>
  </div>
</body>
</html>
HTML

    if [[ "$SERVICIO" == "tomcat" ]]; then
        chown tomcat:tomcat "${DIR_WEB}/index.html"
        chmod 644 "${DIR_WEB}/index.html"
        restorecon -v "${DIR_WEB}/index.html" 2>/dev/null || true
        # Reiniciar Tomcat para que recargue la config de welcome-files
        info "Reiniciando Tomcat para aplicar cambios..."
        systemctl restart tomcat 2>/dev/null
        esperar_puerto_tomcat "$PUERTO" 90 || aviso "Tomcat tardando en reiniciar."
    elif [[ -n "$USR_SERVICIO" ]]; then
        chown "${USR_SERVICIO}:${USR_SERVICIO}" "${DIR_WEB}/index.html"
        chmod 644 "${DIR_WEB}/index.html"
        restorecon -v "${DIR_WEB}/index.html" 2>/dev/null || true
    fi

    ok "Pagina creada: ${DIR_WEB}/index.html"
    ok "URL: http://${ip}:${PUERTO}/"
}

# FLUJO COMPLETO
flujo_instalacion_completo() {
    seleccionar_servidor || return 0

    limpiar; echo -e "  ${W}VERSIONES DISPONIBLES${N}"; echo ""
    case "$SERVICIO" in
        apache2) consultar_versiones_apache ;;
        nginx)   consultar_versiones_nginx  ;;
        tomcat)  consultar_versiones_tomcat ;;
    esac

    local default=80
    [[ "$SERVICIO" == "tomcat" ]] && default=8080
    solicitar_puerto "$default"

    echo ""; sep
    echo -e "  ${W}Resumen:${N}"
    echo -e "  Servidor : ${G}${SERVICIO}${N}"
    echo -e "  Version  : ${G}${VERSION}${N}"
    echo -e "  Puerto   : ${G}${PUERTO}${N}"
    sep
    read -rp "  Confirmar instalacion [S/n]: " conf
    [[ "${conf,,}" == "n" ]] && return 0

    echo ""; sep; echo -e "  ${W}[1/4] INSTALACION${N}"; sep
    instalar_servidor

    echo ""; sep; echo -e "  ${W}[2/4] FIREWALL${N}"; sep
    configurar_firewall

    echo ""; sep; echo -e "  ${W}[3/4] SEGURIDAD${N}"; sep
    aplicar_seguridad

    echo ""; sep; echo -e "  ${W}[4/4] PAGINA DE INICIO${N}"; sep
    crear_pagina_index

    local ip; ip=$(hostname -I 2>/dev/null | awk '{print $1}')
    echo ""; sep
    ok "Instalacion completada."
    ok "Servidor : ${SERVICIO} ${VERSION}"
    ok "Puerto   : ${PUERTO}"
    ok "URL      : http://${ip}:${PUERTO}/"
    sep; pausar
}
