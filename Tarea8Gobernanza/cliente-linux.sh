#!/bin/bash

# CONFIGURACION
DOMAIN='lab.local'
DC_IP='192.168.100.1'
ADMIN_USER='Administrator'
REALM='LAB.LOCAL'
SSSD_CONF='/etc/sssd/sssd.conf'
SUDOERS_FILE='/etc/sudoers.d/ad-admins'
DEBUG=0

set +e
[ "$DEBUG" -eq 1 ] && set -x

# Auto-elevacion a root
if [ "$EUID" -ne 0 ]; then
    echo -e '\e[33m  [!] No eres root. Relanzando con sudo...\e[0m'
    exec sudo bash "$0" "$@"
fi

# Helpers visuales
SEP='=================================================='
banner() { echo -e "\n\e[36m${SEP}\e[0m\n\e[36m  $1\e[0m\n\e[36m${SEP}\e[0m\n"; }
fase()   { echo -e "\n\e[33m${SEP}\e[0m\n\e[33m  $1\e[0m\n\e[33m${SEP}\e[0m\n"; }
ok()     { echo -e "  \e[32m[OK] $1\e[0m"; }
info()   { echo -e "  \e[36m[i]  $1\e[0m"; }
warn()   { echo -e "  \e[33m[!]  $1\e[0m"; }
err()    { echo -e "  \e[31m[X]  $1\e[0m"; }

EXITOSOS=0
FALLIDOS=0

trap 'err "Error inesperado en linea $LINENO. Comando: $BASH_COMMAND"; FALLIDOS=$((FALLIDOS+1))' ERR

# FASE 0 - Inicializacion
fase0() {
    fase 'FASE 0: Inicializacion'
    SO=$(cat /etc/oracle-release 2>/dev/null || grep PRETTY_NAME /etc/os-release | cut -d= -f2 | tr -d '"')
    banner "Practica: Gobernanza AD - Cliente Linux\n  Equipo  : $(hostname)\n  SO      : $SO\n  IP DC   : $DC_IP\n  Dominio : $DOMAIN\n  Fecha   : $(date '+%d/%m/%Y %H:%M')"
    EXITOSOS=$((EXITOSOS+1))
}

# FASE 1 - Instalar paquetes
fase1_paquetes() {
    fase 'FASE 1: Instalacion de paquetes'
    local paquetes=(
        realmd sssd sssd-tools adcli
        oddjob oddjob-mkhomedir
        samba-common-tools
        krb5-workstation krb5-libs
        openldap-clients
        policycoreutils-python-utils
    )
    info "Instalando: ${paquetes[*]}"
    if dnf install -y \
        --setopt=fastestmirror=True \
        --setopt=max_parallel_downloads=10 \
        "${paquetes[@]}"; then
        ok 'Todos los paquetes instalados correctamente.'
        EXITOSOS=$((EXITOSOS+1))
    else
        err 'Error durante la instalacion de paquetes.'
        FALLIDOS=$((FALLIDOS+1))
    fi
}

# FASE 2 - Configurar DNS
fase2_dns() {
    fase 'FASE 2: Configuracion de DNS'
    info "Apuntando DNS al DC: $DC_IP"

    # Desproteger si estaba inmutable
    chattr -i /etc/resolv.conf 2>/dev/null || true

    cat > /etc/resolv.conf << EOF
# Generado por cliente-linux.sh - $(date)
search $DOMAIN
nameserver $DC_IP
EOF

    # Proteger contra sobreescritura por NetworkManager
    chattr +i /etc/resolv.conf 2>/dev/null && \
        info 'resolv.conf protegido con chattr +i.' || \
        warn 'No se pudo proteger resolv.conf (chattr no disponible).'

    ok "DNS configurado: $DC_IP"

    # Verificar resolucion del dominio
    info "Verificando resolucion de '$DOMAIN'..."
    if ping -c 2 -W 3 "$DOMAIN" &>/dev/null; then
        ok "Dominio '$DOMAIN' resuelto correctamente."
        EXITOSOS=$((EXITOSOS+1))
    else
        warn "No se pudo hacer ping a '$DOMAIN'. Verifica conectividad con el DC ($DC_IP)."
        FALLIDOS=$((FALLIDOS+1))
    fi
}

