#!/bin/bash
# ============================================================
#   AUTOMATIZACIÓN SERVIDOR FTP - ORACLE LINUX 9.7 (vsftpd)
#   Gestión completa: instalación, usuarios, permisos, grupos
#   Versión 1.0 | Requiere: root / sudo
# ============================================================

# ── Colores ──────────────────────────────────────────────────
ROJO='\033[0;31m'
VERDE='\033[0;32m'
AMARILLO='\033[1;33m'
AZUL='\033[0;34m'
CYAN='\033[0;36m'
MAGENTA='\033[0;35m'
BLANCO='\033[1;37m'
NC='\033[0m'

# ── Rutas y constantes ────────────────────────────────────────
FTP_BASE="/srv/ftp"
FTP_ANON="$FTP_BASE/anon"
FTP_DATA="$FTP_BASE/data"
FTP_HOMES="$FTP_BASE/homes"
VSFTPD_CONF="/etc/vsftpd/vsftpd.conf"
USER_CONF_DIR="/etc/vsftpd/user_conf"
GRUPO_1="reprobados"
GRUPO_2="recursadores"
GRUPO_FTP="ftplocales"
LOG_FILE="/var/log/ftp_admin.log"
FSTAB_MARKER="# FTP_BIND_MOUNT"

# ── Funciones de utilidad ─────────────────────────────────────

registrar_log() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $1" >> "$LOG_FILE"
}

encabezado() {
    clear
    echo -e "${AZUL}╔══════════════════════════════════════════════════════════╗${NC}"
    echo -e "${AZUL}║${BLANCO}       SERVIDOR FTP - ORACLE LINUX 9.7 (vsftpd)          ${AZUL}║${NC}"
    echo -e "${AZUL}╚══════════════════════════════════════════════════════════╝${NC}"
    echo ""
}

mensaje_ok() {
    echo -e "${VERDE}  ✔  $1${NC}"
    registrar_log "OK: $1"
}

mensaje_error() {
    echo -e "${ROJO}  ✘  $1${NC}"
    registrar_log "ERROR: $1"
}

mensaje_info() {
    echo -e "${CYAN}  ℹ  $1${NC}"
}

mensaje_advertencia() {
    echo -e "${AMARILLO}  ⚠  $1${NC}"
    registrar_log "ADVERTENCIA: $1"
}

separador() {
    echo -e "${AZUL}──────────────────────────────────────────────────────────${NC}"
}

pausar() {
    echo ""
    read -rp "  Presione [Enter] para continuar..."
}

verificar_root() {
    if [[ $EUID -ne 0 ]]; then
        echo -e "${ROJO}  ✘  Este script debe ejecutarse como root o con sudo.${NC}"
        exit 1
    fi
}

# ── 1. INSTALACIÓN DE vsftpd ──────────────────────────────────

# ── Funcion: crear archivo PAM propio para vsftpd ─────────────
# Crea /etc/pam.d/vsftpd-local con solo pam_unix (sin pam_shells)
# Esto evita que PAM rechace usuarios con shell /sbin/nologin
corregir_pam_vsftpd() {
    # Crear PAM minimo: solo pam_unix.so
    # - Sin pam_shells  (rechaza /bin/bash si no esta en /etc/shells de vsftpd)
    # - Sin pam_faillock (bloquea cuentas tras intentos fallidos remotos)
    # - Sin pam_loginuid (falla en VMs)
    cat > /etc/pam.d/vsftpd-local << 'PAMCONF'
#%PAM-1.0
auth    required  pam_unix.so  nullok
account required  pam_unix.so
PAMCONF
    chmod 644 /etc/pam.d/vsftpd-local

    # Resetear faillock global para todos los usuarios FTP
    # (faillock bloquea tras 3 intentos fallidos - causa el 530 remoto)
    if getent group ftplocales &>/dev/null; then
        for u in $(getent group ftplocales | cut -d: -f4 | tr ',' ' '); do
            [ -n "$u" ] && faillock --user "$u" --reset 2>/dev/null || true
        done
    fi

    # Deshabilitar pam_faillock globalmente en /etc/security/faillock.conf
    # para que no bloquee de nuevo tras futuros intentos fallidos
    if [ -f /etc/security/faillock.conf ]; then
        # Aumentar el limite a un numero muy alto (practica entorno educativo)
        if grep -q "^deny" /etc/security/faillock.conf 2>/dev/null; then
            sed -i 's/^deny\s*=.*/deny = 999/' /etc/security/faillock.conf
        else
            echo "deny = 999" >> /etc/security/faillock.conf
        fi
    fi
}

