#!/bin/bash

#PERMISOS ROOT

if [ "$EUID" -ne 0 ]; then
    echo ""
    echo "  [!] Este script debe ejecutarse como root o con sudo."
    echo "      Uso: sudo bash servidor_linux.sh"
    echo ""
    exit 1
fi

RED='\033[0;31m'
GREEN='\033[0;32m'
NC='\033[0m'

#UTILIDADES

ip_to_int() {
    local IFS=.
    read -r i1 i2 i3 i4 <<< "$1"
    echo $(( (i1 << 24) + (i2 << 16) + (i3 << 8) + i4 ))
}

validar_formato_ip() {
    [[ $1 =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]]
}

validar_ip_utilizable() {
    local IP=$1
    if ! validar_formato_ip "$IP"; then return 1; fi
    IFS='.' read -r o1 o2 o3 o4 <<< "$IP"
    for oct in $o1 $o2 $o3 $o4; do
        [ "$oct" -lt 0 ] || [ "$oct" -gt 255 ] && return 1
    done
    [ "$IP"  = "0.0.0.0" ]  && { echo "  Error: IP 0.0.0.0 no valida.";            return 1; }
    [ "$IP"  = "127.0.0.1" ] && { echo "  Error: Localhost no permitido.";           return 1; }
    [ "$o4" -eq 0 ]           && { echo "  Error: IP de Red (termina en .0).";        return 1; }
    [ "$o4" -eq 255 ]         && { echo "  Error: IP de Broadcast (termina en .255)."; return 1; }
    return 0
}

#SERVICIO DHCP

dhcp_estado() {
    while true; do
        clear
        echo "================================"
        echo "  ESTADO DEL SERVICIO DHCP"
        echo "================================"
        echo ""

        if ! rpm -q kea &> /dev/null; then
            echo -e "  ${RED}[!] El paquete 'kea' no esta instalado.${NC}"
            echo "  Use la opcion 2 para instalarlo."
            echo ""
            read -p "  Presione Enter para volver..."
            return
        fi

        if systemctl is-active --quiet kea-dhcp4; then
            echo -e "  Estado: ${GREEN}ACTIVO (Running)${NC}"
            echo ""
            echo "  1) Detener el servicio"
            echo "  2) Reiniciar y limpiar concesiones"
            echo "  3) Volver"
        else
            echo -e "  Estado: ${RED}DETENIDO (Stopped)${NC}"
            echo ""
            echo "  1) Iniciar el servicio"
            echo "  3) Volver"
        fi

        echo ""
        read -p "  Seleccione una opcion: " sub

        case $sub in
            1)
                if systemctl is-active --quiet kea-dhcp4; then
                    echo -e "  ${RED}Deteniendo servicio...${NC}"
                    systemctl stop kea-dhcp4
                else
                    echo -e "  ${GREEN}Iniciando servicio...${NC}"
                    systemctl start kea-dhcp4
                fi
                sleep 1.5
                ;;
            2)
                if systemctl is-active --quiet kea-dhcp4; then
                    echo -e "  ${GREEN}Reiniciando y purgando concesiones...${NC}"
                    systemctl stop kea-dhcp4
                    if [ -f /var/lib/kea/kea-leases4.csv ]; then
                        rm -f /var/lib/kea/kea-leases4.csv
                        echo "  > Historial de IPs eliminado."
                    fi
                    systemctl start kea-dhcp4
                    systemctl is-active --quiet kea-dhcp4 \
                        && echo -e "  ${GREEN}> Servicio reiniciado correctamente.${NC}" \
                        || echo -e "  ${RED}> Error al reiniciar el servicio.${NC}"
                    sleep 2
                else
                    echo "  El servicio no esta activo."
                    sleep 1.5
                fi
                ;;
            3) return ;;
            *) echo "  Opcion no valida."; sleep 1 ;;
        esac
    done
}

