#!/bin/bash

RED='\033[0;31m'
GREEN='\033[0;32m'
NC='\033[0m'

ip_a_entero() {
    local IFS=.
    read -r a b c d <<< "$1"
    echo $(( (a<<24)+(b<<16)+(c<<8)+d ))
}

validar_formato_ip() {
    [[ $1 =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]] && return 0; return 1
}

validar_ip_utilizable() {
    local IP=$1
    if ! validar_formato_ip "$IP"; then return 1; fi
    IFS='.' read -r o1 o2 o3 o4 <<< "$IP"
    for oct in $o1 $o2 $o3 $o4; do
        (( oct < 0 || oct > 255 )) && return 1
    done
    [ "$IP" = "0.0.0.0" ]   && { echo "Error: 0.0.0.0 no valida"; return 1; }
    [ "$IP" = "127.0.0.1" ] && { echo "Error: Localhost no permitido"; return 1; }
    (( o4 == 0 ))   && { echo "Error: IP de red (.0)"; return 1; }
    (( o4 == 255 )) && { echo "Error: IP de broadcast (.255)"; return 1; }
    return 0
}

estado_servicio() {
    while true; do
        clear
        echo "----------------------------------------"
        echo "        ESTADO DEL SERVICIO DHCP"
        echo "----------------------------------------"
        if ! rpm -q kea &>/dev/null; then
            echo -e "${RED}[!] Paquete 'kea' no instalado.${NC}"
            read -p "Enter..."; return
        fi
        if systemctl is-active --quiet kea-dhcp4; then
            echo -e "Estado: ${GREEN}ACTIVO${NC}"
            systemctl status kea-dhcp4 --no-pager | grep "Active:"
            echo "----------------------------------------"
            echo " [1] Detener  [2] Reiniciar y limpiar  [3] Volver"
        else
            echo -e "Estado: ${RED}DETENIDO${NC}"
            echo "----------------------------------------"
            echo " [1] Iniciar  [3] Volver"
        fi
        read -p "Opcion: " sub
        case $sub in
            1)
                if systemctl is-active --quiet kea-dhcp4; then
                    systemctl stop kea-dhcp4 && echo "Servicio detenido."
                else
                    systemctl start kea-dhcp4 && echo "Servicio iniciado."
                fi; sleep 1.5 ;;
            2)
                if systemctl is-active --quiet kea-dhcp4; then
                    systemctl stop kea-dhcp4
                    rm -f /var/lib/kea/kea-leases4.csv
                    systemctl start kea-dhcp4
                    echo "Reiniciado y leases limpiados."; sleep 2
                fi ;;
            3) return ;;
            *) echo "Opcion no valida"; sleep 1 ;;
        esac
    done
}

instalar_servicio() {
    echo "----------------------------------------"
    echo "        INSTALACION DHCP (KEA)"
    echo "----------------------------------------"
    if rpm -q kea &>/dev/null; then
        echo "KEA ya esta instalado."
        read -p "Enter..."; return
    fi
    echo "Instalando... espere."
    dnf install -y epel-release oracle-epel-release-el9 &>/dev/null
    dnf install -y kea &>/dev/null
    if rpm -q kea &>/dev/null; then
        echo -e "${GREEN}[EXITO] KEA instalado.${NC}"
    else
        echo -e "${RED}[ERROR] Fallo la instalacion.${NC}"
    fi
    read -p "Enter..."
}

