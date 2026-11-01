#!/usr/bin/env bash
# Despliega el escenario completo de una sola vez:
#   1) prepara el anfitrión (switch Open vSwitch)
#   2) crea las VMs con OpenTofu (las 5 Debian + la Windows 10 atacante)
#   3) configura las máquinas Debian con Ansible (la Windows se instala sola)
# Pide la contraseña de sudo del ANFITRIÓN (-K): en las VMs no hace falta
# porque el usuario jesusfigueroa tiene sudo NOPASSWD.
set -euo pipefail
dir="$(cd "$(dirname "$0")" && pwd)"

echo ">> 1/3  Preparando el anfitrión (Open vSwitch)..."
ansible-playbook "$dir/ansible/preparar-anfitrion.yaml" -K

echo ">> 2/3  Desplegando las VMs con OpenTofu..."
cd "$dir/opentofu"
tofu init -upgrade
tofu apply -auto-approve

echo ">> 3/3  Configurando las máquinas Debian con Ansible..."
cd "$dir/ansible"
ansible-playbook site.yaml -K

echo ">> Listo. La Windows 10 se instala sola (~20-30 min); se ve por VNC:"
echo "   virsh domdisplay escenario-windows"