dhcp_instalar() {
    clear
    echo "================================"
    echo "  INSTALACION DEL SERVICIO DHCP"
    echo "================================"
    echo ""

    if rpm -q kea &> /dev/null; then
        echo "  El servicio ya esta instalado."
        read -p "  Presione Enter..."
        return
    fi

    echo "  Iniciando instalacion... Por favor espere."
    echo ""

    OL_VERSION=$(grep -oP '(?<=^VERSION_ID=")[0-9]+' /etc/os-release 2>/dev/null | cut -d. -f1)
    if [ -z "$OL_VERSION" ]; then
        OL_VERSION=$(rpm -E '%{rhel}' 2>/dev/null)
    fi

    if [ -z "$OL_VERSION" ]; then
        echo -e "  ${RED}[ERROR] No se pudo detectar la version del sistema operativo.${NC}"
        read -p "  Presione Enter..."
        return
    fi

    echo "  Versión detectada: Oracle Linux $OL_VERSION"
    echo ""

    #Habilitar EPEL con el paquete correcto para la versión detectada
    echo "  [1/3] Habilitando repositorio EPEL..."
    dnf install -y epel-release "oracle-epel-release-el${OL_VERSION}" &> /tmp/kea_install.log
    if [ $? -ne 0 ]; then
        echo "       Intentando metodo alternativo..."
        dnf install -y epel-release &>> /tmp/kea_install.log
    fi

    # Habilitar CodeReady/PowerTools si está disponible
    echo "  [2/3] Habilitando repositorios adicionales..."
    dnf config-manager --set-enabled ol${OL_VERSION}_codeready_builder &>> /tmp/kea_install.log 2>&1 || true
    dnf config-manager --set-enabled powertools &>> /tmp/kea_install.log 2>&1 || true

    #Instalar Kea
    echo "  [3/3] Instalando Kea DHCP..."
    dnf install -y kea &>> /tmp/kea_install.log

    if [ $? -eq 0 ] && rpm -q kea &> /dev/null; then
        echo -e "  ${GREEN}[EXITO] Instalacion completada correctamente.${NC}"
    else
        echo -e "  ${RED}[ERROR] La instalacion fallo. Revise el log para mas detalles:${NC}"
        echo ""
        echo "  --- Ultimas lineas del log ---"
        tail -n 10 /tmp/kea_install.log
        echo "  --- Fin del log ---"
        echo ""
        echo "  Log completo en: /tmp/kea_install.log"
    fi
    read -p "  Presione Enter..."
}

