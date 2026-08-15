# Auditoría técnica de DevLab Manager 2.0

Fecha de revisión: 2026-08-15
Alcance: `produccion.sh`, documentación, flujos de instalación, sitios, SSH, Nginx, bases de datos, Git/deploy y controles anti-intrusión.

## Resumen ejecutivo

La versión revisada tenía una buena base —modo estricto Bash, validaciones, `nginx -t`, backups y confirmaciones— pero conservaba varios comportamientos adecuados para laboratorio y riesgosos en producción. Los de mayor impacto se corrigieron en la versión 2.0.

## Hallazgos corregidos

| Severidad | Hallazgo | Corrección aplicada |
|---|---|---|
| Crítica | El alta de sitios podía habilitar root por contraseña | Se eliminó ese flujo; SSH se gestiona solo desde el módulo de seguridad |
| Alta | `www-data` era dueño de todo el código y del repositorio | Código `root:www-data`; solo `storage` y `uploads` quedan escribibles |
| Alta | Se publicaban `info.php` y una prueba DB con credenciales | Ya no se generan; la limpieza se conserva para instalaciones antiguas |
| Alta | Clone podía borrar irreversiblemente el directorio del sitio | Clone temporal y backup con marca de tiempo antes del reemplazo |
| Alta | `safe.directory '*'` confiaba globalmente en cualquier repo | Confianza limitada a cada ruta administrada |
| Alta | GitHub deshabilitaba la verificación de host SSH | Se usa `StrictHostKeyChecking accept-new` |
| Media | `git pull` podía crear merges o pisar cambios locales | Se rechaza árbol versionado sucio y se exige fast-forward |
| Media | Nginx solo bloqueaba `.ht*` y `.env` | Bloqueo de archivos ocultos y de PHP dentro de uploads |
| Media | Restauración SSH podía copiar varios backups por un glob | Se restaura el archivo exacto creado en la operación |
| Media | Origen UFW para 3306 no se validaba | Validación estricta de IPv4/CIDR |
| Media | Valores SQL solo escapaban apóstrofes | Se escapan también backslashes |
| Alta | Algunas operaciones destructivas aceptaban nombres SQL sin validar | Bases, usuarios, hosts, grants, dump y restore usan validadores estrictos |
| Baja | `npm install` ignoraba el lockfile como instalación reproducible | Se prefiere `npm ci` cuando existe `package-lock.json` |
| Alta | Basic Auth pasaba la contraseña en argumentos visibles del proceso | La contraseña se entrega por entrada estándar y se limpia de memoria después |

## Integración CrowdSec

Se incorporó como alternativa recomendada a Fail2ban, no como segundo motor simultáneo. La instalación usa el repositorio firmado oficial, colecciones Linux y Nginx, adquisición de logs de Nginx y un firewall bouncer compatible con el backend nftables/iptables detectado.

La decisión de no instalar AppSec/WAF por defecto reduce complejidad y posibles incompatibilidades. El firewall bouncer protege servicios de infraestructura y aplica decisiones de bloqueo; una aplicación con riesgo HTTP elevado puede incorporar el componente AppSec en una fase posterior y probarlo en modo controlado.

## Riesgos residuales

1. **Descargas externas:** `cloudflared` aún debería validar checksum/firma de cada `.deb` antes de instalarlo.
2. **Secretos:** `.env` está protegido por permisos, pero no cifrado y no existe rotación automática.
3. **TLS directo:** el flujo asume principalmente Cloudflare Tunnel; un Nginx público requiere certificados y políticas TLS propias.
4. **CSP:** una política genérica puede ser demasiado permisiva o romper aplicaciones; debe ajustarse por sitio.
5. **Cambios masivos:** desinstalación y limpieza siguen siendo operaciones destructivas; necesitan snapshot y backup externo probado.
6. **Automatización:** el script es interactivo y no es idempotente en todos los caminos; para flotas conviene Ansible u otra herramienta declarativa.
7. **Privacidad/red:** el menú consulta la IP pública mediante un servicio externo; debería convertirse en una opción configurable.
8. **Manejo de errores heredado:** `run_item` mantiene el menú disponible tras un fallo; los flujos críticos corregidos validan su resultado, pero conviene migrar gradualmente todas las funciones antiguas a retornos explícitos y transacciones/rollback.

## Recomendaciones operativas

- Probar la versión en una VPS desechable antes de actualizar producción.
- Mantener una consola del proveedor y dos sesiones SSH al cambiar acceso o firewall.
- Elegir CrowdSec o Fail2ban, no ambos.
- Revisar `systemctl --failed`, logs de Nginx/PHP y métricas CrowdSec después de cada despliegue.
- Ejecutar restauraciones de prueba de backups SQL y del sitio, no solo comprobar que el archivo existe.
- Ejecutar periódicamente `bash -n` y ShellCheck antes de publicar cambios.