instalar_vsftpd() {
    encabezado
    echo -e "${BLANCO}  [ INSTALACIÓN E IDEMPOTENCIA DE vsftpd ]${NC}"
    separador

    # Verificar si ya está instalado
    if rpm -q vsftpd &>/dev/null; then
        mensaje_advertencia "vsftpd ya está instalado. Verificando configuración..."
    else
        mensaje_info "Actualizando repositorios..."
        dnf check-update -y &>/dev/null
        mensaje_info "Instalando vsftpd..."
        if dnf install -y vsftpd &>/dev/null; then
            mensaje_ok "vsftpd instalado correctamente."
        else
            mensaje_error "Error al instalar vsftpd. Verifique su conexión y repositorios."
            pausar; return 1
        fi
    fi

    # Instalar herramientas necesarias
    mensaje_info "Instalando herramientas auxiliares (acl, bind-utils)..."
    dnf install -y acl bind-utils policycoreutils-python-utils &>/dev/null
    mensaje_ok "Herramientas auxiliares listas."

    # Crear estructura de directorios
    mensaje_info "Creando estructura de directorios FTP..."
    mkdir -p "$FTP_ANON/general"
    mkdir -p "$FTP_DATA/general"
    mkdir -p "$FTP_DATA/$GRUPO_1"
    mkdir -p "$FTP_DATA/$GRUPO_2"
    mkdir -p "$FTP_DATA/usuarios"
    mkdir -p "$FTP_HOMES"
    mkdir -p "$USER_CONF_DIR"
    mensaje_ok "Estructura de directorios creada en $FTP_BASE."

    # Crear grupos del sistema
    for grupo in "$GRUPO_1" "$GRUPO_2" "$GRUPO_FTP"; do
        if ! getent group "$grupo" &>/dev/null; then
            groupadd "$grupo"
            mensaje_ok "Grupo '$grupo' creado."
        else
            mensaje_advertencia "Grupo '$grupo' ya existe."
        fi
    done

    # Permisos de directorios de datos
    chown root:root "$FTP_ANON"
    chmod 755 "$FTP_ANON"
    chown root:"$GRUPO_FTP" "$FTP_ANON/general"
    chmod 755 "$FTP_ANON/general"

    # Montar data/general en anon/general: el anonimo ve lo que suben los usuarios
    if ! mountpoint -q "$FTP_ANON/general" 2>/dev/null; then
        mount --bind "$FTP_DATA/general" "$FTP_ANON/general"
    fi
    # Persistir en fstab
    if ! grep -qF "$FTP_ANON/general" /etc/fstab 2>/dev/null; then
        echo "$FTP_DATA/general $FTP_ANON/general none bind 0 0" >> /etc/fstab
    fi
    # SELinux: el bind mount necesita contexto publico para que vsftpd sirva los archivos
    chcon -R -t public_content_t "$FTP_DATA/general" &>/dev/null || true
    semanage fcontext -a -t public_content_t "$FTP_DATA/general(/.*)?" &>/dev/null || true
    restorecon -Rv "$FTP_ANON/general" &>/dev/null || true

    chown root:"$GRUPO_FTP" "$FTP_DATA/general"
    chmod 2775 "$FTP_DATA/general"    # setgid: archivos nuevos heredan grupo ftplocales

    chown root:"$GRUPO_1" "$FTP_DATA/$GRUPO_1"
    chmod 2770 "$FTP_DATA/$GRUPO_1"   # setgid: archivos nuevos heredan grupo reprobados

    chown root:"$GRUPO_2" "$FTP_DATA/$GRUPO_2"
    chmod 2770 "$FTP_DATA/$GRUPO_2"   # setgid: archivos nuevos heredan grupo recursadores

    # ACL por defecto para que archivos nuevos hereden el grupo
    setfacl -d -m g:"$GRUPO_FTP":rwx "$FTP_DATA/general"
    setfacl -d -m g:"$GRUPO_1":rwx  "$FTP_DATA/$GRUPO_1"
    setfacl -d -m g:"$GRUPO_2":rwx  "$FTP_DATA/$GRUPO_2"
    mensaje_ok "Permisos y ACL de datos configurados."

    # Configurar vsftpd.conf
    mensaje_info "Generando /etc/vsftpd/vsftpd.conf..."
    cp -f "$VSFTPD_CONF" "${VSFTPD_CONF}.bak.$(date +%s)" 2>/dev/null

    cat > "$VSFTPD_CONF" << 'CONF'
# vsftpd.conf | Generado automaticamente por servidor_ftp_linux.sh

# Modo de ejecucion
listen=YES
listen_ipv6=NO
background=YES

# Acceso anonimo (solo lectura a /anon)
anonymous_enable=YES
no_anon_password=YES
anon_root=/srv/ftp/anon
anon_upload_enable=NO
anon_mkdir_write_enable=NO
anon_other_write_enable=NO

# Usuarios locales autenticados
local_enable=YES
write_enable=YES
local_umask=022

# Lista de usuarios DENEGADOS (usuarios del sistema que NO pueden usar FTP)
userlist_enable=YES
userlist_deny=YES
userlist_file=/etc/vsftpd/user_deny.list

# Chroot: aislar cada usuario en su directorio home
chroot_local_user=YES
allow_writeable_chroot=YES
user_config_dir=/etc/vsftpd/user_conf
user_sub_token=$USER
local_root=/srv/ftp/homes/$USER

# FTP pasivo
pasv_enable=YES
pasv_min_port=30000
pasv_max_port=31000
# pasv_address se configura automaticamente por el script al iniciar

# Logs
xferlog_enable=YES
xferlog_file=/var/log/vsftpd.log
xferlog_std_format=NO
log_ftp_protocol=YES
vsftpd_log_file=/var/log/vsftpd_detail.log

# Seguridad
tcp_wrappers=NO
ftpd_banner=Servidor FTP Educativo
hide_ids=YES
ls_recurse_enable=NO
ascii_upload_enable=NO
ascii_download_enable=NO

# Compatibilidad: mostrar archivos ocultos
force_dot_files=YES

# PAM: usar archivo propio sin restriccion de shell
# Esto evita el error "530 Login incorrect" con usuarios nologin
pam_service_name=vsftpd-local

# Tiempo de espera y conexiones
idle_session_timeout=600
data_connection_timeout=120
max_clients=50
max_per_ip=5
CONF

    mensaje_ok "vsftpd.conf configurado."

    # Asegurar force_dot_files
    grep -q "^force_dot_files" "$VSFTPD_CONF" 2>/dev/null || echo "force_dot_files=YES" >> "$VSFTPD_CONF"
    # Eliminar utf8=NO (directiva invalida de versiones anteriores del script)
    sed -i '/^utf8=NO/d' "$VSFTPD_CONF" 2>/dev/null || true
    # Asegurar pam_service_name=vsftpd-local
    if grep -q "^pam_service_name" "$VSFTPD_CONF" 2>/dev/null; then
        sed -i 's|^pam_service_name=.*|pam_service_name=vsftpd-local|' "$VSFTPD_CONF"
    else
        echo "pam_service_name=vsftpd-local" >> "$VSFTPD_CONF"
    fi
    # Configurar pasv_address con la IP real del servidor
    # Esto es CRITICO para que el modo pasivo funcione desde clientes remotos
    SERVIDOR_IP=$(hostname -I | awk '"'"'{print $1}'"'"')
    if [ -n "$SERVIDOR_IP" ]; then
        if grep -q "^pasv_address" "$VSFTPD_CONF" 2>/dev/null; then
            sed -i "s|^pasv_address=.*|pasv_address=$SERVIDOR_IP|" "$VSFTPD_CONF"
        else
            echo "pasv_address=$SERVIDOR_IP" >> "$VSFTPD_CONF"
        fi
        mensaje_ok "IP del servidor configurada para modo pasivo: $SERVIDOR_IP"
    fi

    # Crear lista de usuarios denegados (usuarios del sistema)
    cat > /etc/vsftpd/user_deny.list << 'EOF'
root
bin
daemon
adm
lp
sync
shutdown
halt
mail
operator
games
nobody
systemd-network
systemd-resolve
tss
polkitd
unbound
sssd
chrony
EOF
    mensaje_ok "Lista de usuarios denegados configurada."

    # Configurar SELinux
    mensaje_info "Configurando SELinux para vsftpd..."
    setsebool -P ftpd_full_access 1 &>/dev/null || true
    setsebool -P ftp_home_dir 1   &>/dev/null || true
    # Contexto SELinux para los directorios FTP
    semanage fcontext -a -t public_content_rw_t "$FTP_DATA(/.*)?" &>/dev/null || true
    semanage fcontext -a -t public_content_t    "$FTP_ANON(/.*)?" &>/dev/null || true
    restorecon -Rv "$FTP_BASE" &>/dev/null || true
    mensaje_ok "SELinux configurado."

    # Crear archivo PAM propio y migrar usuarios existentes a /bin/bash
    corregir_pam_vsftpd
    mensaje_ok "PAM configurado (vsftpd-local)."

    # Migrar usuarios existentes: shell, faillock, cuenta bloqueada
    if getent group ftplocales &>/dev/null; then
        for u in $(getent group ftplocales | cut -d: -f4 | tr ',' ' '); do
            [ -z "$u" ] && continue
            # Corregir shell
            if [ "$(getent passwd "$u" | cut -d: -f7)" != "/bin/bash" ]; then
                usermod -s /bin/bash "$u" 2>/dev/null
                mensaje_ok "Shell de '$u' corregida a /bin/bash."
            fi
            # Resetear faillock (desbloquear cuenta si fue bloqueada por intentos fallidos)
            faillock --user "$u" --reset 2>/dev/null || true
            usermod -U "$u" 2>/dev/null || true
            chage -E -1 "$u" 2>/dev/null || true
            mensaje_ok "Cuenta '$u': desbloqueada y lista."
        done
    fi

    # Configurar firewall
    mensaje_info "Configurando firewalld..."

    # Instalar firewalld si no está presente
    if ! rpm -q firewalld &>/dev/null; then
        mensaje_info "Instalando firewalld..."
        dnf install -y firewalld &>/dev/null && \
            mensaje_ok "firewalld instalado." || \
            { mensaje_error "No se pudo instalar firewalld."; }
    fi

    # Habilitar e iniciar firewalld si no está activo
    if ! systemctl is-enabled --quiet firewalld 2>/dev/null; then
        systemctl enable firewalld &>/dev/null
    fi
    if ! systemctl is-active --quiet firewalld 2>/dev/null; then
        mensaje_info "Iniciando firewalld..."
        systemctl start firewalld &>/dev/null
        sleep 2
    fi

    # Aplicar reglas
    if systemctl is-active --quiet firewalld; then
        firewall-cmd --permanent --add-service=ftp          &>/dev/null
        firewall-cmd --permanent --add-port=30000-31000/tcp &>/dev/null
        firewall-cmd --reload &>/dev/null
        mensaje_ok "Firewall configurado (puerto 21 y 30000-31000)."

    # Bloquear SSH para usuarios FTP (tienen /bin/bash pero no deben entrar por SSH)
    if ! grep -q "DenyGroups.*ftplocales" /etc/ssh/sshd_config 2>/dev/null; then
        echo "" >> /etc/ssh/sshd_config
        echo "# Usuarios FTP bloqueados de SSH (solo acceso por vsftpd)" >> /etc/ssh/sshd_config
        echo "DenyGroups ftplocales" >> /etc/ssh/sshd_config
        systemctl restart sshd &>/dev/null || true
    fi
    mensaje_ok "SSH bloqueado para grupo ftplocales."
    else
        # Fallback: usar iptables directamente si firewalld no puede iniciar
        mensaje_advertencia "firewalld no disponible. Aplicando reglas con iptables..."
        if command -v iptables &>/dev/null; then
            iptables -I INPUT -p tcp --dport 21          -j ACCEPT 2>/dev/null
            iptables -I INPUT -p tcp --dport 30000:31000 -j ACCEPT 2>/dev/null
            # Guardar reglas persistentes
            if command -v iptables-save &>/dev/null; then
                iptables-save > /etc/iptables/rules.v4 2>/dev/null || \
                iptables-save > /etc/sysconfig/iptables 2>/dev/null || true
            fi
            mensaje_ok "Reglas aplicadas con iptables (puerto 21 y 30000-31000)."
        else
            mensaje_advertencia "Sin firewall activo. El FTP funciona pero considera configurar el firewall."
        fi
    fi

    # Habilitar y arrancar vsftpd
    mensaje_info "Habilitando e iniciando vsftpd..."
    systemctl enable vsftpd &>/dev/null
    systemctl restart vsftpd

    if systemctl is-active --quiet vsftpd; then
        mensaje_ok "vsftpd en ejecución correctamente."
    else
        mensaje_error "vsftpd no pudo iniciarse. Revise: journalctl -xe"
    fi

    separador
    mensaje_ok "Instalación y configuración completadas."
    pausar
}

