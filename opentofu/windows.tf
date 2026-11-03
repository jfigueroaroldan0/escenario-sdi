##############################################
# Windows 10 atacante (instalación desatendida)
##############################################
# Máquina aparte del for_each de main.tf: no es un clon de Debian ni usa
# cloud-init. Se instala sola desde el ISO gracias a un autounattend.xml que
# generamos aquí y entregamos en un pequeño ISO (genisoimage). El disco va en
# SATA y las tarjetas en e1000e (vía XSLT) para que el instalador los vea sin
# cargar drivers virtio a mano.

locals {
  win_ip            = "10.0.50.60"
  win_octeto        = format("%02x", tonumber(split(".", local.win_ip)[3])) # "3c"
  win_mac_gestion   = "52:54:00:e5:00:${local.win_octeto}"
  win_mac_escenario = "52:54:00:e5:01:${local.win_octeto}"
  # Formato que muestra Windows (Get-NetAdapter): mayúsculas y guiones
  win_mac_escenario_win = upper(replace(local.win_mac_escenario, ":", "-"))

  win_build = "${path.module}/windows/build"

  # Herramientas de ataque/cracking (IDs de Chocolatey) como lista PowerShell
  win_choco_tools = join(",", [for t in [
    "nmap", "wireshark", "hashcat", "johntheripper", "mimikatz",
    "python", "git", "putty", "7zip",
  ] : "'${t}'"])
}

# ---- autounattend.xml + firstlogon.ps1 renderizados a build/iso/ ----
resource "local_file" "win_autounattend" {
  filename = "${local.win_build}/iso/autounattend.xml"
  content = templatefile("${path.module}/windows/autounattend.xml.tftpl", {
    hostname = "WIN10-ATACANTE"
    usuario  = "jesusfigueroa"
    password = "usuario"
  })
}

resource "local_file" "win_firstlogon" {
  filename = "${local.win_build}/iso/firstlogon.ps1"
  content = templatefile("${path.module}/windows/firstlogon.ps1.tftpl", {
    mac_escenario = local.win_mac_escenario_win
    ip_escenario  = local.win_ip
    choco_tools   = local.win_choco_tools
  })
}

# ---- ISO del autounattend (el instalador lo detecta solo en el medio) ----
resource "terraform_data" "win_unattend_iso" {
  triggers_replace = [
    local_file.win_autounattend.content,
    local_file.win_firstlogon.content,
  ]
  provisioner "local-exec" {
    command = "genisoimage -quiet -J -r -V WINSETUP -o '${local.win_build}/autounattend.iso' '${local.win_build}/iso'"
  }
  depends_on = [local_file.win_autounattend, local_file.win_firstlogon]
}

# ---- Volúmenes (todos en el pool: evita problemas de permisos de qemu) ----
resource "libvirt_volume" "win_disco" {
  name   = "escenario-windows.qcow2"
  pool   = var.libvirt_pool_name
  format = "qcow2"
  size   = 60 * 1024 * 1024 * 1024
}

resource "libvirt_volume" "win_iso" {
  name   = "escenario-windows-win10.iso"
  pool   = var.libvirt_pool_name
  source = pathexpand(var.windows_iso)
  format = "iso"
}

resource "libvirt_volume" "win_virtio_iso" {
  name   = "escenario-windows-virtio.iso"
  pool   = var.libvirt_pool_name
  source = pathexpand(var.virtio_iso)
  format = "iso"
}

resource "libvirt_volume" "win_unattend_iso" {
  name       = "escenario-windows-unattend.iso"
  pool       = var.libvirt_pool_name
  source     = "${local.win_build}/autounattend.iso"
  format     = "iso"
  depends_on = [terraform_data.win_unattend_iso]
}

# ---- Dominio Windows ----
resource "libvirt_domain" "windows" {
  name        = "escenario-windows"
  description = "Atacante Windows 10"
  memory      = 4096
  vcpu        = 2

  cpu { mode = "host-passthrough" }

  # Primer arranque: disco vacío -> arranca del CD (instala). Reinicios
  # posteriores: el disco ya arranca, el "press any key" del CD se ignora solo.
  boot_device {
    dev = ["cdrom", "hd"]
  }

  # Tarjeta 1: gestión (NAT + DHCP) -> Internet para instalar herramientas
  network_interface {
    network_id = libvirt_network.sdi-red-gestion.id
    mac        = local.win_mac_gestion
  }

  # Tarjeta 2: red del escenario (OVS, aislada). La IP estática la pone firstlogon.ps1
  network_interface {
    network_id = libvirt_network.escenario_seguridad.id
    mac        = local.win_mac_escenario
  }

  # Disco del sistema + los tres ISO (el XSLT los marca como SATA/CD-ROM)
  disk { volume_id = libvirt_volume.win_disco.id }
  disk { volume_id = libvirt_volume.win_iso.id }
  disk { volume_id = libvirt_volume.win_unattend_iso.id }
  disk { volume_id = libvirt_volume.win_virtio_iso.id }

  # Consola gráfica VNC (no hay que tocar nada, pero permite ver la instalación)
  graphics {
    type        = "vnc"
    listen_type = "address"
  }
  video {
    type = "qxl"
  }

  # El provider no distingue CD-ROM/bus ni modelo de tarjeta: lo ajusta el XSLT
  # (disco -> SATA, ISO -> CD-ROM solo lectura, tarjetas -> e1000e). Los CD-ROM
  # se emiten como type='file' con la ruta del ISO (el id del volumen es su ruta)
  # para esquivar un nil pointer del provider al leer cdrom de type='volume'.
  xml {
    xslt = templatefile("${path.module}/xslt/windows-devices.xsl.tftpl", {
      win10_iso    = libvirt_volume.win_iso.id
      unattend_iso = libvirt_volume.win_unattend_iso.id
      virtio_iso   = libvirt_volume.win_virtio_iso.id
    })
  }

  # Con la máquina encendida el provider lee las tarjetas OVS como bridge y en
  # cada plan querría "cambiarlas": se ignoran (igual que en main.tf).
  # 'disk' también: el XSLT convierte los CD-ROM a type='file', pero la config
  # los declara con volume_id; sin ignorarlo habría un diff perpetuo (file<->
  # volume_id) en cada plan. La VW se instala sola, no se tocan sus discos.
  lifecycle {
    ignore_changes = [network_interface, disk]
  }
}
