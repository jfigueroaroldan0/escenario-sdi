# Pool de almacenamiento donde se crean los volúmenes (disco y cloud-init)
variable "libvirt_pool_name" {
  type        = string
  description = "Nombre del pool de almacenamiento libvirt."
  default     = "default"
}

# Imagen base Debian 13 (todas las máquinas son clones ligeros de ella)
variable "base_image_debian" {
  type        = string
  description = "Nombre de la imagen base Debian en el pool."
  default     = "debian-13-generic-amd64.qcow2"
}

# Clave pública que se mete en el usuario debian de todas las máquinas
variable "ssh_public_key_file" {
  type        = string
  description = "Fichero con la clave pública SSH."
  default     = "~/.ssh/id_rsa.pub"
}

# Switch Open vSwitch del anfitrión (lo crea ansible/preparar-anfitrion.yaml)
variable "ovs_bridge" {
  type        = string
  description = "Nombre del bridge OVS de la red del escenario."
  default     = "ovsbr0"
}

# Nombre fijo del puerto de captura del SDI en el switch (destino del mirror)
variable "puerto_captura" {
  type        = string
  description = "Nombre de la interfaz tap de captura del SDI."
  default     = "tap-captura"
}
