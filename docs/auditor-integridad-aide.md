# Auditor — Integridad de ficheros (AIDE) y alertas por correo

Máquina **auditor** del escenario (`escenario-auditor`, IP escenario `10.0.50.50`,
gestión por DHCP, hoy `192.168.230.56`). Aquí se explica qué herramientas entran
en juego para vigilar la integridad de ficheros y **qué usar para cada cosa**.

> Acceso: `ssh -i ~/.ssh/id_rsa jesusfigueroa@<IP_gestion>`
> La IP de gestión sale de `ansible/hosts` (campo `ansible_host` del host `auditor`).

---

## 1. El flujo de un vistazo

```
            (al desplegar)                     (cada 10 min, timer)
  estado real de  ──►  aide --init  ──►  aide.db   ──►  aide --check --limit '^/etc'
     /etc                               (foto buena)         │
                                                             ▼
                                              ¿hay cambios en /etc?
                                               │no            │sí
                                               ▼              ▼
                                            nada         correo (msmtp) a
                                                         jesusfigueroaroldan@gmail.com
```

- **AIDE** no es en tiempo real: compara el `/etc` actual contra una **foto buena**
  guardada en una base de datos (`aide.db`). La alerta llega en la **siguiente
  pasada** del timer, no al instante.
- Si hay altas, **modificaciones** o **borrados** en `/etc`, se manda un correo al
  mismo destino que las alertas del SDI.

---

## 2. Piezas y para qué sirve cada una

| Pieza | Ruta (en la VM) | Para qué |
|---|---|---|
| **AIDE** | binario `aide` | Motor de integridad: crea la foto buena y compara. |
| Config principal | `/etc/aide/aide.conf` | Ajustes globales + rutas de la base de datos. Incluye `aide.conf.d`. |
| Reglas (qué vigila) | `/etc/aide/aide.conf.d/` | Drop-ins. La regla raíz `/ 0 Full` hace que vigile **todo**, incluido `/etc`. |
| Base de datos buena | `/var/lib/aide/aide.db` | La "foto" contra la que se compara. |
| Base de datos nueva | `/var/lib/aide/aide.db.new` | La que genera `--init`; se copia sobre la buena para re-sellar. |
| **Chequeo diario (de serie)** | `dailyaidecheck.timer` | Comprobación de **todo el sistema**, 1 vez al día (lo trae el paquete). |
| **Alerta de /etc (nuestra)** | `aide-alerta-etc.timer` → `.service` | Comprobación **solo de /etc** cada 10 min y correo si hay cambios. |
| Script de la alerta | `/usr/local/sbin/aide-alerta-etc.sh` | Ejecuta `aide --check --limit '^/etc'` y envía el correo. |
| **msmtp** | `/etc/msmtprc` | Cliente SMTP que envía el correo por Gmail. |
| Log de envíos | `/var/log/msmtp.log` | Resultado de cada intento de correo (`smtpstatus=250` = OK). |

---

## 3. Qué usar para cada cosa (comandos)

Todo se ejecuta **en la VM** y con `sudo` (los datos de AIDE son de root).

### Ver qué vigila / la configuración
```bash
less /etc/aide/aide.conf                     # config principal
ls /etc/aide/aide.conf.d/                     # reglas (una por paquete)
sudo grep -rnE '^\s*/' /etc/aide/aide.conf*   # ver las rutas vigiladas
```

### Comprobar integridad a mano (sin esperar al timer)
```bash
sudo aide --config /etc/aide/aide.conf --check --limit '^/etc'   # solo /etc
sudo aide --config /etc/aide/aide.conf --check                    # todo el sistema
```
Código de salida: `0` = sin cambios · `1` alta · `2` borrado · `4` modificación
(se suman: p. ej. `6` = borrado + modificación) · `>=14` = error de AIDE.

