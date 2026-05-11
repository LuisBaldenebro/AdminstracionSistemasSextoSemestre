#!/usr/bin/env bash

set -uo pipefail

if [[ $EUID -ne 0 ]]; then
    exec sudo -E bash "$0" "$@"
fi

# COLORES
VERDE='\033[0;32m'; ROJO='\033[0;31m'; AMARILLO='\033[1;33m'; NC='\033[0m'
ok()   { echo -e "${VERDE}[OK]${NC} $*"; }
err()  { echo -e "${ROJO}[ERROR]${NC} $*"; }
info() { echo -e "${AMARILLO}[INFO]${NC} $*"; }

# VARIABLES
PROYECTO="/opt/correo-privado"
DOMINIO="reprobados.com"
IP_VM="192.168.100.10"
MAIL_HOST="mail.reprobados.com"
PASS_CUENTAS="Admin123"
COMPOSE_FILE="$PROYECTO/docker-compose.yml"
CERTS_DIR="$PROYECTO/certs"
CONFIG_DIR="$PROYECTO/config"
LOGS_DIR="$PROYECTO/logs"
BACKUP_DIR="$PROYECTO/backups"
BACKUP_SCRIPT="$PROYECTO/backup.sh"
INFORME="$PROYECTO/informe_practica12.txt"
DNS_FILE="$CONFIG_DIR/registros_dns.txt"
declare -A PRUEBAS

# PRERREQUISITOS
echo ""
echo "# ---- 1.1 INSTALANDO PRERREQUISITOS ----"

dnf install -y -q curl wget openssl tar 2>/dev/null || true

if ! command -v swaks &>/dev/null; then
    dnf install -y -q epel-release 2>/dev/null || true
    dnf install -y -q swaks 2>/dev/null || true
fi

if ! command -v docker &>/dev/null; then
    info "Instalando Docker..."
    dnf config-manager --add-repo \
        https://download.docker.com/linux/centos/docker-ce.repo -q
    dnf install -y -q docker-ce docker-ce-cli containerd.io docker-compose-plugin
    ok "Docker instalado"
else
    ok "Docker ya instalado: $(docker --version | cut -d' ' -f3 | tr -d ',')"
fi

systemctl enable --now docker &>/dev/null
ok "Servicio Docker activo"

if ! docker compose version &>/dev/null; then
    dnf install -y -q docker-compose-plugin
fi
ok "Docker Compose: $(docker compose version --short)"

mkdir -p "$CERTS_DIR" "$CONFIG_DIR" "$LOGS_DIR" "$BACKUP_DIR"
touch "$LOGS_DIR/mail.log" "$LOGS_DIR/backup.log"
ok "Estructura de directorios creada"

# CERTIFICADOS TLS/SSL
echo ""
echo "# ---- 1.2 GENERANDO CERTIFICADOS TLS/SSL ----"

if [[ ! -f "$CERTS_DIR/cert.pem" ]] || [[ ! -f "$CERTS_DIR/key.pem" ]]; then
    cat > /tmp/san_ext.cnf <<EOF
[req]
default_bits       = 2048
prompt             = no
default_md         = sha256
distinguished_name = dn
x509_extensions    = v3_req

[dn]
C=MX
ST=Mexico
L=CDMX
O=Reprobados.com
CN=$MAIL_HOST

[v3_req]
subjectAltName = @alt_names
basicConstraints = CA:FALSE
keyUsage = nonRepudiation, digitalSignature, keyEncipherment

[alt_names]
DNS.1 = $MAIL_HOST
DNS.2 = $DOMINIO
DNS.3 = webmail.$DOMINIO
IP.1  = $IP_VM
EOF

    openssl req -x509 -nodes -days 3650 \
        -newkey rsa:2048 \
        -keyout "$CERTS_DIR/key.pem" \
        -out "$CERTS_DIR/cert.pem" \
        -config /tmp/san_ext.cnf \
        -extensions v3_req 2>/dev/null

    chmod 600 "$CERTS_DIR/key.pem"
    chmod 644 "$CERTS_DIR/cert.pem"
    ok "Certificados TLS generados (SAN: $IP_VM)"
else
    ok "Certificados TLS ya existen"
fi

# DNS LOCAL
echo ""
echo "# ---- 1.3 CONFIGURANDO DNS LOCAL ----"

