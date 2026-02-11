#!/bin/bash

validar_ip() {
    local ip=$1
    
    if [ -z "$ip" ]; then
        return 0
    fi
    
    if [[ ! $ip =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]]; then
        return 1
    fi
    
    IFS='.' read -ra octetos <<< "$ip"
    for octeto in "${octetos[@]}"; do
        if [ $octeto -gt 255 ]; then
            return 1
        fi
    done
    
    local primer_octeto=${octetos[0]}
    local segundo_octeto=${octetos[1]}
    
    if [ $primer_octeto -eq 0 ] || [ $primer_octeto -eq 127 ]; then
        echo "Error: IP reservada (rango $primer_octeto.x.x.x no permitido)"
        return 1
    fi
    
    if [ $primer_octeto -eq 169 ] && [ $segundo_octeto -eq 254 ]; then
        echo "Error: IP reservada (rango 169.254.x.x no permitido)"
        return 1
    fi
    
    if [ $primer_octeto -ge 224 ] && [ $primer_octeto -le 239 ]; then
        echo "Error: IP reservada (rango multicast 224-239.x.x.x no permitido)"
        return 1
    fi
    
    if [ $primer_octeto -eq 255 ]; then
        echo "Error: IP reservada (255.x.x.x no permitido)"
        return 1
    fi
    
    return 0
}

verificar_instalacion() {
    clear
    echo "=========================================="
    echo "  VERIFICACION DE INSTALACION"
    echo "=========================================="
    echo ""
    
    if systemctl list-unit-files | grep -q dhcpd.service; then
        echo "[OK] Servicio DHCP detectado"
        echo ""
        read -p "Desea reinstalar? (s/n): " reinstalar
        if [ "$reinstalar" = "s" ] || [ "$reinstalar" = "S" ]; then
            return 1
        else
            return 0
        fi
    else
        echo "[INFO] Servicio DHCP no instalado"
        return 1
    fi
}

instalar_dhcp() {
    echo ""
    echo "=========================================="
    echo "  INSTALACION DE DHCP SERVER"
    echo "=========================================="
    echo ""
    echo "Instalando paquetes necesarios..."
    
    dnf install -y dhcp-server > /dev/null 2>&1
    
    if [ $? -eq 0 ]; then
        echo "[OK] Instalacion completada"
    else
        echo "[ERROR] Fallo en la instalacion"
        exit 1
    fi
}

configurar_dhcp() {
    clear
    echo "=========================================="
    echo "  CONFIGURACION DEL SERVIDOR DHCP"
    echo "=========================================="
    echo ""
    
    read -p "Nombre del ambito: " scope_name
    
    while true; do
        read -p "IP inicial del rango: " ip_inicio
        if validar_ip "$ip_inicio"; then
            break
        else
            echo "IP invalida. Intente nuevamente."
        fi
    done
    
    while true; do
        read -p "IP final del rango: " ip_final
        if validar_ip "$ip_final"; then
            break
        else
            echo "IP invalida. Intente nuevamente."
        fi
    done
    
    IFS='.' read -ra inicio <<< "$ip_inicio"
    IFS='.' read -ra final <<< "$ip_final"
    subnet="${inicio[0]}.${inicio[1]}.${inicio[2]}.0"
    
    read -p "Puerta de enlace (Enter para omitir): " gateway
    if [ ! -z "$gateway" ]; then
        while ! validar_ip "$gateway"; do
            echo "IP invalida."
            read -p "Puerta de enlace (Enter para omitir): " gateway
            [ -z "$gateway" ] && break
        done
    fi
    
    read -p "DNS (Enter para omitir): " dns
    if [ ! -z "$dns" ]; then
        while ! validar_ip "$dns"; do
            echo "IP invalida."
            read -p "DNS (Enter para omitir): " dns
            [ -z "$dns" ] && break
        done
    fi
    
    read -p "Tiempo de concesion en segundos: " lease_time
    
    echo ""
    echo "Generando configuracion..."
    
    cat > /etc/dhcp/dhcpd.conf <<EOF
authoritative;
subnet $subnet netmask 255.255.255.0 {
    range $ip_inicio $ip_final;
EOF

    if [ ! -z "$gateway" ]; then
        echo "    option routers $gateway;" >> /etc/dhcp/dhcpd.conf
    fi
    
    if [ ! -z "$dns" ]; then
        echo "    option domain-name-servers $dns;" >> /etc/dhcp/dhcpd.conf
    fi
    
    cat >> /etc/dhcp/dhcpd.conf <<EOF
    default-lease-time $lease_time;
    max-lease-time $((lease_time * 2));
}
EOF
    
    echo "[OK] Configuracion guardada"
    
    systemctl enable dhcpd > /dev/null 2>&1
    systemctl restart dhcpd > /dev/null 2>&1
    
    if [ $? -eq 0 ]; then
        echo "[OK] Servicio DHCP iniciado"
    else
        echo "[ERROR] Fallo al iniciar el servicio"
        journalctl -u dhcpd -n 10 --no-pager
    fi
}

estado_servicio() {
    clear
    echo "=========================================="
    echo "  ESTADO DEL SERVICIO DHCP"
    echo "=========================================="
    echo ""
    systemctl status dhcpd --no-pager
}

listar_concesiones() {
    clear
    echo "=========================================="
    echo "  CONCESIONES ACTIVAS"
    echo "=========================================="
    echo ""
    
    if [ -f /var/lib/dhcpd/dhcpd.leases ]; then
        if grep -q "lease" /var/lib/dhcpd/dhcpd.leases; then
            cat /var/lib/dhcpd/dhcpd.leases | grep -E "lease|binding state|client-hostname"
        else
            echo "No hay concesiones activas"
        fi
    else
        echo "Archivo de concesiones no encontrado"
    fi
}

menu_principal() {
    while true; do
        clear
        echo "=========================================="
        echo "  GESTOR DE SERVIDOR DHCP"
        echo "=========================================="
        echo ""
        echo "1. Verificar e Instalar DHCP"
        echo "2. Configurar Servidor DHCP"
        echo "3. Ver Estado del Servicio"
        echo "4. Listar Concesiones Activas"
        echo "5. Salir"
        echo ""
        read -p "Seleccione opcion: " opcion
        
        case $opcion in
            1)
                if verificar_instalacion; then
                    echo ""
                    read -p "Presione Enter para continuar..."
                else
                    instalar_dhcp
                    read -p "Presione Enter para continuar..."
                fi
                ;;
            2)
                configurar_dhcp
                read -p "Presione Enter para continuar..."
                ;;
            3)
                estado_servicio
                read -p "Presione Enter para continuar..."
                ;;
            4)
                listar_concesiones
                read -p "Presione Enter para continuar..."
                ;;
            5)
                echo ""
                echo "Saliendo..."
                exit 0
                ;;
            *)
                echo ""
                echo "Opcion invalida"
                sleep 2
                ;;
        esac
    done
}

if [ "$EUID" -ne 0 ]; then
    echo "Este script debe ejecutarse como root (sudo)"
    exit 1
fi

menu_principal