# ── 2. VERIFICAR INSTALACIÓN ──────────────────────────────────

verificar_instalacion() {
    encabezado
    echo -e "${BLANCO}  [ VERIFICACIÓN DE LA INSTALACIÓN ]${NC}"
    separador

    # vsftpd instalado
    if rpm -q vsftpd &>/dev/null; then
        VERS=$(rpm -q --qf '%{VERSION}' vsftpd)
        mensaje_ok "vsftpd instalado (versión $VERS)."
    else
        mensaje_error "vsftpd NO está instalado."
    fi

    # Servicio activo
    if systemctl is-active --quiet vsftpd; then
        mensaje_ok "Servicio vsftpd: ACTIVO"
    else
        mensaje_error "Servicio vsftpd: INACTIVO"
    fi

    # Habilitado en arranque
    if systemctl is-enabled --quiet vsftpd; then
        mensaje_ok "vsftpd habilitado en el arranque."
    else
        mensaje_advertencia "vsftpd NO está habilitado en el arranque."
    fi

    # Puerto 21 escuchando
    if ss -tlnp | grep -q ':21 '; then
        mensaje_ok "Puerto 21 escuchando."
    else
        mensaje_error "Puerto 21 NO está escuchando."
    fi

    # Directorios base
    for dir in "$FTP_ANON/general" "$FTP_DATA/general" \
               "$FTP_DATA/$GRUPO_1" "$FTP_DATA/$GRUPO_2" \
               "$FTP_HOMES" "$USER_CONF_DIR"; do
        if [[ -d "$dir" ]]; then
            mensaje_ok "Directorio existe: $dir"
        else
            mensaje_error "Directorio FALTANTE: $dir"
        fi
    done

    # Grupos del sistema
    for grupo in "$GRUPO_1" "$GRUPO_2" "$GRUPO_FTP"; do
        if getent group "$grupo" &>/dev/null; then
            mensaje_ok "Grupo '$grupo' existe."
        else
            mensaje_error "Grupo '$grupo' NO existe."
        fi
    done

    # Reglas de firewall
    separador
    echo -e "${CYAN}  Reglas activas del firewall:${NC}"
    if systemctl is-active --quiet firewalld; then
        firewall-cmd --list-services 2>/dev/null | grep -q ftp && \
            mensaje_ok "Servicio FTP habilitado en firewalld." || \
            mensaje_advertencia "FTP no habilitado en firewalld."
        firewall-cmd --list-ports 2>/dev/null | grep -q '30000' && \
            mensaje_ok "Puertos pasivos 30000-31000 habilitados." || \
            mensaje_advertencia "Puertos pasivos no habilitados."
    else
        mensaje_advertencia "firewalld no está activo."
    fi

    # Usuarios FTP creados
    separador
    echo -e "${CYAN}  Usuarios FTP registrados:${NC}"
    FTPUSERS=$(getent group "$GRUPO_FTP" | cut -d: -f4)
    if [[ -z "$FTPUSERS" ]]; then
        mensaje_info "No hay usuarios FTP creados aún."
    else
        IFS=',' read -ra LISTA <<< "$FTPUSERS"
        for u in "${LISTA[@]}"; do
            GRUPO_ASIGNADO=""
            getent group "$GRUPO_1" | grep -qw "$u" && GRUPO_ASIGNADO="$GRUPO_1"
            getent group "$GRUPO_2" | grep -qw "$u" && GRUPO_ASIGNADO="$GRUPO_2"
            echo -e "    ${VERDE}→${NC} $u  ${AMARILLO}[$GRUPO_ASIGNADO]${NC}"
        done
    fi

    pausar
}

