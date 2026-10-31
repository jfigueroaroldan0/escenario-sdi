# Genera el inventario de Ansible (../ansible/hosts) a partir de las IP del escenario
resource "local_file" "inventario" {
  filename        = "${path.module}/../ansible/hosts"
  file_permission = "0644"
  content = templatefile("${path.module}/inventario.tftpl", {
    maquinas = {
      for k, m in local.maquinas : k => {
        ip_gestion    = try(libvirt_domain.maquina[k].network_interface[0].addresses[0], "")
        mac_escenario = local.mac_escenario[k]
      }
    }
    mac_captura = local.mac_captura
    roles = {
      sdi = "sdi", victima = "victima", kali = "atacante", openvas = "openvas", auditor = "auditor"
    }
  })
}