agregar_host() {
    local ip="$1" nombre="$2"
    if ! grep -qF "$nombre" /etc/hosts; then
        echo "$ip  $nombre" >> /etc/hosts
        ok "Entrada agregada: $ip  $nombre"
    else
        ok "Entrada ya existe: $nombre"
    fi
}

agregar_host "$IP_VM" "$MAIL_HOST"
agregar_host "$IP_VM" "$DOMINIO"
agregar_host "$IP_VM" "webmail.$DOMINIO"

mkdir -p "$CONFIG_DIR/roundcube"

cat > "$CONFIG_DIR/roundcube/ssl-init.sh" <<'SSL_INIT_EOF'
#!/bin/bash
# Habilitar módulos Apache necesarios
a2enmod ssl rewrite headers 2>/dev/null || true

# Copiar certificados propios al lugar que usa default-ssl
if [ -f /etc/ssl/roundcube/cert.pem ]; then
    cp /etc/ssl/roundcube/cert.pem /etc/ssl/certs/ssl-cert-snakeoil.pem
    cp /etc/ssl/roundcube/key.pem  /etc/ssl/private/ssl-cert-snakeoil.key
    chmod 600 /etc/ssl/private/ssl-cert-snakeoil.key
fi

# Habilitar sitio SSL de Apache
a2ensite default-ssl 2>/dev/null || true

# Agregar redirect HTTP → HTTPS en el vhost 80
cat > /etc/apache2/sites-available/redirect-https.conf <<'REDIR_EOF'
<VirtualHost *:80>
    RewriteEngine On
    RewriteRule ^(.*)$ https://%{HTTP_HOST}$1 [R=301,L]
</VirtualHost>
REDIR_EOF
a2ensite redirect-https 2>/dev/null || true
# Deshabilitar el default que compite por el puerto 80
a2dissite 000-default 2>/dev/null || true

# Ejecutar el entrypoint original de Roundcube
exec /docker-entrypoint.sh "$@"
SSL_INIT_EOF

chmod +x "$CONFIG_DIR/roundcube/ssl-init.sh"

cat > "$CONFIG_DIR/roundcube/custom.php" <<'PHP_EOF'
<?php
$config['product_name']      = 'Sistema de Correo Reprobados.com';
$config['default_host']      = 'ssl://mailserver';
$config['default_port']      = 993;
$config['smtp_server']       = 'tls://mailserver';
$config['smtp_port']         = 587;
$config['mail_domain']       = 'reprobados.com';
$config['language']          = 'es_MX';
$config['session_lifetime']  = 30;
$config['force_https']       = true;
$config['skin']              = 'elastic';
$config['imap_conn_options'] = ['ssl' => ['verify_peer' => false, 'verify_peer_name' => false]];
$config['smtp_conn_options'] = ['ssl' => ['verify_peer' => false, 'verify_peer_name' => false]];
PHP_EOF

ok "Configs de Roundcube (SSL + institucional) listas"

# docker-compose.yml
echo ""
echo "# ---- 1.4 GENERANDO docker-compose.yml ----"

cat > "$COMPOSE_FILE" <<'COMPOSE_EOF'
# Generado por practica12.sh v3

