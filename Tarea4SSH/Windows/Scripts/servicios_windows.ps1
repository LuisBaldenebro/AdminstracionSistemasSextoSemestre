# Verificar que se ejecuta como Administrador
if (!([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]"Administrator")) {
    Write-Warning "Ejecuta PowerShell como Administrador."
    Start-Process powershell.exe "-NoProfile -ExecutionPolicy Bypass -File `"$PSCommandPath`"" -Verb RunAs
    exit
}

$scriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
. "$scriptDir\servicio_dhcp.ps1"
. "$scriptDir\servicio_dns.ps1"
. "$scriptDir\servicio_ssh.ps1"

while ($true) {
    Clear-Host
    Write-Host "======================================="
    Write-Host "      MENU DE SERVICIOS DEL SERVIDOR"
    Write-Host "======================================="
    Write-Host "1. Servicio DHCP"
    Write-Host "2. Servicio DNS"
    Write-Host "3. Servicio SSH"
    Write-Host "4. Salir"
    Write-Host "======================================="
    $op = Read-Host "Seleccione una opcion"
    switch ($op) {
        "1" { Menu-DHCP }
        "2" { Menu-DNS }
        "3" { Menu-SSH }
        "4" { return }
        default { Write-Host "Opcion invalida"; Start-Sleep 1 }
    }
}
