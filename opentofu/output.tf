# Nombre, IP de gestión (DHCP) e IP en la red del escenario de cada máquina
output "maquinas" {
  value = {
    for k, m in local.maquinas : k => {
      descripcion  = m.descripcion
      ip_gestion   = try(libvirt_domain.maquina[k].network_interface[0].addresses[0], "No disponible")
      ip_escenario = m.ip
    }
  }
}

output "openvas_web" {
  value = "https://${try(libvirt_domain.maquina["openvas"].network_interface[0].addresses[0], "IP-de-gestion")}"
}
