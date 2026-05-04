#!/usr/bin/env bash

if [[ $EUID -ne 0 ]]; then
    echo "[INFO] Re-ejecutando con privilegios de administrador..."
    exec sudo -E bash "$0" "$@"
fi

set -uo pipefail

# VARIABLES GLOBALES
readonly HOST_IP="192.168.100.10"

readonly RED_DOCKER="red_sistemas"
readonly RED_SUBRED="172.30.0.0/24"
readonly RED_GATEWAY="172.30.0.1"

readonly IP_WEB="172.30.0.10"
readonly IP_PG="172.30.0.20"
readonly IP_FTP="172.30.0.30"

readonly CTR_WEB="contenedor_web"
readonly CTR_PG="contenedor_postgres"
readonly CTR_FTP="contenedor_ftp"

readonly VOL_WEB="web_content"
readonly VOL_DB="db_data"

readonly PG_DB="sistemadb"
readonly PG_USER="sysadmin"
readonly PG_PASS="S3gur0_2024!"

readonly FTP_USER="ftpuser"
readonly FTP_PASS="Ftp_S3cur3!"

readonly DIR_RESPALDOS="/opt/respaldos"
readonly DIR_BUILD="/opt/docker_build/web"

# COLORES
VERDE='\033[0;32m'; ROJO='\033[0;31m'; AMARILLO='\033[1;33m'
CYAN='\033[0;36m';  NC='\033[0m'

log_info()  { echo -e "${CYAN}[INFO]${NC}  $*"; }
log_ok()    { echo -e "${VERDE}[OK]${NC}    $*"; }
log_warn()  { echo -e "${AMARILLO}[WARN]${NC}  $*"; }
log_error() { echo -e "${ROJO}[ERROR]${NC} $*"; }
log_sep()   { echo -e "${CYAN}# ---- $* ----${NC}"; }

# HELPER: ESTADO DE UN CONTENEDOR
estado_contenedor() {
    docker inspect --format '{{.State.Status}}' "$1" 2>/dev/null || echo ""
}

# HELPER: ASEGURAR CONTENEDOR SANO
asegurar_contenedor_sano() {
    local nombre="$1"
    local estado
    estado=$(estado_contenedor "$nombre")
    case "$estado" in
        running) log_info "Contenedor '$nombre' ya existe y está corriendo." ;;
        restarting|exited|dead|paused)
            log_warn "Contenedor '$nombre' en estado '${estado}'. Eliminando para recrear..."
            docker rm -f "$nombre" >/dev/null 2>&1 || true ;;
        "") ;; # No existe, se creará
        *)
            log_warn "Estado desconocido '${estado}' en '$nombre'. Eliminando..."
            docker rm -f "$nombre" >/dev/null 2>&1 || true ;;
    esac
}

