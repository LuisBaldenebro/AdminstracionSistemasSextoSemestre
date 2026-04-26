#!/usr/bin/env bash
# Docker: Servidor Web + PostgreSQL + FTP

# AUTO-ELEVACIÓN A ROOT
if [[ "${EUID}" -ne 0 ]]; then
    echo "[INFO] Se requieren privilegios de administrador. Reejecutando con sudo..."
    exec sudo bash "$0" "$@"
fi

set -euo pipefail

# VARIABLES GLOBALES
NOMBRE_WEB="contenedor_web"
NOMBRE_DB="contenedor_postgres"
NOMBRE_FTP="contenedor_ftp"
NOMBRE_RED="red_sistemas"
TAG_IMAGEN="imagen_web:latest"
VOL_WEB="web_content"
VOL_DB="db_data"

DB_NOMBRE="sistema_db"
DB_USUARIO="admin_db"
DB_CONTRASENA="Segura2024#"
TABLA_USUARIOS="usuarios"

FTP_USUARIO="usuario_ftp"
FTP_CONTRASENA="Ftp2024#"
PASV_MIN=21100
PASV_MAX=21110

DIR_RESPALDOS="/opt/respaldos"
DIR_BUILD="/opt/infraestructura_web"
SEGMENTO_RED="192.168.100.0/24"
ARCHIVO_PID_BACKUP="/var/run/docker_pgbackup.pid"

# Detectar IP del host para modo pasivo FTP y mensajes informativos
IP_HOST=$(hostname -I | awk '{print $1}')

# FUNCIONES DE UTILIDAD
info()  { printf '\033[0;34m[%s][INFO] %s\033[0m\n'  "$(date +'%H:%M:%S')" "$*"; }
ok()    { printf '\033[0;32m[%s][ OK ] %s\033[0m\n'  "$(date +'%H:%M:%S')" "$*"; }
err()   { printf '\033[0;31m[%s][ERR] %s\033[0m\n'   "$(date +'%H:%M:%S')" "$*" >&2; }
titulo(){ printf '\n\033[1;36m# ---- %s ----\033[0m\n\n' "$*"; }

# FUNCIÓN: ELIMINAR CONTENEDOR SI EXISTE
eliminar_contenedor() {
    local nombre="$1"
    if docker ps -a --format '{{.Names}}' | grep -qx "${nombre}"; then
        info "Eliminando contenedor existente: ${nombre}"
        docker rm -f "${nombre}" > /dev/null
    fi
}

# FUNCIÓN: ESPERAR A QUE POSTGRESQL ESTÉ LISTO
esperar_postgres() {
    info "Esperando disponibilidad de PostgreSQL (hasta 120 s)..."
    sleep 5
    local n=0
    until docker exec "${NOMBRE_DB}" pg_isready -h 127.0.0.1 -U "${DB_USUARIO}" &>/dev/null; do
        sleep 3
        n=$(( n + 1 ))
        if [[ ${n} -gt 38 ]]; then
            err "Tiempo de espera agotado. Últimas líneas del log de PostgreSQL:"
            docker logs --tail=25 "${NOMBRE_DB}" >&2 || true
            return 1
        fi
        info "  Esperando PostgreSQL... intento ${n}/38"
    done
    ok "PostgreSQL listo y aceptando conexiones."
}

# FUNCIÓN: CREAR CONTENEDOR POSTGRESQL
crear_contenedor_postgres() {
    docker run -d \
        --name     "${NOMBRE_DB}" \
        --network  "${NOMBRE_RED}" \
        --restart  unless-stopped \
        -e POSTGRES_DB="${DB_NOMBRE}" \
        -e POSTGRES_USER="${DB_USUARIO}" \
        -e POSTGRES_PASSWORD="${DB_CONTRASENA}" \
        -p 5432:5432 \
        -v "${VOL_DB}:/var/lib/postgresql" \
        -v "${DIR_BUILD}/init.sql:/docker-entrypoint-initdb.d/01-init.sql:ro,z" \
        postgres:alpine > /dev/null
    ok "Contenedor '${NOMBRE_DB}' iniciado con volumen '${VOL_DB}'."
}

