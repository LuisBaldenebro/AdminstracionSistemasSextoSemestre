#!/bin/bash
set -e

echo "[1/6] Instalando dependencias..."
dnf install -y google-authenticator qrencode acl audit authselect pam_pwquality

echo "[2/6] Creando usuarios y configuración de contraseñas..."
PASS="Admin123"
for u in admin_identidad admin_storage admin_politicas admin_auditoria; do
    useradd -m $u 2>/dev/null || echo "Usuario $u ya existe"
    echo "$u:$PASS" | chpasswd
done

echo "[3/6] Configurando RBAC (Delegación de permisos)..."
cat <<EOF > /etc/sudoers.d/practica09
admin_identidad ALL=(ALL) /usr/bin/passwd, /usr/sbin/useradd, /usr/sbin/userdel
admin_storage ALL=(ALL) /usr/bin/df, /usr/bin/du, /usr/bin/setfacl
admin_politicas ALL=(ALL) /usr/bin/dnf, /usr/bin/systemctl, /usr/bin/vim /etc/*
admin_auditoria ALL=(ALL) NOPASSWD: /usr/local/bin/generar_reporte.sh
EOF
chmod 440 /etc/sudoers.d/practica09

echo "[4/6] Configurando seguridad PAM y bloqueo (Faillock)..."
sed -i 's/^# minlen =.*/minlen = 12/' /etc/security/pwquality.conf
authselect select minimal with-faillock --force
# Configurar faillock para 3 intentos
cat <<EOF > /etc/security/faillock.conf
deny = 3
unlock_time = 1800
silent
EOF

echo "[5/6] Configurando MFA..."
echo "auth required pam_google_authenticator.so nullok" >> /etc/pam.d/sshd
echo "auth required pam_google_authenticator.so nullok" >> /etc/pam.d/login

echo "[6/6] Creando sistema de auditoría perfecto..."
# Crear archivo de log y darle permisos para que el auditor pueda leerlo
touch /var/log/reporte_fallos.txt
chmod 644 /var/log/reporte_fallos.txt

# Script de reporte robusto
cat <<EOF > /usr/local/bin/generar_reporte.sh
#!/bin/bash
# Buscamos eventos de fallo de usuario de forma segura
/usr/sbin/ausearch -m USER_LOGIN,USER_AUTH,USER_ERR --success no -i | /usr/bin/tail -n 20 > /var/log/reporte_fallos.txt
echo "Reporte generado en /var/log/reporte_fallos.txt"
/usr/bin/cat /var/log/reporte_fallos.txt
EOF
chmod +x /usr/local/bin/generar_reporte.sh

# Asegurar que auditd esté corriendo
systemctl enable --now auditd

echo "==========================================================="
echo "CONFIGURACIÓN FINALIZADA CON ÉXITO"
echo "Usuario Auditor: admin_auditoria"
echo "Para generar el reporte, ejecuta: sudo /usr/local/bin/generar_reporte.sh"
echo "==========================================================="
