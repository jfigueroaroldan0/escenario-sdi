# Escenario de detección de intrusos (SDI) con OpenTofu y Ansible

Escenario creado con **OpenTofu** (libvirt/KVM) y configurado con **Ansible**: un SDI con
**Snort 3** que recibe, por *port mirroring* de un switch **Open vSwitch**, todo el tráfico de
una red muy aislada en la que están una víctima, un atacante Kali, un escáner OpenVAS y una
máquina de auditoría.

## Escenario

```
                               Anfitrión
                                   │ 192.168.230.1
   ┌───────────────────────────────┴──────────────────────────────────┐
   │ sdi-red-gestion (NAT + DHCP) 192.168.230.0/24: Ansible e Internet│
   └────┬───────────┬────────────┬────────────┬────────────┬──────────┘
        │           │            │            │            │
   ┌────┴───┐  ┌────┴────┐  ┌────┴───┐  ┌─────┴───┐  ┌─────┴───┐
   │  sdi   │  │ victima │  │  kali  │  │ openvas │  │ auditor │
   │ Snort3 │  │ nginx   │  │atacante│  │Greenbone│  │John     │
   │        │  │ postgres│  │        │  │         │  │Hydra    │
   │        │  │         │  │        │  │         │  │AIDE     │
   └─┬────┬─┘  └────┬────┘  └────┬───┘  └────┬────┘  └────┬────┘
 .10 │    │captura  │ .20        │ .30       │ .40        │ .50
   ┌─┴────┴─────────┴────────────┴───────────┴────────────┴──────── ┐
   │ escenario_seguridad: switch OVS ovsbr0 (muy aislada)           │
   │ 10.0.50.0/24 · sin DHCP · el anfitrión no tiene IP             │
   │ mirror "espejo": copia TODO el tráfico ─────► tap-captura (sdi)│
   └────────────────────────────────────────────────────────────────┘
```

| Máquina (libvirt) | Hostname | Red del escenario | RAM / vCPU / disco | Grupo de Ansible |
|---|---|---|---|---|
| escenario-sdi | sdi | 10.0.50.10 + tarjeta de captura sin IP | 4 GB / 4 / 20 GB | `sensores` |
| escenario-victima | victima | 10.0.50.20 | 2 GB / 1 / 15 GB | `victimas` |
| escenario-kali | kali | 10.0.50.30 | 4 GB / 2 / 40 GB | `atacantes` |
| escenario-openvas | openvas | 10.0.50.40 | 8 GB / 4 / 80 GB | `escaneres` |
| escenario-auditor | auditor | 10.0.50.50 | 1 GB / 1 / 15 GB | `auditores` |

Todas parten de Debian 13 (clones ligeros de `debian-13-generic-amd64.qcow2`) con usuario `debian`.

- **Red de gestión** (NAT): solo sirve para que Ansible entre por SSH y las máquinas descarguen
  paquetes. El tráfico del escenario va siempre por las IP `10.0.50.X` (o por nombre: `victima`,
  `kali`..., que están en `/etc/hosts`), que es el que copia el mirror.
- **Red del escenario** (muy aislada): un switch Open vSwitch en el anfitrión, como en la
  página de Notion, pero **sin IP, NAT ni DHCP** en el anfitrión: las máquinas solo se ven entre sí.
- **Port mirroring**: el mirror `espejo` (`select-all=true`) copia todo el tráfico del switch al
  puerto `tap-captura`, que es la tercera tarjeta del SDI. OpenTofu le pone ese nombre fijo
  (si no, sería `vnetX` y cambiaría en cada arranque).

## Estructura

```
opentofu/
├── provider.tf             providers libvirt (0.8.3) y local
├── variables.tf            pool, imagen base, clave SSH, bridge OVS y nombre del puerto de captura
├── network.tf              red de gestión NAT y red del escenario sobre OVS
├── main.tf                 las 5 máquinas (tabla "maquinas"): disco, cloud-init y dominio
├── output.tf               IP de gestión y del escenario de cada máquina
├── inventario.tf/.tftpl    genera ../ansible/hosts
├── cloud-init/             user-data y network-config (plantillas comunes)
└── xslt/
    ├── red-ovs.xsl         añade <virtualport type='openvswitch'/> a la red
    └── tap-captura.xsl...  pone <target dev='tap-captura'/> a la tarjeta de captura del SDI
ansible/
├── preparar-anfitrion.yaml instala OVS y crea el switch (ANTES de tofu apply)
├── site.yaml               configura el mirror y las 5 máquinas
├── group_vars/             all (IP, versiones, contraseñas) y sensores (interfaz de captura)
└── roles/
    ├── anfitrion/          OVS, ovsbr0, mirror-up.sh y hook de libvirt para el mirror
    ├── commons/            actualiza el sistema, paquetes comunes y /etc/hosts del escenario
    ├── sdi/                compila libdaq + Snort 3, reglas (comunidad + local.rules), servicio
    │                       y (opcional) alertas por correo: msmtp + vigilante snort-mail
    ├── victima/            nginx + PostgreSQL escuchando en todas las direcciones
    ├── atacante/           convierte Debian en Kali (kali-rolling) + kali-linux-headless;
    │                       bloquea systemd-boot (llenaría la partición EFI) y configura la red
    │                       con systemd-networkd (tras pasar a Kali, la de netplan no se levanta)
    ├── openvas/            Docker + Greenbone Community Containers
    │                       y (opcional) alertas por correo en la VM: msmtp + vigilante openvas-mail
    └── auditor/            John the Ripper, Hydra y AIDE con su base de datos inicial
                            y (opcional) alertas por correo: msmtp + timer periódico de /etc
```

## Alertas por correo en las VMs (opcional)

