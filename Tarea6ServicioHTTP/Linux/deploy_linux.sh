#!/usr/bin/env bash

DIR_SCRIPT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FUNCIONES="${DIR_SCRIPT}/http_functions.sh"

if [[ ! -f "$FUNCIONES" ]]; then
    echo "[ERROR] No se encontro http_functions.sh en: ${DIR_SCRIPT}"
    echo "        Coloque ambos archivos en el mismo directorio."
    exit 1
fi
source "$FUNCIONES"

flujo_versiones() {
    limpiar; echo -e "  ${W}CONSULTA DE VERSIONES${N}"; echo ""
    seleccionar_servidor || return
    case "$SERVICIO" in
        apache2) consultar_versiones_apache ;;
        nginx)   consultar_versiones_nginx  ;;
        tomcat)  consultar_versiones_tomcat ;;
    esac; pausar
}

flujo_firewall() {
    limpiar; echo -e "  ${W}GESTION DE FIREWALL${N}"; echo ""
    [[ -z "$SERVICIO" ]] && { seleccionar_servidor || return; }
    solicitar_puerto 80; configurar_firewall; pausar
}

flujo_seguridad() {
    limpiar; echo -e "  ${W}CONFIGURACION DE SEGURIDAD${N}"; echo ""
    [[ -z "$SERVICIO" ]] && { seleccionar_servidor || return; }
    aplicar_seguridad; pausar
}

flujo_index() {
    limpiar; echo -e "  ${W}PAGINA DE INICIO${N}"; echo ""
    [[ -z "$SERVICIO" ]] && { seleccionar_servidor || return; }
    [[ -z "$VERSION" ]] && {
        case "$SERVICIO" in
            apache2) consultar_versiones_apache ;;
            nginx)   consultar_versiones_nginx  ;;
            tomcat)  consultar_versiones_tomcat ;;
        esac
    }
    [[ "$PUERTO" -eq 0 ]] && solicitar_puerto 80
    crear_pagina_index; pausar
}

flujo_salir() { clear; echo -e "\n  Sesion finalizada.\n"; exit 0; }

bucle_menu() {
    while true; do
        mostrar_menu
        read -rp "  Seleccione [0-5]: " op
        case "$op" in
            1) flujo_instalacion_completo ;;
            2) flujo_versiones            ;;
            3) flujo_firewall             ;;
            4) flujo_seguridad            ;;
            5) flujo_index                ;;
            0) flujo_salir                ;;
            *) err "Opcion invalida."; sleep 1 ;;
        esac
    done
}

verificar_root
detectar_gestor
bucle_menu