# ── 3. MONTAR DIRECTORIOS DE USUARIO (bind mounts) ────────────

montar_usuario() {
    local usuario="$1"
    local grupo="$2"
    local HOME_USR="$FTP_HOMES/$usuario"

    # Crear punto de montaje chroot (root lo posee, no escribible por user)
    mkdir -p "$HOME_USR"
    chown root:root "$HOME_USR"
    chmod 755 "$HOME_USR"

    # Crear directorios dentro del chroot
    mkdir -p "$HOME_USR/general"
    mkdir -p "$HOME_USR/$grupo"
    mkdir -p "$HOME_USR/$usuario"

    # Montar solo si no está montado
    if ! mountpoint -q "$HOME_USR/general"; then
        mount --bind "$FTP_DATA/general" "$HOME_USR/general"
        # Permisos en el punto de montaje para que el usuario pueda leer/escribir
        chown "$usuario":"$GRUPO_FTP" "$HOME_USR/general"
        chmod 775 "$HOME_USR/general"
    fi
    if ! mountpoint -q "$HOME_USR/$grupo"; then
        mount --bind "$FTP_DATA/$grupo"   "$HOME_USR/$grupo"
    fi
    if ! mountpoint -q "$HOME_USR/$usuario"; then
        mount --bind "$FTP_DATA/usuarios/$usuario" "$HOME_USR/$usuario"
    fi

    # Persistir en /etc/fstab (evitar duplicados)
    for entrada in \
        "$FTP_DATA/general $HOME_USR/general none bind 0 0 $FSTAB_MARKER:$usuario" \
        "$FTP_DATA/$grupo $HOME_USR/$grupo none bind 0 0 $FSTAB_MARKER:$usuario" \
        "$FTP_DATA/usuarios/$usuario $HOME_USR/$usuario none bind 0 0 $FSTAB_MARKER:$usuario"
    do
        SRC=$(echo "$entrada" | awk '{print $1}')
        DST=$(echo "$entrada" | awk '{print $2}')
        if ! grep -qF "$DST" /etc/fstab; then
            echo "$entrada" >> /etc/fstab
        fi
    done

    # Configuración per-user de vsftpd
    echo "local_root=$HOME_USR" > "$USER_CONF_DIR/$usuario"
}

desmontar_usuario() {
    local usuario="$1"
    local HOME_USR="$FTP_HOMES/$usuario"

    for punto in "$HOME_USR/general" "$HOME_USR/$GRUPO_1" \
                 "$HOME_USR/$GRUPO_2" "$HOME_USR/$usuario"; do
        if mountpoint -q "$punto" 2>/dev/null; then
            umount -l "$punto" 2>/dev/null
        fi
    done

    # Eliminar entradas del fstab
    sed -i "/$FSTAB_MARKER:$usuario/d" /etc/fstab
}

# ── 4. CREAR USUARIOS (MASIVO) ────────────────────────────────

