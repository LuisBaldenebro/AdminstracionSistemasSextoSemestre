#!/bin/bash

# Verificar root obligatorio
if [ "$EUID" -ne 0 ]; then
    echo "ERROR: Ejecuta como root -> sudo bash servicios_linux.sh"
    exit 1
fi

DIR="$(cd "$(dirname "$0")" && pwd)"
source "$DIR/servicio_dhcp.sh"
source "$DIR/servicio_dns.sh"
source "$DIR/servicio_ssh.sh"

while true; do
    clear
    echo "========================================"
    echo "      MENU DE SERVICIOS DEL SERVIDOR"
    echo "========================================"
    echo "1. Servicio DHCP"
    echo "2. Servicio DNS"
    echo "3. Servicio SSH"
    echo "4. Salir"
    echo "========================================"
    read -p "Seleccione una opcion: " op
    case $op in
        1) menu_dhcp ;;
        2) menu_dns ;;
        3) menu_ssh ;;
        4) exit 0 ;;
        *) echo "Opcion invalida"; sleep 1 ;;
    esac
done
