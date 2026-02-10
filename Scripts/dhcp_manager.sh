#!/bin/bash

validar_ip() {
    local ip=$1
    if [[ $ip =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]]; then
        IFS='.' read -ra ADDR <<< "$ip"
        for i in "${ADDR[@]}"; do
            if [ $i -gt 255 ]; then
                return 1
            fi
        done
        return 0
    fi
    return 1
}

verificar_instalacion() {
    if systemctl list-unit-files | grep -q dhcpd.service; then
        echo "Servicio DHCP ya está instalado"
        return 0
    else
        echo "Servicio DHCP no detectado"
        return 1
    fi
}

instalar_dhcp() {
    echo "Iniciando instalación de DHCP Server..."
    dnf install -y dhcp-server > /dev/null 2>&1
    if [ $? -eq 0 ]; then
        echo "DHCP Server instalado correctamente"
    else
        echo "Error en la instalación"
        exit 1
    fi
}

configurar_dhcp() {
    clear
    echo "Configuración del Servidor DHCP"
    echo ""

    read -p "Nombre del Ámbito: " scope_name

    while true; do
        read -p "IP Inicial: " ip_inicio
        validar_ip "$ip_inicio" && break
        echo "IP inválida"
    done

    while true; do
        read -p "IP Final: " ip_final
        validar_ip "$ip_final" && break
        echo "IP inválida"
    done

    while true; do
        read -p "Gateway: " gateway
        validar_ip "$gateway" && break
        echo "IP inválida"
    done

    while true; do
        read -p "DNS: " dns
        validar_ip "$dns" && break
        echo "IP inválida"
    done

    read -p "Tiempo de concesión (segundos): " lease_time

    cat > /etc/dhcp/dhcpd.conf <<EOF
authoritative;
subnet 192.168.100.0 netmask 255.255.255.0 {
    range $ip_inicio $ip_final;
    option routers $gateway;
    option domain-name-servers $dns;
    default-lease-time $lease_time;
    max-lease-time $((lease_time * 2));
}
EOF

    echo "Configuración guardada"

    systemctl enable dhcpd > /dev/null 2>&1
    systemctl restart dhcpd

    if [ $? -eq 0 ]; then
        echo "Servicio DHCP iniciado"
    else
        echo "Error al iniciar el servicio"
    fi
}

estado_servicio() {
    systemctl status dhcpd --no-pager
}

listar_concesiones() {
    if [ -f /var/lib/dhcpd/dhcpd.leases ]; then
        grep -E "lease|binding state|client-hostname" /var/lib/dhcpd/dhcpd.leases
    else
        echo "No hay concesiones registradas"
    fi
}

menu_principal() {
    while true; do
        clear
        echo "Gestor DHCP - Oracle Linux"
        echo "1) Verificar / Instalar DHCP"
        echo "2) Configurar DHCP"
        echo "3) Estado del Servicio"
        echo "4) Listar Concesiones"
        echo "5) Salir"
        read -p "Opción: " opcion

        case $opcion in
            1)
                verificar_instalacion || instalar_dhcp
                read -p "Enter para continuar"
                ;;
            2)
                configurar_dhcp
                read -p "Enter para continuar"
                ;;
            3)
                estado_servicio
                read -p "Enter para continuar"
                ;;
            4)
                listar_concesiones
                read -p "Enter para continuar"
                ;;
            5)
                exit 0
                ;;
            *)
                echo "Opción inválida"
                sleep 2
                ;;
        esac
    done
}

if [ "$EUID" -ne 0 ]; then
    echo "Ejecute el script como root (sudo)"
    exit 1
fi

menu_principal