crear_usuarios_masivo() {
    encabezado
    echo -e "${BLANCO}  [ CREACIÓN MASIVA DE USUARIOS FTP ]${NC}"
    separador

    read -rp "  ¿Cuántos usuarios desea crear? " NUM_USUARIOS
    if ! [[ "$NUM_USUARIOS" =~ ^[0-9]+$ ]] || [[ "$NUM_USUARIOS" -lt 1 ]]; then
        mensaje_error "Número inválido."
        pausar; return
    fi

    echo ""
    for ((i=1; i<=NUM_USUARIOS; i++)); do
        echo -e "${AMARILLO}  ─── Usuario $i de $NUM_USUARIOS ───${NC}"

        # Nombre
        while true; do
            read -rp "    Nombre de usuario: " USUARIO
            USUARIO="${USUARIO// /}"    # eliminar espacios
            USUARIO="${USUARIO,,}"      # minúsculas
            if [[ -z "$USUARIO" ]]; then
                mensaje_error "El nombre no puede estar vacío."; continue
            fi
            if id "$USUARIO" &>/dev/null; then
                mensaje_advertencia "El usuario '$USUARIO' ya existe. Ingrese otro."; continue
            fi
            break
        done

        # Contraseña
        while true; do
            read -rsp "    Contraseña: " PASS; echo ""
            read -rsp "    Confirmar contraseña: " PASS2; echo ""
            [[ "$PASS" == "$PASS2" ]] && break
            mensaje_error "Las contraseñas no coinciden. Intente de nuevo."
        done

        # Grupo
        while true; do
            echo "    Grupos disponibles:"
            echo "      1) $GRUPO_1"
            echo "      2) $GRUPO_2"
            read -rp "    Seleccione grupo (1 o 2): " GSEL
            case "$GSEL" in
                1) GRUPO_ASIGNADO="$GRUPO_1"; break ;;
                2) GRUPO_ASIGNADO="$GRUPO_2"; break ;;
                *) mensaje_error "Opción inválida." ;;
            esac
        done

        # Crear usuario
        crear_usuario_individual_logica "$USUARIO" "$PASS" "$GRUPO_ASIGNADO" && \
            mensaje_ok "Usuario '$USUARIO' creado en grupo '$GRUPO_ASIGNADO'." || \
            mensaje_error "Error al crear usuario '$USUARIO'."
        echo ""
    done

    # Reiniciar vsftpd para aplicar cambios
    systemctl restart vsftpd &>/dev/null
    mensaje_ok "vsftpd reiniciado. Todos los usuarios están listos."
    pausar
}

# Lógica interna de creación de un usuario
crear_usuario_individual_logica() {
    local USUARIO="$1"
    local PASS="$2"
    local GRUPO_ASIGNADO="$3"

    # 1. Garantizar PAM correcto (crea /etc/pam.d/vsftpd-local)
    corregir_pam_vsftpd

    # 2. Crear usuario con /bin/bash
    # (SSH bloqueado para ftplocales via sshd_config)
    if ! id "$USUARIO" &>/dev/null; then
        useradd -s /bin/bash -M -d "$FTP_HOMES/$USUARIO" "$USUARIO" || return 1
    else
        # Usuario ya existe: asegurar shell correcta
        usermod -s /bin/bash "$USUARIO"
    fi

    # 3. Establecer contrasena de tres formas para maxima compatibilidad
    echo "$USUARIO:$PASS" | chpasswd
    # Verificar que chpasswd funciono
    if ! grep -q "^${USUARIO}:" /etc/shadow 2>/dev/null; then
        echo "$PASS" | passwd --stdin "$USUARIO" 2>/dev/null || true
    fi

    # 4. Desbloquear cuenta (por si faillock la bloqueo en intentos anteriores)
    # pam_faillock bloquea cuentas tras varios intentos fallidos
    faillock --user "$USUARIO" --reset 2>/dev/null || true
    usermod -U "$USUARIO" 2>/dev/null || true  # desbloquear shadow si estaba bloqueada
    chage -E -1 "$USUARIO" 2>/dev/null || true  # sin caducidad de cuenta

    # 5. Agregar a grupos
    usermod -aG "$GRUPO_FTP" "$USUARIO"
    usermod -aG "$GRUPO_ASIGNADO" "$USUARIO"

    # 3. Crear directorio personal en datos
    mkdir -p "$FTP_DATA/usuarios/$USUARIO"
    chown "$USUARIO":"$GRUPO_ASIGNADO" "$FTP_DATA/usuarios/$USUARIO"
    chmod 700 "$FTP_DATA/usuarios/$USUARIO"

    # 4. ACL: permitir al usuario escribir en general y en su grupo
    setfacl -m "u:$USUARIO:rwx" "$FTP_DATA/general"
    setfacl -d -m "u:$USUARIO:rwx" "$FTP_DATA/general"
    setfacl -m "u:$USUARIO:rwx" "$FTP_DATA/$GRUPO_ASIGNADO"
    setfacl -d -m "u:$USUARIO:rwx" "$FTP_DATA/$GRUPO_ASIGNADO"

    # 5. Montar bind mounts y configurar chroot
    montar_usuario "$USUARIO" "$GRUPO_ASIGNADO"

    # 6. Contexto SELinux
    restorecon -Rv "$FTP_HOMES/$USUARIO" &>/dev/null || true
    chcon -R -t public_content_rw_t "$FTP_DATA/usuarios/$USUARIO" &>/dev/null || true

    registrar_log "Usuario '$USUARIO' creado en grupo '$GRUPO_ASIGNADO'."
    return 0
}

# ── 5. AÑADIR USUARIO INDIVIDUAL ─────────────────────────────

anadir_usuario_individual() {
    encabezado
    echo -e "${BLANCO}  [ AÑADIR USUARIO INDIVIDUAL ]${NC}"
    separador

    while true; do
        read -rp "  Nombre de usuario: " USUARIO
        USUARIO="${USUARIO// /}"; USUARIO="${USUARIO,,}"
        [[ -z "$USUARIO" ]] && { mensaje_error "Nombre vacío."; continue; }
        id "$USUARIO" &>/dev/null && { mensaje_advertencia "El usuario ya existe."; continue; }
        break
    done

    while true; do
        read -rsp "  Contraseña: " PASS; echo ""
        read -rsp "  Confirmar: "  PASS2; echo ""
        [[ "$PASS" == "$PASS2" ]] && break
        mensaje_error "Las contraseñas no coinciden."
    done

    echo "  Grupos disponibles:"
    echo "    1) $GRUPO_1"
    echo "    2) $GRUPO_2"
    while true; do
        read -rp "  Seleccione grupo (1 o 2): " GSEL
        case "$GSEL" in
            1) GRUPO_ASIGNADO="$GRUPO_1"; break ;;
            2) GRUPO_ASIGNADO="$GRUPO_2"; break ;;
            *) mensaje_error "Opción inválida." ;;
        esac
    done

    if crear_usuario_individual_logica "$USUARIO" "$PASS" "$GRUPO_ASIGNADO"; then
        systemctl restart vsftpd &>/dev/null
        mensaje_ok "Usuario '$USUARIO' añadido en grupo '$GRUPO_ASIGNADO'."
    else
        mensaje_error "No se pudo crear el usuario."
    fi
    pausar
}