dhcp_configurar() {
    clear
    echo "================================"
    echo "  CONFIGURACION DE DHCP"
    echo "================================"
    echo ""

    if ! rpm -q kea &> /dev/null; then
        echo "  Error: Instale el servicio primero."
        read -p "  Enter..."; return
    fi

    echo "  Interfaces disponibles:"
    ip -o link show | awk -F': ' '{print "   - " $2}'
    echo ""

    while true; do
        read -p "  1. Adaptador de red: " INTERFAZ
        ip link show "$INTERFAZ" &> /dev/null && break
        echo -e "  ${RED}[!] La interfaz no existe.${NC}"
    done

    command -v nmcli &> /dev/null && nmcli device set "$INTERFAZ" managed no &> /dev/null

    read -p "  2. Nombre del Ambito: " SCOPE_NAME

    while true; do
        read -p "  3. Rango inicial (IP del servidor): " IP_INICIO
        validar_ip_utilizable "$IP_INICIO" && break
        echo -e "  ${RED}   [!] IP invalida.${NC}"
    done

    PREFIX=$(echo "$IP_INICIO" | cut -d'.' -f1-3)
    LAST_OCTET=$(echo "$IP_INICIO" | cut -d'.' -f4)
    POOL_START="$PREFIX.$((LAST_OCTET + 1))"
    SUBNET="$PREFIX.0"

    while true; do
        read -p "  4. Rango final ($PREFIX.X): " IP_FIN
        if ! validar_ip_utilizable "$IP_FIN"; then echo -e "  ${RED}   [!] IP invalida.${NC}"; continue; fi
        [ "$(echo "$IP_FIN" | cut -d'.' -f1-3)" != "$PREFIX" ] && { echo -e "  ${RED}   [!] Debe estar en el segmento $PREFIX.x${NC}"; continue; }
        [ $(ip_to_int "$POOL_START") -le $(ip_to_int "$IP_FIN") ] && break
        echo -e "  ${RED}   [!] El rango final debe ser mayor o igual a $POOL_START.${NC}"
    done

    while true; do
        read -p "  5. Gateway (Enter para omitir): " GATEWAY
        [ -z "$GATEWAY" ] && break
        if validar_ip_utilizable "$GATEWAY"; then
            [ "$(echo "$GATEWAY" | cut -d'.' -f1-3)" = "$PREFIX" ] && break
            echo -e "  ${RED}   [!] El Gateway debe pertenecer a la red $PREFIX.x${NC}"
        else
            echo -e "  ${RED}   [!] IP invalida.${NC}"
        fi
    done

    read -p "  6. DNS (Enter para omitir): " DNS_SERVER
    if [ -n "$DNS_SERVER" ] && ! validar_formato_ip "$DNS_SERVER"; then
        echo "     [!] DNS invalido, se omitira."; DNS_SERVER=""
    fi

    while true; do
        read -p "  7. Tiempo de concesion (segundos): " LEASE_TIME
        [[ "$LEASE_TIME" =~ ^[0-9]+$ ]] && break
        echo -e "  ${RED}   [!] Debe ser un numero entero.${NC}"
    done

    clear
    echo "================================"
    echo "  RESUMEN DE CONFIGURACION"
    echo "================================"
    echo ""
    echo "  1- Adaptador de red:    $INTERFAZ"
    echo "  2- Nombre del ambito:   $SCOPE_NAME"
    echo "  3- Rango inicial:       $IP_INICIO"
    echo "  4- Rango final:         $IP_FIN"
    echo "  5- Gateway:             ${GATEWAY:-(sin gateway)}"
    echo "  6- DNS:                 ${DNS_SERVER:-(sin DNS)}"
    echo "  7- Tiempo de concesion: $LEASE_TIME segundos"
    echo ""
    read -p "  Confirmar configuracion (S/N): " CONFIRM
    [[ "$CONFIRM" != "s" && "$CONFIRM" != "S" ]] && { echo "  Configuracion cancelada."; sleep 1; return; }

    echo ""
    echo "  Configurando IP estatica en $INTERFAZ..."
    ip link set "$INTERFAZ" down
    ip addr flush dev "$INTERFAZ"
    ip addr add "$IP_INICIO/24" dev "$INTERFAZ"
    ip link set "$INTERFAZ" up
    sleep 2

    echo "  Generando configuracion Kea..."

    OPTIONS_BLOCK=""
    [ -n "$GATEWAY" ]    && OPTIONS_BLOCK="$OPTIONS_BLOCK { \"name\": \"routers\", \"data\": \"$GATEWAY\" },"
    [ -n "$DNS_SERVER" ] && OPTIONS_BLOCK="$OPTIONS_BLOCK { \"name\": \"domain-name-servers\", \"data\": \"$DNS_SERVER\" },"
    OPTIONS_BLOCK=$(echo "$OPTIONS_BLOCK" | sed 's/,$//')

    [ -f /etc/kea/kea-dhcp4.conf ] && cp /etc/kea/kea-dhcp4.conf /etc/kea/kea-dhcp4.conf.bak

    cat <<EOF > /etc/kea/kea-dhcp4.conf
{
    "Dhcp4": {
        "interfaces-config": { "interfaces": [ "$INTERFAZ" ] },
        "lease-database": {
            "type": "memfile",
            "persist": true,
            "name": "/var/lib/kea/kea-leases4.csv"
        },
        "valid-lifetime": $LEASE_TIME,
        "max-valid-lifetime": $(($LEASE_TIME * 2)),
        "subnet4": [
            {
                "id": 1,
                "subnet": "$SUBNET/24",
                "user-context": { "name": "$SCOPE_NAME" },
                "pools": [ { "pool": "$POOL_START - $IP_FIN" } ],
                "option-data": [ $OPTIONS_BLOCK ]
            }
        ]
    }
}
EOF

    firewall-cmd --add-service=dhcp --permanent &>/dev/null
    firewall-cmd --reload &>/dev/null
    systemctl restart kea-dhcp4

    systemctl is-active --quiet kea-dhcp4 \
        && echo -e "  ${GREEN}[EXITO] Servicio configurado y activo.${NC}" \
        || echo -e "  ${RED}[ERROR] Kea no pudo iniciar.${NC}"

    read -p "  Presione Enter..."
}

dhcp_monitorear() {
    LEASE_FILE="/var/lib/kea/kea-leases4.csv"
    watch --color -n 2 -t "
      echo '================================';
      echo '  MONITOREAR SERVICIO DHCP';
      echo '================================';
      echo '';
      if systemctl is-active --quiet kea-dhcp4; then
          printf '  Estado: \033[1;32mACTIVO\033[0m\n';
      else
          printf '  Estado: \033[1;31mINACTIVO\033[0m\n';
      fi
      echo '';
      echo '  Clientes Conectados:';
      printf '  %-18s | %-18s | %-25s\n' 'DIRECCION IP' 'MAC ADDRESS' 'HOSTNAME';
      echo '  ------------------|------------------|------------------------';
      if [ -f $LEASE_FILE ]; then
         tail -n +2 $LEASE_FILE | awk -F, '{
            host = \$9; gsub(/\"/, \"\", host);
            if (host == \"\" || host == \" \") host = \"---\";
            fmt = sprintf(\"  %-18s | %-18s | %-25s\", \$1, \$2, host);
            clientes[\$2] = fmt;
         } END { for (m in clientes) print clientes[m]; }' | sort -V
      else
         echo '  Sin base de datos de concesiones...'
      fi
    "
}

menu_dhcp() {
    while true; do
        clear
        echo "================================"
        echo "  GESTIONAR SERVICIO DHCP"
        echo "================================"
        echo ""
        echo "  1) Verificar Estado del Servicio"
        echo "  2) Instalar Servicio"
        echo "  4) Configurar Servicio"
        echo "  5) Monitorear Servicio"
        echo "  6) Volver al menu principal"
        echo ""
        read -p "  Opcion: " OPCION

        case $OPCION in
            1) dhcp_estado ;;
            2) dhcp_instalar ;;
            4) dhcp_configurar ;;
            5) dhcp_monitorear ;;
            6) break ;;
            *) echo "  Opcion no valida."; sleep 1 ;;
        esac
    done
}

