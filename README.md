# DevLab Manager

Script Bash interactivo para preparar y administrar entornos de producción con **Nginx + PHP-FPM + MariaDB + Cloudflare Tunnel + Git/Deploy** sobre Debian 12 (bookworm) o Debian 13 (trixie).

Menú por terminal con colores, validaciones y submenús por categoría. Pensado para levantar múltiples proyectos PHP nativo / JS / HTML en un mismo LXC o VPS y desplegarlos vía `git pull`.

**Autor:** Marcos Espinoza Torres

---

## Requisitos

- Debian 12 (bookworm) o Debian 13 (trixie)
- Acceso root / sudo
- Terminal interactiva (TTY)
- Conexión a internet (instalaciones y `git pull`)

## Instalación

```bash
chmod +x dep.sh
sudo bash dep.sh
```

### Comando global

Desde el menú: **Sistema → Instalar comando `devlab`**. Crea un enlace simbólico en `/usr/local/bin/devlab` para ejecutar el script desde cualquier ruta:

```bash
sudo devlab
```

---

## Menú principal

```
1) Stack Web      — Nginx, PHP-FPM, sitios
2) MariaDB        — Instalación, bases, usuarios
3) Cloudflare     — Tunnel, config, DNS
4) Git / Deploy   — Deploy key, clone, pull, post-deploy
5) Sistema        — Hora, zona horaria, actualizaciones
6) Seguridad      — Firewall, fail2ban, SSH, auditoría
7) Estado         — Resumen de servicios activos
0) Salir
```

El banner muestra en tiempo real el estado de cada servicio (●) y la IP local / pública del servidor.

---

## 1 — Stack Web (Nginx + PHP-FPM)

**Instalación:** stack base (Nginx + PHP 8.1–8.4 vía repositorio Sury, con catch-all bloqueador incluido) y extensiones PHP adicionales. Al finalizar la instalación, ofrece instalar y autenticar Cloudflare Tunnel para dejar el entorno listo para publicar sitios.

**Sitios:** crear con dominio personalizado (genera `.env`, `test-db.php`, `info.php`), listar, probar, eliminar, limpiar archivos de diagnóstico y reparar permisos de `storage/` y `public/uploads/`.

**Servicios y PHP:** recarga de servicios, cambio del límite de subida de archivos (valida `upload_max_filesize < post_max_size ≤ memory_limit`), duración de sesión PHP, estado de versiones instaladas y cambio de versión activa.

**Zona de peligro:** eliminar por completo el Stack Web (Nginx, PHP, repositorio Sury, sitios) con triple confirmación e inventario previo. No afecta MariaDB ni Cloudflared.

## 2 — MariaDB

Instalación y `bind-address`. Gestión de bases y usuarios (creación simple, dual localhost+remoto, cambio de host y de privilegios). Consultas de tamaño y conexiones activas. Backup/restauración vía `mysqldump` comprimido. Eliminación de bases/usuarios y recordatorio de `mysql_secure_installation`.

## 3 — Cloudflare Tunnel

Instalación de `cloudflared`, autenticación, creación y regeneración de `config.yml` a partir de los sitios Nginx activos. Permite eliminar un sitio del tunnel sin tocar Nginx, eliminar el tunnel completo (verificando sitios vinculados) o desinstalar `cloudflared` de la máquina.

## 4 — Git / Deploy

Flujo: desarrollo en Mac → `git push` a GitHub → `git pull` en producción desde este menú. Genera una clave SSH única por servidor (recomendada como clave de cuenta en GitHub, válida para todos los repos). Permite clonar, hacer pull con reaplicación de permisos, y ejecutar comandos post-deploy (`npm install && npm run build`, recarga de servicios).

## 5 — Sistema

Hora, zona horaria, sincronización NTP, actualización del sistema, información de hardware, e instalación/eliminación del comando global `devlab`.

## 6 — Seguridad (blindaje del entorno)

- **Blindaje completo:** aplica firewall, fail2ban, hardening SSH, headers Nginx y actualizaciones automáticas en secuencia, y termina con una auditoría.
- **SSH:** hardening general, autorización de clave pública desde el Mac (con guía completa de `ssh-keygen` / `ssh-copy-id` / alias en `~/.ssh/config`), toggle de autenticación por contraseña y cambio de puerto (con apertura previa en UFW para evitar bloqueos).
- **Red:** firewall UFW (deny incoming por defecto) y fail2ban (jails SSH + Nginx).
- **Web y sistema:** headers de seguridad Nginx (X-Frame-Options, CSP básico, oculta versión) y actualizaciones de seguridad automáticas.
- **Auditoría:** chequeo completo del entorno (firewall, SSH, Nginx, permisos de sitios, MariaDB, actualizaciones pendientes) con reporte ✔/✖.

## 7 — Estado

Resumen en pantalla de todos los servicios (Nginx, PHP-FPM, MariaDB, Cloudflared), sitios activos e IPs.

---

## Estructura de un sitio creado

```
/var/www/<app-name>/
├── public/
│   ├── index.php
│   ├── test-db.php     ← eliminar en producción
│   ├── info.php        ← eliminar en producción
│   └── uploads/
├── storage/
├── logs/
└── .env
```

## Permisos aplicados automáticamente

| Directorio | Permisos | Notas |
|---|---|---|
| Directorios generales | `755` | owner `www-data` |
| Archivos generales | `644` | owner `www-data` |
| `storage/`, `public/uploads/` | `2775` + setgid | ACL heredadas |
| `.env` | `640` | solo root y www-data |

---

## Licencia / Uso

Script de uso personal para gestión de infraestructura propia. Ajustar antes de reutilizar en otros entornos.