configurar_servicio() {
    clear
    echo "========================================"
    echo "       CONFIGURACION DE DHCP"
    echo "========================================"
    if ! rpm -q kea &>/dev/null; then
        echo "Instale el servicio primero."
        read -p "Enter..."; return
    fi

    echo "Interfaces disponibles:"
    ip -o link show | awk -F': ' '{print " -",$2}'
    echo "----------------------------------------"

    while true; do
        read -p "1. Adaptador de red: " INTERFAZ
        ip link show "$INTERFAZ" &>/dev/null && break
        echo -e "${RED}   [!] Interfaz no encontrada.${NC}"
    done

    command -v nmcli &>/dev/null && nmcli device set "$INTERFAZ" managed no &>/dev/null

    read -p "2. Nombre del Ambito: " SCOPE_NAME

    while true; do
        read -p "3. IP del servidor (rango inicial): " IP_INICIO
        validar_ip_utilizable "$IP_INICIO" && break
        echo -e "${RED}   [!] IP invalida${NC}"
    done

    PREFIX=$(echo "$IP_INICIO" | cut -d'.' -f1-3)
    LAST_OCT=$(echo "$IP_INICIO" | cut -d'.' -f4)
    POOL_START="$PREFIX.$((LAST_OCT+1))"
    SUBNET="$PREFIX.0"

    while true; do
        read -p "4. Rango final ($PREFIX.X): " IP_FIN
        if ! validar_ip_utilizable "$IP_FIN"; then echo -e "${RED}   [!] IP invalida.${NC}"; continue; fi
        if [ "$(echo "$IP_FIN"|cut -d'.' -f1-3)" != "$PREFIX" ]; then
            echo -e "${RED}   [!] Debe estar en $PREFIX.x${NC}"; continue
        fi
        [ "$(ip_a_entero "$POOL_START")" -le "$(ip_a_entero "$IP_FIN")" ] && break
        echo -e "${RED}   [!] Debe ser mayor o igual a $POOL_START.${NC}"
    done

    while true; do
        read -p "5. Gateway (Enter para omitir): " GATEWAY
        [ -z "$GATEWAY" ] && break
        if validar_ip_utilizable "$GATEWAY"; then
            [ "$(echo "$GATEWAY"|cut -d'.' -f1-3)" = "$PREFIX" ] && break
            echo -e "${RED}   [!] Gateway debe estar en $PREFIX.x${NC}"
        else
            echo -e "${RED}   [!] IP invalida.${NC}"
        fi
    done

    DNS_SERVER="$IP_INICIO"

    while true; do
        read -p "6. Tiempo de concesion (segundos): " LEASE_TIME
        [[ "$LEASE_TIME" =~ ^[0-9]+$ ]] && break
        echo -e "${RED}   [!] Solo numeros enteros.${NC}"
    done

    clear
    echo "========================================"
    echo "        RESUMEN DE CONFIGURACION"
    echo "========================================"
    echo "Adaptador:    $INTERFAZ"
    echo "Ambito:       $SCOPE_NAME"
    echo "IP Servidor:  $IP_INICIO"
    echo "Pool:         $POOL_START - $IP_FIN"
    echo "Gateway:      ${GATEWAY:-'(ninguno)'}"
    echo "DNS:          $DNS_SERVER"
    echo "Concesion:    $LEASE_TIME seg"
    echo "========================================"
    read -p "Confirmar (S/N): " CONFIRM
    [[ "$CONFIRM" != "s" && "$CONFIRM" != "S" ]] && { echo "Cancelado."; return; }

    echo "Configurando IP estatica en $INTERFAZ..."
    ip link set "$INTERFAZ" down
    ip addr flush dev "$INTERFAZ"
    ip addr add "$IP_INICIO/24" dev "$INTERFAZ"
    ip link set "$INTERFAZ" up
    sleep 1

    OPT_BLOCK=""
    [ -n "$GATEWAY" ]    && OPT_BLOCK="${OPT_BLOCK}{ \"name\": \"routers\", \"data\": \"$GATEWAY\" },"
    [ -n "$DNS_SERVER" ] && OPT_BLOCK="${OPT_BLOCK}{ \"name\": \"domain-name-servers\", \"data\": \"$DNS_SERVER\" },"
    OPT_BLOCK="${OPT_BLOCK%,}"

    [ -f /etc/kea/kea-dhcp4.conf ] && cp /etc/kea/kea-dhcp4.conf /etc/kea/kea-dhcp4.conf.bak

    cat <<EOF > /etc/kea/kea-dhcp4.conf
{
    "Dhcp4": {
        "interfaces-config": { "interfaces": [ "$INTERFAZ" ] },
        "lease-database": { "type": "memfile", "persist": true, "name": "/var/lib/kea/kea-leases4.csv" },
        "valid-lifetime": $LEASE_TIME,
        "max-valid-lifetime": $((LEASE_TIME*2)),
        "subnet4": [{
            "id": 1,
            "subnet": "$SUBNET/24",
            "user-context": { "name": "$SCOPE_NAME" },
            "pools": [ { "pool": "$POOL_START - $IP_FIN" } ],
            "option-data": [ $OPT_BLOCK ]
        }]
    }
}
EOF

    firewall-cmd --add-service=dhcp --permanent &>/dev/null
    firewall-cmd --reload &>/dev/null
    systemctl enable kea-dhcp4 &>/dev/null
    systemctl restart kea-dhcp4

    if systemctl is-active --quiet kea-dhcp4; then
        echo -e "${GREEN}[EXITO] DHCP activo y configurado.${NC}"
    else
        echo -e "${RED}[ERROR] KEA no pudo iniciar. Revisa /etc/kea/kea-dhcp4.conf${NC}"
    fi
    read -p "Enter..."
}

monitorear_servicio() {
    local LEASE_FILE="/var/lib/kea/kea-leases4.csv"
    watch --color -n 2 -t "
      echo '=========================================================================='
      echo '                   MONITOREAR SERVICIO DHCP'
      echo '=========================================================================='
      if systemctl is-active --quiet kea-dhcp4; then
          printf 'Estado: \033[1;32mACTIVO\033[0m\n'
      else
          printf 'Estado: \033[1;31mINACTIVO\033[0m\n'
      fi
      echo '--------------------------------------------------------------------------'
      printf '%-20s | %-20s | %-30s\n' 'DIRECCION IP' 'MAC ADDRESS' 'HOSTNAME'
      echo '---------------------|----------------------|-----------------------------'
      if [ -f $LEASE_FILE ]; then
         tail -n +2 $LEASE_FILE | awk -F, '{
            host=\$9; gsub(/\"/,\"\",host)
            if(host==\"\"||host==\" \") host=\"---\"
            datos[\$2]=sprintf(\"%-20s | %-20s | %-30s\",\$1,\$2,host)
         } END{for(m in datos)print datos[m]}' | sort -V
      else
         echo '  Sin archivo de leases todavia...'
      fi
    "
}

menu_dhcp() {
    while true; do
        clear
        echo "========================================"
        echo "        GESTIONAR SERVICIO DHCP"
        echo "========================================"
        echo "1. Estado del Servicio"
        echo "2. Instalar Servicio"
        echo "3. Configurar Servicio"
        echo "4. Monitorear Servicio"
        echo "5. Volver"
        echo "========================================"
        read -p "Opcion: " op
        case $op in
            1) estado_servicio ;;
            2) instalar_servicio ;;
            3) configurar_servicio ;;
            4) monitorear_servicio ;;
            5) break ;;
            *) echo "Opcion no valida"; sleep 1 ;;
        esac
    done
}
