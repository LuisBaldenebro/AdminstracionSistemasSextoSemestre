#!/bin/bash

RED='\033[0;31m'
GREEN='\033[0;32m'
NC='\033[0m'

estado_dns() {
    while true; do
        clear
        echo "========================================"
        echo "        ESTADO DEL SERVICIO DNS"
        echo "========================================"
        if ! rpm -q bind &>/dev/null; then
            echo -e "${RED}[!] BIND no instalado.${NC}"
            read -p "Enter..."; return
        fi
        if systemctl is-active --quiet named; then
            echo -e "Estado: ${GREEN}ACTIVO${NC}"
            systemctl status named --no-pager | grep Active
            echo "----------------------------------------"
            echo "1) Detener  2) Reiniciar  3) Volver"
        else
            echo -e "Estado: ${RED}INACTIVO${NC}"
            echo "----------------------------------------"
            echo "1) Iniciar  3) Volver"
        fi
        read -p "Opcion: " op
        case $op in
            1) systemctl is-active --quiet named && systemctl stop named || systemctl start named; sleep 2 ;;
            2) systemctl is-active --quiet named && { systemctl restart named; sleep 2; } ;;
            3) return ;;
            *) echo "Opcion no valida"; sleep 1 ;;
        esac
    done
}

aplicar_reglas_dns() {
    local CONF="/etc/named.conf"
    cp "$CONF" "${CONF}.bak_$(date +%Y%m%d%H%M%S)" &>/dev/null
    grep -q "listen-on port 53" "$CONF" && \
        sed -i 's/listen-on port 53 {[^}]*};/listen-on port 53 { any; };/' "$CONF"
    grep -q "allow-query" "$CONF" && \
        sed -i 's/allow-query[[:space:]]*{[^}]*};/allow-query { any; };/' "$CONF"
    named-checkconf &>/dev/null || return 1
    systemctl restart named &>/dev/null
    if systemctl is-active --quiet firewalld; then
        firewall-cmd --list-services | grep -qw dns || {
            firewall-cmd --add-service=dns --permanent &>/dev/null
            firewall-cmd --reload &>/dev/null
        }
    fi
}

instalar_dns() {
    if rpm -q bind &>/dev/null; then
        echo "BIND ya esta instalado."; read -p "Enter..."; return
    fi
    echo "Instalando BIND..."
    dnf install -y bind bind-utils &>/dev/null
    if rpm -q bind &>/dev/null; then
        echo -e "${GREEN}[EXITO] BIND instalado.${NC}"
        systemctl enable named &>/dev/null
        systemctl start named
        aplicar_reglas_dns
    else
        echo -e "${RED}[ERROR] Fallo la instalacion.${NC}"
    fi
    read -p "Enter..."
}

nuevo_dominio() {
    read -p "Nombre del dominio (ej: empresa.local): " DOMINIO
    [ -z "$DOMINIO" ] && { echo "Dominio invalido."; sleep 2; return; }
    grep -q "zone \"$DOMINIO\"" /etc/named.conf && { echo "El dominio ya existe."; sleep 2; return; }

    while true; do
        read -p "IP para el dominio: " IP_DOM
        [[ $IP_DOM =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]] && break
        echo "Formato de IP invalido."
    done

    local ZONA_FILE="/var/named/$DOMINIO.zone"
    cat <<EOF >> /etc/named.conf

zone "$DOMINIO" IN {
    type master;
    file "$ZONA_FILE";
};
EOF

    cat <<EOF > "$ZONA_FILE"
\$TTL 86400
@   IN  SOA ns1.$DOMINIO. admin.$DOMINIO. (
        $(date +%Y%m%d%H) 3600 1800 604800 86400 )
@       IN  NS  ns1.$DOMINIO.
ns1     IN  A   $IP_DOM
@       IN  A   $IP_DOM
www     IN  A   $IP_DOM
EOF

    chown named:named "$ZONA_FILE"
    chmod 640 "$ZONA_FILE"
    systemctl restart named

    if systemctl is-active --quiet named; then
        echo -e "${GREEN}[EXITO] Dominio $DOMINIO → $IP_DOM${NC}"
    else
        echo -e "${RED}[ERROR] named no pudo iniciar.${NC}"
    fi
    read -p "Enter..."
}

borrar_dominio() {
    read -p "Dominio a eliminar: " DOMINIO
    if ! grep -q "zone \"$DOMINIO\"" /etc/named.conf; then
        echo "El dominio no existe."; sleep 2; return
    fi
    sed -i "/zone \"$DOMINIO\"/,/};/d" /etc/named.conf
    rm -f "/var/named/$DOMINIO.zone"
    systemctl restart named
    echo -e "${GREEN}Dominio eliminado.${NC}"
    read -p "Enter..."
}

consultar_dominio() {
    clear
    mapfile -t DOMINIOS < <(grep -oP 'zone\s+"\K[^"]+' /etc/named.conf)
    if [ ${#DOMINIOS[@]} -eq 0 ]; then
        echo "No hay dominios configurados."; read -p "Enter..."; return
    fi
    echo "Dominios disponibles:"
    for i in "${!DOMINIOS[@]}"; do echo "$((i+1))) ${DOMINIOS[$i]}"; done
    read -p "Seleccione numero: " op
    if ! [[ "$op" =~ ^[0-9]+$ ]] || (( op < 1 || op > ${#DOMINIOS[@]} )); then
        echo "Seleccion invalida."; sleep 2; return
    fi
    local DOM="${DOMINIOS[$((op-1))]}"
    echo "========================================"
    echo "Dominio: $DOM"
    echo "IP: $(dig @localhost +short "$DOM")"
    echo "========================================"
    read -p "Enter..."
}

menu_dns() {
    while true; do
        clear
        echo "========================================"
        echo "            SERVICIO DNS"
        echo "========================================"
        echo "1) Estado    2) Instalar    3) Nuevo Dominio"
        echo "4) Borrar    5) Consultar   6) Volver"
        echo "========================================"
        read -p "Opcion: " op
        case $op in
            1) estado_dns ;;
            2) instalar_dns ;;
            3) nuevo_dominio ;;
            4) borrar_dominio ;;
            5) consultar_dominio ;;
            6) break ;;
            *) echo "Opcion no valida"; sleep 1 ;;
        esac
    done
}