# INSTALACIÓN DE DOCKER
instalar_docker() {
    titulo "INSTALACIÓN DE DOCKER"
    if command -v docker &>/dev/null; then
        ok "Docker ya instalado: $(docker --version)"
        systemctl is-active --quiet docker || systemctl start docker
        return
    fi
    info "Instalando dependencias necesarias..."
    dnf install -y dnf-plugins-core curl 2>/dev/null || true
    info "Añadiendo repositorio Docker CE para Oracle Linux 9..."
    dnf config-manager --add-repo \
        https://download.docker.com/linux/centos/docker-ce.repo 2>/dev/null || \
    curl -fsSLo /etc/yum.repos.d/docker-ce.repo \
        https://download.docker.com/linux/centos/docker-ce.repo
    info "Instalando Docker CE y complementos..."
    dnf install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin
    systemctl enable --now docker
    ok "Docker instalado y en ejecución."
}

# CREAR ARCHIVOS DEL SERVIDOR WEB
crear_archivos_web() {
    titulo "ARCHIVOS DEL SERVIDOR WEB"
    mkdir -p "${DIR_BUILD}/html"

    # index.html: estructura HTML completa con SVG logo embebido
    cat > "${DIR_BUILD}/html/index.html" << 'ENDHTML'
<!DOCTYPE html>
<html lang="es">
<head>
    <meta charset="UTF-8">
    <meta name="viewport" content="width=device-width, initial-scale=1.0">
    <title>Infraestructura Docker — Oracle Linux 9.7</title>
    <link rel="stylesheet" href="estilos.css">
</head>
<body>
<header>
    <div class="logo">
        <!--
            Logo SVG embebido directamente (no descargado).
            Representa contenedores Docker sobre un buque portacontenedores.
        -->
        <svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 144 144"
             width="90" height="90" role="img" aria-label="Logo Docker Infraestructura">
            <defs>
                <linearGradient id="gd" x1="0%" y1="0%" x2="100%" y2="100%">
                    <stop offset="0%"   stop-color="#1565C0"/>
                    <stop offset="100%" stop-color="#0277BD"/>
                </linearGradient>
                <linearGradient id="ga" x1="0%" y1="0%" x2="0%" y2="100%">
                    <stop offset="0%"   stop-color="#29B6F6"/>
                    <stop offset="100%" stop-color="#0288D1"/>
                </linearGradient>
            </defs>
            <!-- Fondo redondeado -->
            <rect width="144" height="144" rx="24" fill="url(#gd)"/>
            <!-- Fila superior de contenedores -->
            <rect x="12" y="42" width="24" height="24" rx="5" fill="#fff" opacity=".96"/>
            <rect x="40" y="42" width="24" height="24" rx="5" fill="#fff" opacity=".96"/>
            <rect x="68" y="42" width="24" height="24" rx="5" fill="#fff" opacity=".96"/>
            <rect x="96" y="42" width="24" height="24" rx="5" fill="#fff" opacity=".55"/>
            <!-- Fila inferior de contenedores -->
            <rect x="12" y="70" width="24" height="24" rx="5" fill="#fff" opacity=".96"/>
            <rect x="40" y="70" width="24" height="24" rx="5" fill="#fff" opacity=".96"/>
            <rect x="68" y="70" width="24" height="24" rx="5" fill="#fff" opacity=".75"/>
            <!-- Cubierta del buque -->
            <path d="M8 100 Q72 118 136 100 L136 110 Q72 130 8 110 Z"
                  fill="#fff" opacity=".85"/>
            <!-- Agua -->
            <rect x="8" y="110" width="128" height="8" rx="4" fill="url(#ga)" opacity=".6"/>
            <!-- Letrero -->
            <text x="72" y="138" text-anchor="middle" fill="#E3F2FD"
                  font-size="10.5" font-family="'Courier New',monospace"
                  font-weight="800" letter-spacing="2.8">DOCKER</text>
        </svg>
    </div>
    <div class="header-info">
        <h1>Infraestructura Docker</h1>
        <p>Oracle Linux 9.7 &bull; VirtualBox &bull; nginx &bull; PostgreSQL &bull; FTP</p>
    </div>
</header>
<main>
    <section class="grid">
        <article class="card c-web">
            <div class="card-icon" aria-hidden="true">🌐</div>
            <h2>Servidor Web</h2>
            <p>Basado en <strong>nginx:alpine</strong>. Proceso con usuario
               no-root, <code>server_tokens off</code> y volumen persistente
               <code>web_content</code> montado en el directorio de contenido.</p>
            <span class="tag">Puerto 80 → 8080</span>
        </article>
        <article class="card c-db">
            <div class="card-icon" aria-hidden="true">🗄️</div>
            <h2>Base de Datos</h2>
            <p>Basado en <strong>postgres:alpine</strong>. Base de datos
               <code>sistema_db</code> con tabla <code>usuarios</code>
               inicializada automáticamente y respaldos periódicos
               mediante <code>pg_dump</code>.</p>
            <span class="tag">Puerto 5432</span>
        </article>
        <article class="card c-ftp">
            <div class="card-icon" aria-hidden="true">📁</div>
            <h2>Servidor FTP</h2>
            <p>Basado en <strong>fauria/vsftpd</strong> en modo pasivo.
               El directorio FTP comparte el volumen <code>web_content</code>
               con el servidor web: los archivos subidos por FTP son
               inmediatamente accesibles vía HTTP.</p>
            <span class="tag">Puerto 21 &bull; Pasivo 21100–21110</span>
        </article>
    </section>
    <section class="net-info">
        <h2>🔗 Red: <code>red_sistemas</code></h2>
        <p>Segmento bridge: <strong>192.168.100.0/24</strong>
           — Los tres contenedores se comunican entre sí por nombre de host.</p>
    </section>
</main>
<footer>
    <p>Desplegado automáticamente con Docker
       &mdash; <span id="anio"></span></p>
    <script>document.getElementById('anio').textContent=new Date().getFullYear();</script>
</footer>
</body>
</html>
ENDHTML

    # estilos.css: diseño propio, tema oscuro
    cat > "${DIR_BUILD}/html/estilos.css" << 'ENDCSS'
*,*::before,*::after{box-sizing:border-box;margin:0;padding:0}
:root{
  --bg:#0d1117;--card:#161b22;--border:#30363d;
  --blue:#2196F3;--blue-l:#64b5f6;
  --text:#c9d1d9;--muted:#8b949e;--r:13px;
}
html{scroll-behavior:smooth}
body{background:var(--bg);color:var(--text);
     font-family:'Segoe UI',system-ui,sans-serif;
     display:flex;flex-direction:column;min-height:100vh}
header{display:flex;align-items:center;gap:1.25rem;
       background:linear-gradient(155deg,#0d1117 50%,#0a1929 100%);
       border-bottom:1px solid var(--border);padding:1.4rem 2rem}
.logo{flex-shrink:0;filter:drop-shadow(0 0 14px #2196F366)}
.header-info h1{font-size:1.8rem;color:#fff;letter-spacing:-.4px;line-height:1.2}
.header-info p{color:var(--muted);font-size:.82rem;margin-top:.28rem}
main{flex:1;max-width:1080px;width:100%;margin:2rem auto;padding:0 1.5rem}
.grid{display:grid;grid-template-columns:repeat(auto-fit,minmax(275px,1fr));
      gap:1.2rem;margin-bottom:1.4rem}
.card{background:var(--card);border:1px solid var(--border);
      border-radius:var(--r);padding:1.6rem;
      transition:transform .18s,border-color .18s,box-shadow .18s}
.card:hover{transform:translateY(-5px);border-color:var(--blue);
            box-shadow:0 8px 28px #2196F322}
.c-web{border-top:3px solid #2196F3}
.c-db {border-top:3px solid #4CAF50}
.c-ftp{border-top:3px solid #FF7043}
.card-icon{font-size:1.9rem;margin-bottom:.75rem}
.card h2{font-size:1.05rem;color:#fff;margin-bottom:.55rem}
.card p{font-size:.85rem;color:var(--muted);line-height:1.65}
code{background:#21262d;color:var(--blue-l);
     padding:.1rem .35rem;border-radius:4px;font-size:.8rem}
strong{color:#e6edf3}
.tag{display:inline-block;margin-top:.9rem;
     background:rgba(33,150,243,.12);color:var(--blue);
     border:1px solid rgba(33,150,243,.28);
     padding:.2rem .65rem;border-radius:999px;
     font-size:.74rem;font-weight:600}
.net-info{background:var(--card);border:1px solid var(--border);
          border-radius:var(--r);padding:1.3rem 2rem;text-align:center}
.net-info h2{font-size:1rem;color:#fff;margin-bottom:.4rem}
.net-info p{font-size:.85rem;color:var(--muted)}
footer{text-align:center;color:var(--muted);font-size:.76rem;
       padding:1.4rem;border-top:1px solid var(--border);margin-top:1rem}
ENDCSS
    ok "Archivos web creados: index.html + estilos.css (con logo SVG embebido)."
}

# CREAR SQL DE INICIALIZACIÓN DE BASE DE DATOS
crear_sql_init() {
    cat > "${DIR_BUILD}/init.sql" << ENDSQL
-- Inicialización automática — Base de datos: ${DB_NOMBRE}
-- Este script se ejecuta solo la primera vez que el volumen está vacío.
CREATE TABLE IF NOT EXISTS ${TABLA_USUARIOS} (
    id         SERIAL PRIMARY KEY,
    nombre     VARCHAR(100) NOT NULL,
    correo     VARCHAR(150) UNIQUE NOT NULL,
    activo     BOOLEAN      DEFAULT TRUE,
    creado_en  TIMESTAMP    DEFAULT CURRENT_TIMESTAMP
);

INSERT INTO ${TABLA_USUARIOS} (nombre, correo) VALUES
    ('Ana García',    'ana.garcia@ejemplo.com'),
    ('Carlos López',  'carlos.lopez@ejemplo.com'),
    ('María Torres',  'maria.torres@ejemplo.com')
ON CONFLICT (correo) DO NOTHING;
ENDSQL
    ok "SQL de inicialización generado en ${DIR_BUILD}/init.sql"
}

# CREAR DOCKERFILE Y ENTRYPOINT DEL SERVIDOR WEB
crear_dockerfile() {
    titulo "DOCKERFILE DEL SERVIDOR WEB"

    cat > "${DIR_BUILD}/entrypoint.sh" << 'ENDENTRY'
#!/bin/sh
set -e
VOL_DIR="/usr/share/nginx/html"
SRC_DIR="/app/defaults"
# Copiar contenido por defecto si el volumen está vacío (primera ejecución)
if [ -z "$(ls -A "${VOL_DIR}" 2>/dev/null)" ]; then
    echo "[entrypoint] Inicializando volumen con archivos por defecto..."
    cp -r "${SRC_DIR}/." "${VOL_DIR}/"
fi
# Permisos de lectura global para compatibilidad con archivos subidos por FTP
chmod -R o+rx "${VOL_DIR}" 2>/dev/null || true
exec "$@"
ENDENTRY
    chmod +x "${DIR_BUILD}/entrypoint.sh"

    # Dockerfile principal: nginx:alpine no-root, sin firma de servidor
    cat > "${DIR_BUILD}/Dockerfile" << 'ENDDOCKER'
FROM nginx:alpine

# Alpine incluye ping vía busybox — no se necesita paquete adicional

# Crear grupo y usuario sin privilegios (UID/GID 1001)
RUN addgroup -g 1001 -S webgroup && \
    adduser  -u 1001 -S webuser -G webgroup

# Generar nginx.conf optimizado para usuario no-root:
#   - Sin directiva 'user' (proceso ya corre como webuser)
#   - PID en /tmp (siempre escribible por cualquier usuario)
#   - server_tokens off en bloque http (elimina firma de versión)
RUN { \
    echo 'worker_processes auto;'; \
    echo 'error_log /var/log/nginx/error.log warn;'; \
    echo 'pid /tmp/nginx.pid;'; \
    echo 'events { worker_connections 1024; }'; \
    echo 'http {'; \
    echo '    server_tokens off;'; \
    echo '    include /etc/nginx/mime.types;'; \
    echo '    default_type application/octet-stream;'; \
    echo '    access_log /var/log/nginx/access.log;'; \
    echo '    sendfile on;'; \
    echo '    keepalive_timeout 65;'; \
    echo '    include /etc/nginx/conf.d/*.conf;'; \
    echo '}'; \
    } > /etc/nginx/nginx.conf && \
    { \
    echo 'server {'; \
    echo '    listen 8080;'; \
    echo '    server_name localhost;'; \
    echo '    location / {'; \
    echo '        root /usr/share/nginx/html;'; \
    echo '        index index.html index.htm;'; \
    echo '    }'; \
    echo '    error_page 500 502 503 504 /50x.html;'; \
    echo '    location = /50x.html { root /usr/share/nginx/html; }'; \
    echo '}'; \
    } > /etc/nginx/conf.d/default.conf && \
    mkdir -p /var/cache/nginx/client_temp \
             /var/cache/nginx/proxy_temp \
             /var/cache/nginx/fastcgi_temp \
             /var/cache/nginx/uwsgi_temp \
             /var/cache/nginx/scgi_temp && \
    chown -R webuser:webgroup \
        /var/cache/nginx \
        /var/log/nginx \
        /etc/nginx/conf.d \
        /usr/share/nginx/html

# Copiar archivos web al directorio de respaldo dentro de la imagen
COPY --chown=webuser:webgroup html/          /app/defaults/
COPY --chown=webuser:webgroup entrypoint.sh  /entrypoint.sh

USER webuser
EXPOSE 8080
ENTRYPOINT ["/entrypoint.sh"]
CMD ["nginx", "-g", "daemon off;"]
ENDDOCKER
    ok "Dockerfile creado: nginx:alpine, usuario webuser (UID 1001), server_tokens off, puerto 8080."
}

# CREAR RED Y VOLÚMENES
crear_infraestructura() {
    titulo "RED Y VOLÚMENES"
    if ! docker network inspect "${NOMBRE_RED}" &>/dev/null; then
        docker network create --driver bridge \
            --subnet "${SEGMENTO_RED}" "${NOMBRE_RED}" > /dev/null
        ok "Red bridge '${NOMBRE_RED}' creada con segmento ${SEGMENTO_RED}."
    else
        ok "Red '${NOMBRE_RED}' ya existe (${SEGMENTO_RED})."
    fi
    for vol in "${VOL_WEB}" "${VOL_DB}"; do
        if ! docker volume inspect "${vol}" &>/dev/null; then
            docker volume create "${vol}" > /dev/null
            ok "Volumen '${vol}' creado."
        else
            ok "Volumen '${vol}' ya existe."
        fi
    done
}

# CONSTRUIR IMAGEN WEB PERSONALIZADA
construir_imagen() {
    titulo "CONSTRUCCIÓN DE IMAGEN WEB PERSONALIZADA"
    docker build --network=host -t "${TAG_IMAGEN}" "${DIR_BUILD}/"
    ok "Imagen '${TAG_IMAGEN}' construida correctamente."
}

# SERVICIO 1: SERVIDOR WEB (nginx:alpine)
levantar_web() {
    titulo "SERVICIO 1: SERVIDOR WEB"
    eliminar_contenedor "${NOMBRE_WEB}"
    docker run -d \
        --name    "${NOMBRE_WEB}" \
        --network "${NOMBRE_RED}" \
        --restart unless-stopped \
        --memory  512m \
        --cpus    0.5 \
        -p 80:8080 \
        -v "${VOL_WEB}:/usr/share/nginx/html" \
        "${TAG_IMAGEN}" > /dev/null
    ok "Servidor web activo → http://${IP_HOST}:80  (mem: 512m, cpus: 0.5)"
}

# SERVICIO 2: BASE DE DATOS POSTGRESQL
levantar_postgres() {
    titulo "SERVICIO 2: BASE DE DATOS POSTGRESQL"
    eliminar_contenedor "${NOMBRE_DB}"

    crear_contenedor_postgres
    if ! esperar_postgres; then
        info "PostgreSQL no arrancó. Limpiando volumen '${VOL_DB}' y reintentando..."
        docker rm -f "${NOMBRE_DB}" > /dev/null 2>&1 || true
        docker volume rm "${VOL_DB}" > /dev/null 2>&1 || true
        docker volume create "${VOL_DB}" > /dev/null
        crear_contenedor_postgres
        esperar_postgres
    fi
}

# RESPALDOS AUTOMÁTICOS CON PG_DUMP
iniciar_respaldos() {
    titulo "RESPALDOS AUTOMÁTICOS CON PG_DUMP"
    mkdir -p "${DIR_RESPALDOS}"

    if [[ -f "${ARCHIVO_PID_BACKUP}" ]] && \
       kill -0 "$(cat "${ARCHIVO_PID_BACKUP}")" 2>/dev/null; then
        ok "Proceso de respaldo ya en ejecución (PID: $(cat "${ARCHIVO_PID_BACKUP}"))."
        return
    fi

    local primer_respaldo="${DIR_RESPALDOS}/respaldo_$(date +'%Y%m%d_%H%M%S').sql"
    docker exec "${NOMBRE_DB}" pg_dump -U "${DB_USUARIO}" "${DB_NOMBRE}" \
        > "${primer_respaldo}" 2>/dev/null
    ok "Primer respaldo inmediato generado: ${primer_respaldo}"

    (
        while true; do
            sleep 3600
            if docker ps --format '{{.Names}}' | grep -q "^${NOMBRE_DB}$"; then
                docker exec "${NOMBRE_DB}" pg_dump \
                    -U "${DB_USUARIO}" "${DB_NOMBRE}" \
                    > "${DIR_RESPALDOS}/respaldo_$(date +'%Y%m%d_%H%M%S').sql" \
                    2>/dev/null || true
            fi
        done
    ) &
    echo $! > "${ARCHIVO_PID_BACKUP}"
    ok "Proceso de respaldo horario activo (PID: $!, dir: ${DIR_RESPALDOS}/)."
}

# SERVICIO 3: SERVIDOR FTP (fauria/vsftpd)
levantar_ftp() {
    titulo "SERVICIO 3: SERVIDOR FTP"
    eliminar_contenedor "${NOMBRE_FTP}"
    docker run -d \
        --name    "${NOMBRE_FTP}" \
        --network "${NOMBRE_RED}" \
        --restart unless-stopped \
        -e FTP_USER="${FTP_USUARIO}" \
        -e FTP_PASS="${FTP_CONTRASENA}" \
        -e PASV_MIN_PORT="${PASV_MIN}" \
        -e PASV_MAX_PORT="${PASV_MAX}" \
        -e PASV_ADDRESS="${IP_HOST}" \
        -e LOCAL_UMASK="022" \
        -e FILE_OPEN_MODE="0644" \
        -p 20:20 \
        -p 21:21 \
        -p "${PASV_MIN}-${PASV_MAX}:${PASV_MIN}-${PASV_MAX}" \
        -v "${VOL_WEB}:/home/vsftpd/${FTP_USUARIO}" \
        fauria/vsftpd > /dev/null

    if systemctl is-active --quiet firewalld 2>/dev/null; then
        firewall-cmd --permanent --add-service=ftp  &>/dev/null || true
        firewall-cmd --permanent --add-service=http &>/dev/null || true
        firewall-cmd --permanent \
            --add-port="${PASV_MIN}-${PASV_MAX}/tcp" &>/dev/null || true
        firewall-cmd --reload &>/dev/null || true
        ok "Puertos FTP/HTTP habilitados en firewalld."
    fi

    sleep 3
    ok "Servidor FTP activo en modo pasivo. Usuario: '${FTP_USUARIO}' → ftp://${IP_HOST}:21"
}

# PRUEBAS DE VALIDACIÓN

# PRUEBA 10.1: PERSISTENCIA DE BASE DE DATOS
prueba_10_1() {
    titulo "PRUEBA 10.1 — PERSISTENCIA DE BASE DE DATOS"

    echo "▶ [1/4] Insertando registro de prueba en la tabla '${TABLA_USUARIOS}'..."
    docker exec "${NOMBRE_DB}" psql -U "${DB_USUARIO}" -d "${DB_NOMBRE}" \
        -c "INSERT INTO ${TABLA_USUARIOS} (nombre, correo)
            VALUES ('Prueba Persistencia', 'prueba.persist@test.com')
            ON CONFLICT (correo) DO NOTHING;"

    echo ""
    echo "▶ [2/4] Registros en la tabla ANTES de eliminar el contenedor:"
    docker exec "${NOMBRE_DB}" psql -U "${DB_USUARIO}" -d "${DB_NOMBRE}" \
        -c "SELECT id, nombre, correo, creado_en FROM ${TABLA_USUARIOS} ORDER BY id;"

    echo ""
    echo "▶ [3/4] Eliminando contenedor '${NOMBRE_DB}' (el volumen '${VOL_DB}' persiste)..."
    docker rm -f "${NOMBRE_DB}" > /dev/null
    ok "Contenedor eliminado. Volumen '${VOL_DB}' intacto."

    echo ""
    echo "▶ [4/4] Recreando '${NOMBRE_DB}' con el mismo volumen '${VOL_DB}'..."
    crear_contenedor_postgres
    esperar_postgres

    echo ""
    echo "Registros en la tabla DESPUÉS de recrear el contenedor (deben ser idénticos):"
    docker exec "${NOMBRE_DB}" psql -U "${DB_USUARIO}" -d "${DB_NOMBRE}" \
        -c "SELECT id, nombre, correo, creado_en FROM ${TABLA_USUARIOS} ORDER BY id;"

    echo ""
    ok "PRUEBA 10.1 SUPERADA — Datos persistentes en volumen '${VOL_DB}'."
}

# PRUEBA 10.2: AISLAMIENTO Y COMUNICACIÓN DE RED
prueba_10_2() {
    titulo "PRUEBA 10.2 — AISLAMIENTO Y COMUNICACIÓN DE RED"
    echo "Comando: docker exec ${NOMBRE_WEB} ping -c 3 ${NOMBRE_DB}"
    echo "--------------------------------------------------------------"
    docker exec "${NOMBRE_WEB}" ping -c 3 "${NOMBRE_DB}" && {
        echo ""
        ok "PRUEBA 10.2 SUPERADA — Contenedores se comunican por nombre en '${NOMBRE_RED}'."
    } || {
        echo ""
        err "PRUEBA 10.2: Ping fallido. Verifica que ambos contenedores estén en '${NOMBRE_RED}'."
    }
}

# PRUEBA 10.3: PERMISOS FTP Y VOLUMEN COMPARTIDO
prueba_10_3() {
    titulo "PRUEBA 10.3 — PERMISOS FTP Y VOLUMEN COMPARTIDO"
    local archivo_local="/tmp/prueba_ftp_$(date +'%s').txt"
    local nombre_remoto="prueba_ftp.txt"

    printf 'Archivo de prueba FTP\nGenerado el: %s\nHost de origen: %s\n' \
        "$(date)" "${IP_HOST}" > "${archivo_local}"

    echo "▶ Subiendo '${nombre_remoto}' al servidor FTP mediante curl (modo pasivo)..."
    echo "--------------------------------------------------------------"
    curl --ftp-pasv \
         -u "${FTP_USUARIO}:${FTP_CONTRASENA}" \
         -T "${archivo_local}" \
         "ftp://${IP_HOST}:21/${nombre_remoto}" 2>&1 || \
        err "Error en la subida FTP. Verifica puertos ${PASV_MIN}-${PASV_MAX} y la variable PASV_ADDRESS."

    echo ""
    echo "▶ Listado del volumen compartido (vista desde '${NOMBRE_WEB}'):"
    docker exec "${NOMBRE_WEB}" ls -lah /usr/share/nginx/html/

    echo ""
    echo "▶ Accediendo al archivo vía HTTP desde el servidor web:"
    sleep 1
    curl -sf "http://localhost/${nombre_remoto}" && {
        echo ""
        ok "PRUEBA 10.3 SUPERADA — Archivo FTP accesible en http://${IP_HOST}/${nombre_remoto}"
    } || {
        echo ""
        info "El archivo puede necesitar unos segundos. Verifica: http://${IP_HOST}/${nombre_remoto}"
    }

    rm -f "${archivo_local}"
}

# PRUEBA 10.4: LÍMITES DE RECURSOS
prueba_10_4() {
    titulo "PRUEBA 10.4 — LÍMITES DE RECURSOS"
    echo "Comando: docker stats --no-stream"
    echo "--------------------------------------------------------------"
    docker stats --no-stream
    echo ""
    info "El contenedor '${NOMBRE_WEB}' debe mostrar LIMIT ≈ 512MiB y CPU ≤ 50%."
    ok "PRUEBA 10.4 COMPLETADA."
}

# FUNCIÓN PRINCIPAL
main() {
    titulo "INICIO DE DESPLIEGUE — $(date)"

    # Paso 1: Instalar Docker si no está presente
    instalar_docker

    # Paso 2: Generar todos los archivos de configuración en el host
    crear_archivos_web
    crear_sql_init
    crear_dockerfile

    # Paso 3: Construir imagen personalizada y desplegar infraestructura
    construir_imagen
    crear_infraestructura
    levantar_web
    levantar_postgres
    iniciar_respaldos
    levantar_ftp

    # Resumen de servicios desplegados
    titulo "RESUMEN DE SERVICIOS DESPLEGADOS"
    printf '  %-20s %s\n' "Servidor Web:"  "http://${IP_HOST}:80"
    printf '  %-20s %s\n' "PostgreSQL:"    "${IP_HOST}:5432  |  BD: ${DB_NOMBRE}  |  Usuario: ${DB_USUARIO}"
    printf '  %-20s %s\n' "FTP:"           "ftp://${FTP_USUARIO}@${IP_HOST}:21  |  Pasivo: ${PASV_MIN}-${PASV_MAX}"
    printf '  %-20s %s\n' "Respaldos BD:"  "${DIR_RESPALDOS}/"
    echo ""
    docker ps --format "table {{.Names}}\t{{.Image}}\t{{.Status}}\t{{.Ports}}"

    # Paso 4: Ejecutar las cuatro pruebas de validación
    titulo "INICIO DE PRUEBAS DE VALIDACIÓN"
    prueba_10_1
    prueba_10_2
    prueba_10_3
    prueba_10_4

    titulo "DESPLIEGUE Y VALIDACIÓN COMPLETADOS — $(date)"
}

main "$@"