# FASE 3 - Union al dominio
fase3_union() {
    fase 'FASE 3: Union al dominio Active Directory'

    if realm list 2>/dev/null | grep -qi "$DOMAIN"; then
        warn "El equipo ya esta unido a '$DOMAIN'. Se omite la union."
        EXITOSOS=$((EXITOSOS+1))
        return 0
    fi

    info "Uniendo '$(hostname)' al dominio '$DOMAIN'..."
    info "Usuario administrador: $ADMIN_USER"
    info '(Se solicitara la contrasena del administrador del dominio)'

    if realm join --user="$ADMIN_USER" "$DOMAIN"; then
        ok "Equipo unido al dominio '$DOMAIN' correctamente."
        EXITOSOS=$((EXITOSOS+1))
    else
        err 'Error al unirse al dominio. Verifica credenciales y conectividad.'
        FALLIDOS=$((FALLIDOS+1))
    fi
}

# FASE 4 - Configurar SSSD y sudo
fase4_sssd() {
    fase 'FASE 4: Configuracion de SSSD, PAM y sudo'

    info "Escribiendo $SSSD_CONF ..."
    cat > "$SSSD_CONF" << EOF
# sssd.conf - generado por cliente-linux.sh - $(date)
[sssd]
domains = $DOMAIN
config_file_version = 2
services = nss, pam

[domain/$DOMAIN]
default_shell = /bin/bash
krb5_store_password_if_offline = True
cache_credentials = True
krb5_realm = $REALM
realmd_tags = manages-system joined-with-adcli
id_provider = ad
fallback_homedir = /home/%u@%d
ad_domain = $DOMAIN
use_fully_qualified_names = True
ldap_id_mapping = True
access_provider = ad
EOF

    chmod 600 "$SSSD_CONF"
    ok 'sssd.conf configurado (permisos 600).'

    info 'Configurando sudo para administradores del dominio...'
    cat > "$SUDOERS_FILE" << 'EOF'
# Acceso sudo para administradores del dominio AD
# Generado por cliente-linux.sh
%admins@lab.local ALL=(ALL) NOPASSWD:ALL
EOF
    chmod 440 "$SUDOERS_FILE"

    if visudo -cf "$SUDOERS_FILE" &>/dev/null; then
        ok "Archivo sudoers validado: $SUDOERS_FILE"
    else
        warn 'Advertencia de sintaxis en sudoers. Revisa manualmente.'
    fi

    info 'Habilitando sssd y oddjobd...'
    systemctl enable --now sssd oddjobd
    ok 'Servicios sssd y oddjobd activos.'

    info 'Configurando authselect con mkhomedir...'
    authselect select sssd with-mkhomedir --force
    ok 'authselect configurado.'

    systemctl restart sssd
    ok 'SSSD reiniciado.'
    EXITOSOS=$((EXITOSOS+1))
}

# FASE 5 - Verificacion
fase5_verificacion() {
    fase 'FASE 5: Verificacion'

    info '-- Estado del dominio (realm list) --'
    realm list 2>/dev/null || warn 'realm list no retorno resultados.'

    info '-- Estado de SSSD --'
    if systemctl is-active --quiet sssd; then
        ok 'SSSD activo.'
    else
        err 'SSSD no esta activo.'
        FALLIDOS=$((FALLIDOS+1))
    fi

    info "-- Identidad del administrador AD ($ADMIN_USER@$DOMAIN) --"
    if id "${ADMIN_USER}@${DOMAIN}" &>/dev/null; then
        ok "Usuario AD resoluble: $(id ${ADMIN_USER}@${DOMAIN})"
        EXITOSOS=$((EXITOSOS+1))
    else
        warn "No se pudo resolver '${ADMIN_USER}@${DOMAIN}'. SSSD puede necesitar unos momentos."
    fi
}

# Resumen final
resumen_final() {
    echo ''
    echo -e "\e[36m${SEP}\e[0m"
    echo -e "\e[36m  RESUMEN FINAL\e[0m"
    echo -e "\e[36m${SEP}\e[0m"
    echo -e "  \e[32mExitosas : $EXITOSOS\e[0m"
    echo -e "  \e[31mFallidas : $FALLIDOS\e[0m"
    echo ''
}