# ── 6. CAMBIAR GRUPO DE USUARIO ───────────────────────────────

cambiar_grupo_usuario() {
    encabezado
    echo -e "${BLANCO}  [ CAMBIAR GRUPO DE USUARIO ]${NC}"
    separador

    # Listar usuarios FTP
    FTPUSERS=$(getent group "$GRUPO_FTP" | cut -d: -f4)
    if [[ -z "$FTPUSERS" ]]; then
        mensaje_info "No hay usuarios FTP registrados."
        pausar; return
    fi

    echo "  Usuarios FTP disponibles:"
    IFS=',' read -ra LISTA <<< "$FTPUSERS"
    for idx in "${!LISTA[@]}"; do
        u="${LISTA[$idx]}"
        G=""
        getent group "$GRUPO_1" | grep -qw "$u" && G="$GRUPO_1"
        getent group "$GRUPO_2" | grep -qw "$u" && G="$GRUPO_2"
        echo -e "    $((idx+1))) ${VERDE}$u${NC}  ${AMARILLO}[$G]${NC}"
    done
    echo ""

    read -rp "  Nombre del usuario a cambiar: " USUARIO
    if ! id "$USUARIO" &>/dev/null; then
        mensaje_error "Usuario '$USUARIO' no existe."
        pausar; return
    fi

    # Grupo actual
    GRUPO_ACTUAL=""
    getent group "$GRUPO_1" | grep -qw "$USUARIO" && GRUPO_ACTUAL="$GRUPO_1"
    getent group "$GRUPO_2" | grep -qw "$USUARIO" && GRUPO_ACTUAL="$GRUPO_2"

    echo "  Grupo actual: ${AMARILLO}$GRUPO_ACTUAL${NC}"
    if [[ "$GRUPO_ACTUAL" == "$GRUPO_1" ]]; then
        GRUPO_NUEVO="$GRUPO_2"
    else
        GRUPO_NUEVO="$GRUPO_1"
    fi
    echo "  Nuevo grupo: ${VERDE}$GRUPO_NUEVO${NC}"
    echo ""
    read -rp "  ¿Confirmar el cambio? (s/N): " CONF
    [[ "${CONF,,}" != "s" ]] && { mensaje_info "Operación cancelada."; pausar; return; }

    # Desmontar bind mounts del grupo anterior
    desmontar_usuario "$USUARIO"

    # Actualizar grupos del sistema
    gpasswd -d "$USUARIO" "$GRUPO_ACTUAL" &>/dev/null
    usermod -aG "$GRUPO_NUEVO" "$USUARIO"

    # Asegurar que el usuario tenga /bin/bash (por si fue creado con version anterior)
    usermod -s /bin/bash "$USUARIO" 2>/dev/null || true

    # Eliminar directorio de grupo anterior del chroot
    rm -rf "$FTP_HOMES/$USUARIO/$GRUPO_ACTUAL"

    # Actualizar ACLs en datos
    setfacl -x "u:$USUARIO" "$FTP_DATA/$GRUPO_ACTUAL" 2>/dev/null
    setfacl -m "u:$USUARIO:rwx" "$FTP_DATA/$GRUPO_NUEVO"
    setfacl -d -m "u:$USUARIO:rwx" "$FTP_DATA/$GRUPO_NUEVO"

    # Cambiar propietario del dir personal al nuevo grupo
    chown "$USUARIO":"$GRUPO_NUEVO" "$FTP_DATA/usuarios/$USUARIO"

    # Remontar con nuevo grupo
    montar_usuario "$USUARIO" "$GRUPO_NUEVO"

    # Actualizar vsftpd user_conf (sin cambios, sigue apuntando al chroot del usuario)
    restorecon -Rv "$FTP_HOMES/$USUARIO" &>/dev/null || true

    systemctl restart vsftpd &>/dev/null
    mensaje_ok "Usuario '$USUARIO' cambiado de '$GRUPO_ACTUAL' a '$GRUPO_NUEVO'."
    pausar
}

# ── 7. LISTAR USUARIOS ────────────────────────────────────────

listar_usuarios() {
    encabezado
    echo -e "${BLANCO}  [ USUARIOS FTP REGISTRADOS ]${NC}"
    separador
    printf "  %-20s %-15s %-10s\n" "USUARIO" "GRUPO" "ESTADO"
    separador

    FTPUSERS=$(getent group "$GRUPO_FTP" | cut -d: -f4)
    if [[ -z "$FTPUSERS" ]]; then
        mensaje_info "No hay usuarios FTP registrados."
        pausar; return
    fi

    IFS=',' read -ra LISTA <<< "$FTPUSERS"
    for u in "${LISTA[@]}"; do
        [[ -z "$u" ]] && continue
        G=""
        getent group "$GRUPO_1" | grep -qw "$u" && G="$GRUPO_1"
        getent group "$GRUPO_2" | grep -qw "$u" && G="$GRUPO_2"
        ESTADO=$(id "$u" &>/dev/null && echo "activo" || echo "error")
        printf "  ${VERDE}%-20s${NC} ${AMARILLO}%-15s${NC} %-10s\n" "$u" "$G" "$ESTADO"
    done
    pausar
}

# ── 8. CONFIGURAR PERMISOS ────────────────────────────────────