### Re-sellar la foto buena (tras un cambio LEGÍTIMO en /etc)
Si has editado tú una config a propósito, acepta el nuevo estado para que deje de
avisar. **Ojo:** `aideinit` da error 18 en esta versión; usa el método directo:
```bash
sudo sh -c 'aide --config /etc/aide/aide.conf --init && \
            cp -f /var/lib/aide/aide.db.new /var/lib/aide/aide.db'
```

### El timer de la alerta de /etc
```bash
systemctl status aide-alerta-etc.timer        # estado
systemctl list-timers aide-alerta-etc.timer   # próxima ejecución
sudo systemctl start aide-alerta-etc.service   # lanzar la comprobación YA
journalctl -u aide-alerta-etc.service -n 30    # qué hizo la última vez
```
Cambiar cada cuánto comprueba: edita `aide_intervalo_etc` en
`ansible/group_vars/all` (acepta `5min`, `1h`, `1d`…) y re-aplica el rol (ver §4).

### El correo
```bash
sudo tail -n 5 /var/log/msmtp.log             # ver si el envío fue bien (250) o no
cat /etc/msmtprc                               # cuenta, servidor, puerto (contraseña incluida)
```
Prueba rápida de punta a punta (crea un fichero, comprueba, limpia):
```bash
sudo touch /etc/zzz_prueba
sudo systemctl start aide-alerta-etc.service
sudo tail -n 1 /var/log/msmtp.log              # smtpstatus=250 => entregado
sudo rm -f /etc/zzz_prueba
```

### Añadir rutas propias a vigilar (además de /etc)
Crea un fichero en `/etc/aide/aide.conf.d/` con nombre que case con
`^[a-zA-Z0-9_-]+$` (sin puntos), p. ej. `99_local`:
```
/ruta/que/quiero    NORMAL
!/ruta/a/excluir
```
Y re-sella la base (comando de arriba) para que tome la nueva foto.

---

## 4. Dónde se define en el código (cambios reproducibles)

Para que los cambios **sobrevivan** a `destruir.sh` + `desplegar.sh`, edítalos en el
rol, no solo a mano en la VM:

| Quiero cambiar… | Fichero del rol |
|---|---|
| Paquetes del auditor (john, hydra, aide…) | `ansible/group_vars/all` → `paquetes_auditor` |
| Frecuencia de la alerta de /etc | `ansible/group_vars/all` → `aide_intervalo_etc` |
| A quién/por dónde se manda el correo | `ansible/group_vars/all` → `smtp_destinatario`, `smtp_*` |
| Lógica de la alerta (qué filtra, asunto…) | `ansible/roles/auditor/templates/aide-alerta-etc.sh.j2` |
| Servicio/timer systemd | `ansible/roles/auditor/templates/aide-alerta-etc.{service,timer}.j2` |
| Plantilla de msmtp | `ansible/roles/auditor/templates/msmtprc.j2` |
| Tareas (instalar, desplegar, re-sellar) | `ansible/roles/auditor/tasks/{main,correo}.yaml` |

Re-aplicar solo el auditor:
```bash
cd ~/github/escenario-sdi/ansible
ansible-playbook -i hosts site.yaml --limit auditor
```

El correo solo se configura si `smtp_password` tiene valor
(`correo_habilitado`). Al tocar la config de correo, el rol **re-sella la base de
AIDE** automáticamente para no alertar de sus propios cambios en `/etc`.

---

## 5. Notas / avisos

- **No es tiempo real.** Si quieres que en clase salte más rápido, baja
  `aide_intervalo_etc` (p. ej. `2min`).
- **Gmail puede dar `454 Too many login attempts`**: es un bloqueo temporal por
  muchos envíos seguidos; no es fallo de config. Espera un rato y reintenta.
- La contraseña de `/etc/msmtprc` es una **contraseña de aplicación de Gmail**; el
  repo no se sube a GitHub, así que se queda en local.
- `/var/lib/aide/` es solo de root → todo con `sudo`.
