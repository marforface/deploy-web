# DevLab Manager

Gestor Bash interactivo para preparar y operar VPS/LXC de producción con **Nginx, PHP-FPM, MySQL o MariaDB, Cloudflare Tunnel, Git y CrowdSec/Fail2ban** sobre Debian 12 (bookworm) y Debian 13 (trixie).

Está orientado a múltiples aplicaciones PHP, HTML o JavaScript en un mismo servidor. Incluye creación de virtual hosts, despliegues desde GitHub, backups SQL, hardening SSH, firewall, monitoreo y auditoría básica.

**Autor:** Marcos Espinoza Torres
**Versión:** 2.0

> Este script modifica servicios del sistema. Pruébalo primero en una VPS desechable o snapshot y mantén abierta una segunda sesión SSH durante cambios de firewall, puerto o autenticación.

## Compatibilidad y requisitos

- Debian 12 o Debian 13; otras distribuciones no están soportadas.
- Ejecución como `root` o mediante `sudo`.
- Terminal interactiva (TTY).
- Acceso a Internet para APT, Sury, GitHub, Cloudflare y CrowdSec.
- Snapshot o backup del proveedor antes de preparar una VPS existente.

## Instalación

```bash
chmod +x produccion.sh
sudo ./produccion.sh
```

Ayuda y versión:

```bash
./produccion.sh --help
./produccion.sh --version
```

Desde **Sistema → Instalar comando `devlab`** se puede crear un enlace en `/usr/local/bin/devlab`:

```bash
sudo devlab
```

## Funciones principales

1. **Stack Web:** Nginx, PHP-FPM 8.1–8.4, extensiones, virtual hosts, límites PHP y catch-all.
2. **MySQL / MariaDB:** instalación, bases, usuarios, grants, diagnóstico, backups y restauración.
3. **Cloudflare Tunnel:** instalación, autenticación, túneles, `config.yml`, estado y logs.
4. **Git / Deploy:** clave SSH, clone seguro, pull fast-forward y acciones post-deploy.
5. **Sistema:** zona horaria, NTP, actualizaciones y comando global.
6. **Seguridad:** UFW, CrowdSec o Fail2ban, claves SSH, hardening, headers y auditoría.
7. **Monitor:** CPU, RAM, disco, red, servicios y actividad Nginx.
8. **Dev Tools:** logs, tráfico, benchmark, mantenimiento, Basic Auth y OPcache.
9. **Estado:** resumen estático de servicios y sitios.

## Flujo recomendado para una VPS nueva

1. Crear un snapshot y abrir dos sesiones SSH.
2. Instalar el stack web y seleccionar una versión PHP compatible con la aplicación.
3. Crear el sitio y configurar MySQL/MariaDB solo si corresponde.
4. Configurar la clave de despliegue y clonar el repositorio.
5. Ejecutar **Seguridad → Blindaje completo**.
6. Elegir **CrowdSec** como motor anti-intrusión recomendado.
7. Configurar Cloudflare Tunnel o abrir 80/443 en UFW, no ambos por obligación.
8. Ejecutar la auditoría y revisar que no queden advertencias críticas.
9. Probar desde otra sesión antes de cerrar la conexión administrativa.

## Modelo de seguridad de los sitios

El generador crea una estructura mínima, sin publicar `phpinfo()` ni pruebas de conexión a la base de datos:

```text
/var/www/<app-name>/
├── public/
│   ├── index.php
│   └── uploads/
├── storage/
├── logs/
└── .env
```

Permisos aplicados:

| Ruta | Propietario | Modo | Propósito |
|---|---|---:|---|
| Código y archivos públicos | `root:www-data` | `644` / `755` | Nginx/PHP leen, pero no modifican código |
| `.git/` | `root:root` | `600` / `700` | El repositorio no queda accesible a `www-data` |
| `.env` | `root:www-data` | `640` | Solo root y el grupo web pueden leerlo |
| `storage/`, `public/uploads/` | `www-data:www-data` | `664` / `2775` + ACL | Escritura limitada a datos de ejecución |

Nginx bloquea archivos ocultos (incluido `.env`) y rechaza PHP/PHTML/PHAR dentro de `public/uploads`.

## Git y despliegues

El flujo previsto es Mac → push a GitHub → deploy en el VPS.