configurar_permisos() {
    encabezado
    echo -e "${BLANCO}  [ CONFIGURACIÓN DE PERMISOS Y ACLs ]${NC}"
    separador

    mensaje_info "Reestableciendo permisos base..."

    # Permisos de datos
    chown root:root "$FTP_BASE" "$FTP_ANON" "$FTP_DATA" "$FTP_HOMES"
    chmod 755 "$FTP_BASE" "$FTP_ANON" "$FTP_DATA" "$FTP_HOMES"

    chown root:"$GRUPO_FTP" "$FTP_ANON/general"
    chmod 755 "$FTP_ANON/general"
    # Re-montar si no esta montado
    if ! mountpoint -q "$FTP_ANON/general" 2>/dev/null; then
        mount --bind "$FTP_DATA/general" "$FTP_ANON/general" 2>/dev/null || true
    fi

    chown root:"$GRUPO_FTP" "$FTP_DATA/general"
    chmod 775 "$FTP_DATA/general"

    chown root:"$GRUPO_1" "$FTP_DATA/$GRUPO_1"
    chmod 770 "$FTP_DATA/$GRUPO_1"

    chown root:"$GRUPO_2" "$FTP_DATA/$GRUPO_2"
    chmod 770 "$FTP_DATA/$GRUPO_2"

    # ACLs de grupos sobre general
    setfacl -m "g:$GRUPO_1:rwx"   "$FTP_DATA/general"
    setfacl -m "g:$GRUPO_2:rwx"   "$FTP_DATA/general"
    setfacl -d -m "g:$GRUPO_1:rwx" "$FTP_DATA/general"
    setfacl -d -m "g:$GRUPO_2:rwx" "$FTP_DATA/general"

    mensaje_ok "Permisos de directorios compartidos configurados."

    # Permisos individuales
    FTPUSERS=$(getent group "$GRUPO_FTP" | cut -d: -f4)
    if [[ -n "$FTPUSERS" ]]; then
        IFS=',' read -ra LISTA <<< "$FTPUSERS"
        for u in "${LISTA[@]}"; do
            [[ -z "$u" ]] && continue
            if [[ -d "$FTP_DATA/usuarios/$u" ]]; then
                G=""
                getent group "$GRUPO_1" | grep -qw "$u" && G="$GRUPO_1"
                getent group "$GRUPO_2" | grep -qw "$u" && G="$GRUPO_2"
                chown "$u":"${G:-$GRUPO_FTP}" "$FTP_DATA/usuarios/$u"
                chmod 700 "$FTP_DATA/usuarios/$u"
                setfacl -m "u:$u:rwx" "$FTP_DATA/general"
                setfacl -d -m "u:$u:rwx" "$FTP_DATA/general"
                [[ -n "$G" ]] && setfacl -m "u:$u:rwx" "$FTP_DATA/$G" && \
                                  setfacl -d -m "u:$u:rwx" "$FTP_DATA/$G"
                # Chroot dir: root lo posee
                if [[ -d "$FTP_HOMES/$u" ]]; then
                    chown root:root "$FTP_HOMES/$u"
                    chmod 755 "$FTP_HOMES/$u"
                fi
                mensaje_ok "Permisos de '$u' actualizados."
            fi
        done
    fi

    # Contextos SELinux
    restorecon -Rv "$FTP_BASE" &>/dev/null || true
    mensaje_ok "Contextos SELinux restaurados."

    systemctl restart vsftpd &>/dev/null
    mensaje_ok "Permisos aplicados y vsftpd reiniciado."
    pausar
}

# ── 9. VALIDAR ESTADO DEL SERVIDOR ───────────────────────────