#SERVICIO DNS

dns_estado() {
    while true; do
        clear
        echo "================================"
        echo "  ESTADO DEL SERVICIO DNS"
        echo "================================"
        echo ""

        if ! rpm -q bind &> /dev/null; then
            echo -e "  ${RED}[!] El paquete 'bind' no esta instalado.${NC}"
            echo "  Use la opcion 2 para instalarlo."
            echo ""
            read -p "  Presione Enter..."
            return
        fi

        if systemctl is-active --quiet named; then
            echo -e "  Estado: ${GREEN}ACTIVO (Running)${NC}"
            echo ""
            echo "  1) Detener servicio"
            echo "  2) Reiniciar servicio"
            echo "  3) Volver"
        else
            echo -e "  Estado: ${RED}INACTIVO (Stopped)${NC}"
            echo ""
            echo "  1) Iniciar servicio"
            echo "  3) Volver"
        fi

        echo ""
        read -p "  Seleccione una opcion: " opcion

        case $opcion in
            1)
                if systemctl is-active --quiet named; then
                    echo "  Deteniendo servicio..."; systemctl stop named
                else
                    echo "  Iniciando servicio..."; systemctl start named
                fi
                sleep 2 ;;
            2)
                if systemctl is-active --quiet named; then
                    echo "  Reiniciando servicio..."; systemctl restart named; sleep 2
                else
                    echo "  El servicio esta detenido. No se puede reiniciar."; sleep 2
                fi ;;
            3) return ;;
            *) echo "  Opcion no valida."; sleep 1 ;;
        esac
    done
}

dns_instalar() {
    clear
    echo "================================"
    echo "  INSTALACION DEL SERVICIO DNS"
    echo "================================"
    echo ""

    if rpm -q bind &> /dev/null; then
        echo "  El servicio DNS ya esta instalado."
        read -p "  Presione Enter..."; return
    fi

    echo "  Instalando BIND... Por favor espere."
    dnf install -y bind bind-utils &> /dev/null

    if [ $? -eq 0 ]; then
        echo -e "  ${GREEN}[EXITO] Instalacion completada.${NC}"
        systemctl enable named &> /dev/null
        systemctl start named
    else
        echo -e "  ${RED}[ERROR] Fallo la instalacion.${NC}"
    fi
    read -p "  Presione Enter..."
}

dns_nuevo_dominio() {
    clear
    echo "================================"
    echo "  NUEVO DOMINIO DNS"
    echo "================================"
    echo ""

    read -p "  Nombre del dominio (ej: reprobados.com): " DOMINIO
    if [ -z "$DOMINIO" ]; then echo "  Dominio invalido."; sleep 2; return; fi

    read -p "  Interfaz de red interna (ej: enp0s8): " INTERFAZ_DNS
    IP_SERVIDOR=$(ip -4 addr show "$INTERFAZ_DNS" 2>/dev/null | grep inet | awk '{print $2}' | cut -d/ -f1)

    if [ -z "$IP_SERVIDOR" ]; then
        echo "  No se pudo obtener la IP de la interfaz '$INTERFAZ_DNS'."
        sleep 2; return
    fi

    ZONA_FILE="/var/named/$DOMINIO.zone"

    if grep -q "zone \"$DOMINIO\"" /etc/named.conf 2>/dev/null; then
        echo "  El dominio ya existe."; sleep 2; return
    fi

    echo "  Creando zona DNS..."

    cat <<EOF >> /etc/named.conf

zone "$DOMINIO" IN {
    type master;
    file "$ZONA_FILE";
    allow-query { any; };
};
EOF

    cat <<EOF > "$ZONA_FILE"
\$TTL 86400
@   IN  SOA ns1.$DOMINIO. admin.$DOMINIO. (
        2026021701 3600 1800 604800 86400 )

@       IN  NS      ns1.$DOMINIO.
ns1     IN  A       $IP_SERVIDOR
@       IN  A       $IP_SERVIDOR
www     IN  A       $IP_SERVIDOR
EOF

    chown named:named "$ZONA_FILE"
    chmod 640 "$ZONA_FILE"

    firewall-cmd --add-service=dns --permanent &> /dev/null
    firewall-cmd --reload &> /dev/null

    systemctl restart named

    # Limpiar cache para que los clientes resuelvan el nuevo dominio
    command -v rndc &> /dev/null && { rndc flush &> /dev/null; echo "  > Cache DNS limpiada."; }

    systemctl is-active --quiet named \
        && echo -e "  ${GREEN}[EXITO] Dominio '$DOMINIO' creado. IP: $IP_SERVIDOR${NC}" \
        || echo -e "  ${RED}[ERROR] named no pudo iniciar.${NC}"

    read -p "  Presione Enter..."
}