Los servicios de detección y auditoría configurados directamente en las **máquinas virtuales**
pueden avisar por correo automáticamente. Las alertas van **en las VMs y no en contenedores Docker**,
usando clientes ligeros `msmtp` y servicios/timers nativos de `systemd`.
Es **opcional** y está apagado por defecto: solo se configura si se define `smtp_password` en
`group_vars/all` (una **contraseña de aplicación de Gmail**, 16 letras sin espacios, con la
verificación en dos pasos activada en la cuenta remitente). Lo suyo es cifrarla con ansible-vault:

```bash
ansible-vault encrypt_string 'abcdefghijklmnop' --name smtp_password
```

Con `smtp_password` puesto y relanzando `ansible-playbook site.yaml`:

- **SDI (Snort 3)**: instala `msmtp` y deja un servicio `snort-mail` que vigila `alert_fast.txt`
  y manda un correo por cada alerta **grave** (las reglas con `priority:1` de `local.rules`: `/admin`,
  escaneo de puertos, DoS HTTP y fuerza bruta a PostgreSQL o SSH). El ruido (ping, acceso web normal)
  se queda solo en el log.
- **Auditor (AIDE)**: instala `msmtp` y activa un timer `aide-alerta-etc.timer` que comprueba
  periódicamente la integridad de `/etc` contra su base de datos de referencia y manda un correo
  si detecta altas, modificaciones o borrados de ficheros.
- **OpenVAS**: instala `msmtp` en la máquina virtual y activa un servicio vigilante nativo
  `openvas-mail.service` que escucha eventos de finalización de escaneos a través del socket de
  `gvmd` y envía automáticamente un informe detallado por correo (destacando alertas de severidad alta
  si la puntuación es ≥ 7.0), todo gestionado íntegramente en la VM fuera de los contenedores Docker.

Remitente y destinatario se configuran en `group_vars/all` (`smtp_remitente`, `smtp_destinatario`).

## Requisitos

- KVM/libvirt, OpenTofu y Ansible (con `community.general`, que trae el paquete `ansible` de Debian).
- La imagen `debian-13-generic-amd64.qcow2` en el pool `default`.
- Clave SSH en `~/.ssh/id_rsa(.pub)`.
- Unos 20 GB de RAM libres para las cinco máquinas.

## Puesta en marcha

```bash
# 1. Anfitrión: Open vSwitch, xsltproc, switch ovsbr0 y hook del mirror
cd ansible
ansible-playbook preparar-anfitrion.yaml -K

# 2. Crear las máquinas y las redes (genera ansible/hosts)
cd ../opentofu
tofu init
tofu apply

# 3. Configurar el mirror y las máquinas (las cinco a la vez)
cd ../ansible
ansible-playbook site.yaml -K
```

`-K` pide la contraseña de sudo del anfitrión (no hace falta si tu sudo no la pide).
El paso 3 tarda: Snort se compila desde el código fuente, OpenVAS descarga sus imágenes y la
máquina atacante pasa entera a Kali.

## Comprobaciones

```bash
# Mirror en el anfitrión: output_port no debe salir vacío ([])
sudo ovs-vsctl list mirror

# Snort en el SDI
ssh debian@<ip_gestion_sdi>
systemctl status snort3
sudo tail -f /var/log/snort/alert_fast.txt
```

Desde `kali` (o cualquier otra máquina del escenario), un `ping victima` o un
`curl http://victima/admin` hacen saltar al momento las reglas propias de
`roles/sdi/files/local.rules`.

Las reglas, `checksum_eval = 'none'` y `daq.batch_size = 1` están al final de
`/usr/local/etc/snort/snort.lua` (bloque `ANSIBLE ESCENARIO`), así que también funciona
lanzar Snort a mano como en la página de Notion:

```bash
sudo snort -c /usr/local/etc/snort/snort.lua -i ens5 -A alert_fast
```

(`batch_size = 1`: con el valor por defecto la DAQ junta 64 paquetes antes de pasárselos a
Snort y, con tan poco tráfico, las alertas tardarían mucho en salir.)

La regla `1000040` detecta la **fuerza bruta a PostgreSQL** (muchos SYN al 5432 desde el mismo
origen): desde `kali`, con PostgreSQL ya abierto a la red,
`hydra -l postgres -P /usr/share/wordlists/rockyou.txt 10.0.50.20 postgres` la hace saltar.

- **OpenVAS**: `https://<ip_gestion_openvas>` (sale en `tofu output openvas_web`), usuario `admin`
  y la contraseña de `openvas_admin_password`. Tras el primer arranque los feeds tardan un buen rato
  en cargarse: hasta entonces la web funciona pero no hay NVT ni configuraciones de escaneo.
  Para escanear la víctima, el objetivo es `10.0.50.20` (por la red del escenario). OpenVAS
  necesita disco: con 40 GB se llena y PostgreSQL deja de arrancar; por eso su disco es de 80 GB.
- **Víctima**: `curl http://10.0.50.20` y `ss -tlnp | grep 5432` (PostgreSQL en `0.0.0.0` y `::`).
- **Auditor**: `sudo john --list=formats` (en Debian John está en `/usr/sbin`), `hydra -h` y
  `sudo aide --config /etc/aide/aide.conf --check`.

## El mirror tras reiniciar

Al reiniciar el SDI (o el anfitrión) el puerto `tap-captura` se recrea y el mirror se queda con
`output_port` vacío. El hook `/etc/libvirt/hooks/qemu.d/mirror-sdi` lo rehace solo cada vez
que arranca `escenario-sdi`. A mano se puede rehacer con `sudo mirror-up.sh`.

## Destruir el escenario

```bash
cd opentofu
tofu destroy
```

El switch `ovsbr0` sigue en el anfitrión; se borra con `sudo ovs-vsctl del-br ovsbr0`.