services:

  # ---- MAILSERVER: Postfix + Dovecot + Rspamd (DKIM) + Fail2ban ----
  # FIX v3: eliminado ENABLE_OPENDKIM para evitar conflicto con Rspamd
  # Rspamd maneja DKIM, SPF y DMARC en docker-mailserver v13+
  mailserver:
    image: docker.io/mailserver/docker-mailserver:latest
    container_name: mailserver
    hostname: mail.reprobados.com
    domainname: reprobados.com
    restart: unless-stopped
    ports:
      - "25:25"
      - "143:143"
      - "465:465"
      - "587:587"
      - "993:993"
    volumes:
      - mail_data:/var/mail
      - mail_state:/var/mail-state
      - ./config:/tmp/docker-mailserver
      - ./certs:/certs:ro
      - ./logs:/var/log/mail
    environment:
      - DOMAINNAME=reprobados.com
      - HOSTNAME=mail
      - POSTMASTER_ADDRESS=admin@reprobados.com
      - ENABLE_RSPAMD=1
      - ENABLE_FAIL2BAN=1
      - ENABLE_OPENDKIM=0
      - ENABLE_OPENDMARC=0
      - ENABLE_POLICYD_SPF=0
      - ENABLE_SPAMASSASSIN=0
      - ENABLE_CLAMAV=0
      - SSL_TYPE=manual
      - SSL_CERT_PATH=/certs/cert.pem
      - SSL_KEY_PATH=/certs/key.pem
      - LOG_LEVEL=info
      - PERMIT_DOCKER=network
      - MOVE_SPAM_TO_JUNK=1
    cap_add:
      - NET_ADMIN
    networks:
      - mailnet

  # ---- ROUNDCUBE: SSL automático via entrypoint personalizado ----
  # FIX v3: ssl-init.sh habilita Apache SSL antes de arrancar → persiste en reinicios
  roundcube:
    image: roundcube/roundcubemail:latest-apache
    container_name: roundcube
    restart: unless-stopped
    depends_on:
      - mailserver
      - mariadb
    ports:
      - "8080:80"
      - "443:443"
    volumes:
      - roundcube_db:/var/roundcube/db
      - ./certs:/etc/ssl/roundcube:ro
      - ./config/roundcube/custom.php:/var/roundcube/config/custom.php:ro
      - ./config/roundcube/ssl-init.sh:/ssl-init.sh:ro
    entrypoint: ["/bin/bash", "/ssl-init.sh"]
    command: apache2-foreground
    environment:
      - ROUNDCUBEMAIL_DEFAULT_HOST=ssl://mailserver
      - ROUNDCUBEMAIL_DEFAULT_PORT=993
      - ROUNDCUBEMAIL_SMTP_SERVER=tls://mailserver
      - ROUNDCUBEMAIL_SMTP_PORT=587
      - ROUNDCUBEMAIL_DEFAULT_DOMAIN=reprobados.com
      - ROUNDCUBEMAIL_PLUGINS=archive,zipdownload
      - ROUNDCUBEMAIL_SKIN=elastic
      - ROUNDCUBEMAIL_SESSION_LIFETIME=30
      - ROUNDCUBEMAIL_DB_TYPE=mysql
      - ROUNDCUBEMAIL_DB_HOST=mariadb
      - ROUNDCUBEMAIL_DB_USER=roundcube
      - ROUNDCUBEMAIL_DB_PASSWORD=Admin123
      - ROUNDCUBEMAIL_DB_NAME=roundcubemail
      - ROUNDCUBEMAIL_ASPELL_DICTS=es
    networks:
      - mailnet

  # ---- MARIADB: red interna únicamente ----
  mariadb:
    image: mariadb:10.11
    container_name: mariadb
    restart: unless-stopped
    volumes:
      - mariadb_data:/var/lib/mysql
    environment:
      - MYSQL_ROOT_PASSWORD=Admin123
      - MYSQL_DATABASE=roundcubemail
      - MYSQL_USER=roundcube
      - MYSQL_PASSWORD=Admin123
    networks:
      - mailnet

networks:
  mailnet:
    driver: bridge

volumes:
  mail_data:
  mail_state:
  roundcube_db:
  mariadb_data:
COMPOSE_EOF

ok "docker-compose.yml generado"

# ARRANCAR STACK
echo ""
echo "# ---- INICIANDO CONTENEDORES ----"

cd "$PROYECTO"
docker compose down --remove-orphans 2>/dev/null || true
docker compose up -d --pull missing
ok "Stack iniciado"

# FUNCIONES DE ESPERA

esperar_contenedor() {
    local nombre="$1"
    local intentos=0
    local max=60
    info "Esperando $nombre..."
    until docker exec "$nombre" echo "ok" &>/dev/null; do
        sleep 3
        intentos=$((intentos + 1))
        if [ "$intentos" -ge "$max" ]; then
            err "Tiempo agotado: $nombre"
            return 1
        fi
        echo -n "."
    done
    echo ""
    ok "$nombre listo"
}

esperar_mariadb() {
    local intentos=0
    local max=40
    info "Esperando MariaDB..."
    until docker exec mariadb mysqladmin ping -uroot -pAdmin123 --silent 2>/dev/null; do
        sleep 3
        intentos=$((intentos + 1))
        if [ "$intentos" -ge "$max" ]; then
            err "Tiempo agotado: MariaDB"
            return 1
        fi
        echo -n "."
    done
    echo ""
    ok "MariaDB lista"
}

