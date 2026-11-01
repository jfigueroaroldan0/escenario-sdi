#!/usr/bin/env bash
# Tira el escenario completo. Contraparte de desplegar.sh.
#   1) tofu destroy  -> borra lo que OpenTofu gestiona: las 6 VMs escenario-*
#                       (5 Debian + Windows), sus discos/ISOs y las 2 redes.
#   2) barrido de seguridad en libvirt: por si el estado de OpenTofu se quedó
#      vacío (ya ha pasado), elimina a mano cualquier resto escenario-*.
#   3) limpia lo que OpenTofu NO gestiona porque lo puso
#      ansible/preparar-anfitrion.yaml en el ANFITRIÓN:
#        - el switch Open vSwitch y su port-mirror
#        - el script mirror-up.sh y el hook de libvirt
#   4) borra los ficheros generados del autounattend de Windows.
#
# Pide sudo del anfitrión (para OVS, el hook de libvirt y /usr/local/sbin).
# NO toca tus otras VMs (openvas, kali, metasploitable3, p7-*, etc.): solo
# actúa sobre nombres escenario-* y los volúmenes del proyecto.
# NO desinstala openvswitch-switch ni xsltproc (son del sistema); si los
# quieres fuera:  sudo apt-get purge openvswitch-switch
set -uo pipefail
dir="$(cd "$(dirname "$0")" && pwd)"

# --- Estos valores deben coincidir con ansible/group_vars/all ---
OVS_BRIDGE="ovsbr0"
PUERTO_CAPTURA="tap-captura"
POOL="default"
REDES=(sdi-red-gestion escenario_seguridad)
VOLS=(
  sdi-sdi-linked.qcow2      sdi-sdi-cloudinit.iso
  sdi-victima-linked.qcow2  sdi-victima-cloudinit.iso
  sdi-kali-linked.qcow2     sdi-kali-cloudinit.iso
  sdi-openvas-linked.qcow2  sdi-openvas-cloudinit.iso
  sdi-auditor-linked.qcow2  sdi-auditor-cloudinit.iso
  escenario-windows.qcow2   escenario-windows-unattend.iso
  escenario-windows-win10.iso escenario-windows-virtio.iso
)

echo ">> 1/4  tofu destroy (lo que gestiona OpenTofu)..."
if [ -d "$dir/opentofu" ]; then
  ( cd "$dir/opentofu" && tofu destroy -auto-approve ) || \
    echo "   (tofu destroy terminó con avisos; sigo con el barrido manual)"
fi

echo ">> 2/4  Barrido de restos en libvirt (dominios, redes y volúmenes escenario-*)..."
# Dominios escenario-* que hayan quedado sueltos (estado de OpenTofu perdido)
for dom in $(virsh list --all --name 2>/dev/null | grep '^escenario-' || true); do
  echo "   - dominio $dom"
  virsh destroy "$dom"  >/dev/null 2>&1 || true   # apágalo si está encendido
  virsh undefine "$dom" --nvram --remove-all-storage >/dev/null 2>&1 \
    || virsh undefine "$dom" --nvram >/dev/null 2>&1 || true
done
# Redes del proyecto
for net in "${REDES[@]}"; do
  if virsh net-info "$net" >/dev/null 2>&1; then
    echo "   - red $net"
    virsh net-destroy  "$net" >/dev/null 2>&1 || true
    virsh net-undefine "$net" >/dev/null 2>&1 || true
  fi
done
# Volúmenes del proyecto que no se hayan borrado con los dominios
for vol in "${VOLS[@]}"; do
  if virsh vol-info --pool "$POOL" "$vol" >/dev/null 2>&1; then
    echo "   - volumen $vol"
    virsh vol-delete --pool "$POOL" "$vol" >/dev/null 2>&1 || true
  fi
done

echo ">> 3/4  Limpiando el anfitrión (Open vSwitch y hook de libvirt)..."
# del-br borra el bridge, sus puertos y el port-mirror de una vez
if command -v ovs-vsctl >/dev/null 2>&1; then
  sudo ovs-vsctl --if-exists del-br "$OVS_BRIDGE"
  echo "   - switch OVS $OVS_BRIDGE (y su mirror) eliminado"
fi
sudo rm -f /usr/local/sbin/mirror-up.sh
sudo rm -f /etc/libvirt/hooks/qemu.d/mirror-sdi
echo "   - mirror-up.sh y hook mirror-sdi eliminados"
# El hook se registra al arrancar libvirtd; al quitarlo conviene recargar
sudo systemctl restart libvirtd >/dev/null 2>&1 \
  || sudo systemctl restart libvirtd.service >/dev/null 2>&1 || true

echo ">> 4/4  Borrando ficheros generados del autounattend de Windows..."
rm -rf "$dir/opentofu/windows/build"

echo ">> Listo. Escenario eliminado. Tus otras VMs no se han tocado."