validar_estado() {
    encabezado
    echo -e "${BLANCO}  [ VALIDACIÓN DEL ESTADO DEL SERVIDOR ]${NC}"
    separador

    # Estado del servicio
    echo -e "  ${CYAN}▸ Servicio vsftpd:${NC}"
    systemctl status vsftpd --no-pager | grep -E "Active:|Loaded:" | \
        sed 's/^/    /'
    echo ""

    # Conexiones activas
    echo -e "  ${CYAN}▸ Conexiones FTP activas (puerto 21):${NC}"
    ss -tnp | grep ':21' | awk '{print "    "$0}' || echo "    Ninguna conexión activa."
    echo ""

    # Últimas líneas del log
    echo -e "  ${CYAN}▸ Últimas 10 entradas del log vsftpd:${NC}"
    if [[ -f /var/log/vsftpd.log ]]; then
        tail -10 /var/log/vsftpd.log | sed 's/^/    /'
    else
        echo "    Log no disponible aún."
    fi
    echo ""

    # Bind mounts activos
    echo -e "  ${CYAN}▸ Bind mounts FTP activos:${NC}"
    mount | grep "$FTP_BASE" | awk '{print "    "$0}' || echo "    Ninguno."
    echo ""

    # Uso de disco
    echo -e "  ${CYAN}▸ Uso de disco en $FTP_BASE:${NC}"
    du -sh "$FTP_BASE"/* 2>/dev/null | sed 's/^/    /'

    pausar
}

# ── 10. ELIMINAR USUARIO ──────────────────────────────────────

eliminar_usuario() {
    encabezado
    echo -e "${BLANCO}  [ ELIMINAR USUARIO FTP ]${NC}"
    separador

    FTPUSERS=$(getent group "$GRUPO_FTP" | cut -d: -f4)
    if [[ -z "$FTPUSERS" ]]; then
        mensaje_info "No hay usuarios FTP para eliminar."
        pausar; return
    fi

    listar_usuarios_corto
    read -rp "  Nombre del usuario a eliminar: " USUARIO

    if ! id "$USUARIO" &>/dev/null; then
        mensaje_error "El usuario '$USUARIO' no existe."
        pausar; return
    fi

    read -rp "  ¿Eliminar también sus datos personales? (s/N): " DATOS
    read -rp "  ${ROJO}¿Confirmar eliminación de '$USUARIO'? (s/N): ${NC}" CONF
    [[ "${CONF,,}" != "s" ]] && { mensaje_info "Cancelado."; pausar; return; }

    desmontar_usuario "$USUARIO"
    rm -rf "$FTP_HOMES/$USUARIO"
    rm -f "$USER_CONF_DIR/$USUARIO"

    [[ "${DATOS,,}" == "s" ]] && rm -rf "$FTP_DATA/usuarios/$USUARIO"

    userdel "$USUARIO" 2>/dev/null
    systemctl restart vsftpd &>/dev/null
    mensaje_ok "Usuario '$USUARIO' eliminado."
    pausar
}

listar_usuarios_corto() {
    FTPUSERS=$(getent group "$GRUPO_FTP" | cut -d: -f4)
    echo ""
    IFS=',' read -ra LISTA <<< "$FTPUSERS"
    for u in "${LISTA[@]}"; do
        [[ -z "$u" ]] && continue
        G=""
        getent group "$GRUPO_1" | grep -qw "$u" && G="$GRUPO_1"
        getent group "$GRUPO_2" | grep -qw "$u" && G="$GRUPO_2"
        echo -e "    → ${VERDE}$u${NC}  ${AMARILLO}[$G]${NC}"
    done
    echo ""
}

# ── 11. VER LOGS ──────────────────────────────────────────────

ver_logs() {
    encabezado
    echo -e "${BLANCO}  [ REGISTROS DEL SERVIDOR FTP ]${NC}"
    separador
    echo "  1) Log de transferencias  (/var/log/vsftpd.log)"
    echo "  2) Log detallado          (/var/log/vsftpd_detail.log)"
    echo "  3) Log de administración  (/var/log/ftp_admin.log)"
    echo "  4) Journalctl vsftpd"
    echo "  0) Volver"
    echo ""
    read -rp "  Seleccione: " OPT
    case "$OPT" in
        1) [[ -f /var/log/vsftpd.log ]] && less /var/log/vsftpd.log || mensaje_info "Log vacío." ;;
        2) [[ -f /var/log/vsftpd_detail.log ]] && less /var/log/vsftpd_detail.log || mensaje_info "Log vacío." ;;
        3) [[ -f "$LOG_FILE" ]] && less "$LOG_FILE" || mensaje_info "Log vacío." ;;
        4) journalctl -u vsftpd --no-pager | tail -50 ;;
        0) return ;;
    esac
    pausar
}

# ── MENÚ PRINCIPAL ────────────────────────────────────────────

menu_gestion_usuarios() {
    while true; do
        encabezado
        echo -e "${BLANCO}  [ GESTIÓN DE USUARIOS ]${NC}"
        separador
        echo "    1) Creación masiva de usuarios"
        echo "    2) Añadir usuario individual"
        echo "    3) Cambiar grupo de usuario"
        echo "    4) Listar usuarios"
        echo "    5) Eliminar usuario"
        echo "    0) Volver al menú principal"
        separador
        read -rp "  Seleccione una opción: " OPT
        case "$OPT" in
            1) crear_usuarios_masivo ;;
            2) anadir_usuario_individual ;;
            3) cambiar_grupo_usuario ;;
            4) listar_usuarios ;;
            5) eliminar_usuario ;;
            0) return ;;
            *) mensaje_error "Opción inválida." ; sleep 1 ;;
        esac
    done
}

menu_principal() {
    while true; do
        encabezado
        echo -e "  ${CYAN}Sistema Operativo:${NC} Oracle Linux 9.7"
        echo -e "  ${CYAN}Servidor FTP:${NC}     vsftpd"
        echo -e "  ${CYAN}Grupos FTP:${NC}       $GRUPO_1 | $GRUPO_2"
        separador
        echo ""
        echo -e "  ${BLANCO}OPCIONES DISPONIBLES:${NC}"
        echo ""
        echo "    1) Instalar y configurar vsftpd"
        echo "    2) Verificar instalación"
        echo "    3) Gestión de usuarios y grupos"
        echo "    4) Configurar / reestablecer permisos"
        echo "    5) Validar estado del servidor"
        echo "    6) Ver logs"
        echo "    7) Reiniciar servicio vsftpd"
        echo "    8) Desbloquear cuentas FTP (fix 530 Login incorrect)"
        echo "    0) Salir"
        echo ""
        separador
        read -rp "  Seleccione una opcion: " OPT
        case "$OPT" in
            1) instalar_vsftpd ;;
            2) verificar_instalacion ;;
            3) menu_gestion_usuarios ;;
            4) configurar_permisos ;;
            5) validar_estado ;;
            6) ver_logs ;;
            7)
                systemctl restart vsftpd
                systemctl is-active --quiet vsftpd &&                     mensaje_ok "vsftpd reiniciado correctamente." ||                     mensaje_error "Error al reiniciar vsftpd."
                pausar
                ;;
            8)
                encabezado
                echo "  [ DESBLOQUEAR CUENTAS FTP ]"
                separador
                corregir_pam_vsftpd
                mensaje_ok "PAM vsftpd-local recreado."
                if getent group ftplocales &>/dev/null; then
                    for u in $(getent group ftplocales | cut -d: -f4 | tr ',' ' '); do
                        [ -z "$u" ] && continue
                        usermod -s /bin/bash "$u" 2>/dev/null || true
                        faillock --user "$u" --reset 2>/dev/null || true
                        usermod -U "$u" 2>/dev/null || true
                        chage -E -1 "$u" 2>/dev/null || true
                        # Asegurar pam_service_name en vsftpd.conf
                        grep -q "^pam_service_name" "$VSFTPD_CONF" 2>/dev/null ||                             echo "pam_service_name=vsftpd-local" >> "$VSFTPD_CONF"
                        mensaje_ok "Usuario '$u' desbloqueado."
                    done
                fi
                systemctl restart vsftpd &>/dev/null
                mensaje_ok "vsftpd reiniciado. Prueba conectarte ahora."
                pausar
                ;;
            0)
                echo ""
                mensaje_info "Saliendo del administrador FTP. ¡Hasta luego!"
                echo ""
                exit 0
                ;;
            *) mensaje_error "Opción inválida." ; sleep 1 ;;
        esac
    done
}

# ── PUNTO DE ENTRADA ──────────────────────────────────────────
verificar_root
touch "$LOG_FILE" 2>/dev/null || LOG_FILE="/tmp/ftp_admin.log"
registrar_log "Script iniciado por: $(whoami)"
menu_principal
