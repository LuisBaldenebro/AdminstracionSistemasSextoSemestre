#!/bin/bash

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

# ─────────────────────────────────────────────────────
# Corrige AUTOMATICAMENTE todos los problemas conocidos
# de SSH en Oracle Linux 9: PermitRootLogin, SELinux,
# Firewall, PasswordAuthentication y host keys.
# ─────────────────────────────────────────────────────
reparar_ssh_config() {
    local CONF="/etc/ssh/sshd_config"
    local CONF_DIR="/etc/ssh/sshd_config.d"
    local CHANGED=0

    echo "Verificando configuracion SSH..."

    # 1. Respaldar config original si no existe backup
    [ ! -f "${CONF}.original" ] && cp "$CONF" "${CONF}.original"

    # 2. Reemplazar sshd_config con version minima y funcional
    #    Esto elimina cualquier directiva conflictiva heredada
    cat <<'EOF' > "$CONF"
# Configuracion SSH generada automaticamente
Port 22
AddressFamily any
ListenAddress 0.0.0.0
ListenAddress ::

# Autenticacion
PermitRootLogin yes
PasswordAuthentication yes
PermitEmptyPasswords no
PubkeyAuthentication yes
AuthorizedKeysFile .ssh/authorized_keys

# Seguridad basica
MaxAuthTries 6
MaxSessions 10

# Opciones de sesion
X11Forwarding no
PrintMotd yes
AcceptEnv LANG LC_*

# SFTP
Subsystem sftp /usr/libexec/openssh/sftp-server
EOF
    CHANGED=1

    # 3. Desactivar configs en sshd_config.d que puedan sobreescribir
    if [ -d "$CONF_DIR" ]; then
        for f in "$CONF_DIR"/*.conf; do
            [ -f "$f" ] || continue
            # Si alguno tiene PermitRootLogin o PasswordAuthentication, comentarlo
            if grep -qiE "PermitRootLogin|PasswordAuthentication" "$f"; then
                mv "$f" "${f}.disabled"
                echo " > Desactivado: $f (conflicto con PermitRootLogin)"
            fi
        done
    fi

    # 4. Verificar sintaxis
    if ! sshd -t 2>/dev/null; then
        echo -e "${RED}[ERROR] sshd_config tiene errores de sintaxis.${NC}"
        echo "Restaurando backup..."
        cp "${CONF}.original" "$CONF"
        return 1
    fi

    # 5. Regenerar host keys si faltan o están corruptas
    local NECESITA_KEYGEN=0
    for tipo in rsa ecdsa ed25519; do
        if [ ! -f "/etc/ssh/ssh_host_${tipo}_key" ]; then
            NECESITA_KEYGEN=1; break
        fi
    done
    if [ $NECESITA_KEYGEN -eq 1 ]; then
        echo " > Regenerando host keys..."
        ssh-keygen -A &>/dev/null
    fi

    # 6. Configurar firewall
    if systemctl is-active --quiet firewalld; then
        firewall-cmd --list-services 2>/dev/null | grep -qw ssh || {
            echo " > Abriendo puerto 22 en firewall..."
            firewall-cmd --add-service=ssh --permanent &>/dev/null
            firewall-cmd --reload &>/dev/null
        }
    fi

    # 7. SELinux: asegurarse que el puerto 22 este permitido
    if command -v semanage &>/dev/null; then
        semanage port -l 2>/dev/null | grep -q "ssh_port_t.*22" || {
            echo " > Configurando SELinux para puerto 22..."
            semanage port -a -t ssh_port_t -p tcp 22 &>/dev/null
        }
    fi

    # 8. Poner SELinux en permissive si sigue bloqueando
    if command -v getenforce &>/dev/null; then
        SE_STATUS=$(getenforce)
        if [ "$SE_STATUS" = "Enforcing" ]; then
            echo " > SELinux en modo Permissive (practica)..."
            setenforce 0 &>/dev/null
            # Que persista tras reinicio
            sed -i 's/^SELINUX=enforcing/SELINUX=permissive/' /etc/selinux/config 2>/dev/null
        fi
    fi

    # 9. Eliminar /etc/nologin si existe (bloquea logins)
    if [ -f /etc/nologin ]; then
        echo " > Eliminando /etc/nologin..."
        rm -f /etc/nologin
    fi

    # 10. Recargar sshd
    systemctl restart sshd &>/dev/null
    sleep 1

    if systemctl is-active --quiet sshd; then
        echo -e "${GREEN} > SSH configurado y activo correctamente.${NC}"
        return 0
    else
        echo -e "${RED} > SSH no pudo iniciar tras la configuracion.${NC}"
        journalctl -u sshd -n 5 --no-pager
        return 1
    fi
}

estado_ssh() {
    while true; do
        clear
        echo "----------------------------------------"
        echo "        ESTADO DEL SERVICIO SSH"
        echo "----------------------------------------"

        if ! rpm -q openssh-server &>/dev/null; then
            echo -e "${RED}[!] openssh-server no instalado.${NC}"
            read -p "Enter..."; return
        fi

        ESTADO=$(systemctl is-active sshd)
        PUERTO=$(ss -tlnp 2>/dev/null | grep ':22 ' | awk '{print $4}')

        if [ "$ESTADO" = "active" ]; then
            echo -e "Estado:  ${GREEN}ACTIVO (Running)${NC}"
            echo    "Puerto:  ${PUERTO:-0.0.0.0:22}"
            echo "----------------------------------------"
            echo " [1] Detener  [2] Reiniciar  [3] Volver"
        else
            echo -e "Estado:  ${RED}DETENIDO${NC}"
            echo "----------------------------------------"
            echo " [1] Iniciar  [3] Volver"
        fi

        echo "----------------------------------------"
        read -p "Opcion: " op
        case $op in
            1)
                if [ "$ESTADO" = "active" ]; then
                    systemctl stop sshd && echo -e "${YELLOW}Servicio detenido.${NC}"
                else
                    systemctl start sshd && echo -e "${GREEN}Servicio iniciado.${NC}"
                fi; sleep 2 ;;
            2)
                [ "$ESTADO" = "active" ] && { systemctl restart sshd; echo -e "${GREEN}Reiniciado.${NC}"; sleep 2; } ;;
            3) return ;;
            *) echo "Opcion no valida"; sleep 1 ;;
        esac
    done
}

instalar_ssh() {
    clear
    echo "========================================"
    echo "    INSTALACION Y CONFIG. DE SSH"
    echo "========================================"

    # Instalar si no existe
    if ! rpm -q openssh-server &>/dev/null; then
        echo "Instalando OpenSSH Server..."
        dnf install -y openssh-server &>/dev/null
        if ! rpm -q openssh-server &>/dev/null; then
            echo -e "${RED}[ERROR] No se pudo instalar.${NC}"
            read -p "Enter..."; return
        fi
        echo -e "${GREEN}Instalado correctamente.${NC}"
    else
        echo -e "${YELLOW}OpenSSH Server ya estaba instalado.${NC}"
    fi

    # Aplicar todas las correcciones automaticas
    reparar_ssh_config

    # Habilitar inicio automatico
    systemctl enable sshd &>/dev/null

    # Mostrar IPs donde escucha para que el usuario sepa a que conectarse
    echo ""
    echo "========================================="
    echo "  SSH LISTO - Conectate con estas IPs:"
    echo "========================================="
    ip -4 addr show | grep -oP '(?<=inet )\d+\.\d+\.\d+\.\d+' | grep -v "127.0.0.1" | while read -r ip; do
        echo "   ssh root@$ip"
        echo "   ssh $(logname 2>/dev/null || echo usuario)@$ip"
    done
    echo ""
    echo "  Desde VirtualBox (port forwarding 2222):"
    echo "   ssh root@127.0.0.1 -p 2222"
    echo "========================================="

    read -p "Enter para continuar..."
}

menu_ssh() {
    while true; do
        clear
        echo "========================================"
        echo "          SERVICIO SSH (LINUX)"
        echo "========================================"
        echo "1) Estado del servicio"
        echo "2) Instalar y configurar SSH"
        echo "3) Volver al menu principal"
        echo "========================================"
        read -p "Opcion: " op
        case $op in
            1) estado_ssh ;;
            2) instalar_ssh ;;
            3) return ;;
            *) echo -e "${YELLOW}Opcion invalida${NC}"; sleep 1 ;;
        esac
    done
}