# Funciones del menu
menu_unir()   { fase3_union; }
menu_estado() {
    banner 'Estado de union al dominio'
    info "Hostname : $(hostname)"
    info "Dominio  : $(realm list 2>/dev/null | grep 'realm-name' | awk '{print $2}' || echo 'No unido')"
    info "SSSD     : $(systemctl is-active sssd 2>/dev/null)"
    info "oddjobd  : $(systemctl is-active oddjobd 2>/dev/null)"
    realm list 2>/dev/null || warn 'No unido a ningun dominio.'
}
menu_sssd()   {
    warn 'Se reconfigurara SSSD. Continuar? (s/N)'
    read -r resp
    [[ "$resp" =~ ^[sS]$ ]] && fase4_sssd || info 'Operacion cancelada.'
}
menu_sudo()   {
    banner 'Reconfigurar sudo para AD'
    cat > "$SUDOERS_FILE" << 'EOF'
%admins@lab.local ALL=(ALL) NOPASSWD:ALL
EOF
    chmod 440 "$SUDOERS_FILE"
    ok 'Archivo sudoers AD actualizado.'
}
menu_dns()    {
    banner 'Cambiar servidor DNS'
    read -rp '  IP del nuevo servidor DNS: ' nueva_ip
    [ -z "$nueva_ip" ] && return
    chattr -i /etc/resolv.conf 2>/dev/null || true
    sed -i "s/nameserver.*/nameserver $nueva_ip/" /etc/resolv.conf
    chattr +i /etc/resolv.conf 2>/dev/null || true
    ok "DNS actualizado a $nueva_ip"
}
menu_info()   {
    banner 'Informacion del sistema'
    info "Hostname   : $(hostname)"
    info "FQDN       : $(hostname -f 2>/dev/null)"
    info "SO         : $(cat /etc/oracle-release 2>/dev/null || grep PRETTY_NAME /etc/os-release | cut -d= -f2 | tr -d '"')"
    info "Kernel     : $(uname -r)"
    info "IP         : $(hostname -I | awk '{print $1}')"
    info "DNS actual : $(grep nameserver /etc/resolv.conf 2>/dev/null | awk '{print $2}' | tr '\n' ' ')"
    info "Dominio    : $(realm list 2>/dev/null | grep 'realm-name' | awk '{print $2}' || echo 'No unido')"
    info "Uptime     : $(uptime -p)"
}

# MENU INTERACTIVO
mostrar_menu() {
    while true; do
        clear
        echo -e "\n\e[36m  ╔══════════════════════════════════════════╗"
        echo -e "  ║     GESTION - CLIENTE LINUX              ║"
        echo -e "  ╠══════════════════════════════════════════╣"
        echo -e "  ║  [1]  Unirse al dominio                  ║"
        echo -e "  ║  [2]  Verificar estado de union          ║"
        echo -e "  ║  [3]  Reconfigurar SSSD                  ║"
        echo -e "  ║  [4]  Reconfigurar sudo para AD          ║"
        echo -e "  ║  [5]  Cambiar servidor DNS               ║"
        echo -e "  ║  [6]  Ver informacion del sistema        ║"
        echo -e "  ║  [0]  Salir                              ║"
        echo -e "  ╚══════════════════════════════════════════╝\e[0m"
        read -rp $'\n  Selecciona una opcion: ' opcion
        case "$opcion" in
            1) menu_unir   ;;
            2) menu_estado ;;
            3) menu_sssd   ;;
            4) menu_sudo   ;;
            5) menu_dns    ;;
            6) menu_info   ;;
            0) ok 'Saliendo. Hasta pronto!'; exit 0 ;;
            *) warn 'Opcion no valida.' ;;
        esac
        [ "$opcion" != '0' ] && read -rp $'\n  Presiona ENTER para continuar...' _
    done
}

# PUNTO DE ENTRADA
case "${1:-}" in
    --menu)
        fase0
        mostrar_menu
        ;;
    *)
        fase0
        fase1_paquetes
        fase2_dns
        fase3_union
        fase4_sssd
        fase5_verificacion
        resumen_final
        ;;
esac