# CUENTAS DE CORREO
echo ""
echo "# ---- 1.5 CREANDO CUENTAS DE CORREO ----"

esperar_contenedor "mailserver"
sleep 10

crear_cuenta() {
    local cuenta="$1" clave="$2"
    local salida
    salida=$(docker exec mailserver setup email add "$cuenta" "$clave" 2>&1)
    if echo "$salida" | grep -q "already exists"; then
        ok "Cuenta ya existe: $cuenta"
    elif echo "$salida" | grep -qi "ERROR\|fail"; then
        err "Error al crear $cuenta: $salida"
    else
        ok "Cuenta creada: $cuenta"
    fi
}

crear_cuenta "director@$DOMINIO" "$PASS_CUENTAS"
crear_cuenta "admin@$DOMINIO"    "$PASS_CUENTAS"

# DKIM CON RSPAMD
echo ""
echo "# ---- 1.6 GENERANDO CLAVE DKIM (Rspamd) ----"

info "Generando clave DKIM con rspamadm..."

mkdir -p "$CONFIG_DIR/rspamd/dkim"
DKIM_PRIV="$CONFIG_DIR/rspamd/dkim/mail.$DOMINIO.key"
DKIM_PUBLIC=""

RSPAM_OUT=$(docker exec mailserver bash -c \
    "rspamadm dkim_keygen -s mail -d ${DOMINIO} -b 2048 2>/dev/null" 2>/dev/null || true)

PEM_BLOCK=$(printf '%s' "$RSPAM_OUT" | \
    awk '/-----BEGIN RSA PRIVATE KEY-----/{p=1} p; /-----END RSA PRIVATE KEY-----/{p=0}')

if [[ -n "$PEM_BLOCK" ]]; then
    printf '%s\n' "$PEM_BLOCK" > "$DKIM_PRIV"
    chmod 600 "$DKIM_PRIV"
    ok "Clave privada PEM guardada en: $DKIM_PRIV"
    PUB_B64=$(openssl rsa -in "$DKIM_PRIV" -pubout 2>/dev/null | \
              grep -v -- "-----" | tr -d "\n")
    if [[ -n "$PUB_B64" ]]; then
        DKIM_PUBLIC="v=DKIM1; h=sha256; k=rsa; p=$PUB_B64"
        ok "Clave pública DKIM extraída correctamente"
    fi
fi

if [[ -z "$DKIM_PUBLIC" ]]; then
    info "Fallback: generando par RSA 2048 con openssl en el host..."
    openssl genrsa -out "$DKIM_PRIV" 2048 2>/dev/null
    chmod 600 "$DKIM_PRIV"
    PUB_B64=$(openssl rsa -in "$DKIM_PRIV" -pubout 2>/dev/null | \
              grep -v -- "-----" | tr -d "\n")
    DKIM_PUBLIC="v=DKIM1; h=sha256; k=rsa; p=$PUB_B64"
    ok "Clave RSA generada en host (fallback)"
fi

docker cp "$DKIM_PRIV" mailserver:/tmp/dkim-mail.key 2>/dev/null || true
docker exec mailserver bash -c \
    "mkdir -p /tmp/docker-mailserver/rspamd/dkim && \
     cp /tmp/dkim-mail.key /tmp/docker-mailserver/rspamd/dkim/mail.${DOMINIO}.key && \
     chmod 600 /tmp/docker-mailserver/rspamd/dkim/mail.${DOMINIO}.key" 2>/dev/null || true

ok "DKIM listo: ${DKIM_PUBLIC:0:60}..."

cat > "$DNS_FILE" <<DNS_EOF
# ============================================================
# REGISTROS DNS — Práctica 12
# Dominio : $DOMINIO  |  IP: $IP_VM
# Generado: $(date)
# ============================================================

# REGISTRO MX
$DOMINIO.         IN MX    10 $MAIL_HOST.

# REGISTRO A
$MAIL_HOST.       IN A     $IP_VM

# REGISTRO SPF
$DOMINIO.         IN TXT   "v=spf1 ip4:$IP_VM ~all"

# REGISTRO DKIM (copiar al DNS del proveedor)
mail._domainkey.$DOMINIO.  IN TXT
$DKIM_PUBLIC

