##############################################
# Máquinas del escenario (todas Debian 13)
##############################################

# Cada máquina tiene dos tarjetas (el SDI, tres):
#   gestion   -> sdi-red-gestion (NAT + DHCP): Ansible e Internet
#   escenario -> escenario_seguridad (OVS, muy aislada): IP estática 10.0.50.X
#   captura   -> solo el SDI: recibe el mirror de todo el switch, sin IP
# Las MAC son fijas (52:54:00:e5:<red>:<último octeto de la IP>) para que
# cloud-init configure cada tarjeta por su MAC y no por el nombre (ens3...).
locals {
  maquinas = {
    sdi = {
      descripcion = "SDI con Snort 3"
      ip          = "10.0.50.10"
      memoria     = 4096
      vcpu        = 4
      disco_gb    = 20
    }
    victima = {
      descripcion = "Víctima: nginx + PostgreSQL"
      ip          = "10.0.50.20"
      memoria     = 2048
      vcpu        = 1
      disco_gb    = 15
    }
    kali = {
      descripcion = "Atacante Kali Linux"
      ip          = "10.0.50.30"
      memoria     = 4096
      vcpu        = 2
      disco_gb    = 40
    }
    openvas = {
      descripcion = "Escáner de vulnerabilidades OpenVAS"
      ip          = "10.0.50.40"
      memoria     = 8192
      vcpu        = 4
      # Los feeds de Greenbone + la base de datos + las imágenes pasan de 30 GB;
      # con 40 GB el disco se llena y PostgreSQL deja de arrancar
      disco_gb = 80
    }
    auditor = {
      descripcion = "John the Ripper + Hydra + AIDE"
      ip          = "10.0.50.50"
      memoria     = 1024
      vcpu        = 1
      disco_gb    = 15
    }
  }

  # Último octeto de la IP en hexadecimal de dos cifras (para la MAC)
  octeto = { for k, m in local.maquinas : k => format("%02x", tonumber(split(".", m.ip)[3])) }

  mac_gestion   = { for k, o in local.octeto : k => "52:54:00:e5:00:${o}" }
  mac_escenario = { for k, o in local.octeto : k => "52:54:00:e5:01:${o}" }
  mac_captura   = "52:54:00:e5:02:${local.octeto["sdi"]}"

  clave_ssh = trimspace(file(pathexpand(var.ssh_public_key_file)))
}

# Clon ligero sobre la imagen base Debian, agrandado al tamaño de cada máquina
# (cloud-init amplía la partición raíz en el primer arranque)
resource "libvirt_volume" "disco" {
  for_each         = local.maquinas
  name             = "sdi-${each.key}-linked.qcow2"
  pool             = var.libvirt_pool_name
  base_volume_name = var.base_image_debian
  base_volume_pool = var.libvirt_pool_name
  format           = "qcow2"
  size             = each.value.disco_gb * 1024 * 1024 * 1024
}

# ISO cloud-init de cada máquina (mismas plantillas, distintos valores)
resource "libvirt_cloudinit_disk" "cloudinit" {
  for_each = local.maquinas
  name     = "sdi-${each.key}-cloudinit.iso"
  pool     = var.libvirt_pool_name
  user_data = templatefile("${path.module}/cloud-init/user-data.tftpl", {
    hostname  = each.key
    clave_ssh = local.clave_ssh
  })
  network_config = templatefile("${path.module}/cloud-init/network-config.tftpl", {
    mac_gestion   = local.mac_gestion[each.key]
    mac_escenario = local.mac_escenario[each.key]
    ip_escenario  = each.value.ip
    mac_captura   = each.key == "sdi" ? local.mac_captura : ""
  })
}

resource "libvirt_domain" "maquina" {
  for_each    = local.maquinas
  name        = "escenario-${each.key}"
  description = each.value.descripcion
  memory      = each.value.memoria
  vcpu        = each.value.vcpu

  # OpenVAS y la compilación de Snort van mucho mejor con la CPU del anfitrión
  cpu { mode = "host-passthrough" }

  # Tarjeta 1: red de gestión (NAT + DHCP)
  network_interface {
    network_id     = libvirt_network.sdi-red-gestion.id
    mac            = local.mac_gestion[each.key]
    wait_for_lease = true
  }

  # Tarjeta 2: red del escenario (switch OVS, muy aislada)
  network_interface {
    network_id = libvirt_network.escenario_seguridad.id
    mac        = local.mac_escenario[each.key]
  }

  # Tarjeta 3 (solo el SDI): captura, destino del port mirroring
  dynamic "network_interface" {
    for_each = each.key == "sdi" ? [1] : []
    content {
      network_id = libvirt_network.escenario_seguridad.id
      mac        = local.mac_captura
    }
  }

  # Solo el SDI: nombre fijo del puerto de captura en el switch
  dynamic "xml" {
    for_each = each.key == "sdi" ? [1] : []
    content {
      xslt = templatefile("${path.module}/xslt/tap-captura.xsl.tftpl", {
        mac    = local.mac_captura
        puerto = var.puerto_captura
      })
    }
  }

  disk { volume_id = libvirt_volume.disco[each.key].id }
  cloudinit = libvirt_cloudinit_disk.cloudinit[each.key].id

  # Consola serie: las imágenes cloud la esperan y permite "virsh console"
  console {
    type        = "pty"
    target_port = "0"
    target_type = "serial"
  }

  # Con la máquina encendida, el provider lee las tarjetas de la red OVS como
  # "bridge = ovsbr0" en vez de network_id y en cada plan querría "cambiarlas"
  lifecycle {
    ignore_changes = [network_interface]
  }
}