dns_borrar_dominio() {
    clear
    echo "================================"
    echo "  BORRAR DOMINIO DNS"
    echo "================================"
    echo ""

    read -p "  Dominio a eliminar: " DOMINIO
    ZONA_FILE="/var/named/$DOMINIO.zone"

    if ! grep -q "zone \"$DOMINIO\"" /etc/named.conf 2>/dev/null; then
        echo "  El dominio no existe."; sleep 2; return
    fi

    sed -i "/zone \"$DOMINIO\"/,/};/d" /etc/named.conf
    rm -f "$ZONA_FILE"
    systemctl restart named

    #Limpiar cache para que los clientes dejen de resolver el dominio eliminado
    command -v rndc &> /dev/null && { rndc flush &> /dev/null; echo "  > Cache DNS limpiada."; }

    echo -e "  ${GREEN}Dominio '$DOMINIO' eliminado correctamente.${NC}"
    read -p "  Presione Enter..."
}

dns_consultar_dominio() {
    clear
    echo "================================"
    echo "  CONSULTAR DOMINIO DNS"
    echo "================================"
    echo ""

    DOMINIOS=($(grep -oP 'zone\s+"\K[^"]+' /etc/named.conf 2>/dev/null))

    if [ ${#DOMINIOS[@]} -eq 0 ]; then
        echo "  No hay dominios configurados."
        read -p "  Presione Enter..."; return
    fi

    echo "  Dominios disponibles:"
    echo ""
    for i in "${!DOMINIOS[@]}"; do echo "  $((i+1))) ${DOMINIOS[$i]}"; done

    echo ""
    read -p "  Seleccione un dominio: " opcion

    if ! [[ "$opcion" =~ ^[0-9]+$ ]] || [ "$opcion" -lt 1 ] || [ "$opcion" -gt ${#DOMINIOS[@]} ]; then
        echo "  Seleccion invalida."; sleep 2; return
    fi

    DOMINIO_SEL=${DOMINIOS[$((opcion-1))]}

    clear
    echo "================================"
    echo "  DOMINIO: $DOMINIO_SEL"
    echo "================================"
    echo ""
    echo "  IP asociada al dominio:"
    dig @localhost +short "$DOMINIO_SEL"
    echo ""
    read -p "  Presione Enter..."
}

menu_dns() {
    while true; do
        clear
        echo "================================"
        echo "  GESTIONAR SERVICIO DNS"
        echo "================================"
        echo ""
        echo "  1) Estado del servicio DNS"
        echo "  2) Instalar el servicio DNS"
        echo "  3) Nuevo Dominio"
        echo "  4) Borrar Dominio"
        echo "  5) Consultar Dominio"
        echo "  6) Volver al menu principal"
        echo ""
        read -p "  Selecciona una opcion: " opcion

        case $opcion in
            1) dns_estado ;;
            2) dns_instalar ;;
            3) dns_nuevo_dominio ;;
            4) dns_borrar_dominio ;;
            5) dns_consultar_dominio ;;
            6) break ;;
            *) echo "  Opcion invalida."; sleep 1 ;;
        esac
    done
}

#MENU PRINCIPAL

while true; do
    clear
    echo "================================"
    echo "  MENU DE SERVICIOS DEL SERVIDOR"
    echo "================================"
    echo ""
    echo "  1. Servicio DHCP"
    echo "  2. Servicio DNS"
    echo "  3. Salir"
    echo ""
    read -p "  Seleccione una opcion: " op

    case $op in
        1) menu_dhcp ;;
        2) menu_dns ;;
        3) exit 0 ;;
        *) echo "  Opcion invalida."; sleep 1 ;;
    esac
done