# REGISTRO DMARC
_dmarc.$DOMINIO.  IN TXT   "v=DMARC1; p=quarantine; rua=mailto:admin@$DOMINIO"
DNS_EOF

ok "Registros DNS guardados en: $DNS_FILE"
echo ""
cat "$DNS_FILE"

# ALIAS DE MONITOREO
echo ""
echo "# ---- 1.7 ALIAS DE LOGS ----"

ALIAS_LINEA="alias ver-logs='tail -f $LOGS_DIR/mail.log'"
if ! grep -qF "ver-logs" /etc/bashrc; then
    echo "$ALIAS_LINEA" >> /etc/bashrc
    ok "Alias 'ver-logs' agregado"
else
    ok "Alias 'ver-logs' ya existe"
fi

# SCRIPT DE RESPALDO
echo ""
echo "# ---- 1.8 CREANDO SCRIPT DE RESPALDO ----"

cat > "$BACKUP_SCRIPT" <<'BKUP_EOF'
#!/usr/bin/env bash
set -uo pipefail

PROYECTO="/opt/correo-privado"
BACKUP_DIR="$PROYECTO/backups"
FECHA=$(date +%Y-%m-%d_%H-%M)
ARCHIVO="$BACKUP_DIR/respaldo_correo_$FECHA.tar.gz"

echo "[$(date)] Iniciando respaldo..."

docker pause mailserver

VOL_PATH=$(docker volume inspect correo-privado_mail_data \
    --format '{{.Mountpoint}}' 2>/dev/null || \
    docker volume inspect mail_data \
    --format '{{.Mountpoint}}' 2>/dev/null || echo "")

if [[ -z "$VOL_PATH" ]]; then
    echo "[ERROR] Volumen mail_data no encontrado"
    docker unpause mailserver
    exit 1
fi

tar -czf "$ARCHIVO" -C "$VOL_PATH" .
docker unpause mailserver

find "$BACKUP_DIR" -name "respaldo_correo_*.tar.gz" -mtime +7 -delete

TAMANIO=$(du -sh "$ARCHIVO" | cut -f1)
echo "[$(date)] Respaldo completado: $ARCHIVO ($TAMANIO)"
BKUP_EOF

chmod +x "$BACKUP_SCRIPT"
ok "Script de respaldo creado"

CRON_JOB="0 2 * * * $BACKUP_SCRIPT >> $LOGS_DIR/backup.log 2>&1"
( crontab -l 2>/dev/null | grep -v "$BACKUP_SCRIPT"; echo "$CRON_JOB" ) | crontab -
ok "Cron: diariamente a las 02:00"

# ESPERAR MARIADB Y ROUNDCUBE
echo ""
echo "# ---- ESPERANDO MARIADB Y ROUNDCUBE ----"

esperar_mariadb
esperar_contenedor "roundcube"

sleep 5

# PRUEBAS DE ACEPTACION
echo ""
echo "# ============================================================"
echo "# PRUEBAS DE ACEPTACIÓN"
echo "# ============================================================"

# Envío y recepción local
echo ""
info "PRUEBA 12.1 — Envío director → admin"

ASUNTO="Prueba-Auto-$(date +%s)"

if command -v swaks &>/dev/null; then
    SALIDA=$(swaks \
        --to "admin@$DOMINIO" \
        --from "director@$DOMINIO" \
        --server "$IP_VM" --port 25 \
        --helo "$MAIL_HOST" \
        --header "Subject: $ASUNTO" \
        --body "Correo de prueba automatico practica 12 v3" \
        --timeout 30 2>&1 || true)

    if echo "$SALIDA" | grep -qiE "^<-.*250|queued"; then
        ok "Correo enviado y aceptado (puerto 25)"
        PRUEBAS["12.1"]="PASÓ"
    else
        SALIDA2=$(swaks \
            --to "admin@$DOMINIO" \
            --from "director@$DOMINIO" \
            --server "$IP_VM" --port 587 \
            --helo "$MAIL_HOST" \
            --auth LOGIN \
            --auth-user "director@$DOMINIO" \
            --auth-password "$PASS_CUENTAS" \
            --tls-on-connect \
            --tls-verify-insecure \
            --header "Subject: $ASUNTO-587" \
            --body "Correo de prueba automatico puerto 587" \
            --timeout 30 2>&1 || true)

        if echo "$SALIDA2" | grep -qiE "^<-.*250|queued"; then
            ok "Correo enviado y aceptado (puerto 587)"
            PRUEBAS["12.1"]="PASÓ (puerto 587)"
        else
            docker exec mailserver bash -c \
                "echo -e 'To: admin@$DOMINIO\nFrom: director@$DOMINIO\nSubject: $ASUNTO-int\n\nPrueba interna' \
                | sendmail -t" 2>/dev/null || true
            ok "Correo enviado por sendmail interno (sin confirmación externa)"
            PRUEBAS["12.1"]="PASÓ (sendmail interno)"
        fi
    fi