# DEPENDENCIAS DEL HOST
instalar_dependencias() {
    log_sep "DEPENDENCIAS DEL HOST"
    local paquetes=(curl ftp git)
    local faltan=()
    for pkg in "${paquetes[@]}"; do command -v "$pkg" &>/dev/null || faltan+=("$pkg"); done
    [[ ${#faltan[@]} -gt 0 ]] && dnf install -y "${faltan[@]}" --quiet
    log_ok "Dependencias del host listas."
}

# INSTALAR DOCKER CE
instalar_docker() {
    log_sep "INSTALACIÓN DE DOCKER CE"
    if command -v docker &>/dev/null && systemctl is-active --quiet docker; then
        log_ok "Docker ya está instalado y activo."; return 0
    fi
    log_info "Agregando repositorio oficial Docker CE para RHEL/Oracle Linux 9..."
    dnf config-manager --add-repo \
        https://download.docker.com/linux/rhel/docker-ce.repo &>/dev/null
    log_info "Instalando Docker CE, CLI y containerd..."
    dnf install -y docker-ce docker-ce-cli containerd.io --quiet --allowerasing
    log_info "Habilitando y arrancando servicio Docker..."
    systemctl enable --now docker
    log_info "Verificando que Docker responde..."
    local i=0
    until docker info &>/dev/null; do
        (( i++ )); [[ $i -ge 15 ]] && { log_error "Docker no respondió."; exit 1; }
        log_warn "Esperando Docker... $i/15"; sleep 2
    done
    log_ok "Docker CE operativo. $(docker --version)"
}

# FIREWALLD
configurar_firewall() {
    log_sep "CONFIGURACIÓN FIREWALLD"
    systemctl is-active --quiet firewalld || systemctl enable --now firewalld
    for p in 8080/tcp 21/tcp 5432/tcp; do
        firewall-cmd --quiet --permanent --add-port="$p" 2>/dev/null || true
    done
    firewall-cmd --quiet --permanent --add-port=21100-21110/tcp 2>/dev/null || true
    firewall-cmd --quiet --permanent --add-source=172.30.0.0/24 2>/dev/null || true
    firewall-cmd --quiet --reload
    log_ok "Reglas de firewall aplicadas (8080, 21, 5432, 21100-21110)."
}

# VOLUMENES
crear_volumenes() {
    log_sep "VOLÚMENES PERSISTENTES"
    for vol in "$VOL_WEB" "$VOL_DB"; do
        if docker volume inspect "$vol" &>/dev/null; then
            log_info "Volumen '$vol' ya existe."
        else
            docker volume create "$vol" >/dev/null
            log_ok "Volumen '$vol' creado."
        fi
    done
}

# RED DOCKER
crear_red() {
    log_sep "RED DOCKER: $RED_DOCKER"
    if docker network inspect "$RED_DOCKER" &>/dev/null; then
        log_info "Red '$RED_DOCKER' ya existe."
    else
        docker network create --driver bridge \
            --subnet "$RED_SUBRED" --gateway "$RED_GATEWAY" \
            "$RED_DOCKER" >/dev/null
        log_ok "Red '$RED_DOCKER' ($RED_SUBRED) creada."
    fi
}

# DIRECTORIO DE RESPALDOS
preparar_respaldos() {
    log_sep "DIRECTORIO DE RESPALDOS"
    mkdir -p "$DIR_RESPALDOS"
    chown root:root "$DIR_RESPALDOS"; chmod 750 "$DIR_RESPALDOS"
    chcon -Rt svirt_sandbox_file_t "$DIR_RESPALDOS" 2>/dev/null || true
    log_ok "Directorio $DIR_RESPALDOS listo con permisos y contexto SELinux."
}

# ARCHIVOS ESTÁTICOS WEB
generar_archivos_web() {
    log_sep "ARCHIVOS ESTÁTICOS WEB"
    mkdir -p "$DIR_BUILD"

    cat > "$DIR_BUILD/logo.svg" <<'SVGEOF'
<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 120 120" width="80" height="80">
  <defs>
    <linearGradient id="g1" x1="0%" y1="0%" x2="100%" y2="100%">
      <stop offset="0%" style="stop-color:#0f4c81"/>
      <stop offset="100%" style="stop-color:#1a8fe3"/>
    </linearGradient>
  </defs>
  <circle cx="60" cy="60" r="55" fill="url(#g1)"/>
  <rect x="30" y="38" width="60" height="8" rx="4" fill="#fff" opacity=".9"/>
  <rect x="30" y="52" width="45" height="8" rx="4" fill="#fff" opacity=".7"/>
  <rect x="30" y="66" width="52" height="8" rx="4" fill="#fff" opacity=".5"/>
  <circle cx="85" cy="80" r="14" fill="#e8f4fd" opacity=".9"/>
  <text x="85" y="85" text-anchor="middle" font-size="14"
        font-family="monospace" font-weight="bold" fill="#0f4c81">&#x2726;</text>
</svg>
SVGEOF

    cat > "$DIR_BUILD/estilos.css" <<'CSSEOF'
@import url('https://fonts.googleapis.com/css2?family=Space+Mono:wght@400;700&family=IBM+Plex+Sans:wght@300;400;600;700&display=swap');
:root{--azul-oscuro:#0a1628;--azul-medio:#0f4c81;--azul-claro:#1a8fe3;
  --azul-acento:#4fc3f7;--blanco:#f0f6ff;--gris:#b0c4de;
  --verde:#2ecc71;--borde:rgba(79,195,247,.3);--sombra:0 8px 32px rgba(0,0,0,.4)}
*,*::before,*::after{box-sizing:border-box;margin:0;padding:0}
html{scroll-behavior:smooth}
body{font-family:'IBM Plex Sans',sans-serif;background:var(--azul-oscuro);
  color:var(--blanco);min-height:100vh;
  background-image:radial-gradient(ellipse at 10% 20%,rgba(26,143,227,.12) 0%,transparent 50%),
  radial-gradient(ellipse at 90% 80%,rgba(15,76,129,.18) 0%,transparent 50%)}
header{display:flex;align-items:center;gap:1.2rem;padding:1.5rem 3rem;
  background:rgba(10,22,40,.85);backdrop-filter:blur(12px);
  border-bottom:1px solid var(--borde);position:sticky;top:0;z-index:100}
.header-texto h1{font-family:'Space Mono',monospace;font-size:1.4rem;
  color:var(--azul-acento);letter-spacing:.05em}
.header-texto p{font-size:.8rem;color:var(--gris);font-weight:300;
  letter-spacing:.12em;text-transform:uppercase}
.badge{margin-left:auto;display:flex;align-items:center;gap:.5rem;
  font-size:.75rem;font-family:'Space Mono',monospace;color:var(--verde);
  border:1px solid var(--verde);padding:.35rem .9rem;border-radius:999px;
  background:rgba(46,204,113,.08)}
.badge::before{content:'';width:8px;height:8px;border-radius:50%;
  background:var(--verde);box-shadow:0 0 6px var(--verde);animation:pulso 2s infinite}
@keyframes pulso{0%,100%{opacity:1}50%{opacity:.4}}
.hero{text-align:center;padding:5rem 2rem 3.5rem;position:relative}
.hero::after{content:'';position:absolute;bottom:0;left:50%;transform:translateX(-50%);
  width:80px;height:2px;background:linear-gradient(90deg,transparent,var(--azul-acento),transparent)}
.hero h2{font-family:'Space Mono',monospace;font-size:clamp(1.8rem,4vw,3rem);
  color:var(--blanco);line-height:1.2;margin-bottom:1rem}
.hero h2 span{background:linear-gradient(135deg,var(--azul-claro),var(--azul-acento));
  -webkit-background-clip:text;-webkit-text-fill-color:transparent;background-clip:text}
.hero p{max-width:520px;margin:0 auto;color:var(--gris);font-size:1rem;
  line-height:1.7;font-weight:300}
.hero-meta{display:flex;justify-content:center;gap:2rem;margin-top:2.5rem;flex-wrap:wrap}
.meta-item{display:flex;flex-direction:column;align-items:center;gap:.3rem}
.meta-label{font-size:.7rem;text-transform:uppercase;letter-spacing:.12em;
  color:var(--gris);font-family:'Space Mono',monospace}
.meta-valor{font-family:'Space Mono',monospace;font-size:.9rem;color:var(--azul-acento)}
.seccion{max-width:1000px;margin:3rem auto;padding:0 2rem}
.seccion-titulo{font-family:'Space Mono',monospace;font-size:.8rem;
  text-transform:uppercase;letter-spacing:.2em;color:var(--azul-acento);
  margin-bottom:1.2rem;display:flex;align-items:center;gap:.8rem}
.seccion-titulo::after{content:'';flex:1;height:1px;background:var(--borde)}
.tabla-wrapper{border-radius:12px;overflow:hidden;border:1px solid var(--borde);box-shadow:var(--sombra)}
table{width:100%;border-collapse:collapse;font-size:.88rem}
thead{background:rgba(15,76,129,.5)}
th{padding:1rem 1.2rem;text-align:left;font-family:'Space Mono',monospace;
  font-size:.72rem;text-transform:uppercase;letter-spacing:.1em;
  color:var(--azul-acento);border-bottom:1px solid var(--borde)}
td{padding:.95rem 1.2rem;border-bottom:1px solid rgba(79,195,247,.08)}
tr:last-child td{border-bottom:none}
tr:nth-child(even) td{background:rgba(15,76,129,.15)}
tr:hover td{background:rgba(26,143,227,.12);transition:background .2s}
.chip{display:inline-flex;align-items:center;gap:.35rem;font-family:'Space Mono',monospace;
  font-size:.72rem;padding:.25rem .7rem;border-radius:999px;font-weight:700}
.chip-activo{background:rgba(46,204,113,.15);color:var(--verde);border:1px solid rgba(46,204,113,.35)}
.chip-activo::before{content:'●';font-size:.6rem}
.ip{font-family:'Space Mono',monospace;font-size:.82rem;color:var(--azul-acento);
  background:rgba(79,195,247,.08);padding:.15rem .5rem;border-radius:4px}
footer{text-align:center;padding:2.5rem;color:var(--gris);font-size:.75rem;
  font-family:'Space Mono',monospace;border-top:1px solid var(--borde);margin-top:4rem;opacity:.7}
@media(max-width:640px){header{padding:1rem 1.5rem;flex-wrap:wrap}
  .hero{padding:3rem 1.5rem 2.5rem}.seccion{padding:0 1rem}
  th,td{padding:.75rem .8rem}.badge{margin-left:0}}
CSSEOF

    cat > "$DIR_BUILD/index.html" <<HTMLEOF
<!DOCTYPE html>
<html lang="es">
<head>
  <meta charset="UTF-8"/>
  <meta name="viewport" content="width=device-width, initial-scale=1.0"/>
  <title>Panel de Infraestructura — Sistemas</title>
  <link rel="stylesheet" href="estilos.css"/>
</head>
<body>
<header>
  <img src="logo.svg" alt="Logo" width="48" height="48"/>
  <div class="header-texto">
    <h1>SYS_INFRA</h1>
    <p>Infraestructura Dockerizada · Oracle Linux 9.7</p>
  </div>
  <div class="badge">OPERATIVO</div>
</header>
<main>
  <section class="hero">
    <h2>Panel de <span>Control</span><br/>de Infraestructura</h2>
    <p>Despliegue automatizado de servicios sobre contenedores Docker
       con red privada, persistencia de datos y acceso FTP integrado.</p>
    <div class="hero-meta">
      <div class="meta-item"><span class="meta-label">Host IP</span><span class="meta-valor">192.168.100.10</span></div>
      <div class="meta-item"><span class="meta-label">Red Docker</span><span class="meta-valor">172.30.0.0/24</span></div>
      <div class="meta-item"><span class="meta-label">Contenedores</span><span class="meta-valor">3 activos</span></div>
      <div class="meta-item"><span class="meta-label">Motor</span><span class="meta-valor">Docker CE</span></div>
    </div>
  </section>
  <section class="seccion">
    <div class="seccion-titulo">Servicios Activos</div>
    <div class="tabla-wrapper">
      <table>
        <thead><tr><th>Servicio</th><th>Imagen</th><th>IP Interna</th><th>Puerto(s)</th><th>Estado</th><th>Volumen</th></tr></thead>
        <tbody>
          <tr><td><strong>Servidor Web</strong></td><td>nginx:alpine</td><td><span class="ip">172.30.0.10</span></td><td><span class="ip">8080:80</span></td><td><span class="chip chip-activo">Activo</span></td><td>web_content</td></tr>
          <tr><td><strong>PostgreSQL</strong></td><td>postgres:15-alpine</td><td><span class="ip">172.30.0.20</span></td><td><span class="ip">5432:5432</span></td><td><span class="chip chip-activo">Activo</span></td><td>db_data</td></tr>
          <tr><td><strong>Servidor FTP</strong></td><td>fauria/vsftpd</td><td><span class="ip">172.30.0.30</span></td><td><span class="ip">21, 21100-21110</span></td><td><span class="chip chip-activo">Activo</span></td><td>web_content</td></tr>
        </tbody>
      </table>
    </div>
  </section>
  <section class="seccion">
    <div class="seccion-titulo">Configuración de Red</div>
    <div class="tabla-wrapper">
      <table>
        <thead><tr><th>Parámetro</th><th>Valor</th><th>Descripción</th></tr></thead>
        <tbody>
          <tr><td>Red Docker</td><td><span class="ip">red_sistemas</span></td><td>Red bridge privada interna</td></tr>
          <tr><td>Subred</td><td><span class="ip">172.30.0.0/24</span></td><td>Aislada de la red del host</td></tr>
          <tr><td>Gateway</td><td><span class="ip">172.30.0.1</span></td><td>Gateway de la red Docker</td></tr>
          <tr><td>IP Host (enp0s8)</td><td><span class="ip">192.168.100.10/24</span></td><td>Interfaz host-only de VirtualBox</td></tr>
          <tr><td>Respaldos BD</td><td><span class="ip">/opt/respaldos/</span></td><td>pg_dump automatizado cada hora</td></tr>
        </tbody>
      </table>
    </div>
  </section>
</main>
<footer>&copy; 2024 · Infraestructura Dockerizada · Oracle Linux 9.7 · VirtualBox</footer>
</body>
</html>
HTMLEOF

    log_ok "Archivos estáticos generados en $DIR_BUILD"
}

# DOCKERFILE + NGINX.CONF
generar_dockerfile() {
    log_sep "DOCKERFILE SERVIDOR WEB"

    cat > "$DIR_BUILD/nginx.conf" <<'NGINXEOF'
user  webuser;
worker_processes  auto;
error_log  /var/log/nginx/error.log warn;
pid        /tmp/nginx.pid;
events { worker_connections 1024; }
http {
    server_tokens off;
    include       /etc/nginx/mime.types;
    default_type  application/octet-stream;
    sendfile      on;
    keepalive_timeout 65;
    server {
        listen 80;
        server_name _;
        root  /usr/share/nginx/html;
        index index.html;
        location / { try_files $uri $uri/ =404; }
        add_header X-Content-Type-Options "nosniff" always;
        add_header X-Frame-Options "SAMEORIGIN" always;
        add_header X-XSS-Protection "1; mode=block" always;
    }
}
NGINXEOF

    cat > "$DIR_BUILD/Dockerfile" <<'DOCKEREOF'
FROM nginx:alpine

RUN addgroup -g 1001 webgroup && \
    adduser -u 1001 -G webgroup -s /sbin/nologin -D webuser && \
    mkdir -p /var/cache/nginx/client_temp \
             /var/cache/nginx/proxy_temp \
             /var/cache/nginx/fastcgi_temp \
             /var/cache/nginx/uwsgi_temp \
             /var/cache/nginx/scgi_temp \
             /var/log/nginx && \
    chown -R webuser:webgroup \
        /var/cache/nginx /var/log/nginx /usr/share/nginx/html && \
    chmod -R 755 /var/cache/nginx

COPY nginx.conf  /etc/nginx/nginx.conf
COPY index.html  /usr/share/nginx/html/index.html
COPY estilos.css /usr/share/nginx/html/estilos.css
COPY logo.svg    /usr/share/nginx/html/logo.svg

RUN chown -R webuser:webgroup /usr/share/nginx/html

USER webuser
EXPOSE 80
CMD ["nginx", "-g", "daemon off;"]
DOCKEREOF

    log_ok "Dockerfile y nginx.conf generados."
}

# BUILD IMAGEN WEB
construir_imagen_web() {
    log_sep "BUILD IMAGEN WEB PERSONALIZADA"
    local IMG="imagen_web_sistemas:latest"
    if docker image inspect "$IMG" &>/dev/null; then
        log_info "Imagen '$IMG' ya existe. Omitiendo build."
    else
        log_info "Construyendo imagen personalizada..."
        docker build -t "$IMG" "$DIR_BUILD" --quiet
        log_ok "Imagen '$IMG' construida."
    fi
}

# INICIAR CONTENEDOR WEB
iniciar_contenedor_web() {
    log_sep "CONTENEDOR: $CTR_WEB"
    asegurar_contenedor_sano "$CTR_WEB"
    [[ $(estado_contenedor "$CTR_WEB") == "running" ]] && return 0

    local MNT_WEB
    MNT_WEB="$(docker volume inspect "$VOL_WEB" --format '{{.Mountpoint}}')"
    cp "$DIR_BUILD/index.html" "$DIR_BUILD/estilos.css" "$DIR_BUILD/logo.svg" "$MNT_WEB/"
    chcon -Rt svirt_sandbox_file_t "$MNT_WEB" 2>/dev/null || true

    docker run -d \
        --name    "$CTR_WEB" \
        --network "$RED_DOCKER" \
        --ip      "$IP_WEB" \
        --restart unless-stopped \
        --memory  512m \
        --cpus    0.5 \
        -p        8080:80 \
        -v        "${VOL_WEB}:/usr/share/nginx/html" \
        imagen_web_sistemas:latest >/dev/null

    log_ok "Contenedor '$CTR_WEB' iniciado en $IP_WEB → puerto 8080."
}

# INICIAR CONTENEDOR POSTGRESQL
iniciar_contenedor_postgres() {
    log_sep "CONTENEDOR: $CTR_PG"
    asegurar_contenedor_sano "$CTR_PG"
    [[ $(estado_contenedor "$CTR_PG") == "running" ]] && return 0

    docker run -d \
        --name    "$CTR_PG" \
        --network "$RED_DOCKER" \
        --ip      "$IP_PG" \
        --restart unless-stopped \
        -p        5432:5432 \
        -e        POSTGRES_DB="$PG_DB" \
        -e        POSTGRES_USER="$PG_USER" \
        -e        POSTGRES_PASSWORD="$PG_PASS" \
        -v        "${VOL_DB}:/var/lib/postgresql/data" \
        postgres:15-alpine >/dev/null

    log_ok "Contenedor '$CTR_PG' iniciado en $IP_PG → puerto 5432."
}

esperar_postgres() {
    local max=40 i=0
    log_info "Esperando que PostgreSQL esté completamente listo (máx ${max} intentos × 3s)..."
    while [[ $i -lt $max ]]; do
        local est; est=$(estado_contenedor "$CTR_PG")

        if docker exec "$CTR_PG" pg_isready -U "$PG_USER" -d "$PG_DB" &>/dev/null; then
            if docker exec "$CTR_PG" \
                psql -U "$PG_USER" -d "$PG_DB" -c "SELECT 1" &>/dev/null; then
                log_ok "PostgreSQL listo y aceptando consultas (intento $((i+1)))."
                return 0
            fi
            log_warn "  pg_isready OK pero SELECT 1 aún falla... intento $((i+1))/$max  [estado: ${est}]"
        else
            log_warn "  pg_isready... intento $((i+1))/$max  [estado: ${est}]"
        fi

        (( i++ ))
        sleep 3
    done

    log_error "PostgreSQL no respondió tras $max intentos."
    log_error "--- Log del contenedor ($CTR_PG) ---"
    docker logs --tail 30 "$CTR_PG" 2>&1 || true
    return 1
}

# INICIALIZAR SCHEMA BD
inicializar_schema_bd() {
    log_sep "INICIALIZACIÓN ESQUEMA BD"

    local existe
    existe=$(docker exec "$CTR_PG" psql -U "$PG_USER" -d "$PG_DB" -tAc \
        "SELECT EXISTS(SELECT FROM information_schema.tables \
         WHERE table_schema='public' AND table_name='usuarios');" 2>/dev/null || echo "f")

    if [[ "${existe// /}" == "t" ]]; then
        log_info "Tabla 'usuarios' ya existe. Omitiendo."; return 0
    fi

    local intento=0 max_init=5
    while [[ $intento -lt $max_init ]]; do
        (( intento++ ))
        log_info "Aplicando schema BD (intento $intento/$max_init)..."

        local salida
        salida=$(docker exec -i "$CTR_PG" psql -U "$PG_USER" -d "$PG_DB" 2>&1 <<'SQLEOF'
CREATE TABLE IF NOT EXISTS usuarios (
    id             SERIAL PRIMARY KEY,
    nombre         VARCHAR(100) NOT NULL,
    email          VARCHAR(150) UNIQUE NOT NULL,
    fecha_registro TIMESTAMP DEFAULT CURRENT_TIMESTAMP
);
INSERT INTO usuarios (nombre, email) VALUES
    ('Ana García',   'ana.garcia@sistemas.local'),
    ('Carlos López', 'carlos.lopez@sistemas.local')
ON CONFLICT (email) DO NOTHING;
SQLEOF
        )

        local verifica
        verifica=$(docker exec "$CTR_PG" psql -U "$PG_USER" -d "$PG_DB" -tAc \
            "SELECT EXISTS(SELECT FROM information_schema.tables \
             WHERE table_schema='public' AND table_name='usuarios');" 2>/dev/null || echo "f")

        if [[ "${verifica// /}" == "t" ]]; then
            log_ok "Tabla 'usuarios' creada y verificada (intento $intento)."
            return 0
        fi

        log_warn "Intento $intento fallido: $salida"
        sleep 4
    done

    log_error "No se pudo crear el schema tras $max_init intentos."
    return 1
}

# INICIAR CONTENEDOR FTP
iniciar_contenedor_ftp() {
    log_sep "CONTENEDOR: $CTR_FTP"
    asegurar_contenedor_sano "$CTR_FTP"
    [[ $(estado_contenedor "$CTR_FTP") == "running" ]] && return 0

    docker run -d \
        --name    "$CTR_FTP" \
        --network "$RED_DOCKER" \
        --ip      "$IP_FTP" \
        --restart unless-stopped \
        -p        21:21 \
        -p        21100-21110:21100-21110 \
        -e        FTP_USER="$FTP_USER" \
        -e        FTP_PASS="$FTP_PASS" \
        -e        PASV_ADDRESS="$HOST_IP" \
        -e        PASV_MIN_PORT=21100 \
        -e        PASV_MAX_PORT=21110 \
        -v        "${VOL_WEB}:/home/vsftpd/${FTP_USER}:z" \
        fauria/vsftpd >/dev/null

    log_ok "Contenedor '$CTR_FTP' iniciado en $IP_FTP → puertos 21, 21100-21110."
}

# CRONTAB RESPALDO POSTGRESQL
configurar_crontab_respaldo() {
    log_sep "CRONTAB RESPALDO POSTGRESQL"
    local CRON_CMD="0 * * * * docker exec $CTR_PG pg_dump -U $PG_USER $PG_DB > $DIR_RESPALDOS/backup_\$(date +\\%Y\\%m\\%d_\\%H\\%M\\%S).sql 2>/dev/null"
    local TMP; TMP=$(mktemp)
    crontab -l 2>/dev/null > "$TMP" || true
    if ! grep -q "pg_dump.*$PG_DB" "$TMP"; then
        echo "$CRON_CMD" >> "$TMP"
        crontab "$TMP"
        log_ok "Crontab configurado (pg_dump cada hora → $DIR_RESPALDOS)."
    else
        log_info "Crontab de respaldo ya existe."
    fi
    rm -f "$TMP"
}

# PROTOCOLO DE PRUEBAS

prueba_persistencia_bd() {
    log_sep "PRUEBA 10.1 — PERSISTENCIA DE BD"
    local RES="FAIL"

    if ! esperar_postgres; then
        echo -e "  [PRUEBA 10.1] PERSISTENCIA BD: ${ROJO}FAIL ✘${NC} — PostgreSQL no arrancó."
        return
    fi

    docker exec "$CTR_PG" psql -U "$PG_USER" -d "$PG_DB" \
        -c "INSERT INTO usuarios (nombre, email) \
            VALUES ('Test Persistencia','test.persistencia@sistemas.local') \
            ON CONFLICT (email) DO NOTHING;" &>/dev/null

    log_info "Eliminando contenedor $CTR_PG (volumen $VOL_DB persiste)..."
    docker rm -f "$CTR_PG" >/dev/null

    log_info "Recreando $CTR_PG con el mismo volumen..."
    docker run -d \
        --name    "$CTR_PG" \
        --network "$RED_DOCKER" \
        --ip      "$IP_PG" \
        --restart unless-stopped \
        -p        5432:5432 \
        -e        POSTGRES_DB="$PG_DB" \
        -e        POSTGRES_USER="$PG_USER" \
        -e        POSTGRES_PASSWORD="$PG_PASS" \
        -v        "${VOL_DB}:/var/lib/postgresql/data" \
        postgres:15-alpine >/dev/null

    if ! esperar_postgres; then
        echo -e "  [PRUEBA 10.1] PERSISTENCIA BD: ${ROJO}FAIL ✘${NC} — No arrancó al recrear."
        return
    fi

    local SALIDA
    SALIDA=$(docker exec "$CTR_PG" psql -U "$PG_USER" -d "$PG_DB" \
        -c "SELECT id, nombre, email FROM usuarios;" 2>&1)
    echo "$SALIDA"

    echo "$SALIDA" | grep -q "test.persistencia@sistemas.local" && RES="PASS"
    echo ""
    echo -e "  [PRUEBA 10.1] PERSISTENCIA BD: $(
        [[ $RES == PASS ]] && echo "${VERDE}PASS ✔${NC}" || echo "${ROJO}FAIL ✘${NC}")"
}

prueba_aislamiento_red() {
    log_sep "PRUEBA 10.2 — AISLAMIENTO DE RED"
    local RES="FAIL"
    log_info "Probando conectividad $CTR_WEB ($IP_WEB) → $CTR_PG ($IP_PG)..."

    local SALIDA
    SALIDA=$(docker exec "$CTR_WEB" ping -c 3 -W 2 "$IP_PG" 2>&1 || true)
    echo "$SALIDA"
    echo "$SALIDA" | grep -qE "bytes from|0% packet loss" && RES="PASS"

    if [[ $RES == "FAIL" ]]; then
        log_warn "Ping por IP no tuvo respuesta. Probando por nombre DNS..."
        local SALIDA2
        SALIDA2=$(docker exec "$CTR_WEB" ping -c 3 -W 2 "$CTR_PG" 2>&1 || true)
        echo "$SALIDA2"
        echo "$SALIDA2" | grep -qE "bytes from|0% packet loss" && RES="PASS"
    fi

    echo ""
    echo -e "  [PRUEBA 10.2] AISLAMIENTO DE RED: $(
        [[ $RES == PASS ]] && echo "${VERDE}PASS ✔${NC}" || echo "${ROJO}FAIL ✘${NC}")"
}

prueba_permisos_ftp() {
    log_sep "PRUEBA 10.3 — PERMISOS FTP"
    local RES="FAIL"
    local TMP="/tmp/prueba_ftp.txt"
    local NOMBRE="prueba_ftp.txt"

    echo "Archivo de prueba FTP — $(date)" > "$TMP"
    log_info "Esperando 8s a que vsftpd esté listo..."
    sleep 8

    log_info "Subiendo '$NOMBRE' → ftp://${HOST_IP}/${NOMBRE}"
    local SALIDA_CURL
    SALIDA_CURL=$(curl -s -v \
        -T "$TMP" "ftp://${HOST_IP}/${NOMBRE}" \
        --user "${FTP_USER}:${FTP_PASS}" \
        --ftp-pasv \
        --connect-timeout 10 \
        2>&1 || true)
    echo "$SALIDA_CURL"

    sleep 2
    local MNT_WEB
    MNT_WEB="$(docker volume inspect "$VOL_WEB" --format '{{.Mountpoint}}')"

    if [[ -f "${MNT_WEB}/${NOMBRE}" ]]; then
        RES="PASS"
        log_ok "Archivo confirmado en volumen: ${MNT_WEB}/${NOMBRE}"
    else
        log_warn "Archivo NO encontrado en ${MNT_WEB}/${NOMBRE}"
    fi
    echo ""
    echo -e "  [PRUEBA 10.3] PERMISOS FTP: $(
        [[ $RES == PASS ]] && echo "${VERDE}PASS ✔${NC}" || echo "${ROJO}FAIL ✘${NC}")"
}

prueba_limites_recursos() {
    log_sep "PRUEBA 10.4 — LÍMITES DE RECURSOS"
    log_info "Ejecutando docker stats (instantáneo)..."
    echo ""
    docker stats --no-stream \
        --format "table {{.Name}}\t{{.CPUPerc}}\t{{.MemUsage}}\t{{.NetIO}}\t{{.BlockIO}}"

    echo ""
    local BYTES MIB
    BYTES=$(docker inspect "$CTR_WEB" --format '{{.HostConfig.Memory}}' 2>/dev/null || echo "0")
    MIB=$(( BYTES / 1024 / 1024 ))
    echo -e "  Límite configurado en $CTR_WEB: ${AMARILLO}${MIB} MiB${NC}"
    echo -e "  [PRUEBA 10.4] LÍMITES DE RECURSOS: $(
        [[ $MIB -eq 512 ]] \
        && echo "${VERDE}PASS ✔ — 512 MiB confirmado${NC}" \
        || echo "${ROJO}FAIL ✘ — esperado 512 MiB, encontrado ${MIB} MiB${NC}")"
}