- La deploy key usa ED25519 y `StrictHostKeyChecking accept-new`.
- `safe.directory` se agrega por repositorio; nunca se habilita `*` globalmente.
- El clone se realiza primero en un directorio temporal.
- Si el sitio ya existe, se mueve a `/var/backups/devlab/sites/` antes de activar el clon.
- Al reemplazarlo, se recuperan `.env`, `storage/` y `public/uploads/` desde ese backup.
- El pull se cancela si hay cambios locales en archivos versionados.
- La actualización usa `fetch` + `merge --ff-only`, evitando merges inesperados en producción.
- Con `package-lock.json` se ejecuta `npm ci`; sin lockfile se avisa y usa `npm install`.

Los archivos no versionados, por ejemplo `.env`, no bloquean el pull. Aun así, deben respaldarse fuera del repositorio.

## CrowdSec o Fail2ban

El menú ofrece ambos motores, pero recomienda seleccionar **uno solo** para evitar reglas duplicadas y diagnósticos confusos.

### CrowdSec (recomendado)

La integración instala desde el repositorio oficial:

- motor `crowdsec`;
- colecciones `crowdsecurity/linux` y `crowdsecurity/nginx`;
- adquisición de `/var/log/nginx/*.log`;
- firewall bouncer para nftables o iptables según el backend detectado.

Comandos útiles:

```bash
sudo cscli metrics
sudo cscli decisions list
sudo cscli bouncers list
sudo journalctl -u crowdsec -n 100 --no-pager
sudo journalctl -u crowdsec-firewall-bouncer -n 100 --no-pager
```

CrowdSec aporta señales colaborativas y bloqueo a nivel firewall. Esta versión no instala AppSec/WAF; puede añadirse después si la aplicación necesita inspección HTTP avanzada.

### Fail2ban

Se conserva como alternativa local y simple, con jails para SSH, autenticación HTTP de Nginx y detección de bots. Al cambiar de motor, el script solicita deshabilitar el que ya esté activo.

## UFW y Cloudflare Tunnel

- UFW aplica `deny incoming` y `allow outgoing`.
- El puerto SSH efectivo se permite antes de activar el firewall.
- Una regla remota para MySQL/MariaDB exige una IPv4 o CIDR válida.
- Si todo el tráfico web entra por Cloudflare Tunnel, no es necesario exponer 80/443 públicamente.
- No expongas 3306 a `0.0.0.0/0`; limita origen, grants y `bind-address`.

## SSH

El alta de un sitio nunca habilita acceso root por contraseña. El endurecimiento SSH está separado y:

- usa `PermitRootLogin prohibit-password`;
- permite deshabilitar contraseñas para todos los usuarios;
- valida con `sshd -t` antes de reiniciar;
- restaura el backup exacto si la validación falla;
- abre primero el puerto nuevo en UFW y comprueba el puerto realmente escuchado.

Mantén siempre una segunda terminal conectada y una consola alternativa del proveedor.

## Backups y datos sensibles

- Backups SQL: `/var/backups/mysql` o `/var/backups/mariadb`.
- Sitios sustituidos durante clone: `/var/backups/devlab/sites`.
- Backups de configuraciones: sufijo `.bak.<fecha-hora>` junto al archivo original.
- No subas `.env`, claves privadas, dumps SQL ni configuraciones con tokens a GitHub.
- Los backups locales no sustituyen una copia cifrada fuera del VPS.

## Validación después de instalar

```bash
sudo nginx -t
sudo sshd -t
sudo systemctl --failed
sudo ufw status verbose
sudo cscli metrics                    # si elegiste CrowdSec
sudo fail2ban-client status           # si elegiste Fail2ban
curl -I https://tu-dominio.cl
curl -I https://tu-dominio.cl/.env    # debe responder 403 o 404
```

También ejecuta **Seguridad → Auditoría de seguridad** y revisa manualmente los logs del primer despliegue.

## Alcance y limitaciones

- Es un asistente operativo, no reemplaza un sistema de gestión de configuración ni una auditoría externa.
- No configura TLS directo en Nginx; el diseño principal usa Cloudflare Tunnel. Si expones Nginx, configura certificados y HTTPS explícitamente.
- No rota secretos ni cifra `.env` en reposo.
- No verifica todavía checksum de todos los binarios externos descargados, especialmente `cloudflared`.
- Los headers de seguridad genéricos pueden requerir ajustes por aplicación.
- Antes de usar “Zona de peligro”, confirma backups recuperables.

Consulta [AUDITORIA.md](AUDITORIA.md) para el análisis técnico y los riesgos residuales.

## Licencia / uso

Script de uso personal para infraestructura propia. Revísalo y adáptalo antes de utilizarlo en entornos de terceros.