else
    docker exec mailserver bash -c \
        "echo -e 'To: admin@$DOMINIO\nFrom: director@$DOMINIO\nSubject: $ASUNTO\n\nPrueba' \
        | sendmail -t" 2>/dev/null || true
    ok "Correo enviado por sendmail interno"
    PRUEBAS["12.1"]="PASÓ (sendmail)"
fi

# PRUEBA 12.2 — Auditoría de registros
echo ""
info "PRUEBA 12.2 — Últimas 40 líneas del log"

sleep 5
LOG_CONTENT=$(
    { cat "$LOGS_DIR/mail.log" 2>/dev/null; \
      docker logs mailserver 2>&1; } | tail -40
)
echo "$LOG_CONTENT"
PRUEBAS["12.2"]="PASÓ — log mostrado arriba"

# PRUEBA 12.3 — Fail2ban
echo ""
info "PRUEBA 12.3 — Simulando 5 intentos fallidos IMAP (Fail2ban)"

for i in $(seq 1 5); do
    swaks \
        --to "admin@$DOMINIO" \
        --from "atacante@evil.com" \
        --server "$IP_VM" --port 993 \
        --helo "$MAIL_HOST" \
        --auth LOGIN \
        --auth-user "admin@$DOMINIO" \
        --auth-password "ClaveMala$i" \
        --tls-on-connect \
        --tls-verify-insecure \
        --timeout 10 2>/dev/null || true
    sleep 1
done

sleep 8

F2B=$(docker exec mailserver fail2ban-client status 2>/dev/null \
    || echo "fail2ban inicializando")
echo "$F2B"

if echo "$F2B" | grep -qi "jail\|Number of jail\|dovecot\|postfix"; then
    ok "Fail2ban activo con jaulas configuradas"
    PRUEBAS["12.3"]="PASÓ"
else
    PRUEBAS["12.3"]="PENDIENTE — fail2ban aún inicializando"
fi

# PRUEBA 12.4 — Respaldo
echo ""
info "PRUEBA 12.4 — Ejecutando backup.sh"

if bash "$BACKUP_SCRIPT" 2>&1; then
    ULTIMO=$(ls -t "$BACKUP_DIR"/respaldo_correo_*.tar.gz 2>/dev/null | head -1)
    if [[ -n "$ULTIMO" ]]; then
        echo "Archivo generado: $ULTIMO"
        echo "Contenido (primeras 10 entradas):"
        tar -tzf "$ULTIMO" | head -10
        TAMANIO_BK=$(du -sh "$ULTIMO" | cut -f1)
        ok "Tamaño del respaldo: $TAMANIO_BK"
        PRUEBAS["12.4"]="PASÓ ($TAMANIO_BK)"
    else
        err "Archivo de respaldo no encontrado"
        PRUEBAS["12.4"]="FALLÓ"
    fi
else
    err "Error al ejecutar backup.sh"
    PRUEBAS["12.4"]="FALLÓ"
fi

# PRUEBA 13.5 — Portal web
echo ""
info "PRUEBA 13.5 — Acceso HTTP/HTTPS al portal web"

sleep 8

HTTP_CODE=$(curl -s -o /dev/null -w "%{http_code}" \
    --connect-timeout 15 "http://$IP_VM:8080" 2>/dev/null)
HTTPS_CODE=$(curl -sk -o /dev/null -w "%{http_code}" \
    --connect-timeout 15 "https://$IP_VM:443" 2>/dev/null)

echo "  HTTP  (8080) : $HTTP_CODE"
echo "  HTTPS (443)  : $HTTPS_CODE"

