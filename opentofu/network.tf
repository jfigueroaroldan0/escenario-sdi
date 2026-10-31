# Red NAT con DHCP: gestión desde el anfitrión (Ansible) y salida a Internet
# para instalar paquetes. Los ataques y el análisis NO pasan por aquí.
resource "libvirt_network" "sdi-red-gestion" {
  name      = "sdi-red-gestion"
  mode      = "nat"
  domain    = "gestion.sdi"
  addresses = ["192.168.230.0/24"]
  bridge    = "br-sdi-gest"
  dhcp { enabled = true }
  dns { enabled = true }
  autostart = true
}

# Red del escenario (muy aislada) sobre el switch Open vSwitch del anfitrión.
# El anfitrión no tiene IP en ella, no hay DHCP ni salida: las máquinas solo
# se ven entre sí (IP estáticas 10.0.50.0/24). OVS permite el port mirroring
# de todo su tráfico hacia el puerto de captura del SDI.
resource "libvirt_network" "escenario_seguridad" {
  name      = "escenario_seguridad"
  mode      = "bridge"
  bridge    = var.ovs_bridge
  autostart = true

  # El provider no tiene opción para <virtualport type='openvswitch'/>:
  # se añade al XML de la red con una transformación XSLT
  xml {
    xslt = file("${path.module}/xslt/red-ovs.xsl")
  }
}