# EJECUCIÓN PRINCIPAL
main() {
    echo ""
    log_sep "INICIO DEL DESPLIEGUE AUTOMATIZADO"
    echo "  Sistema  : Oracle Linux 9.7 · VirtualBox"
    echo "  Host IP  : $HOST_IP"
    echo "  Fecha    : $(date '+%Y-%m-%d %H:%M:%S')"
    echo ""

    instalar_dependencias
    instalar_docker
    configurar_firewall
    crear_volumenes
    crear_red
    preparar_respaldos
    generar_archivos_web
    generar_dockerfile
    construir_imagen_web

    iniciar_contenedor_web
    iniciar_contenedor_postgres

    if ! esperar_postgres; then
        log_error "PostgreSQL no disponible. Ver diagnóstico arriba."
        log_error "Si persiste: docker rm -f $CTR_PG && docker volume rm $VOL_DB && re-ejecutar."
    else
        inicializar_schema_bd
    fi

    iniciar_contenedor_ftp
    configurar_crontab_respaldo

    log_sep "ESPERA DE ESTABILIZACIÓN"
    log_info "Esperando 8 segundos adicionales..."
    sleep 8

    log_sep "ESTADO DE CONTENEDORES"
    docker ps --format "table {{.Names}}\t{{.Status}}\t{{.Ports}}\t{{.Image}}"
    echo ""

    log_sep "INICIO PROTOCOLO DE PRUEBAS"
    prueba_persistencia_bd
    prueba_aislamiento_red
    prueba_permisos_ftp
    prueba_limites_recursos

    log_sep "DESPLIEGUE COMPLETADO"
    echo "  Acceso Web  : http://${HOST_IP}:8080"
    echo "  PostgreSQL  : ${HOST_IP}:5432 | BD: $PG_DB | Usuario: $PG_USER"
    echo "  FTP         : ftp://${HOST_IP}   | Usuario: $FTP_USER"
    echo "  Respaldos   : $DIR_RESPALDOS (crontab cada hora)"
    echo ""
}

main "$@"