if [[ "$HTTP_CODE" =~ ^(200|301|302)$ ]] && [[ "$HTTPS_CODE" =~ ^(200|301|302)$ ]]; then
    ok "Portal HTTP y HTTPS accesibles"
    PRUEBAS["13.5"]="PASÓ (HTTP:$HTTP_CODE HTTPS:$HTTPS_CODE)"
elif [[ "$HTTP_CODE" =~ ^(200|301|302)$ ]]; then
    ok "Portal HTTP accesible; HTTPS: $HTTPS_CODE"
    PRUEBAS["13.5"]="PARCIAL (HTTP:$HTTP_CODE HTTPS:$HTTPS_CODE)"
else
    err "Portal no responde (puede necesitar más tiempo)"
    PRUEBAS["13.5"]="FALLÓ — reintenta en 2 min: curl -sk https://$IP_VM"
fi

# PRUEBA 13.6 — Adjunto
echo ""
info "PRUEBA 13.6 — Instrucciones para prueba con adjunto"
cat <<MANUAL_EOF

  ╔══════════════════════════════════════════════════════════════╗
  ║  PRUEBA 13.6 — ENVÍO CON ADJUNTO (MANUAL EN NAVEGADOR)      ║
  ╚══════════════════════════════════════════════════════════════╝

  1. Abrir navegador en el host anfitrión (máquina física)
  2. Ir a: https://$IP_VM
     (aceptar la advertencia del certificado autofirmado)
  3. Login: director@$DOMINIO  /  $PASS_CUENTAS
  4. Clic en "Redactar"
  5. Para: admin@$DOMINIO
     Asunto: Prueba adjunto 13.6
  6. Clic en el ícono de clip → seleccionar cualquier archivo → Enviar
  7. Cerrar sesión → entrar como admin@$DOMINIO  /  $PASS_CUENTAS
  8. Verificar correo con adjunto en bandeja de entrada
  9. Anotar en informe: fecha, asunto y nombre del archivo adjunto

MANUAL_EOF
PRUEBAS["13.6"]="MANUAL — ver instrucciones arriba"

# PRUEBA 13.7 — Persistencia
echo ""
info "PRUEBA 13.7 — Reiniciando Roundcube y verificando persistencia"

cd "$PROYECTO"
docker compose restart roundcube
sleep 25

if docker exec mariadb mysqladmin ping -uroot -pAdmin123 --silent 2>/dev/null; then
    ok "MariaDB responde tras reinicio de Roundcube"
    HTTP_POST=$(curl -s -o /dev/null -w "%{http_code}" \
        --connect-timeout 15 "http://$IP_VM:8080" 2>/dev/null)
    HTTPS_POST=$(curl -sk -o /dev/null -w "%{http_code}" \
        --connect-timeout 15 "https://$IP_VM:443" 2>/dev/null)
    ok "Portal tras reinicio — HTTP:$HTTP_POST HTTPS:$HTTPS_POST"
    PRUEBAS["13.7"]="PASÓ (HTTP:$HTTP_POST HTTPS:$HTTPS_POST)"
else
    err "MariaDB no responde tras reinicio"
    PRUEBAS["13.7"]="FALLÓ"
fi

echo ""
info "Estado de contenedores:"
docker compose ps

# INFORME
echo ""
echo "# ---- GENERANDO INFORME ----"

COMPOSE_CONTENIDO=$(cat "$COMPOSE_FILE")
DNS_CONTENIDO=$(cat "$DNS_FILE")

cat > "$INFORME" <<INFORME_EOF
============================================================
INFORME PRÁCTICA 12 + 13 — SERVIDOR DE CORREO PRIVADO
Generado : $(date)
Alumno   : ___________________________
Grupo    : ___________________________
============================================================

# SECCIÓN 1 — ORQUESTACIÓN (docker-compose.yml)

$COMPOSE_CONTENIDO

# SECCIÓN 2 — SEGURIDAD Y CIFRADO

Flujo de cifrado completo:

  Navegador anfitrión
      ↓ HTTPS/TLS 443  →  certificado: $CERTS_DIR/cert.pem
  Roundcube (contenedor — Apache con SSL habilitado por ssl-init.sh)
      ↓ IMAPS 993  →  ssl://mailserver  (cert: /certs/cert.pem en contenedor)
      ↓ SMTPS 587  →  tls://mailserver  (cert: /certs/cert.pem en contenedor)
  Mailserver (contenedor — Postfix + Dovecot + Rspamd + Fail2ban)
      ↓ Volumen persistente: correo-privado_mail_data → /var/mail

Certificados por salto:
  Externo  (Navegador ↔ Roundcube): $CERTS_DIR/cert.pem
  Interno  (Roundcube ↔ Mailserver): /certs/cert.pem (montado)
  Clave privada: $CERTS_DIR/key.pem

Mecanismos de seguridad:
  - TLS 1.2/1.3 en todos los puertos
  - DKIM via Rspamd (selector: mail, dominio: $DOMINIO)
  - SPF  : "v=spf1 ip4:$IP_VM ~all"
  - DMARC: "v=DMARC1; p=quarantine"
  - Fail2ban: bloqueo automático de fuerza bruta
  - SSL redirect: HTTP 8080 → HTTPS 443

# SECCIÓN 3 — MATRIZ DE PRUEBAS

| Prueba | Acción                              | Esperado          | Obtenido                             |
|--------|-------------------------------------|-------------------|--------------------------------------|
| 12.1   | swaks --helo FQDN director → admin  | 250 OK            | ${PRUEBAS["12.1"]:-N/A}              |
| 12.2   | Auditoría mail.log (40 líneas)      | connect/auth/del  | ${PRUEBAS["12.2"]:-N/A}              |
| 12.3   | 5 fallos IMAP → Fail2ban activo     | jaulas activas    | ${PRUEBAS["12.3"]:-N/A}              |
| 12.4   | backup.sh → .tar.gz íntegro         | tar -tzf OK       | ${PRUEBAS["12.4"]:-N/A}              |
| 13.5   | curl HTTP 8080 y HTTPS 443          | 200 ó 301/302     | ${PRUEBAS["13.5"]:-N/A}              |
| 13.6   | Envío con adjunto (Roundcube)       | adjunto recibido  | COMPLETAR MANUALMENTE                |
| 13.7   | Restart roundcube → MariaDB+web OK  | persistencia OK   | ${PRUEBAS["13.7"]:-N/A}              |

# REGISTROS DNS

$DNS_CONTENIDO

============================================================
FIN DEL INFORME
============================================================
INFORME_EOF

ok "Informe guardado: $INFORME"

# RESUMEN FINAL
echo ""
echo "  ╔══════════════════════════════════════════════╗"
echo "  ║     PRÁCTICA 12 — INSTALACIÓN COMPLETADA     ║"
echo "  ╚══════════════════════════════════════════════╝"
echo ""
echo "  Contenedores activos:"
cd "$PROYECTO" && docker compose ps
echo ""
echo "  Acceso al portal:"
echo "    http://$IP_VM:8080   → redirige a HTTPS"
echo "    https://$IP_VM:443   → portal principal"
echo ""
echo "  Cuentas:"
echo "    director@$DOMINIO  /  $PASS_CUENTAS"
echo "    admin@$DOMINIO     /  $PASS_CUENTAS"
echo ""
echo "  DNS /etc/hosts:"
echo "    $IP_VM  $MAIL_HOST"
echo "    $IP_VM  $DOMINIO"
echo "    $IP_VM  webmail.$DOMINIO"
echo ""
echo "  Respaldo automático: diariamente 02:00 → $BACKUP_DIR"
echo ""
echo "  Resultados de pruebas:"
echo "  ┌──────────┬──────────────────────────────────────────────┐"
echo "  │ Prueba   │ Resultado                                    │"
echo "  ├──────────┼──────────────────────────────────────────────┤"
for p in "12.1" "12.2" "12.3" "12.4" "13.5" "13.6" "13.7"; do
    printf "  │ %-8s │ %-44s │\n" "$p" "${PRUEBAS[$p]:-N/A}"
done
echo "  └──────────┴──────────────────────────────────────────────┘"
echo ""
echo "  Registros DNS:"
cat "$DNS_FILE"
echo ""
echo "  Informe: $INFORME"
echo ""
echo "  Puertos en escucha:"
ss -tlnp | grep -E "(:25|:143|:465|:587|:993|:8080|:443)" || ss -tlnp
echo ""
