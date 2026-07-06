#!/usr/bin/env bash
# ==============================================================================
#  DevLab Manager v1.7 - Marcos Espinoza Torres
#  Stack completo: Nginx · PHP-FPM · MariaDB · Cloudflared | Debian 12/13
# ==============================================================================
set -euo pipefail

readonly SCRIPT_VERSION="1.8 - Marcos Espinoza Torres"
readonly CATCH_ALL_FILE="/etc/nginx/sites-available/000-catch-all"
readonly MARIADB_CNF="/etc/mysql/mariadb.conf.d/50-server.cnf"
readonly SESSION_OPTIONS=(2 4 8 16 24)
readonly PHP_SUPPORTED_VERSIONS=(8.1 8.2 8.3 8.4)
readonly CLOUDFLARED_CONFIG="/etc/cloudflared/config.yml"
readonly CLOUDFLARED_DIR="/etc/cloudflared"
readonly GIT_DEPLOY_KEY="/root/.ssh/deploy_ed25519"

PHP_VERSION=""
DEBIAN_CODENAME=""
APP_DB_PASS=""
APP_NAME=""
SERVER_IP=""
DB_HOST=""
DB_PORT=""
DB_NAME=""
DB_USER=""
CREATE_ENV_FILE="s"
ENABLE_ROOT_SSH="n"
APP_DIR=""
UPLOAD_MAX_SIZE=""
PRIMARY_HOST=""
CHOSEN_SITE=""
REPLY_YESNO=""
REPLY_SIZE=""
DB_PASS_VALUE=""
REPLY_HOST=""
SELECTED_DB_USER=""
SELECTED_DB_HOST=""

setup_colors() {
  if [[ "${NO_COLOR_FORCE:-n}" != "s" && -z "${NO_COLOR:-}" ]] \
     && command -v tput >/dev/null 2>&1 && [ -t 1 ]; then
    BOLD="$(tput bold)";   RESET="$(tput sgr0)"
    RED="$(tput setaf 1)"; GREEN="$(tput setaf 2)"
    YELLOW="$(tput setaf 3)"; BLUE="$(tput setaf 4)"
    MAGENTA="$(tput setaf 5)"; CYAN="$(tput setaf 6)"
    WHITE="$(tput setaf 7)"; DIM="$(tput dim)"
  else
    BOLD=""; RESET=""; RED=""; GREEN=""; YELLOW=""
    BLUE=""; MAGENTA=""; CYAN=""; WHITE=""; DIM=""
  fi
}

msg_info()    { echo -e "${CYAN}  ▸ ${1}${RESET}"; }
msg_ok()      { echo -e "${GREEN}  ✔ ${1}${RESET}"; }
msg_warn()    { echo -e "${YELLOW}  ⚠ ${1}${RESET}"; }
msg_error()   { echo -e "${RED}  ✖ ${1}${RESET}"; }
msg_section() { echo -e "\n${BOLD}${BLUE}── ${1} ${RESET}${DIM}$(printf '─%.0s' {1..40})${RESET}"; echo; }

menu_cat() {
  local label="$1" color="${2:-$CYAN}"
  echo -e "  ${color}${DIM}──[ ${BOLD}${label}${RESET}${color}${DIM} ]$(printf '─%.0s' {1..28})${RESET}"
}

run_item() {
  local header_fn="$1"; shift
  clear
  "$header_fn"
  echo
  "$@" || true
  pause
}

pause() { echo; read -rp "  Presiona Enter para continuar..."; }

detect_debian_codename() {
  if [[ -f /etc/os-release ]]; then
    source /etc/os-release
    DEBIAN_CODENAME="${VERSION_CODENAME:-}"
  fi
  if [[ -z "$DEBIAN_CODENAME" ]] && command -v lsb_release >/dev/null 2>&1; then
    DEBIAN_CODENAME="$(lsb_release -sc 2>/dev/null || true)"
  fi
  case "$DEBIAN_CODENAME" in
    bookworm) msg_ok "Debian 12 (bookworm) detectado." ;;
    trixie)   msg_ok "Debian 13 (trixie) detectado."  ;;
    *) msg_warn "Codename '${DEBIAN_CODENAME:-desconocido}' no reconocido." ;;
  esac
}

valid_ip() {
  local ip="$1" stat=1
  if [[ $ip =~ ^[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}$ ]]; then
    IFS='.' read -r -a _p <<< "$ip"
    [[ ${_p[0]} -le 255 && ${_p[1]} -le 255 && ${_p[2]} -le 255 && ${_p[3]} -le 255 ]]
    stat=$?
  fi
  return $stat
}

valid_port()     { [[ "$1" =~ ^[0-9]+$ ]] && (( $1 >= 1 && $1 <= 65535 )); }
valid_app_name() { [[ "$1" =~ ^[a-zA-Z0-9][a-zA-Z0-9._-]*$ ]]; }
valid_db_name()  { [[ "$1" =~ ^[a-zA-Z0-9_]+$ ]]; }
valid_db_user()  { [[ "$1" =~ ^[a-zA-Z0-9_]+$ ]]; }
valid_size()     { [[ "$1" =~ ^[0-9]+[MG]$ ]]; }
valid_fqdn()     { [[ "$1" =~ ^([a-zA-Z0-9]([a-zA-Z0-9-]{0,61}[a-zA-Z0-9])?\.)+[a-zA-Z]{2,}$ ]]; }

prompt_yes_no() {
  local prompt="$1" default="${2:-n}" answer=""
  while true; do
    read -rp "  ${prompt} [s/n] (default: ${default}): " answer
    answer="${answer:-$default}"; answer="${answer,,}"
    case "$answer" in
      s|n) REPLY_YESNO="$answer"; return 0 ;;
      *)   msg_error "Responde 's' o 'n'." ;;
    esac
  done
}

prompt_password_generic() {
  local label="${1:-Clave}"
  local pass1 pass2
  while true; do
    read -rsp "  ${label}: " pass1; echo
    read -rsp "  Confirmar ${label,,}: " pass2; echo
    [[ -z "$pass1" ]]          && msg_error "La clave no puede estar vacía." && continue
    [[ "$pass1" != "$pass2" ]] && msg_error "Las claves no coinciden."       && continue
    DB_PASS_VALUE="$pass1"; return 0
  done
}

prompt_upload_size() {
  local input=""
  while true; do
    read -rp "  Tamaño máximo de subida (ej: 20M, 100M, 1G): " input
    [[ -z "$input" ]]   && msg_error "Campo obligatorio."                 && continue
    valid_size "$input" && REPLY_SIZE="$input" && return 0
    msg_error "Formato inválido. Usa número seguido de M o G."
  done
}

detect_primary_ip() {
  local ip=""
  ip="$(ip route get 1.1.1.1 2>/dev/null \
        | awk '/src/ {for(i=1;i<=NF;i++) if($i=="src"){print $(i+1);exit}}')"
  [[ -z "$ip" ]] && ip="$(hostname -I 2>/dev/null | awk '{print $1}')"
  if [[ -n "$ip" ]] && valid_ip "$ip"; then printf '%s\n' "$ip"; return 0; fi
  return 1
}

prompt_server_ip() {
  local detected="" input=""
  if detected="$(detect_primary_ip)"; then
    msg_info "IP detectada en este LXC: ${detected}"
    while true; do
      read -rp "  IP local del LXC [${detected}]: " input
      input="${input:-$detected}"
      valid_ip "$input" && SERVER_IP="$input" && return 0
      msg_error "IP inválida."
    done
  else
    msg_warn "No se pudo detectar la IP automáticamente."
    while true; do
      read -rp "  IP local del LXC: " input
      [[ -z "$input" ]] && msg_error "La IP es obligatoria." && continue
      valid_ip "$input" && SERVER_IP="$input" && return 0
      msg_error "IP inválida."
    done
  fi
}

prompt_host_scope() {
  local choice remote_host
  while true; do
    echo
    echo "  Host permitido para el usuario:"
    echo "  1) localhost"
    echo "  2) IP específica"
    echo "  3) Red local  192.168.11.%"
    echo "  4) Cualquier host  (%)"
    read -rp "  Opción [1-4]: " choice
    case "$choice" in
      1) REPLY_HOST="localhost";     return 0 ;;
      2) read -rp "  IP autorizada: " remote_host
         REPLY_HOST="$remote_host"; return 0 ;;
      3) REPLY_HOST="192.168.11.%"; return 0 ;;
      4) REPLY_HOST="%";            return 0 ;;
      *) msg_error "Opción inválida (1-4)." ;;
    esac
  done
}

detect_installed_php_versions() {
  local ver found=()
  for ver in "${PHP_SUPPORTED_VERSIONS[@]}"; do
    dpkg -s "php${ver}-fpm" >/dev/null 2>&1 && found+=("$ver")
  done
  while IFS= read -r pkg; do
    ver="${pkg#php}"; ver="${ver%-fpm}"
    local already=0
    local v; for v in "${found[@]:-}"; do [[ "$v" == "$ver" ]] && already=1 && break; done
    [[ $already -eq 0 ]] && found+=("$ver")
  done < <(dpkg -l 'php*-fpm' 2>/dev/null | awk '/^ii/{print $2}' \
           | grep -oP 'php\K[0-9]+\.[0-9]+(?=-fpm)')
  printf '%s\n' "${found[@]:-}"
}

select_php_version() {
  local mode="${1:-install}"
  local versions=() label i=1 opt chosen

  if [[ "$mode" == "switch" ]]; then
    mapfile -t versions < <(detect_installed_php_versions)
    if [[ "${#versions[@]}" -eq 0 ]]; then
      msg_warn "No hay versiones PHP-FPM instaladas. Instala el stack base primero."
      return 1
    fi
    label="Cambiar versión PHP activa en el script"
  else
    versions=("${PHP_SUPPORTED_VERSIONS[@]}")
    label="Selecciona versión de PHP a instalar"
  fi

  echo
  msg_section "$label"
  for ver in "${versions[@]}"; do
    local mark=""
    dpkg -s "php${ver}-fpm" >/dev/null 2>&1 \
      && mark=" ${GREEN}[instalada]${RESET}" || mark=""
    printf "  %d) PHP %s%b\n" "$i" "$ver" "$mark"
    ((i++))
  done
  [[ "$mode" == "install" ]] && echo "  $i) Otra versión (manual)"
  echo "  0) Cancelar"; echo

  while true; do
    read -rp "  Opción: " opt
    [[ "$opt" == "0" ]] && return 1
    if [[ "$opt" =~ ^[1-9][0-9]*$ ]] && (( opt >= 1 && opt <= ${#versions[@]} )); then
      chosen="${versions[$((opt-1))]}"; break
    fi
    if [[ "$mode" == "install" ]] && (( opt == ${#versions[@]} + 1 )); then
      while true; do
        read -rp "  Versión PHP (ej: 8.5): " chosen
        if [[ "$chosen" =~ ^[0-9]+\.[0-9]+$ ]]; then
          msg_warn "Versión '${chosen}' manual. Asegúrate de que Sury la soporte."; break
        fi
        msg_error "Formato inválido. Usa X.Y"
      done
      break
    fi
    msg_error "Opción inválida."
  done

  PHP_VERSION="$chosen"
  msg_ok "Versión PHP seleccionada: ${PHP_VERSION}"
  return 0
}

show_php_status() {
  msg_section "Estado de PHP en el sistema"
  local installed=()
  mapfile -t installed < <(detect_installed_php_versions)

  if [[ "${#installed[@]}" -eq 0 ]]; then
    msg_warn "No se detectaron versiones PHP-FPM instaladas."
  else
    printf '  %-12s %-14s %-22s\n' "VERSIÓN" "FPM" "CLI"
    printf '  %s\n' "$(printf '─%.0s' {1..50})"
    for ver in "${installed[@]}"; do
      local fpm_status cli_bin active_mark=""
      systemctl is-active --quiet "php${ver}-fpm" 2>/dev/null \
        && fpm_status="${GREEN}activo${RESET}" \
        || fpm_status="${RED}inactivo${RESET}"
      cli_bin="$(command -v "php${ver}" 2>/dev/null || echo '-')"
      [[ "$ver" == "$PHP_VERSION" ]] && active_mark=" ${CYAN}← activa${RESET}"
      printf "  %-12s %-22b %-20s%b\n" "$ver" "$fpm_status" "$cli_bin" "$active_mark"
    done
  fi

  echo
  [[ -n "$PHP_VERSION" ]] \
    && msg_info "Versión activa en el script: PHP ${PHP_VERSION}" \
    || msg_warn "Ninguna versión seleccionada en el script aún."

  if command -v php >/dev/null 2>&1; then
    msg_info "php CLI sistema: $(php -r 'echo PHP_VERSION;' 2>/dev/null)"
  fi
}

install_catch_all() {
  cat > "${CATCH_ALL_FILE}" <<'EOF'
server {
    listen 80 default_server;
    listen [::]:80 default_server;
    server_name _;
    access_log /var/log/nginx/catch-all.access.log;
    return 444;
}
EOF
  rm -f /etc/nginx/sites-enabled/default
  ln -sf "${CATCH_ALL_FILE}" /etc/nginx/sites-enabled/000-catch-all
  nginx -t >/dev/null 2>&1 && systemctl reload nginx && msg_ok "Catch-all bloqueador instalado." \
    || msg_error "nginx -t falló al instalar catch-all."
}

install_base_stack() {
  detect_debian_codename
  echo
  msg_info "¿Qué versión de PHP deseas instalar?"
  select_php_version "install" || { msg_warn "Instalación cancelada."; return 1; }
  echo

  msg_info "[1/6] Actualizando sistema..."
  apt-get update && apt-get upgrade -y

  msg_info "[2/6] Instalando utilidades base..."
  apt-get install -y curl wget git unzip nano htop ca-certificates lsb-release gnupg acl

  msg_info "[3/6] Instalando Nginx..."
  apt-get install -y nginx
  systemctl enable --now nginx

  msg_info "[4/6] Agregando repositorio Sury para PHP ${PHP_VERSION} (${DEBIAN_CODENAME})..."
  install -d -m 0755 /usr/share/keyrings
  wget -qO /usr/share/keyrings/deb.sury.org-php.gpg \
    https://packages.sury.org/php/apt.gpg
  echo "deb [signed-by=/usr/share/keyrings/deb.sury.org-php.gpg] \
https://packages.sury.org/php/ ${DEBIAN_CODENAME} main" \
    > /etc/apt/sources.list.d/php.list
  apt-get update

  msg_info "[5/6] Instalando PHP ${PHP_VERSION}..."
  local php_modules=(fpm cli common mysql curl gd mbstring xml zip
                     bcmath intl soap imagick redis opcache)
  local php_pkgs=() m
  for m in "${php_modules[@]}"; do php_pkgs+=("php${PHP_VERSION}-${m}"); done
  apt-get install -y "${php_pkgs[@]}"
  systemctl enable --now "php${PHP_VERSION}-fpm"

  msg_info "[6/6] Instalando catch-all bloqueador..."
  install_catch_all

  echo
  msg_ok "Stack base listo: Nginx + PHP ${PHP_VERSION}-FPM en ${DEBIAN_CODENAME}."

  # Ofrecer cloudflared para dejar el entorno listo para publicar sitios
  if ! cf_installed; then
    echo
    msg_info "Para publicar sitios vía Cloudflare Tunnel se recomienda instalar cloudflared ahora."
    prompt_yes_no "¿Instalar cloudflared?" "s"
    if [[ "$REPLY_YESNO" == "s" ]]; then
      echo
      cf_install || { msg_warn "cloudflared no se pudo instalar. Hazlo desde el menú Cloudflare."; return 0; }
      echo
      prompt_yes_no "¿Autenticar con Cloudflare ahora? (abre URL para autorizar el dominio)" "s"
      if [[ "$REPLY_YESNO" == "s" ]]; then
        echo
        cf_login || msg_warn "Autenticación pendiente. Complétala en: Cloudflare → opción 2."
        echo
        msg_info "Siguiente paso sugerido: Cloudflare → opción 3 (Crear tunnel + config.yml)"
      else
        msg_info "Cuando quieras: Cloudflare → opción 2 (Autenticar) → opción 3 (Crear tunnel)."
      fi
    fi
  else
    echo
    msg_ok "cloudflared ya está instalado en esta máquina."
  fi
}

ensure_web_stack_installed() {
  if [[ -z "$PHP_VERSION" ]]; then
    local detected=()
    mapfile -t detected < <(detect_installed_php_versions)
    if   [[ "${#detected[@]}" -eq 1 ]]; then
      PHP_VERSION="${detected[0]}"; msg_info "PHP autodetectado: ${PHP_VERSION}"
    elif [[ "${#detected[@]}" -gt 1 ]]; then
      msg_warn "Varias versiones PHP instaladas. Selecciona cuál usar:"
      select_php_version "switch" || { msg_error "Operación cancelada."; return 1; }
    else
      msg_error "No hay PHP-FPM instalado. Usa: Stack Web → opción 1."
      return 1
    fi
  fi
  dpkg -s nginx >/dev/null 2>&1 \
    || { msg_error "Nginx no instalado."; return 1; }
  dpkg -s "php${PHP_VERSION}-fpm" >/dev/null 2>&1 \
    || { msg_error "PHP-FPM ${PHP_VERSION} no instalado."; return 1; }
  systemctl enable --now nginx                   >/dev/null 2>&1 || true
  systemctl enable --now "php${PHP_VERSION}-fpm" >/dev/null 2>&1 || true
}

install_php_extension() {
  ensure_web_stack_installed || return 1
  msg_section "Instalar extensión PHP adicional"
  msg_info "Versión activa: PHP ${PHP_VERSION}"
  echo

  local common_exts=(xdebug memcached ldap pgsql sqlite3 tidy snmp imap gmp readline)

  echo "  Extensiones frecuentes:"
  local i=1
  for ext in "${common_exts[@]}"; do
    local mark=""
    dpkg -s "php${PHP_VERSION}-${ext}" >/dev/null 2>&1 \
      && mark=" ${GREEN}[instalada]${RESET}" || mark=""
    printf "  %2d) php%s-%-14s%b\n" "$i" "${PHP_VERSION}" "${ext}" "$mark"
    ((i++))
  done
  echo "  $i) Otra (manual)"
  echo "  0) Cancelar"; echo

  local opt chosen_ext
  while true; do
    read -rp "  Opción: " opt
    [[ "$opt" == "0" ]] && return 0
    if [[ "$opt" =~ ^[1-9][0-9]*$ ]] && (( opt >= 1 && opt <= ${#common_exts[@]} )); then
      chosen_ext="${common_exts[$((opt-1))]}"; break
    fi
    if (( opt == ${#common_exts[@]} + 1 )); then
      while true; do
        read -rp "  Nombre (sin php${PHP_VERSION}-, ej: xdebug): " chosen_ext
        [[ -n "$chosen_ext" ]] && break
        msg_error "El nombre no puede estar vacío."
      done
      break
    fi
    msg_error "Opción inválida."
  done

  local pkg="php${PHP_VERSION}-${chosen_ext}"
  if dpkg -s "$pkg" >/dev/null 2>&1; then
    msg_warn "${pkg} ya está instalado."; return 0
  fi
  msg_info "Instalando ${pkg}..."
  if apt-get install -y "$pkg"; then
    systemctl restart "php${PHP_VERSION}-fpm"
    msg_ok "${pkg} instalado y PHP-FPM reiniciado."
  else
    msg_error "Falló la instalación de ${pkg}."
    return 1
  fi
}

# ══════════════════════════════════════════════════════════════════════════════
# PERMISOS STORAGE / UPLOADS
# ══════════════════════════════════════════════════════════════════════════════

_apply_writable_perms() {
  local app_dir="$1"
  local writable_dirs=("${app_dir}/storage" "${app_dir}/public/uploads")

  for dir in "${writable_dirs[@]}"; do
    [[ -d "$dir" ]] || continue
    chown -R www-data:www-data "$dir"
    # setgid: subdirectorios nuevos heredan grupo www-data
    chmod 2775 "$dir"
    find "$dir" -type d -exec chmod 2775 {} \;
    find "$dir" -type f -exec chmod 664 {} \;
    # ACL por defecto: archivos/dirs creados por PHP heredan rwX para www-data
    if command -v setfacl >/dev/null 2>&1; then
      setfacl -R  -m  "u:www-data:rwX,g:www-data:rwX" "$dir" 2>/dev/null || true
      setfacl -R  -d  -m "u:www-data:rwX,g:www-data:rwX" "$dir" 2>/dev/null || true
      setfacl -R  -m  "o::r-X" "$dir" 2>/dev/null || true
      setfacl -R  -d  -m "o::r-X" "$dir" 2>/dev/null || true
    fi
    msg_ok "Permisos aplicados: ${dir}"
  done
}

fix_storage_permissions() {
  ensure_web_stack_installed || return 1
  msg_section "Reparar permisos de storage y uploads"

  local sites=()
  mapfile -t sites < <(
    find /etc/nginx/sites-available -maxdepth 1 -type f -printf '%f\n' \
      | grep -v '^default$' | grep -v '^000-catch-all$' | grep -v '\.maintenance$' | sort
  )

  if [[ "${#sites[@]}" -eq 0 ]]; then
    msg_warn "No hay sitios configurados."; return 0
  fi

  echo "  Selecciona el sitio a reparar:"
  echo
  local i=1
  for site in "${sites[@]}"; do
    local app_dir="/var/www/${site}"
    local has_storage has_uploads
    [[ -d "${app_dir}/storage" ]]        \
      && has_storage="${GREEN}storage✓${RESET} " \
      || has_storage="${YELLOW}sin storage ${RESET}"
    [[ -d "${app_dir}/public/uploads" ]] \
      && has_uploads="${GREEN}uploads✓${RESET}" \
      || has_uploads="${YELLOW}sin uploads${RESET}"
    printf "  %2d) %-20s  %b %b\n" "$i" "$site" "$has_storage" "$has_uploads"
    ((i++))
  done
  echo "   a) Todos los sitios"
  echo "   0) Cancelar"
  echo

  # Verificar acl
  if ! command -v setfacl >/dev/null 2>&1; then
    msg_warn "El paquete 'acl' no está instalado."
    msg_warn "Sin ACL, subdirectorios creados por PHP pueden quedar sin permisos correctos."
    prompt_yes_no "¿Instalar acl ahora? (recomendado)" "s"
    [[ "$REPLY_YESNO" == "s" ]] && apt-get install -y acl && msg_ok "acl instalado."
  fi

  local opt
  read -rp "  Opción: " opt
  [[ "$opt" == "0" ]] && return 0

  if [[ "$opt" == "a" || "$opt" == "A" ]]; then
    for site in "${sites[@]}"; do
      msg_info "Reparando: ${site}"
      _apply_writable_perms "/var/www/${site}"
    done
    msg_ok "Permisos reparados en todos los sitios."
  elif [[ "$opt" =~ ^[0-9]+$ ]] && (( opt >= 1 && opt <= ${#sites[@]} )); then
    local site="${sites[$((opt-1))]}"
    msg_info "Reparando: ${site}"
    _apply_writable_perms "/var/www/${site}"
    msg_ok "Listo."
  else
    msg_error "Opción inválida."; return 1
  fi

  echo
  msg_info "Permisos aplicados:"
  printf '  %-30s %s\n' "Directorios writable:"   "2775 + setgid (grupo www-data)"
  printf '  %-30s %s\n' "Archivos dentro:"         "664"
  if command -v setfacl >/dev/null 2>&1; then
    printf '  %-30s %s\n' "ACL por defecto:" "www-data:rwX (heredado en subdirs nuevos)"
  else
    printf '  %-30s %s\n' "ACL:" "no disponible — instala el paquete acl"
  fi
}

# ══════════════════════════════════════════════════════════════════════════════
# RESIDUOS / ROLLBACK
# ══════════════════════════════════════════════════════════════════════════════

site_has_residue() {
  local n="$1"
  [[ -e "/etc/nginx/sites-available/${n}" || -L "/etc/nginx/sites-available/${n}" ||
     -e "/etc/nginx/sites-enabled/${n}"   || -L "/etc/nginx/sites-enabled/${n}"   ||
     -d "/var/www/${n}" ]]
}

cleanup_site_residue() {
  local name="$1" remove_dir="${2:-s}" removed="n"
  for target in "/etc/nginx/sites-enabled/${name}" "/etc/nginx/sites-available/${name}"; do
    if [[ -e "$target" || -L "$target" ]]; then
      rm -f "$target" || true; msg_warn "Eliminado: ${target}"; removed="s"
    fi
  done
  if [[ "${remove_dir}" == "s" && -d "/var/www/${name}" ]]; then
    rm -rf "/var/www/${name}" || true; msg_warn "Eliminado: /var/www/${name}"; removed="s"
  fi
  if [[ "${removed}" == "s" ]]; then
    nginx -t >/dev/null 2>&1 && systemctl reload nginx || true
    msg_ok "Limpieza completada."
  fi
}

prompt_cleanup_if_needed() {
  local name="$1"
  site_has_residue "$name" || return 0
  msg_warn "Se detectaron residuos previos del sitio '${name}'."
  prompt_yes_no "¿Eliminar también /var/www/${name}?" "s"; local rd="$REPLY_YESNO"
  prompt_yes_no "¿Limpiar residuos antes de recrear?" "s"
  if [[ "$REPLY_YESNO" == "s" ]]; then
    cleanup_site_residue "$name" "$rd"
    site_has_residue "$name" && { msg_error "Quedan residuos. Revisa manualmente."; return 1; }
  else
    msg_error "Operación cancelada."; return 1
  fi
}

rollback_failed_creation() {
  msg_warn "Aplicando rollback por fallo en la creación de '${1}'."
  cleanup_site_residue "${1}" "s"
}

# ══════════════════════════════════════════════════════════════════════════════
# CREACIÓN DE SITIO
# ══════════════════════════════════════════════════════════════════════════════

prompt_common_site_data() {
  while true; do
    read -rp "  Nombre corto de la app (ej: mi-app): " APP_NAME
    [[ -z "$APP_NAME" ]] && msg_error "Nombre obligatorio." && continue
    valid_app_name "$APP_NAME" && break
    msg_error "Solo letras, números, punto, guion o guion bajo."
  done

  prompt_server_ip

  while true; do
    read -rp "  Dominio/FQDN (ej: wayhost.cl, app.wayhost.cl): " PRIMARY_HOST
    [[ -z "$PRIMARY_HOST" ]] && msg_error "Dominio obligatorio." && continue
    PRIMARY_HOST="${PRIMARY_HOST,,}"
    valid_fqdn "$PRIMARY_HOST" && break
    msg_error "Dominio inválido. Usa: dominio.tld o sub.dominio.tld"
  done

  while true; do
    read -rp "  IP/hostname del servidor MariaDB: " DB_HOST
    [[ -n "$DB_HOST" ]] && break
    msg_error "Host MariaDB obligatorio."
  done

  while true; do
    read -rp "  Puerto MariaDB: " DB_PORT
    [[ -z "$DB_PORT" ]] && msg_error "Puerto obligatorio." && continue
    valid_port "$DB_PORT" && break
    msg_error "Puerto inválido (1-65535)."
  done

  while true; do
    read -rp "  Nombre de la base de datos: " DB_NAME
    [[ -z "$DB_NAME" ]] && msg_error "Nombre DB obligatorio." && continue
    valid_db_name "$DB_NAME" && break
    msg_error "Solo letras, números y guion bajo."
  done

  while true; do
    read -rp "  Usuario de la base de datos: " DB_USER
    [[ -z "$DB_USER" ]] && msg_error "Usuario DB obligatorio." && continue
    valid_db_user "$DB_USER" && break
    msg_error "Solo letras, números y guion bajo."
  done

  prompt_password_generic "Clave de la base de datos"
  APP_DB_PASS="$DB_PASS_VALUE"

  prompt_upload_size; UPLOAD_MAX_SIZE="$REPLY_SIZE"

  prompt_yes_no "¿Crear archivo .env con credenciales?" "s"
  CREATE_ENV_FILE="$REPLY_YESNO"

  prompt_yes_no "¿Habilitar SSH root por contraseña (solo lab/admin)?" "n"
  ENABLE_ROOT_SSH="$REPLY_YESNO"

  APP_DIR="/var/www/${APP_NAME}"
}

write_app_files() {
  mkdir -p "${APP_DIR}/public" "${APP_DIR}/public/uploads" \
           "${APP_DIR}/storage" "${APP_DIR}/logs"

  cat > "${APP_DIR}/public/index.php" <<PHP
<?php
declare(strict_types=1);
echo "<h1>${APP_NAME}</h1>";
echo "<p>Sitio PHP operativo en ${PRIMARY_HOST}</p>";
echo "<p>PHP version: " . PHP_VERSION . "</p>";
PHP

  cat > "${APP_DIR}/public/test-db.php" <<PHP
<?php
declare(strict_types=1);
\$host = '${DB_HOST}';
\$port = '${DB_PORT}';
\$db   = '${DB_NAME}';
\$user = '${DB_USER}';
\$pass = '${APP_DB_PASS}';
try {
    \$dsn = "mysql:host={\$host};port={\$port};dbname={\$db};charset=utf8mb4";
    \$pdo = new PDO(\$dsn, \$user, \$pass, [
        PDO::ATTR_ERRMODE            => PDO::ERRMODE_EXCEPTION,
        PDO::ATTR_DEFAULT_FETCH_MODE => PDO::FETCH_ASSOC,
    ]);
    \$row = \$pdo->query("SELECT NOW() AS server_time, DATABASE() AS db_name")->fetch();
    echo "<h1>Conexión PDO OK</h1><pre>"; print_r(\$row); echo "</pre>";
} catch (Throwable \$e) {
    http_response_code(500);
    echo "<h1>Error de conexión</h1><pre>"
       . htmlspecialchars(\$e->getMessage(), ENT_QUOTES, 'UTF-8')
       . "</pre>";
}
PHP

  cat > "${APP_DIR}/public/info.php" <<PHP
<?php
// ⚠ ELIMINAR EN PRODUCCIÓN — solo diagnóstico de lab
phpinfo();
PHP

  if [[ "${CREATE_ENV_FILE}" == "s" ]]; then
    cat > "${APP_DIR}/.env" <<EOF
APP_NAME=${APP_NAME}
APP_ENV=development
APP_URL=http://${PRIMARY_HOST}

DB_CONNECTION=mysql
DB_HOST=${DB_HOST}
DB_PORT=${DB_PORT}
DB_DATABASE=${DB_NAME}
DB_USERNAME=${DB_USER}
DB_PASSWORD=${APP_DB_PASS}
EOF
  fi

  chown -R www-data:www-data "${APP_DIR}"
  find "${APP_DIR}" -type d -exec chmod 755 {} \;
  find "${APP_DIR}" -type f -exec chmod 644 {} \;
  [[ -f "${APP_DIR}/.env" ]] && chmod 640 "${APP_DIR}/.env"

  # Permisos de escritura para storage y uploads
  _apply_writable_perms "${APP_DIR}"
}

nginx_php_location_block() {
  cat <<EOF
    location / {
        try_files \$uri \$uri/ /index.php?\$query_string;
    }
    location ~ \.php$ {
        include snippets/fastcgi-php.conf;
        fastcgi_pass unix:/run/php/php${PHP_VERSION}-fpm.sock;
        fastcgi_param SCRIPT_FILENAME \$realpath_root\$fastcgi_script_name;
        include fastcgi_params;
    }
    location ~ /\.(ht|env) { deny all; }
EOF
}

write_nginx_site() {
  cat > "/etc/nginx/sites-available/${APP_NAME}" <<EOF
server {
    listen 80;
    server_name ${PRIMARY_HOST};
    root ${APP_DIR}/public;
    index index.php index.html;

    client_max_body_size ${UPLOAD_MAX_SIZE};
    client_body_timeout 300s;

    access_log /var/log/nginx/${APP_NAME}.access.log;
    error_log  /var/log/nginx/${APP_NAME}.error.log;
$(nginx_php_location_block)
}
EOF
}

configure_php_upload_limits() {
  local php_ini="/etc/php/${PHP_VERSION}/fpm/php.ini"
  [[ ! -f "$php_ini" ]] && { msg_warn "No se encontró ${php_ini}. Saltando."; return 0; }
  sed -i "s/^upload_max_filesize\s*=.*/upload_max_filesize = ${UPLOAD_MAX_SIZE}/" "$php_ini"
  sed -i "s/^post_max_size\s*=.*/post_max_size = ${UPLOAD_MAX_SIZE}/"             "$php_ini"
  sed -i "s/^max_execution_time\s*=.*/max_execution_time = 300/"                  "$php_ini"
  sed -i "s/^max_input_time\s*=.*/max_input_time = 300/"                          "$php_ini"
  sed -i "s/^memory_limit\s*=.*/memory_limit = 256M/"                             "$php_ini"
  systemctl restart "php${PHP_VERSION}-fpm"
  msg_ok "PHP-FPM reiniciado con límites de subida: ${UPLOAD_MAX_SIZE}."
}

change_upload_limits() {
  ensure_web_stack_installed || return 1
  msg_section "Cambiar límite de subida de archivos"

  choose_site || return 0
  local site="$CHOSEN_SITE"
  local nginx_conf="/etc/nginx/sites-available/${site}"
  local php_ini="/etc/php/${PHP_VERSION}/fpm/php.ini"

  # Leer valores actuales
  local cur_nginx cur_upload cur_post cur_mem
  cur_nginx="$(awk '/client_max_body_size / {gsub(/;/,"",$2); print $2; exit}' "$nginx_conf" 2>/dev/null || echo '—')"
  cur_upload="$(awk -F'=' '/^upload_max_filesize\s*=/ {gsub(/ /,"",$2); print $2; exit}' "$php_ini" 2>/dev/null || echo '—')"
  cur_post="$(awk   -F'=' '/^post_max_size\s*=/        {gsub(/ /,"",$2); print $2; exit}' "$php_ini" 2>/dev/null || echo '—')"
  cur_mem="$(awk    -F'=' '/^memory_limit\s*=/          {gsub(/ /,"",$2); print $2; exit}' "$php_ini" 2>/dev/null || echo '—')"

  echo
  printf "  ${BOLD}Sitio:${RESET} %s\n" "$site"
  echo
  printf "  %-34s %s\n" "Nginx  client_max_body_size:"  "$cur_nginx"
  printf "  %-34s %s\n" "PHP    upload_max_filesize:"   "$cur_upload"
  printf "  %-34s %s\n" "PHP    post_max_size:"         "$cur_post"
  printf "  %-34s %s\n" "PHP    memory_limit:"          "$cur_mem"
  echo

  # Convierte tamaño (ej: 50M, 1G) a bytes para comparar
  _size_to_bytes() {
    local s="${1^^}"; local n="${s%[MG]}"
    [[ "$s" == *G ]] && echo $(( n * 1024 * 1024 * 1024 )) || echo $(( n * 1024 * 1024 ))
  }

  # 1) upload_max_filesize
  echo "  ${BOLD}upload_max_filesize${RESET} — tamaño máximo por archivo individual"
  prompt_upload_size
  local new_upload="$REPLY_SIZE"

  # 2) post_max_size — debe ser > upload_max_filesize
  local new_post=""
  while true; do
    echo
    echo "  ${BOLD}post_max_size${RESET} — tamaño máximo del cuerpo completo del request"
    msg_warn "Debe ser mayor que upload_max_filesize (${new_upload})"
    read -rp "  post_max_size [${cur_post}]: " new_post
    [[ -z "$new_post" ]] && new_post="$cur_post"
    if ! valid_size "$new_post"; then
      msg_error "Formato inválido. Usa número seguido de M o G (ej: 64M, 1G)."; continue
    fi
    if (( $(_size_to_bytes "$new_post") <= $(_size_to_bytes "$new_upload") )); then
      msg_error "post_max_size (${new_post}) debe ser mayor que upload_max_filesize (${new_upload})."; continue
    fi
    break
  done

  # 3) memory_limit — debe ser >= post_max_size
  local new_mem=""
  while true; do
    echo
    echo "  ${BOLD}memory_limit${RESET} — memoria máxima por proceso PHP"
    msg_warn "Debe ser mayor o igual a post_max_size (${new_post})"
    read -rp "  memory_limit [${cur_mem}]: " new_mem
    [[ -z "$new_mem" ]] && new_mem="$cur_mem"
    if ! valid_size "$new_mem"; then
      msg_error "Formato inválido. Usa número seguido de M o G (ej: 256M, 1G)."; continue
    fi
    if (( $(_size_to_bytes "$new_mem") < $(_size_to_bytes "$new_post") )); then
      msg_error "memory_limit (${new_mem}) debe ser mayor o igual a post_max_size (${new_post})."; continue
    fi
    break
  done

  echo

  # Nginx usa post_max_size como techo (es el límite real del request HTTP)
  sed -i "s/client_max_body_size\s*[^;]*/client_max_body_size ${new_post}/" "$nginx_conf"
  if nginx -t >/dev/null 2>&1; then
    systemctl reload nginx
    msg_ok "Nginx: client_max_body_size → ${new_post}"
  else
    msg_error "Validación Nginx falló. Revisa ${nginx_conf}."; return 1
  fi

  if [[ ! -f "$php_ini" ]]; then
    msg_warn "No se encontró ${php_ini}. Saltando configuración PHP."
  else
    sed -i "s/^upload_max_filesize\s*=.*/upload_max_filesize = ${new_upload}/" "$php_ini"
    sed -i "s/^post_max_size\s*=.*/post_max_size = ${new_post}/"               "$php_ini"
    sed -i "s/^memory_limit\s*=.*/memory_limit = ${new_mem}/"                  "$php_ini"
    systemctl restart "php${PHP_VERSION}-fpm"
    msg_ok "PHP-FPM reiniciado."
  fi

  echo
  printf "  %-34s %s\n" "Nginx  client_max_body_size:"  "$new_post"
  printf "  %-34s %s\n" "PHP    upload_max_filesize:"   "$new_upload"
  printf "  %-34s %s\n" "PHP    post_max_size:"         "$new_post"
  printf "  %-34s %s\n" "PHP    memory_limit:"          "$new_mem"
}

enable_nginx_site() {
  rm -f /etc/nginx/sites-enabled/default
  ln -sf "/etc/nginx/sites-available/${APP_NAME}" "/etc/nginx/sites-enabled/${APP_NAME}"
  if ! nginx -t; then
    echo; msg_error "Validación de Nginx falló."
    rollback_failed_creation "${APP_NAME}"; return 1
  fi
  systemctl reload nginx
}

setup_ssh_if_requested() {
  [[ "${ENABLE_ROOT_SSH}" != "s" ]] && return 0
  apt-get install -y openssh-server
  systemctl enable --now ssh
  cp /etc/ssh/sshd_config "/etc/ssh/sshd_config.bak.$(date +%F-%H%M%S)"
  local sshd=/etc/ssh/sshd_config
  grep -q '^[#[:space:]]*PermitRootLogin' "$sshd" \
    && sed -i 's/^[#[:space:]]*PermitRootLogin.*/PermitRootLogin yes/' "$sshd" \
    || echo 'PermitRootLogin yes' >> "$sshd"
  grep -q '^[#[:space:]]*PasswordAuthentication' "$sshd" \
    && sed -i 's/^[#[:space:]]*PasswordAuthentication.*/PasswordAuthentication yes/' "$sshd" \
    || echo 'PasswordAuthentication yes' >> "$sshd"
  systemctl restart ssh
  msg_warn "SSH root por contraseña: habilitado."
}

print_creation_summary() {
  echo
  echo -e "${BOLD}${GREEN}  ╔══════════════════════════════════════════╗${RESET}"
  echo -e "${BOLD}${GREEN}  ║  Sitio creado correctamente: ${APP_NAME}${RESET}"
  echo -e "${BOLD}${GREEN}  ╚══════════════════════════════════════════╝${RESET}"
  echo
  printf '  %-22s %s\n' "IP del LXC:"        "${SERVER_IP}"
  printf '  %-22s %s\n' "Dominio:"           "http://${PRIMARY_HOST}"
  printf '  %-22s %s\n' "Raíz app:"          "${APP_DIR}/public"
  printf '  %-22s %s\n' "Uploads:"           "${APP_DIR}/public/uploads"
  printf '  %-22s %s\n' "Test DB:"           "http://${PRIMARY_HOST}/test-db.php"
  printf '  %-22s %s\n' "phpinfo:"           "http://${PRIMARY_HOST}/info.php"
  printf '  %-22s %s\n' "DB host:puerto:"    "${DB_HOST}:${DB_PORT}"
  printf '  %-22s %s\n' "DB nombre/usuario:" "${DB_NAME} / ${DB_USER}"
  printf '  %-22s %s\n' "Máx. subida:"       "${UPLOAD_MAX_SIZE}"
  [[ "${CREATE_ENV_FILE}" == "s" ]] \
    && printf '  %-22s %s\n' "Archivo .env:" "${APP_DIR}/.env"
  echo
  msg_warn "Elimina test-db.php e info.php antes de pasar a producción."
  echo
  echo "  Bloque para config.yml de cloudflared:"
  echo "  - hostname: ${PRIMARY_HOST}"
  echo "    service: http://127.0.0.1:80"
  echo "    originRequest:"
  echo "      httpHostHeader: ${PRIMARY_HOST}"
  echo
  msg_info "Menú Cloudflare → opción 4 para regenerar config.yml con todos los sitios."
  echo
  echo "  Pruebas rápidas:"
  echo "    curl -I -H 'Host: ${PRIMARY_HOST}' http://${SERVER_IP}"
  echo "    curl -H 'Host: ${PRIMARY_HOST}' http://${SERVER_IP}/test-db.php"
  echo "    curl -H 'Host: ${PRIMARY_HOST}' http://${SERVER_IP}/info.php"
}

create_site_custom_domain() {
  ensure_web_stack_installed || return 1
  msg_section "Crear sitio PHP con dominio personalizado"
  prompt_common_site_data
  prompt_cleanup_if_needed "${APP_NAME}" || return 1

  msg_info "[1/5] Creando estructura y archivos..."
  write_app_files

  msg_info "[2/5] Configurando Nginx..."
  write_nginx_site; enable_nginx_site || return 1

  msg_info "[3/5] Ajustando límites PHP-FPM..."
  configure_php_upload_limits

  msg_info "[4/5] Configurando SSH opcional..."
  setup_ssh_if_requested

  msg_info "[5/5] Finalizado."
  print_creation_summary

  if cf_installed; then
    echo
    prompt_yes_no "¿Regenerar el config.yml de cloudflared con este nuevo sitio?" "s"
    if [[ "$REPLY_YESNO" == "s" ]]; then
      echo
      cf_regen_config || msg_warn "No se pudo regenerar el config.yml. Hazlo desde el menú Cloudflare."
    fi
  fi
}

# ══════════════════════════════════════════════════════════════════════════════
# GESTIÓN DE SESIÓN PHP
# ══════════════════════════════════════════════════════════════════════════════

_hours_to_seconds() { echo $(( $1 * 3600 )); }

_current_session_lifetime() {
  local php_ini="/etc/php/${PHP_VERSION}/fpm/php.ini"
  [[ -f "$php_ini" ]] || { echo "N/A"; return; }
  local val=""
  val="$(awk -F'=' '/^[[:space:]]*session\.gc_maxlifetime[[:space:]]*=/ \
    {gsub(/[[:space:]]/,"",$2); print $2; exit}' "$php_ini")"
  if [[ -z "$val" ]]; then
    val="$(awk -F'=' '/^[[:space:]]*;[[:space:]]*session\.gc_maxlifetime[[:space:]]*=/ \
      {gsub(/[[:space:]]/,"",$2); print $2; exit}' "$php_ini")"
    [[ -n "$val" ]] && val="${val} (default)"
  fi
  echo "${val:-N/A}"
}

configure_session_lifetime() {
  ensure_web_stack_installed || return 1
  msg_section "Configurar duración de sesión PHP"

  local current; current="$(_current_session_lifetime)"
  if [[ "$current" =~ ^[0-9]+ ]]; then
    local secs="${current%% *}"
    printf "  Valor actual → %s seg (%.1f h)%s\n" \
      "$secs" "$(awk "BEGIN{printf \"%.1f\", $secs/3600}")" \
      "$([[ "$current" == *"default"* ]] && echo ' — fábrica' || echo '')"
  else
    msg_warn "No se pudo leer el valor actual (php.ini no encontrado)."
  fi
  echo

  echo "  Opciones predefinidas:"
  local i=1
  for h in "${SESSION_OPTIONS[@]}"; do
    printf "  %d) %2d horas  (%d seg)\n" "$i" "$h" "$(_hours_to_seconds "$h")"
    ((i++))
  done
  echo "  $i) Valor personalizado (en horas)"
  echo "  0) Cancelar"; echo

  local opt chosen_hours chosen_secs
  while true; do
    read -rp "  Opción: " opt
    [[ "$opt" == "0" ]] && return 0
    if [[ "$opt" =~ ^[1-9][0-9]*$ ]] && (( opt >= 1 && opt <= ${#SESSION_OPTIONS[@]} )); then
      chosen_hours="${SESSION_OPTIONS[$((opt-1))]}"; break
    fi
    if (( opt == ${#SESSION_OPTIONS[@]} + 1 )); then
      while true; do
        read -rp "  Horas (1-720): " chosen_hours
        [[ "$chosen_hours" =~ ^[1-9][0-9]*$ ]] && (( chosen_hours >= 1 && chosen_hours <= 720 )) && break
        msg_error "Ingresa un número entre 1 y 720."
      done; break
    fi
    msg_error "Opción inválida."
  done

  chosen_secs="$(_hours_to_seconds "$chosen_hours")"

  _patch_ini() {
    local ini="$1"
    [[ -f "$ini" ]] || { msg_warn "No encontrado: ${ini}"; return; }
    local bak; bak="${ini}.bak.$(date +%F)"
    [[ -f "$bak" ]] || cp "$ini" "$bak"
    _set_or_add() {
      local key="$1" val="$2"
      if grep -qE "^[;#[:space:]]*${key}\s*=" "$ini"; then
        sed -i "s|^[;#[:space:]]*${key}\s*=.*|${key} = ${val}|" "$ini"
      else
        printf '\n; Added by devlab-manager\n%s = %s\n' "$key" "$val" >> "$ini"
      fi
    }
    _set_or_add "session.gc_maxlifetime"  "$chosen_secs"
    _set_or_add "session.cookie_lifetime" "$chosen_secs"
    _set_or_add "session.gc_probability"  "1"
    _set_or_add "session.gc_divisor"      "100"
    msg_ok "Parcheado: ${ini}"
  }

  msg_info "Aplicando ${chosen_hours}h (${chosen_secs}s) en FPM y CLI..."
  _patch_ini "/etc/php/${PHP_VERSION}/fpm/php.ini"
  _patch_ini "/etc/php/${PHP_VERSION}/cli/php.ini"

  systemctl restart "php${PHP_VERSION}-fpm" \
    && msg_ok "PHP-FPM reiniciado." \
    || { msg_error "Falló el reinicio. Revisa: journalctl -u php${PHP_VERSION}-fpm"; return 1; }

  echo
  printf '  %-30s %s\n' "session.gc_maxlifetime:"  "${chosen_secs} seg"
  printf '  %-30s %s\n' "session.cookie_lifetime:" "${chosen_secs} seg"
  printf '  %-30s %s\n' "session.gc_probability:"  "1 / 100"
  echo
  msg_warn "Si tu app define session.gc_maxlifetime en runtime, ese valor tiene precedencia."
}

# ══════════════════════════════════════════════════════════════════════════════
# LISTADO Y SELECCIÓN DE SITIOS
# ══════════════════════════════════════════════════════════════════════════════

list_sites() {
  msg_section "Sitios Nginx configurados"
  local sites=()
  mapfile -t sites < <(
    find /etc/nginx/sites-available -maxdepth 1 -type f -printf '%f\n' \
      | grep -v '^default$' | grep -v '^000-catch-all$' | grep -v '\.maintenance$' | sort
  )
  if [[ "${#sites[@]}" -eq 0 ]]; then msg_warn "No hay sitios configurados."; return 0; fi

  printf "  %-22s %-8s %-35s %-25s %-10s\n" "SITIO" "ACTIVO" "SERVER_NAME" "RAÍZ" "MAX_UPLOAD"
  printf '  %s\n' "$(printf '─%.0s' {1..104})"
  for site in "${sites[@]}"; do
    local mark sn root up
    [[ -L "/etc/nginx/sites-enabled/${site}" ]] \
      && mark="${GREEN}SÍ${RESET}" || mark="${RED}NO${RESET}"
    sn="$(awk '/server_name / && !/default_server/ {print $2; exit}' \
      "/etc/nginx/sites-available/${site}" | tr -d ';')"
    root="$(awk '/root / {print $2; exit}' \
      "/etc/nginx/sites-available/${site}" | tr -d ';')"
    up="$(awk '/client_max_body_size / {print $2; exit}' \
      "/etc/nginx/sites-available/${site}" | tr -d ';')"; up="${up:-—}"
    printf "  %-22s %-16b %-35s %-25s %-10s\n" "$site" "$mark" "$sn" "$root" "$up"
  done; echo
}

choose_site() {
  local sites=() i=1 site opt
  mapfile -t sites < <(
    find /etc/nginx/sites-available -maxdepth 1 -type f -printf '%f\n' \
      | grep -v '^default$' | grep -v '^000-catch-all$' | grep -v '\.maintenance$' | sort
  )
  if [[ "${#sites[@]}" -eq 0 ]]; then
    msg_warn "No hay sitios configurados."
    return 2
  fi
  echo; echo "  Selecciona un sitio:"; echo
  for site in "${sites[@]}"; do
    local mark
    [[ -L "/etc/nginx/sites-enabled/${site}" ]] \
      && mark="${GREEN}[activo]${RESET}" || mark="${RED}[inactivo]${RESET}"
    printf "  %d) %-25s %b\n" "$i" "$site" "$mark"; ((i++))
  done
  echo "  0) Cancelar"; echo
  read -rp "  Opción: " opt
  [[ "$opt" == "0" ]] && return 1
  if [[ "$opt" =~ ^[0-9]+$ ]] && (( opt >= 1 && opt <= ${#sites[@]} )); then
    CHOSEN_SITE="${sites[$((opt-1))]}"; return 0
  fi
  msg_error "Opción inválida."; return 1
}

test_site() {
  choose_site || return 0
  local site="$CHOSEN_SITE" sn
  sn="$(awk '/server_name / && !/default_server/ {print $2; exit}' \
    "/etc/nginx/sites-available/${site}" | tr -d ';')"
  msg_section "Test Nginx + PHP-FPM"
  nginx -t && msg_ok "nginx -t: OK" || msg_error "nginx -t: FALLÓ"
  systemctl is-active --quiet nginx \
    && msg_ok "nginx: activo" || msg_error "nginx: inactivo"
  systemctl is-active --quiet "php${PHP_VERSION}-fpm" \
    && msg_ok "php${PHP_VERSION}-fpm: activo" || msg_error "php${PHP_VERSION}-fpm: inactivo"
  local cur; cur="$(_current_session_lifetime)"
  if [[ "$cur" =~ ^[0-9]+ ]]; then
    local s="${cur%% *}"
    msg_info "Sesión PHP: ${s}s ($(awk "BEGIN{printf \"%.1f\", $s/3600}")h)"
  fi
  echo
  local ip; ip="$(detect_primary_ip 2>/dev/null || echo '<IP>')"
  echo "  Pruebas sugeridas:"
  echo "    curl -I http://${sn}"
  echo "    curl http://${sn}/test-db.php"
  echo "    curl http://${sn}/info.php"
  echo "    curl -v -H 'Host: ${sn}' http://${ip}"
}

delete_site() {
  choose_site || return 0
  local site="$CHOSEN_SITE" del confirm sn
  sn="$(awk '/server_name / && !/default_server/ {print $2; exit}' \
        "/etc/nginx/sites-available/${site}" 2>/dev/null | tr -d ';')"

  prompt_yes_no "¿Eliminar también /var/www/${site}?" "s"; del="$REPLY_YESNO"
  prompt_yes_no "¿Confirmar eliminación del sitio '${site}'?" "n"; confirm="$REPLY_YESNO"
  [[ "$confirm" != "s" ]] && { msg_warn "Operación cancelada."; return 0; }

  cleanup_site_residue "${site}" "${del}"
  if site_has_residue "${site}"; then
    msg_warn "Quedaron residuos. Revísalos manualmente."
  else
    msg_ok "Sitio eliminado: ${site}"
  fi

  if cf_installed && [[ -f "$CLOUDFLARED_CONFIG" ]]; then
    echo
    if [[ -n "$sn" ]] && grep -qF "hostname: ${sn}" "$CLOUDFLARED_CONFIG" 2>/dev/null; then
      msg_warn "El hostname '${sn}' aún figura en el config.yml de cloudflared."
    fi
    prompt_yes_no "¿Regenerar el config.yml de cloudflared para quitar este sitio?" "s"
    if [[ "$REPLY_YESNO" == "s" ]]; then
      echo
      if cf_regen_config; then
        [[ -n "$sn" ]] && msg_warn "Nota: el registro DNS (CNAME) de '${sn}' debe borrarse manualmente en Cloudflare."
      else
        msg_warn "No se pudo regenerar el config.yml. Hazlo desde el menú Cloudflare."
      fi
    fi
  fi
}

remove_debug_files() {
  choose_site || return 0
  local site="$CHOSEN_SITE"
  local pub_dir="/var/www/${site}/public"
  local removed_any=0

  msg_section "Eliminar archivos de diagnóstico"

  local files=("info.php" "test-db.php")
  for f in "${files[@]}"; do
    local fp="${pub_dir}/${f}"
    if [[ -f "$fp" ]]; then
      printf "  %-30s " "${fp}"
      if rm -f "$fp"; then echo -e "${GREEN}eliminado${RESET}"; else echo -e "${RED}error${RESET}"; fi
      removed_any=1
    else
      printf "  %-30s %b\n" "${fp}" "${YELLOW}no existe${RESET}"
    fi
  done

  echo
  if [[ $removed_any -eq 1 ]]; then
    msg_ok "Limpieza completada en: ${pub_dir}"
  else
    msg_warn "No se encontraron archivos de diagnóstico en: ${pub_dir}"
  fi
}

reload_services() {
  if [[ -z "$PHP_VERSION" ]]; then
    msg_warn "No hay versión PHP activa. Selecciona una primero."; return 1
  fi
  nginx -t || { msg_error "Nginx inválido. No se recargó."; return 1; }
  systemctl reload nginx
  systemctl restart "php${PHP_VERSION}-fpm"
  msg_ok "Nginx recargado y PHP-FPM ${PHP_VERSION} reiniciado."
}

# ══════════════════════════════════════════════════════════════════════════════
# MARIADB
# ══════════════════════════════════════════════════════════════════════════════

mariadb_installed() { dpkg -s mariadb-server >/dev/null 2>&1; }
mariadb_running()   { systemctl is-active --quiet mariadb; }

require_mariadb() {
  if ! mariadb_installed; then
    msg_error "MariaDB no está instalado. Usa: MariaDB → opción 1."; return 1
  fi
  if ! mariadb_running; then
    msg_warn "MariaDB instalado pero inactivo. Iniciando..."
    systemctl enable --now mariadb
  fi
}

_select_app_user() {
  local prompt_label="${1:-Selecciona un usuario:}"
  SELECTED_DB_USER=""; SELECTED_DB_HOST=""

  local raw=()
  mapfile -t raw < <(
    mariadb -sNe "SELECT User, Host FROM mysql.user
                  WHERE User NOT IN ('root','mariadb.sys','mysql')
                  ORDER BY User, Host;" 2>/dev/null
  )
  if [[ "${#raw[@]}" -eq 0 ]]; then
    msg_warn "No hay usuarios de aplicación en MariaDB."
    return 1
  fi

  echo "  ${prompt_label}"; echo
  local i=1 users=() hosts=()
  for row in "${raw[@]}"; do
    local u h
    u="$(awk '{print $1}' <<< "$row")"
    h="$(awk '{print $2}' <<< "$row")"
    users+=("$u"); hosts+=("$h")
    printf "  %2d) %-20s @ %s\n" "$i" "$u" "$h"
    ((i++))
  done
  echo "   0) Cancelar"; echo

  local opt
  while true; do
    read -rp "  Opción: " opt
    [[ "$opt" == "0" ]] && return 1
    if [[ "$opt" =~ ^[0-9]+$ ]] && (( opt >= 1 && opt <= ${#users[@]} )); then
      SELECTED_DB_USER="${users[$((opt-1))]}"
      SELECTED_DB_HOST="${hosts[$((opt-1))]}"
      return 0
    fi
    msg_error "Opción inválida."
  done
}

install_mariadb() {
  if mariadb_installed; then
    msg_warn "MariaDB ya está instalado."
    systemctl enable --now mariadb
    msg_ok "Servicio activo y habilitado."
    msg_info "Puedes endurecer con: mysql_secure_installation"
    return 0
  fi
  msg_info "[1/3] Actualizando repositorios..."
  apt-get update
  msg_info "[2/3] Instalando MariaDB..."
  apt-get install -y mariadb-server mariadb-client
  msg_info "[3/3] Habilitando servicio..."
  systemctl enable --now mariadb
  echo
  msg_ok "MariaDB instalado y habilitado."
  msg_info "Recuerda ejecutar: mysql_secure_installation"
}

configure_bind_address() {
  require_mariadb || return 1
  msg_section "Configurar bind-address"

  echo "  1) Solo local        → 127.0.0.1"
  echo "  2) IP específica del LXC"
  echo "  3) Todas las interfaces → 0.0.0.0"
  echo "  0) Cancelar"; echo
  read -rp "  Opción [0-3]: " mode; echo
  [[ "$mode" == "0" ]] && return 0

  local ip_val
  case "$mode" in
    1) ip_val="127.0.0.1" ;;
    2) read -rp "  IP del LXC MariaDB (ej: 192.168.11.20): " ip_val ;;
    3) ip_val="0.0.0.0" ;;
    *) msg_error "Opción inválida."; return 1 ;;
  esac

  cp "$MARIADB_CNF" "${MARIADB_CNF}.bak.$(date +%F-%H%M%S)"
  if grep -q '^[#[:space:]]*bind-address' "$MARIADB_CNF"; then
    sed -i "s/^[#[:space:]]*bind-address.*/bind-address = ${ip_val}/" "$MARIADB_CNF"
  else
    echo "bind-address = ${ip_val}" >> "$MARIADB_CNF"
  fi

  systemctl restart mariadb
  msg_ok "bind-address configurado: ${ip_val}. MariaDB reiniciado."
}

create_database_only() {
  require_mariadb || return 1
  msg_section "Crear base de datos"
  local db_name
  read -rp "  Nombre de la base de datos: " db_name
  [[ -z "$db_name" ]] && { msg_error "Nombre obligatorio."; return 1; }
  mariadb <<SQL
CREATE DATABASE IF NOT EXISTS \`${db_name}\` CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;
SQL
  msg_ok "Base de datos lista: ${db_name}"
}

create_user_and_grant() {
  require_mariadb || return 1
  msg_section "Crear base de datos + usuario"
  local db_name db_user

  read -rp "  Nombre de la base de datos: " db_name
  read -rp "  Usuario MariaDB: " db_user
  prompt_password_generic "Clave MariaDB"
  prompt_host_scope || return 1

  mariadb <<SQL
CREATE DATABASE IF NOT EXISTS \`${db_name}\` CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;
CREATE USER IF NOT EXISTS '${db_user}'@'${REPLY_HOST}' IDENTIFIED BY '${DB_PASS_VALUE}';
ALTER USER '${db_user}'@'${REPLY_HOST}' IDENTIFIED BY '${DB_PASS_VALUE}';
GRANT ALL PRIVILEGES ON \`${db_name}\`.* TO '${db_user}'@'${REPLY_HOST}';
FLUSH PRIVILEGES;
SQL

  echo
  msg_ok "Base y usuario creados/actualizados."
  printf '  %-10s %s\n' "DB:"    "$db_name"
  printf '  %-10s %s\n' "USER:"  "$db_user"
  printf '  %-10s %s\n' "HOST:"  "$REPLY_HOST"
}

create_user_only() {
  require_mariadb || return 1
  msg_section "Crear usuario y asignarlo a una base"
  local db_name db_user

  read -rp "  Base de datos a asignar: " db_name
  read -rp "  Usuario MariaDB: " db_user
  prompt_password_generic "Clave MariaDB"
  prompt_host_scope || return 1

  mariadb <<SQL
CREATE USER IF NOT EXISTS '${db_user}'@'${REPLY_HOST}' IDENTIFIED BY '${DB_PASS_VALUE}';
ALTER USER '${db_user}'@'${REPLY_HOST}' IDENTIFIED BY '${DB_PASS_VALUE}';
GRANT ALL PRIVILEGES ON \`${db_name}\`.* TO '${db_user}'@'${REPLY_HOST}';
FLUSH PRIVILEGES;
SQL

  echo
  msg_ok "Usuario creado/actualizado."
  printf '  %-10s %s\n' "DB:"    "$db_name"
  printf '  %-10s %s\n' "USER:"  "$db_user"
  printf '  %-10s %s\n' "HOST:"  "$REPLY_HOST"
}

create_dual_user() {
  require_mariadb || return 1
  msg_section "Crear usuario dual (localhost + remoto)"
  local db_name db_user remote_host

  read -rp "  Nombre de la base de datos: " db_name
  read -rp "  Usuario MariaDB: " db_user
  prompt_password_generic "Clave MariaDB"
  read -rp "  IP o red remota autorizada (ej: 192.168.11.% o 100.64.0.10): " remote_host

  mariadb <<SQL
CREATE DATABASE IF NOT EXISTS \`${db_name}\` CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;
CREATE USER IF NOT EXISTS '${db_user}'@'localhost'       IDENTIFIED BY '${DB_PASS_VALUE}';
ALTER  USER              '${db_user}'@'localhost'       IDENTIFIED BY '${DB_PASS_VALUE}';
GRANT ALL PRIVILEGES ON \`${db_name}\`.* TO '${db_user}'@'localhost';
CREATE USER IF NOT EXISTS '${db_user}'@'${remote_host}' IDENTIFIED BY '${DB_PASS_VALUE}';
ALTER  USER              '${db_user}'@'${remote_host}' IDENTIFIED BY '${DB_PASS_VALUE}';
GRANT ALL PRIVILEGES ON \`${db_name}\`.* TO '${db_user}'@'${remote_host}';
FLUSH PRIVILEGES;
SQL

  echo
  msg_ok "Usuario dual creado/actualizado."
  printf '  %-14s %s\n' "DB:"            "$db_name"
  printf '  %-14s %s\n' "USER:"          "$db_user"
  printf '  %-14s %s\n' "HOST local:"    "localhost"
  printf '  %-14s %s\n' "HOST remoto:"   "$remote_host"
}

list_databases() {
  require_mariadb || return 1
  msg_section "Bases de datos"
  mariadb -e "SHOW DATABASES;"
}

list_users() {
  require_mariadb || return 1
  msg_section "Usuarios MariaDB"
  mariadb -e "SELECT User, Host FROM mysql.user ORDER BY User, Host;"
}

show_grants_for_user() {
  require_mariadb || return 1
  msg_section "Grants de un usuario"
  _select_app_user "Selecciona un usuario:" || return 0
  echo
  msg_info "SHOW GRANTS FOR '${SELECTED_DB_USER}'@'${SELECTED_DB_HOST}':"
  echo
  mariadb -e "SHOW GRANTS FOR '${SELECTED_DB_USER}'@'${SELECTED_DB_HOST}';" 2>&1 \
    || msg_error "No se pudieron obtener los grants."
}

change_user_password() {
  require_mariadb || return 1
  msg_section "Cambiar contraseña de usuario"
  _select_app_user "Selecciona el usuario al que cambiar la contraseña:" || return 0
  echo
  msg_info "Cambiando contraseña de '${SELECTED_DB_USER}'@'${SELECTED_DB_HOST}'"
  prompt_password_generic "Nueva contraseña"
  mariadb <<SQL
ALTER USER '${SELECTED_DB_USER}'@'${SELECTED_DB_HOST}' IDENTIFIED BY '${DB_PASS_VALUE}';
FLUSH PRIVILEGES;
SQL
  msg_ok "Contraseña actualizada: '${SELECTED_DB_USER}'@'${SELECTED_DB_HOST}'"
}

delete_database() {
  require_mariadb || return 1
  msg_section "Eliminar base de datos"
  local db_name confirm
  read -rp "  Base de datos a eliminar: " db_name
  prompt_yes_no "¿Confirmar eliminación de '${db_name}'?" "n"; confirm="$REPLY_YESNO"
  [[ "$confirm" != "s" ]] && { msg_warn "Cancelado."; return 0; }
  mariadb -e "DROP DATABASE IF EXISTS \`${db_name}\`;"
  msg_ok "Base eliminada: ${db_name}"
}

delete_user() {
  require_mariadb || return 1
  msg_section "Eliminar usuario"
  local db_user db_host confirm
  read -rp "  Usuario MariaDB a eliminar: " db_user
  read -rp "  Host del usuario (ej: localhost, %): " db_host
  prompt_yes_no "¿Confirmar eliminación de '${db_user}'@'${db_host}'?" "n"; confirm="$REPLY_YESNO"
  [[ "$confirm" != "s" ]] && { msg_warn "Cancelado."; return 0; }
  mariadb -e "DROP USER IF EXISTS '${db_user}'@'${db_host}'; FLUSH PRIVILEGES;"
  msg_ok "Usuario eliminado: ${db_user}@${db_host}"
}

mariadb_secure_hint() {
  msg_section "Endurecer MariaDB"
  msg_info "Para endurecer MariaDB ejecuta manualmente:"
  echo "    mysql_secure_installation"
  msg_warn "Recomendado si este LXC no es solo de laboratorio."
}

change_user_host() {
  require_mariadb || return 1
  msg_section "Cambiar host de un usuario"
  _select_app_user "Selecciona el usuario a modificar:" || return 0

  local db_user="$SELECTED_DB_USER"
  local old_host="$SELECTED_DB_HOST"

  msg_info "Usuario actual: ${db_user}@${old_host}"
  echo
  msg_info "Grants actuales:"
  mariadb -e "SHOW GRANTS FOR '${db_user}'@'${old_host}';" 2>/dev/null || true
  echo

  prompt_host_scope || return 1
  local new_host="$REPLY_HOST"

  if [[ "$new_host" == "$old_host" ]]; then
    msg_warn "El nuevo host es igual al actual. Sin cambios."; return 0
  fi

  prompt_yes_no "¿Cambiar host de '${db_user}@${old_host}' → '${db_user}@${new_host}'?" "s"
  [[ "$REPLY_YESNO" != "s" ]] && { msg_warn "Cancelado."; return 0; }

  mariadb <<SQL
UPDATE mysql.user SET Host='${new_host}' WHERE User='${db_user}' AND Host='${old_host}';
UPDATE mysql.db   SET Host='${new_host}' WHERE User='${db_user}' AND Host='${old_host}';
FLUSH PRIVILEGES;
SQL

  msg_ok "Host cambiado: ${db_user}@${old_host}  →  ${db_user}@${new_host}"
  echo
  msg_info "Grants resultantes:"
  mariadb -e "SHOW GRANTS FOR '${db_user}'@'${new_host}';" 2>/dev/null || true
}

change_user_grants() {
  require_mariadb || return 1
  msg_section "Cambiar privilegios de un usuario"
  _select_app_user "Selecciona el usuario:" || return 0

  local db_user="$SELECTED_DB_USER"
  local db_host="$SELECTED_DB_HOST"

  msg_info "Usuario: ${db_user}@${db_host}"
  echo
  msg_info "Grants actuales:"
  mariadb -e "SHOW GRANTS FOR '${db_user}'@'${db_host}';" 2>/dev/null || true
  echo

  local db_name
  read -rp "  Base de datos (Enter para aplicar en *.*): " db_name
  local grant_target
  if [[ -z "$db_name" ]]; then
    grant_target="*.*"
  else
    grant_target="\`${db_name}\`.*"
  fi

  echo
  echo "  Nivel de privilegio:"
  echo "  1) ALL PRIVILEGES                                       — acceso completo"
  echo "  2) SELECT                                               — solo lectura"
  echo "  3) SELECT, INSERT, UPDATE, DELETE                       — DML sin DDL"
  echo "  4) SELECT, INSERT, UPDATE, DELETE, CREATE, DROP, INDEX, ALTER  — DML + DDL"
  echo "  0) Cancelar"
  echo

  local opt priv
  read -rp "  Opción: " opt
  case "$opt" in
    1) priv="ALL PRIVILEGES" ;;
    2) priv="SELECT" ;;
    3) priv="SELECT, INSERT, UPDATE, DELETE" ;;
    4) priv="SELECT, INSERT, UPDATE, DELETE, CREATE, DROP, INDEX, ALTER" ;;
    0) return 0 ;;
    *) msg_error "Opción inválida."; return 1 ;;
  esac

  prompt_yes_no "¿Aplicar REVOKE ALL + GRANT ${priv} ON ${grant_target} a '${db_user}'@'${db_host}'?" "s"
  [[ "$REPLY_YESNO" != "s" ]] && { msg_warn "Cancelado."; return 0; }

  mariadb <<SQL
REVOKE ALL PRIVILEGES, GRANT OPTION FROM '${db_user}'@'${db_host}';
GRANT ${priv} ON ${grant_target} TO '${db_user}'@'${db_host}';
FLUSH PRIVILEGES;
SQL

  msg_ok "Privilegios actualizados."
  echo
  msg_info "Grants resultantes:"
  mariadb -e "SHOW GRANTS FOR '${db_user}'@'${db_host}';" 2>/dev/null || true
}

dump_database() {
  require_mariadb || return 1
  msg_section "Backup de base de datos (mysqldump)"

  echo "  Bases de datos disponibles:"; echo
  mariadb -sNe "SHOW DATABASES WHERE \`Database\` NOT IN \
    ('information_schema','performance_schema','sys','mysql');" 2>/dev/null \
    | nl -ba -nrz -w2 | sed 's/^/  /'
  echo

  local db_name
  read -rp "  Nombre de la base de datos: " db_name
  [[ -z "$db_name" ]] && { msg_error "Nombre obligatorio."; return 1; }

  local dump_dir="/var/backups/mariadb"
  mkdir -p "$dump_dir"
  local dump_file="${dump_dir}/${db_name}_$(date +%F_%H%M%S).sql.gz"

  msg_info "Volcando ${db_name} → ${dump_file}..."
  if mysqldump --single-transaction --quick --lock-tables=false "$db_name" \
     | gzip > "$dump_file"; then
    local size; size="$(du -sh "$dump_file" | cut -f1)"
    msg_ok "Backup completado: ${dump_file}  (${size})"
  else
    rm -f "$dump_file"
    msg_error "mysqldump falló."; return 1
  fi

  echo
  echo "  Backups existentes en ${dump_dir}:"
  ls -lh "${dump_dir}/"*.sql.gz 2>/dev/null | awk '{print "  " $NF "  " $5}' || true
}

restore_database() {
  require_mariadb || return 1
  msg_section "Restaurar base de datos desde backup"

  local dump_dir="/var/backups/mariadb"
  local files=()
  if [[ -d "$dump_dir" ]]; then
    mapfile -t files < <(
      find "$dump_dir" -maxdepth 1 -type f \( -name "*.sql" -o -name "*.sql.gz" \) \
        | sort -r
    )
  fi

  local source_file=""
  if [[ "${#files[@]}" -gt 0 ]]; then
    echo "  Backups disponibles en ${dump_dir}:"; echo
    local i=1
    for f in "${files[@]}"; do
      local sz; sz="$(du -sh "$f" | cut -f1)"
      printf "  %2d) %-52s %s\n" "$i" "$(basename "$f")" "$sz"
      ((i++))
    done
    echo "   m) Ingresar ruta manualmente"
    echo "   0) Cancelar"; echo

    local opt
    read -rp "  Opción: " opt
    [[ "$opt" == "0" ]] && return 0
    if [[ "$opt" == "m" || "$opt" == "M" ]]; then
      read -rp "  Ruta al archivo (.sql o .sql.gz): " source_file
    elif [[ "$opt" =~ ^[0-9]+$ ]] && (( opt >= 1 && opt <= ${#files[@]} )); then
      source_file="${files[$((opt-1))]}"
    else
      msg_error "Opción inválida."; return 1
    fi
  else
    msg_warn "No se encontraron backups en ${dump_dir}."
    read -rp "  Ruta al archivo (.sql o .sql.gz): " source_file
  fi

  [[ -z "$source_file" || ! -f "$source_file" ]] \
    && { msg_error "Archivo no encontrado: ${source_file}"; return 1; }

  local db_name
  read -rp "  Base de datos destino (debe existir): " db_name
  [[ -z "$db_name" ]] && { msg_error "Nombre obligatorio."; return 1; }

  prompt_yes_no "¿Restaurar '$(basename "$source_file")' en '${db_name}'? (se sobreescribirán los datos actuales)" "n"
  [[ "$REPLY_YESNO" != "s" ]] && { msg_warn "Cancelado."; return 0; }

  msg_info "Restaurando en ${db_name}..."
  if [[ "$source_file" == *.gz ]]; then
    gunzip -c "$source_file" | mariadb "$db_name" 2>&1
  else
    mariadb "$db_name" < "$source_file" 2>&1
  fi && msg_ok "Restauración completada en: ${db_name}" \
     || { msg_error "Falló la restauración."; return 1; }
}

show_db_sizes() {
  require_mariadb || return 1
  msg_section "Tamaño de bases de datos"
  mariadb -t -e "
SELECT
  table_schema                                                     AS 'Base de datos',
  COUNT(*)                                                         AS 'Tablas',
  ROUND(SUM(data_length)              / 1024 / 1024, 2)           AS 'Datos (MB)',
  ROUND(SUM(index_length)             / 1024 / 1024, 2)           AS 'Índices (MB)',
  ROUND(SUM(data_length + index_length) / 1024 / 1024, 2)         AS 'Total (MB)'
FROM information_schema.tables
WHERE table_schema NOT IN ('information_schema','performance_schema','sys','mysql')
GROUP BY table_schema
ORDER BY SUM(data_length + index_length) DESC;" 2>/dev/null \
    || msg_warn "No se pudo consultar information_schema."
}

show_active_connections() {
  require_mariadb || return 1
  msg_section "Conexiones activas"
  mariadb -t -e "SHOW FULL PROCESSLIST;" 2>/dev/null \
    || msg_warn "No se pudo obtener el processlist."
  echo
  local total; total="$(mariadb -sNe "SELECT COUNT(*) FROM information_schema.processlist;" 2>/dev/null || echo '?')"
  msg_info "Total de conexiones activas: ${total}"
}

# ══════════════════════════════════════════════════════════════════════════════
# SISTEMA — UTILIDADES
# ══════════════════════════════════════════════════════════════════════════════

sys_show_time() {
  msg_section "Hora y zona horaria del sistema"
  local tz ntp_active ntp_sync
  tz="$(timedatectl show --property=Timezone --value 2>/dev/null \
        || cat /etc/timezone 2>/dev/null || echo 'desconocida')"
  ntp_active="$(timedatectl show --property=NTPSynchronized --value 2>/dev/null || echo 'n/a')"
  ntp_sync="$(timedatectl show --property=NTP --value 2>/dev/null || echo 'n/a')"

  printf "  %-26s %s\n" "Fecha y hora actual:"  "$(date '+%Y-%m-%d %H:%M:%S %Z')"
  printf "  %-26s %s\n" "Zona horaria:"          "$tz"
  printf "  %-26s %s\n" "NTP activo:"            "$ntp_sync"
  printf "  %-26s %s\n" "NTP sincronizado:"      "$ntp_active"
  echo

  if systemd-detect-virt --quiet --container 2>/dev/null; then
    msg_warn "Este sistema corre en un contenedor (LXC/VM)."
    msg_warn "El reloj es compartido con el host Proxmox."
    msg_warn "Si la hora está mal, corrígela en el nodo Proxmox primero."
  fi
}

sys_set_timezone() {
  msg_section "Cambiar zona horaria"

  local current_tz
  current_tz="$(timedatectl show --property=Timezone --value 2>/dev/null \
                || cat /etc/timezone 2>/dev/null || echo 'desconocida')"
  msg_info "Zona actual: ${current_tz}"; echo

  local regions=(Africa America Antarctica Arctic Asia Atlantic Australia Europe
                 Indian Pacific US)
  echo "  Regiones disponibles:"
  local i=1
  for r in "${regions[@]}"; do
    printf "  %2d) %s\n" "$i" "$r"; ((i++))
  done
  echo "   m) Ingresar zona manualmente"
  echo "   0) Cancelar"; echo

  local opt chosen_tz
  read -rp "  Selecciona región: " opt
  [[ "$opt" == "0" ]] && return 0

  if [[ "$opt" == "m" || "$opt" == "M" ]]; then
    read -rp "  Zona horaria (ej: America/Santiago): " chosen_tz
    [[ -z "$chosen_tz" ]] && { msg_error "Zona obligatoria."; return 1; }
  elif [[ "$opt" =~ ^[0-9]+$ ]] && (( opt >= 1 && opt <= ${#regions[@]} )); then
    local region="${regions[$((opt-1))]}"
    echo
    echo "  Zonas disponibles en ${region}:"
    echo
    local zone_list=()
    mapfile -t zone_list < <(timedatectl list-timezones 2>/dev/null | grep "^${region}/")
    if [[ "${#zone_list[@]}" -eq 0 ]]; then
      msg_warn "No se encontraron zonas para ${region}."; return 1
    fi
    local j=1
    for z in "${zone_list[@]}"; do
      printf "  %3d) %s\n" "$j" "$z"; ((j++))
    done
    echo "    0) Cancelar"; echo
    local zone_opt
    read -rp "  Selecciona zona: " zone_opt
    [[ "$zone_opt" == "0" ]] && return 0
    if [[ "$zone_opt" =~ ^[0-9]+$ ]] && (( zone_opt >= 1 && zone_opt <= ${#zone_list[@]} )); then
      chosen_tz="${zone_list[$((zone_opt-1))]}"
    else
      msg_error "Opción inválida."; return 1
    fi
  else
    msg_error "Opción inválida."; return 1
  fi

  if ! timedatectl list-timezones 2>/dev/null | grep -qx "$chosen_tz"; then
    msg_error "Zona '${chosen_tz}' no reconocida por timedatectl."
    return 1
  fi

  timedatectl set-timezone "$chosen_tz"
  msg_ok "Zona horaria establecida: ${chosen_tz}"
  echo
  printf "  %-26s %s\n" "Nueva hora del sistema:" "$(date '+%Y-%m-%d %H:%M:%S %Z')"
}

sys_configure_ntp() {
  msg_section "Sincronización NTP"

  local ntp_active ntp_sync
  ntp_active="$(timedatectl show --property=NTP --value 2>/dev/null || echo 'n/a')"
  ntp_sync="$(timedatectl show --property=NTPSynchronized --value 2>/dev/null || echo 'n/a')"

  printf "  %-26s %s\n" "NTP habilitado:"   "$ntp_active"
  printf "  %-26s %s\n" "NTP sincronizado:" "$ntp_sync"
  echo

  if systemd-detect-virt --quiet --container 2>/dev/null; then
    msg_warn "Contenedor detectado: la sincronización NTP la controla el host Proxmox."
    prompt_yes_no "¿Continuar de todas formas?" "n"
    [[ "$REPLY_YESNO" != "s" ]] && return 0
  fi

  echo "  1) Habilitar NTP (systemd-timesyncd)"
  echo "  2) Deshabilitar NTP"
  echo "  3) Forzar sincronización ahora"
  echo "  4) Ver estado detallado"
  echo "  0) Cancelar"
  echo
  local opt
  read -rp "  Opción: " opt
  case "$opt" in
    1)
      dpkg -s systemd-timesyncd >/dev/null 2>&1 \
        || apt-get install -y systemd-timesyncd
      systemctl enable --now systemd-timesyncd
      timedatectl set-ntp true
      msg_ok "NTP habilitado."
      sleep 2; timedatectl status
      ;;
    2) timedatectl set-ntp false; msg_warn "NTP deshabilitado." ;;
    3)
      if systemctl is-active --quiet systemd-timesyncd; then
        systemctl restart systemd-timesyncd
        sleep 2; timedatectl status
        msg_ok "Sincronización forzada."
      else
        msg_error "systemd-timesyncd no está activo. Habilita NTP primero (opción 1)."
      fi
      ;;
    4)
      timedatectl status
      echo
      journalctl -u systemd-timesyncd -n 20 --no-pager 2>/dev/null || true
      ;;
    0) return 0 ;;
    *) msg_error "Opción inválida." ;;
  esac
}

install_global_command() {
  msg_section "Instalar comando global"

  local script_path; script_path="$(realpath "$0" 2>/dev/null || readlink -f "$0")"
  if [[ ! -f "$script_path" ]]; then
    msg_error "No se pudo determinar la ruta del script."; return 1
  fi

  local link_path="/usr/local/bin/devlab"

  echo "  Script actual:  ${script_path}"
  echo "  Enlace a crear: ${link_path}"
  echo

  if [[ -L "$link_path" ]]; then
    local current_target; current_target="$(readlink -f "$link_path")"
    msg_warn "Ya existe un enlace: ${link_path} → ${current_target}"
    prompt_yes_no "¿Sobreescribir?" "s"
    [[ "$REPLY_YESNO" != "s" ]] && { msg_warn "Cancelado."; return 0; }
  elif [[ -e "$link_path" ]]; then
    msg_error "${link_path} ya existe y no es un enlace simbólico. Revisa manualmente."; return 1
  fi

  chmod +x "$script_path"
  ln -sf "$script_path" "$link_path"
  msg_ok "Enlace creado: ${link_path} → ${script_path}"
  echo
  msg_info "Ahora puedes ejecutar el script desde cualquier ruta con:"
  echo
  echo "      devlab"
  echo
  msg_warn "Requiere root: sudo devlab  o  ejecutar como root."
}

remove_global_command() {
  msg_section "Eliminar comando global"
  local link_path="/usr/local/bin/devlab"

  if [[ ! -L "$link_path" && ! -e "$link_path" ]]; then
    msg_warn "No existe ningún enlace en ${link_path}."; return 0
  fi

  echo "  Enlace: ${link_path} → $(readlink -f "$link_path")"
  echo
  prompt_yes_no "¿Confirmar eliminación?" "n"
  [[ "$REPLY_YESNO" != "s" ]] && { msg_warn "Cancelado."; return 0; }

  rm -f "$link_path"
  msg_ok "Enlace eliminado. El script original no fue modificado."
}

sys_update() {
  msg_section "Actualizar sistema"
  msg_info "Actualizando lista de paquetes..."
  apt-get update
  echo
  msg_info "Paquetes con actualización disponible:"
  apt list --upgradable 2>/dev/null | grep -v "^Listing" || true
  echo
  prompt_yes_no "¿Aplicar actualizaciones?" "s"
  [[ "$REPLY_YESNO" != "s" ]] && return 0
  apt-get upgrade -y
  msg_ok "Sistema actualizado."
}

sys_info() {
  msg_section "Información del sistema"
  local ip
  ip="$(detect_primary_ip 2>/dev/null || echo 'no detectada')"

  printf "  %-26s %s\n" "Hostname:"       "$(hostname)"
  printf "  %-26s %s\n" "IP principal:"   "$ip"
  printf "  %-26s %s\n" "OS:"             "$(grep PRETTY_NAME /etc/os-release 2>/dev/null | cut -d= -f2 | tr -d '\"')"
  printf "  %-26s %s\n" "Kernel:"         "$(uname -r)"
  printf "  %-26s %s\n" "Uptime:"         "$(uptime -p 2>/dev/null || uptime)"
  printf "  %-26s %s\n" "Zona horaria:"   "$(timedatectl show --property=Timezone --value 2>/dev/null)"
  printf "  %-26s %s\n" "Hora actual:"    "$(date '+%Y-%m-%d %H:%M:%S %Z')"
  echo
  printf "  %-26s %s\n" "CPU:"            "$(grep 'model name' /proc/cpuinfo 2>/dev/null | head -1 | cut -d: -f2 | xargs)"
  printf "  %-26s %s\n" "Núcleos:"        "$(nproc)"
  printf "  %-26s %s\n" "RAM total:"      "$(free -h | awk '/^Mem:/ {print $2}')"
  printf "  %-26s %s\n" "RAM usada:"      "$(free -h | awk '/^Mem:/ {print $3}')"
  printf "  %-26s %s\n" "Disco /:"        "$(df -h / | awk 'NR==2 {print $3 " / " $2 " (" $5 " usado)"}')"
  echo
  printf "  %-26s %s\n" "Virtualización:" "$(systemd-detect-virt 2>/dev/null || echo 'desconocido')"
}

# ══════════════════════════════════════════════════════════════════════════════
# CLOUDFLARED
# ══════════════════════════════════════════════════════════════════════════════

cf_installed()  { command -v cloudflared >/dev/null 2>&1; }
cf_running()    { systemctl is-active --quiet cloudflared 2>/dev/null; }

cf_require_installed() {
  cf_installed || { msg_error "cloudflared no instalado. Usa: Cloudflare → opción 1."; return 1; }
}
cf_require_config() {
  [[ -f "$CLOUDFLARED_CONFIG" ]] \
    || { msg_error "No existe ${CLOUDFLARED_CONFIG}. Configura el tunnel primero (opción 3)."; return 1; }
}

_cf_uuid_by_name() { cloudflared tunnel list 2>/dev/null | awk -v n="$1" '$2==n {print $1; exit}'; }
_cf_name_by_uuid() { cloudflared tunnel list 2>/dev/null | awk -v u="$1" '$1==u {print $2; exit}'; }

cf_install() {
  if cf_installed; then
    msg_warn "cloudflared ya está instalado: $(cloudflared --version 2>&1 | head -1)"
    return 0
  fi
  local arch deb_arch
  arch="$(dpkg --print-architecture 2>/dev/null || uname -m)"
  case "$arch" in
    amd64|x86_64)     deb_arch="amd64" ;;
    arm64|aarch64)    deb_arch="arm64" ;;
    armhf|armv7l|arm) deb_arch="arm"   ;;
    i386|i686)        deb_arch="386"   ;;
    *) msg_error "Arquitectura no soportada: ${arch}"; return 1 ;;
  esac
  msg_info "Arquitectura detectada: ${arch} → cloudflared-linux-${deb_arch}"

  local tmp url
  tmp="$(mktemp -d)"
  url="https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-linux-${deb_arch}.deb"
  msg_info "Descargando cloudflared..."
  if ! wget -qO "${tmp}/cloudflared.deb" "$url"; then
    msg_error "Falló la descarga desde: ${url}"; rm -rf "$tmp"; return 1
  fi
  if ! dpkg -i "${tmp}/cloudflared.deb"; then
    msg_warn "dpkg reportó dependencias faltantes. Resolviendo con apt..."
    apt-get install -f -y || { rm -rf "$tmp"; msg_error "No se pudieron resolver dependencias."; return 1; }
  fi
  rm -rf "$tmp"
  msg_ok "cloudflared instalado: $(cloudflared --version 2>&1 | head -1)"
}

cf_login() {
  cf_require_installed || return 1
  msg_section "Autenticar cloudflared con Cloudflare"
  msg_info "Se abrirá una URL. Cópiala en tu navegador y autoriza la zona."
  echo
  cloudflared tunnel login
  msg_ok "Autenticación completada."
}

cf_write_systemd_unit() {
  local unit_file="/etc/systemd/system/cloudflared.service"
  cat > "$unit_file" <<'UNIT'
[Unit]
Description=cloudflared
After=network.target

[Service]
TimeoutStartSec=0
Type=notify
ExecStart=/usr/bin/cloudflared --no-autoupdate tunnel run
Restart=on-failure
RestartSec=5s

[Install]
WantedBy=multi-user.target
UNIT
  systemctl daemon-reload
  systemctl enable --now cloudflared
  msg_ok "Unit file escrito en modo config.yml."
  msg_ok "Servicio iniciado."
}

cf_fix_service() {
  cf_require_installed || return 1
  cf_require_config    || return 1
  msg_section "Reparar servicio cloudflared"
  local unit_file="/etc/systemd/system/cloudflared.service"
  if grep -q "\-\-token" "$unit_file" 2>/dev/null; then
    msg_warn "El unit file usa --token (modo dashboard). Corrigiendo..."
  else
    msg_info "El unit file ya parece correcto:"
    cat "$unit_file"; echo
    prompt_yes_no "¿Reescribir el unit file de todas formas?" "n"
    [[ "$REPLY_YESNO" != "s" ]] && return 0
  fi
  systemctl stop cloudflared 2>/dev/null || true
  cf_write_systemd_unit
  echo
  msg_info "Verificando estado..."
  sleep 2
  systemctl status cloudflared --no-pager -l || true
}

_cf_build_config() {
  local uuid="$1" creds_file="$2" tunnel_name="$3"

  local sites=()
  mapfile -t sites < <(
    find /etc/nginx/sites-enabled -maxdepth 1 -type l -printf '%f\n' \
      | grep -Ev '^default$|^000-catch-all$|\.maintenance$' | sort
  )

  local ingress_blocks=""
  if [[ "${#sites[@]}" -gt 0 ]]; then
    msg_info "Sitios Nginx detectados:"
    for site in "${sites[@]}"; do
      local sn
      sn="$(awk '/server_name / && !/default_server/ {print $2; exit}' \
            "/etc/nginx/sites-available/${site}" 2>/dev/null | tr -d ';')"
      [[ -z "$sn" ]] && continue
      echo "    ${sn}"
      ingress_blocks+="  - hostname: ${sn}
    service: http://127.0.0.1:80
    originRequest:
      httpHostHeader: ${sn}
"
    done
  else
    msg_warn "No hay sitios Nginx activos. El config tendrá un bloque de ejemplo."
    ingress_blocks="  - hostname: tudominio.cl
    service: http://127.0.0.1:80
    originRequest:
      httpHostHeader: tudominio.cl
"
  fi

  [[ -f "$CLOUDFLARED_CONFIG" ]] \
    && cp "$CLOUDFLARED_CONFIG" "${CLOUDFLARED_CONFIG}.bak.$(date +%F-%H%M%S)"

  install -d -m 0755 "$CLOUDFLARED_DIR"
  cat > "$CLOUDFLARED_CONFIG" <<EOF
tunnel: ${uuid}
credentials-file: ${creds_file}

ingress:
${ingress_blocks}  - service: http_status:404
EOF

  msg_ok "config.yml escrito: ${CLOUDFLARED_CONFIG}"
  echo; cat "$CLOUDFLARED_CONFIG"; echo

  prompt_yes_no "¿Crear/actualizar rutas DNS en Cloudflare?" "s"
  if [[ "$REPLY_YESNO" == "s" ]]; then
    for site in "${sites[@]:-}"; do
      [[ -z "$site" ]] && continue
      local sn
      sn="$(awk '/server_name / && !/default_server/ {print $2; exit}' \
            "/etc/nginx/sites-available/${site}" 2>/dev/null | tr -d ';')"
      [[ -z "$sn" ]] && continue
      msg_info "Creando ruta DNS para ${sn}..."
      cloudflared tunnel route dns "$tunnel_name" "$sn" 2>&1 \
        && msg_ok "DNS OK: ${sn}" \
        || msg_warn "No se pudo crear DNS para ${sn} (puede ya existir)."
    done
  fi
}

cf_create_tunnel() {
  cf_require_installed || return 1
  msg_section "Crear tunnel y configurar config.yml"

  echo "  Tunnels existentes en tu cuenta:"; echo
  cloudflared tunnel list 2>/dev/null | while IFS= read -r line; do echo "    $line"; done
  echo

  prompt_yes_no "¿Reusar un tunnel existente de la lista?" "n"
  local tunnel_name uuid

  if [[ "$REPLY_YESNO" == "s" ]]; then
    read -rp "  Nombre exacto del tunnel a reusar: " tunnel_name
    [[ -z "$tunnel_name" ]] && { msg_error "Nombre obligatorio."; return 1; }
    uuid="$(_cf_uuid_by_name "$tunnel_name")"
    if [[ -z "$uuid" ]]; then
      msg_error "No se encontró el tunnel '${tunnel_name}'."; return 1
    fi
    msg_ok "Tunnel encontrado: ${tunnel_name} (${uuid})"
  else
    read -rp "  Nombre del nuevo tunnel: " tunnel_name
    [[ -z "$tunnel_name" ]] && { msg_error "Nombre obligatorio."; return 1; }
    local existing; existing="$(_cf_uuid_by_name "$tunnel_name")"
    if [[ -n "$existing" ]]; then
      msg_warn "Ya existe un tunnel '${tunnel_name}' (UUID: ${existing})."
      prompt_yes_no "¿Reusar ese tunnel?" "s"
      if [[ "$REPLY_YESNO" == "s" ]]; then
        uuid="$existing"
        msg_ok "Reusando tunnel: ${uuid}"
      else
        msg_error "Elige un nombre diferente."; return 1
      fi
    else
      msg_info "Creando tunnel '${tunnel_name}'..."
      cloudflared tunnel create "$tunnel_name" 2>&1 \
        || { msg_error "No se pudo crear el tunnel."; return 1; }
      uuid="$(_cf_uuid_by_name "$tunnel_name")"
      [[ -z "$uuid" ]] && { msg_error "No se pudo obtener el UUID."; return 1; }
      msg_ok "Tunnel creado: ${uuid}"
    fi
  fi

  local creds_file=""
  for f in "/root/.cloudflared/${uuid}.json" "${CLOUDFLARED_DIR}/${uuid}.json"; do
    [[ -f "$f" ]] && creds_file="$f" && break
  done
  if [[ -z "$creds_file" ]]; then
    msg_warn "No se encontró el archivo de credenciales (.json)."
    msg_warn "Si reusaste un tunnel del dashboard:"
    msg_warn "  cloudflared tunnel token --cred-file /etc/cloudflared/${uuid}.json ${tunnel_name}"
    read -rp "  Ruta al archivo .json: " creds_file
    [[ ! -f "$creds_file" ]] && { msg_error "Archivo no encontrado."; return 1; }
  fi
  msg_ok "Credenciales: ${creds_file}"

  _cf_build_config "$uuid" "$creds_file" "$tunnel_name"

  prompt_yes_no "¿Instalar/actualizar cloudflared como servicio systemd?" "s"
  [[ "$REPLY_YESNO" == "s" ]] && cf_write_systemd_unit
}

cf_regen_config() {
  cf_require_installed || return 1
  msg_section "Regenerar config.yml desde sitios Nginx"

  echo "  Tunnels activos en tu cuenta:"; echo
  cloudflared tunnel list 2>/dev/null | while IFS= read -r line; do echo "    $line"; done
  echo

  local uuid creds tunnel_name
  if [[ -f "$CLOUDFLARED_CONFIG" ]]; then
    uuid="$(awk '/^tunnel:/ {print $2}' "$CLOUDFLARED_CONFIG")"
    creds="$(awk '/^credentials-file:/ {print $2}' "$CLOUDFLARED_CONFIG")"
    tunnel_name="$(_cf_name_by_uuid "$uuid")"
    msg_info "Tunnel actual: ${tunnel_name:-desconocido} (${uuid:-N/A})"; echo
    prompt_yes_no "¿Cambiar a otro tunnel?" "n"
  else
    msg_warn "No existe config.yml. Se creará desde cero."
    REPLY_YESNO="s"
  fi

  if [[ "$REPLY_YESNO" == "s" ]]; then
    read -rp "  Nombre exacto del tunnel a usar: " tunnel_name
    [[ -z "$tunnel_name" ]] && { msg_error "Nombre obligatorio."; return 1; }
    uuid="$(_cf_uuid_by_name "$tunnel_name")"
    [[ -z "$uuid" ]] && { msg_error "Tunnel '${tunnel_name}' no encontrado."; return 1; }
    msg_ok "UUID: ${uuid}"
    creds=""
    for f in "/root/.cloudflared/${uuid}.json" "${CLOUDFLARED_DIR}/${uuid}.json"; do
      [[ -f "$f" ]] && creds="$f" && break
    done
    if [[ -z "$creds" ]]; then
      msg_warn "No se encontró el archivo .json de credenciales."
      msg_warn "cloudflared tunnel token --cred-file /etc/cloudflared/${uuid}.json ${tunnel_name}"
      read -rp "  Ruta al archivo .json: " creds
      [[ ! -f "$creds" ]] && { msg_error "Archivo no encontrado."; return 1; }
    fi
    msg_ok "Credenciales: ${creds}"
  else
    if [[ -z "$uuid" || -z "$creds" ]]; then
      msg_error "No se pudo leer tunnel/credentials del config actual."; return 1
    fi
  fi

  _cf_build_config "$uuid" "$creds" "$tunnel_name"

  if cf_running; then
    prompt_yes_no "¿Reiniciar cloudflared para aplicar cambios?" "s"
    [[ "$REPLY_YESNO" == "s" ]] && systemctl restart cloudflared && msg_ok "cloudflared reiniciado."
  fi
}

cf_show_config() {
  cf_require_config || return 1
  msg_section "Config.yml actual"
  cat "$CLOUDFLARED_CONFIG"
}

cf_status() {
  cf_require_installed || return 1
  msg_section "Estado de cloudflared"
  local svc_status
  cf_running && svc_status="${GREEN}activo${RESET}" || svc_status="${RED}inactivo${RESET}"
  printf "  %-22s %b\n" "Servicio:" "$svc_status"
  cf_running && printf "  %-22s %s\n" "Versión:" "$(cloudflared --version 2>&1 | head -1)"
  if [[ -f "$CLOUDFLARED_CONFIG" ]]; then
    local uuid tunnel_name
    uuid="$(awk '/^tunnel:/ {print $2}' "$CLOUDFLARED_CONFIG")"
    tunnel_name="$(_cf_name_by_uuid "$uuid")"
    printf "  %-22s %s\n" "Tunnel UUID:"  "${uuid:-—}"
    printf "  %-22s %s\n" "Tunnel name:"  "${tunnel_name:-—}"
    echo
    echo "  Hostnames configurados:"
    awk '/hostname:/ {print "    " $2}' "$CLOUDFLARED_CONFIG"
  else
    msg_warn "No existe ${CLOUDFLARED_CONFIG}"
  fi
  echo
  echo "  Tunnels en Cloudflare:"
  cloudflared tunnel list 2>/dev/null || msg_warn "No se pudo listar tunnels."
}

cf_service_control() {
  cf_require_installed || return 1
  msg_section "Control del servicio cloudflared"
  echo "  1) Iniciar"
  echo "  2) Detener"
  echo "  3) Reiniciar"
  echo "  0) Cancelar"; echo
  local opt; read -rp "  Opción: " opt
  case "$opt" in
    1) systemctl start   cloudflared && msg_ok "Iniciado."   ;;
    2) systemctl stop    cloudflared && msg_ok "Detenido."   ;;
    3) systemctl restart cloudflared && msg_ok "Reiniciado." ;;
    0) return 0 ;;
    *) msg_error "Opción inválida." ;;
  esac
}

cf_logs() {
  cf_require_installed || return 1
  msg_section "Logs de cloudflared (últimas 50 líneas)"
  journalctl -u cloudflared -n 50 --no-pager 2>/dev/null \
    || msg_warn "No hay logs disponibles."
}

cf_remove_site() {
  cf_require_installed || return 1
  cf_require_config    || return 1
  msg_section "Eliminar sitio del tunnel (solo config.yml)"

  local hostnames=()
  mapfile -t hostnames < <(awk '/^  - hostname:/ {print $3}' "$CLOUDFLARED_CONFIG")

  if [[ "${#hostnames[@]}" -eq 0 ]]; then
    msg_warn "No hay hostnames configurados en el tunnel."; return 0
  fi

  echo "  Hostnames activos en el tunnel:"; echo
  local i=1
  for h in "${hostnames[@]}"; do
    printf "  %d) %s\n" "$i" "$h"; ((i++))
  done
  echo "  0) Cancelar"; echo

  local opt
  read -rp "  Opción: " opt
  [[ "$opt" == "0" ]] && return 0
  if ! [[ "$opt" =~ ^[0-9]+$ ]] || (( opt < 1 || opt > ${#hostnames[@]} )); then
    msg_error "Opción inválida."; return 1
  fi

  local chosen="${hostnames[$((opt-1))]}"
  echo
  msg_info "Sitio a eliminar del tunnel: ${chosen}"
  prompt_yes_no "¿Confirmar?" "n"
  [[ "$REPLY_YESNO" != "s" ]] && { msg_warn "Cancelado."; return 0; }

  cp "$CLOUDFLARED_CONFIG" "${CLOUDFLARED_CONFIG}.bak.$(date +%F-%H%M%S)"

  # Elimina el bloque de 4 líneas generado por este script para ese hostname
  sed -i "/^  - hostname: ${chosen}$/,/^      httpHostHeader: ${chosen}$/d" \
    "$CLOUDFLARED_CONFIG"

  msg_ok "Hostname '${chosen}' eliminado de config.yml"
  echo
  echo "  Config.yml resultante:"
  cat "$CLOUDFLARED_CONFIG"
  echo
  msg_warn "El registro CNAME de '${chosen}' en Cloudflare debe eliminarse manualmente"
  msg_warn "desde el panel → DNS → buscar el registro CNAME que apunta al tunnel."
  echo

  if cf_running; then
    prompt_yes_no "¿Reiniciar cloudflared para aplicar cambios?" "s"
    [[ "$REPLY_YESNO" == "s" ]] && systemctl restart cloudflared \
      && msg_ok "cloudflared reiniciado."
  fi
}

cf_delete_tunnel() {
  cf_require_installed || return 1
  msg_section "Eliminar tunnel completo de Cloudflare"

  local tunnels=()
  mapfile -t tunnels < <(cloudflared tunnel list 2>/dev/null | awk 'NR>1 && NF>=2 {print $1" "$2}')

  if [[ "${#tunnels[@]}" -eq 0 ]]; then
    msg_warn "No hay tunnels en tu cuenta."; return 0
  fi

  echo "  Tunnels existentes en tu cuenta:"; echo
  local i=1 uuids=() names=()
  for t in "${tunnels[@]}"; do
    local u n
    u="$(awk '{print $1}' <<< "$t")"
    n="$(awk '{print $2}' <<< "$t")"
    uuids+=("$u"); names+=("$n")
    printf "  %d) %-26s %s\n" "$i" "$n" "$u"
    ((i++))
  done
  echo "  0) Cancelar"; echo

  local opt
  read -rp "  Tunnel a eliminar: " opt
  [[ "$opt" == "0" ]] && return 0
  if ! [[ "$opt" =~ ^[0-9]+$ ]] || (( opt < 1 || opt > ${#uuids[@]} )); then
    msg_error "Opción inválida."; return 1
  fi

  local del_uuid="${uuids[$((opt-1))]}"
  local del_name="${names[$((opt-1))]}"
  echo
  msg_info "Tunnel seleccionado: ${del_name} (${del_uuid})"
  echo

  # Verificar sitios vinculados en el config.yml activo
  local linked_hosts=() is_active_config="n"
  if [[ -f "$CLOUDFLARED_CONFIG" ]]; then
    local cfg_uuid
    cfg_uuid="$(awk '/^tunnel:/ {print $2}' "$CLOUDFLARED_CONFIG")"
    if [[ "$cfg_uuid" == "$del_uuid" ]]; then
      is_active_config="s"
      mapfile -t linked_hosts < <(awk '/^  - hostname:/ {print $3}' "$CLOUDFLARED_CONFIG")
    fi
  fi

  if [[ "${#linked_hosts[@]}" -gt 0 ]]; then
    msg_warn "Este tunnel tiene ${#linked_hosts[@]} sitio(s) vinculado(s) en config.yml:"
    for h in "${linked_hosts[@]}"; do echo "      - $h"; done
    echo
    msg_warn "Si lo eliminas, estos sitios dejarán de ser accesibles vía Cloudflare."
    prompt_yes_no "¿Eliminar el tunnel de todas formas?" "n"
    [[ "$REPLY_YESNO" != "s" ]] && { msg_warn "Cancelado."; return 0; }
    echo
  else
    msg_ok "No se detectaron sitios vinculados a este tunnel en config.yml."
    echo
  fi

  prompt_yes_no "¿Confirmar eliminación DEFINITIVA del tunnel '${del_name}'?" "n"
  [[ "$REPLY_YESNO" != "s" ]] && { msg_warn "Cancelado."; return 0; }

  # Si es el tunnel activo, detener el servicio antes de eliminar
  local was_running="n"
  if [[ "$is_active_config" == "s" ]] && cf_running; then
    was_running="s"
    msg_info "Deteniendo servicio cloudflared (usa este tunnel)..."
    systemctl stop cloudflared 2>/dev/null || true
  fi

  # -f fuerza la limpieza de conexiones activas antes de borrar
  msg_info "Eliminando tunnel '${del_name}'..."
  if cloudflared tunnel delete -f "$del_name" 2>&1; then
    msg_ok "Tunnel '${del_name}' eliminado de Cloudflare."
  else
    msg_error "No se pudo eliminar el tunnel (¿conexiones activas o credenciales faltantes?)."
    [[ "$was_running" == "s" ]] && systemctl start cloudflared 2>/dev/null || true
    return 1
  fi

  # Limpiar credenciales locales del tunnel eliminado
  for f in "/root/.cloudflared/${del_uuid}.json" "${CLOUDFLARED_DIR}/${del_uuid}.json"; do
    [[ -f "$f" ]] && rm -f "$f" && msg_warn "Credenciales eliminadas: ${f}"
  done

  echo
  if [[ "$is_active_config" == "s" ]]; then
    msg_warn "El config.yml apuntaba a este tunnel y ahora quedó huérfano."
    msg_warn "Los registros CNAME en Cloudflare DNS deben eliminarse manualmente."
    echo
    msg_info "Para crear e incorporar un nuevo tunnel:"
    echo "      Cloudflare → opción 2 (Autenticar) → opción 3 (Crear tunnel + config.yml)"
  else
    msg_info "El config.yml activo no se vio afectado."
  fi
}

cf_uninstall() {
  cf_require_installed || return 1
  msg_section "Eliminar cloudflared de la máquina"

  # Detectar hostnames configurados en el config.yml
  local linked_hosts=()
  if [[ -f "$CLOUDFLARED_CONFIG" ]]; then
    mapfile -t linked_hosts < <(awk '/^  - hostname:/ {print $3}' "$CLOUDFLARED_CONFIG")
  fi

  echo -e "  ${BOLD}${RED}╔══════════════════════════════════════════════════╗${RESET}"
  echo -e "  ${BOLD}${RED}║   ⚠  DESINSTALAR CLOUDFLARED DE LA MÁQUINA  ⚠    ║${RESET}"
  echo -e "  ${BOLD}${RED}╚══════════════════════════════════════════════════╝${RESET}"
  echo
  msg_warn "Esta acción eliminará de este servidor:"
  echo -e "    ${RED}•${RESET} El binario/paquete cloudflared"
  echo -e "    ${RED}•${RESET} El servicio systemd (/etc/systemd/system/cloudflared.service)"
  echo -e "    ${RED}•${RESET} La configuración local (opcional: /etc/cloudflared y credenciales)"
  echo

  # Alerta si hay sitios en el config.yml
  if [[ "${#linked_hosts[@]}" -gt 0 ]]; then
    msg_error "Hay ${#linked_hosts[@]} sitio(s) publicado(s) por este tunnel en config.yml:"
    for h in "${linked_hosts[@]}"; do echo "      - $h"; done
    echo
    msg_warn "Al desinstalar cloudflared, estos sitios DEJARÁN de ser accesibles vía Cloudflare."
    echo
    prompt_yes_no "¿Continuar de todas formas?" "n"
    [[ "$REPLY_YESNO" != "s" ]] && { msg_ok "Cancelado. No se eliminó nada."; return 0; }
    echo
  else
    msg_ok "No hay sitios configurados en el config.yml."
    echo
  fi

  msg_info "Nota: el tunnel y su DNS siguen existiendo en tu cuenta Cloudflare."
  msg_info "Para borrarlos usa antes: Cloudflare → opción 7 (Eliminar tunnel completo)."
  echo

  prompt_yes_no "¿Confirmar la desinstalación de cloudflared?" "n"
  [[ "$REPLY_YESNO" != "s" ]] && { msg_ok "Cancelado."; return 0; }

  # Preguntar si borrar también config y credenciales locales
  prompt_yes_no "¿Eliminar también /etc/cloudflared y credenciales locales?" "n"
  local remove_config="$REPLY_YESNO"
  echo

  msg_info "[1/4] Deteniendo y deshabilitando el servicio..."
  systemctl stop cloudflared 2>/dev/null || true
  systemctl disable cloudflared 2>/dev/null || true

  msg_info "[2/4] Eliminando unit file systemd..."
  rm -f /etc/systemd/system/cloudflared.service 2>/dev/null || true
  # Unit alternativo que crea 'cloudflared service install'
  rm -f /etc/systemd/system/multi-user.target.wants/cloudflared.service 2>/dev/null || true
  systemctl daemon-reload 2>/dev/null || true

  msg_info "[3/4] Desinstalando el paquete cloudflared..."
  if dpkg -s cloudflared >/dev/null 2>&1; then
    apt-get purge -y cloudflared 2>/dev/null \
      || dpkg -r cloudflared 2>/dev/null || true
  else
    # Instalado por binario suelto, no por .deb
    rm -f /usr/bin/cloudflared /usr/local/bin/cloudflared 2>/dev/null || true
  fi

  msg_info "[4/4] Limpiando configuración local..."
  if [[ "$remove_config" == "s" ]]; then
    rm -rf "$CLOUDFLARED_DIR" 2>/dev/null || true
    rm -rf /root/.cloudflared 2>/dev/null || true
    msg_warn "Configuración y credenciales locales eliminadas."
  else
    msg_info "Se conservó ${CLOUDFLARED_DIR} y las credenciales locales."
  fi

  echo
  if command -v cloudflared >/dev/null 2>&1; then
    msg_warn "El binario cloudflared aún se detecta en el PATH. Revisa manualmente:"
    echo "      which cloudflared"
  else
    msg_ok "cloudflared desinstalado de la máquina."
  fi
  echo
  msg_info "MariaDB y el Stack Web NO fueron tocados."
}

# ══════════════════════════════════════════════════════════════════════════════
# SEGURIDAD — BLINDAJE DEL ENTORNO
# ══════════════════════════════════════════════════════════════════════════════

readonly NGINX_SEC_SNIPPET="/etc/nginx/snippets/security-headers.conf"

_detect_ssh_port() {
  local p
  p="$(awk '/^[[:space:]]*Port[[:space:]]/ {print $2; exit}' /etc/ssh/sshd_config 2>/dev/null)"
  echo "${p:-22}"
}

sec_install_ufw() {
  msg_section "Firewall UFW"

  if ! command -v ufw >/dev/null 2>&1; then
    msg_info "Instalando ufw..."
    apt-get install -y ufw
  else
    msg_ok "ufw ya está instalado."
  fi

  local ssh_port; ssh_port="$(_detect_ssh_port)"
  echo
  msg_info "Política propuesta:"
  echo "      deny  incoming (todo lo entrante bloqueado por defecto)"
  echo "      allow outgoing"
  echo "      allow ${ssh_port}/tcp   (SSH)"
  echo "      allow 80/tcp    (HTTP)"
  echo "      allow 443/tcp   (HTTPS)"
  echo
  msg_info "Nota: si publicas SOLO vía Cloudflare Tunnel, 80/443 pueden cerrarse"
  msg_info "(el tunnel es conexión saliente y no necesita puertos abiertos)."
  echo

  prompt_yes_no "¿Abrir 80/443? (responde 'n' si solo usas Cloudflare Tunnel)" "s"
  local open_web="$REPLY_YESNO"

  local mdb_rule="n" mdb_src=""
  if mariadb_installed; then
    prompt_yes_no "¿Permitir acceso remoto a MariaDB (puerto 3306) desde una red/IP?" "n"
    if [[ "$REPLY_YESNO" == "s" ]]; then
      read -rp "  Red o IP origen (ej: 192.168.11.0/24): " mdb_src
      [[ -n "$mdb_src" ]] && mdb_rule="s"
    fi
  fi

  echo
  msg_warn "IMPORTANTE: se permitirá el puerto SSH ${ssh_port} ANTES de activar el firewall"
  msg_warn "para no cortar tu sesión actual."
  prompt_yes_no "¿Aplicar y activar UFW ahora?" "s"
  [[ "$REPLY_YESNO" != "s" ]] && { msg_warn "Cancelado."; return 0; }

  ufw default deny incoming  >/dev/null
  ufw default allow outgoing >/dev/null
  ufw allow "${ssh_port}/tcp" comment 'SSH' >/dev/null
  if [[ "$open_web" == "s" ]]; then
    ufw allow 80/tcp  comment 'HTTP'  >/dev/null
    ufw allow 443/tcp comment 'HTTPS' >/dev/null
  fi
  [[ "$mdb_rule" == "s" ]] \
    && ufw allow from "$mdb_src" to any port 3306 proto tcp comment 'MariaDB LAN' >/dev/null

  ufw --force enable >/dev/null
  systemctl enable ufw >/dev/null 2>&1 || true

  echo
  msg_ok "UFW activo. Reglas actuales:"
  echo
  ufw status verbose | sed 's/^/    /'
}

sec_install_fail2ban() {
  msg_section "Fail2ban — bloqueo de ataques por fuerza bruta"

  if ! dpkg -s fail2ban >/dev/null 2>&1; then
    msg_info "Instalando fail2ban..."
    apt-get install -y fail2ban
  else
    msg_ok "fail2ban ya está instalado."
  fi

  local jail_local="/etc/fail2ban/jail.local"
  [[ -f "$jail_local" ]] && cp "$jail_local" "${jail_local}.bak.$(date +%F-%H%M%S)"

  local ssh_port; ssh_port="$(_detect_ssh_port)"

  cat > "$jail_local" <<EOF
# Generado por DevLab Manager — $(date +%F)
[DEFAULT]
bantime  = 1h
findtime = 10m
maxretry = 5
ignoreip = 127.0.0.1/8 ::1
backend  = systemd

[sshd]
enabled = true
port    = ${ssh_port}
maxretry = 4

[nginx-http-auth]
enabled  = true
port     = http,https
logpath  = /var/log/nginx/*error.log

[nginx-botsearch]
enabled  = true
port     = http,https
logpath  = /var/log/nginx/*access.log
maxretry = 10
EOF

  systemctl enable --now fail2ban >/dev/null 2>&1
  systemctl restart fail2ban

  sleep 1
  echo
  msg_ok "fail2ban activo con jails: sshd, nginx-http-auth, nginx-botsearch"
  echo
  msg_info "Política: 5 intentos fallidos en 10 min → baneo de 1 hora."
  echo
  fail2ban-client status 2>/dev/null | sed 's/^/    /' || true
  echo
  msg_info "Comandos útiles:"
  echo "      fail2ban-client status sshd            # ver IPs baneadas"
  echo "      fail2ban-client set sshd unbanip <IP>  # desbanear"
}

sec_harden_ssh() {
  msg_section "Endurecer SSH"

  local sshd=/etc/ssh/sshd_config
  [[ ! -f "$sshd" ]] && { msg_warn "OpenSSH server no está instalado."; return 0; }

  local ssh_port; ssh_port="$(_detect_ssh_port)"
  echo
  msg_info "Configuración propuesta:"
  echo "      PermitRootLogin prohibit-password  (root solo con clave SSH, nunca password)"
  echo "      MaxAuthTries 4"
  echo "      LoginGraceTime 30"
  echo "      X11Forwarding no"
  echo "      ClientAliveInterval 300 / ClientAliveCountMax 2"
  echo
  msg_warn "ANTES de aplicar, verifica que puedes entrar por SSH con clave pública."
  msg_warn "Si solo tienes acceso por contraseña de root, quedarás fuera del servidor"
  msg_warn "(salvo consola Proxmox/VPS)."
  echo

  prompt_yes_no "¿Tienes acceso por clave SSH o consola alternativa (Proxmox/panel VPS)?" "n"
  [[ "$REPLY_YESNO" != "s" ]] && { msg_warn "Cancelado. Configura una clave SSH primero."; return 0; }

  prompt_yes_no "¿Deshabilitar TAMBIÉN la autenticación por contraseña para TODOS los usuarios?" "n"
  local no_passwords="$REPLY_YESNO"

  cp "$sshd" "${sshd}.bak.$(date +%F-%H%M%S)"

  _sshd_set() {
    local key="$1" val="$2"
    if grep -qE "^[#[:space:]]*${key}[[:space:]]" "$sshd"; then
      sed -i "s|^[#[:space:]]*${key}[[:space:]].*|${key} ${val}|" "$sshd"
    else
      echo "${key} ${val}" >> "$sshd"
    fi
  }

  _sshd_set "PermitRootLogin"        "prohibit-password"
  _sshd_set "MaxAuthTries"           "4"
  _sshd_set "LoginGraceTime"         "30"
  _sshd_set "X11Forwarding"          "no"
  _sshd_set "ClientAliveInterval"    "300"
  _sshd_set "ClientAliveCountMax"    "2"
  _sshd_set "PermitEmptyPasswords"   "no"
  [[ "$no_passwords" == "s" ]] && _sshd_set "PasswordAuthentication" "no"

  if sshd -t 2>/dev/null; then
    systemctl restart ssh 2>/dev/null || systemctl restart sshd 2>/dev/null
    msg_ok "SSH endurecido y reiniciado (puerto ${ssh_port})."
    [[ "$no_passwords" == "s" ]] \
      && msg_warn "Autenticación por contraseña DESHABILITADA. Solo claves SSH."
  else
    msg_error "sshd_config inválido. Restaurando backup..."
    cp "${sshd}.bak."* "$sshd" 2>/dev/null || true
    return 1
  fi
  echo
  msg_warn "NO cierres esta sesión: abre OTRA terminal y verifica que puedes conectar."
}

sec_ssh_password_toggle() {
  msg_section "Acceso SSH por contraseña"

  local sshd=/etc/ssh/sshd_config
  [[ ! -f "$sshd" ]] && { msg_warn "OpenSSH server no está instalado."; return 0; }

  local current
  current="$(awk '/^[[:space:]]*PasswordAuthentication[[:space:]]/ {print $2; exit}' "$sshd")"
  current="${current:-yes (default)}"

  echo
  printf "  %-32s ${BOLD}%s${RESET}\n" "PasswordAuthentication actual:" "$current"
  echo
  echo "  1) Habilitar acceso por contraseña"
  echo "  2) Deshabilitar acceso por contraseña  (solo claves SSH)"
  echo "  0) Cancelar"
  echo

  local opt new_val=""
  read -rp "  Opción: " opt
  case "$opt" in
    1) new_val="yes" ;;
    2) new_val="no"  ;;
    0) return 0 ;;
    *) msg_error "Opción inválida."; return 1 ;;
  esac

  if [[ "$new_val" == "no" ]]; then
    msg_warn "Con contraseñas deshabilitadas SOLO podrás entrar con clave SSH."
    prompt_yes_no "¿Confirmas que tienes una clave SSH funcionando o consola alternativa?" "n"
    [[ "$REPLY_YESNO" != "s" ]] && { msg_warn "Cancelado. Configura una clave SSH primero."; return 0; }
  else
    msg_warn "Habilitar contraseñas reduce la seguridad. Úsalo solo si es necesario."
    prompt_yes_no "¿Continuar?" "s"
    [[ "$REPLY_YESNO" != "s" ]] && { msg_warn "Cancelado."; return 0; }
  fi

  cp "$sshd" "${sshd}.bak.$(date +%F-%H%M%S)"
  if grep -qE "^[#[:space:]]*PasswordAuthentication[[:space:]]" "$sshd"; then
    sed -i "s|^[#[:space:]]*PasswordAuthentication[[:space:]].*|PasswordAuthentication ${new_val}|" "$sshd"
  else
    echo "PasswordAuthentication ${new_val}" >> "$sshd"
  fi

  if sshd -t 2>/dev/null; then
    systemctl restart ssh 2>/dev/null || systemctl restart sshd 2>/dev/null
    msg_ok "PasswordAuthentication → ${new_val}. Servicio SSH reiniciado."
    [[ "$new_val" == "no" ]] \
      && msg_warn "Verifica el acceso con clave desde OTRA terminal antes de cerrar esta sesión."
  else
    msg_error "sshd_config inválido. Restaurando backup..."
    cp "$(ls -t "${sshd}.bak."* | head -1)" "$sshd" 2>/dev/null || true
    return 1
  fi
}

sec_change_ssh_port() {
  msg_section "Cambiar puerto SSH"

  local sshd=/etc/ssh/sshd_config
  [[ ! -f "$sshd" ]] && { msg_warn "OpenSSH server no está instalado."; return 0; }

  local old_port; old_port="$(_detect_ssh_port)"
  echo
  printf "  %-24s ${BOLD}%s${RESET}\n" "Puerto SSH actual:" "$old_port"
  echo
  msg_info "Un puerto no estándar reduce el ruido de bots (no sustituye a fail2ban/UFW)."
  msg_info "Sugerencia: usa un puerto entre 1024 y 65535 no ocupado (ej: 2222, 22022)."
  echo

  local new_port=""
  while true; do
    read -rp "  Nuevo puerto SSH (0 = cancelar): " new_port
    [[ "$new_port" == "0" ]] && return 0
    if ! valid_port "$new_port"; then
      msg_error "Puerto inválido (1-65535)."; continue
    fi
    if [[ "$new_port" == "$old_port" ]]; then
      msg_warn "Es el mismo puerto actual."; continue
    fi
    if ss -tln 2>/dev/null | awk '{print $4}' | grep -qE ":${new_port}$"; then
      msg_error "El puerto ${new_port} ya está en uso por otro servicio."; continue
    fi
    break
  done

  echo
  msg_warn "Pasos que se aplicarán:"
  echo "      1. Permitir ${new_port}/tcp en UFW (si está activo) ANTES del cambio"
  echo "      2. Cambiar Port en sshd_config y reiniciar SSH"
  echo "      3. Actualizar el puerto en fail2ban (si está instalado)"
  echo "      4. La regla UFW del puerto antiguo (${old_port}) se elimina SOLO cuando confirmes"
  echo "         que ya probaste la conexión nueva."
  echo
  prompt_yes_no "¿Aplicar el cambio de puerto ${old_port} → ${new_port}?" "n"
  [[ "$REPLY_YESNO" != "s" ]] && { msg_warn "Cancelado."; return 0; }

  # 1) Abrir el puerto nuevo en UFW antes de tocar SSH (anti-lockout)
  if command -v ufw >/dev/null 2>&1 && ufw status 2>/dev/null | grep -q "Status: active"; then
    ufw allow "${new_port}/tcp" comment 'SSH' >/dev/null
    msg_ok "UFW: ${new_port}/tcp permitido."
  fi

  # 2) sshd_config
  cp "$sshd" "${sshd}.bak.$(date +%F-%H%M%S)"
  if grep -qE "^[#[:space:]]*Port[[:space:]]" "$sshd"; then
    sed -i "0,/^[#[:space:]]*Port[[:space:]].*/s//Port ${new_port}/" "$sshd"
  else
    echo "Port ${new_port}" >> "$sshd"
  fi

  if ! sshd -t 2>/dev/null; then
    msg_error "sshd_config inválido. Restaurando backup..."
    cp "$(ls -t "${sshd}.bak."* | head -1)" "$sshd" 2>/dev/null || true
    return 1
  fi
  systemctl restart ssh 2>/dev/null || systemctl restart sshd 2>/dev/null
  msg_ok "SSH escuchando en el puerto ${new_port}."

  # 3) fail2ban
  if [[ -f /etc/fail2ban/jail.local ]]; then
    sed -i "s/^port    = .*/port    = ${new_port}/" /etc/fail2ban/jail.local
    systemctl restart fail2ban 2>/dev/null || true
    msg_ok "fail2ban actualizado al puerto ${new_port}."
  fi

  echo
  msg_warn "PRUEBA AHORA desde OTRA terminal (sin cerrar esta):"
  echo "      ssh -p ${new_port} root@$(detect_primary_ip 2>/dev/null || echo '<IP>')"
  echo

  # 4) Cierre del puerto antiguo solo tras confirmación
  if command -v ufw >/dev/null 2>&1 && ufw status 2>/dev/null | grep -q "Status: active"; then
    prompt_yes_no "¿La conexión por el puerto ${new_port} funciona? (eliminar regla del ${old_port})" "n"
    if [[ "$REPLY_YESNO" == "s" ]]; then
      ufw delete allow "${old_port}/tcp" >/dev/null 2>&1 || true
      msg_ok "UFW: regla del puerto ${old_port} eliminada."
    else
      msg_warn "Se mantuvo abierta la regla del puerto ${old_port} en UFW por seguridad."
      msg_info "Elimínala luego con: ufw delete allow ${old_port}/tcp"
    fi
  fi
}

sec_ssh_key_access() {
  msg_section "Acceso por clave SSH desde tu Mac"

  local auth_keys="/root/.ssh/authorized_keys"
  local ssh_port; ssh_port="$(_detect_ssh_port)"
  local server_ip; server_ip="$(detect_primary_ip 2>/dev/null || echo '<IP-DEL-VPS>')"

  mkdir -p /root/.ssh
  chmod 700 /root/.ssh
  touch "$auth_keys"
  chmod 600 "$auth_keys"

  local n_keys
  n_keys="$(grep -cE '^(ssh-|ecdsa-|sk-)' "$auth_keys" 2>/dev/null || echo 0)"

  echo
  printf "  %-28s %s\n" "Claves autorizadas (root):" "${n_keys}"
  printf "  %-28s %s\n" "Puerto SSH:"                 "${ssh_port}"
  printf "  %-28s %s\n" "IP del servidor:"            "${server_ip}"
  echo
  echo "  1) Autorizar la clave pública de tu Mac  (pegar aquí)"
  echo "  2) Ver guía completa de conexión desde el Mac"
  echo "  3) Listar claves autorizadas"
  echo "  4) Eliminar una clave autorizada"
  echo "  0) Cancelar"
  echo

  local opt
  read -rp "  Opción: " opt
  case "$opt" in

    1)
      echo
      msg_info "En tu Mac, obtén la clave pública con:"
      echo
      echo "      cat ~/.ssh/id_ed25519.pub"
      echo
      msg_info "Si no existe, créala primero (en el Mac):"
      echo
      echo "      ssh-keygen -t ed25519 -C \"macbook\""
      echo
      msg_info "Pega aquí la clave pública completa (una sola línea):"
      echo
      local pubkey=""
      read -rp "  > " pubkey
      [[ -z "$pubkey" ]] && { msg_error "No se ingresó ninguna clave."; return 1; }

      if ! [[ "$pubkey" =~ ^(ssh-(ed25519|rsa)|ecdsa-sha2-nistp(256|384|521)|sk-ssh-ed25519@openssh\.com)[[:space:]] ]]; then
        msg_error "Formato inválido. Debe comenzar con ssh-ed25519, ssh-rsa o ecdsa-sha2-*."
        return 1
      fi

      if grep -qF "$(awk '{print $2}' <<< "$pubkey")" "$auth_keys" 2>/dev/null; then
        msg_warn "Esa clave ya está autorizada."; return 0
      fi

      echo "$pubkey" >> "$auth_keys"
      chmod 600 "$auth_keys"
      msg_ok "Clave autorizada en ${auth_keys}"
      echo
      msg_info "Prueba desde tu Mac (sin cerrar esta sesión):"
      echo
      echo "      ssh -p ${ssh_port} root@${server_ip}"
      echo
      msg_info "Si conecta sin pedir contraseña, ya puedes deshabilitar el acceso"
      msg_info "por contraseña en: Seguridad → Habilitar/Deshabilitar acceso SSH por contraseña."
      ;;

    2)
      echo
      msg_section "Guía: conexión por clave SSH desde tu Mac"
      echo -e "  ${BOLD}Paso 1 — Generar la clave en el Mac (si no existe):${RESET}"
      echo
      echo "      ssh-keygen -t ed25519 -C \"macbook\""
      echo "      (Enter en todas las preguntas para usar los valores por defecto)"
      echo
      echo -e "  ${BOLD}Paso 2 — Copiar la clave al VPS (elige UNA opción):${RESET}"
      echo
      echo "      # Opción A — automática (pide la contraseña una última vez):"
      echo "      ssh-copy-id -i ~/.ssh/id_ed25519.pub -p ${ssh_port} root@${server_ip}"
      echo
      echo "      # Opción B — manual: copia la salida de"
      echo "      cat ~/.ssh/id_ed25519.pub"
      echo "      # y pégala en este menú → opción 1"
      echo
      echo -e "  ${BOLD}Paso 3 — Crear alias en el Mac (archivo ~/.ssh/config):${RESET}"
      echo
      echo "      Host vps"
      echo "          HostName ${server_ip}"
      echo "          User root"
      echo "          Port ${ssh_port}"
      echo "          IdentityFile ~/.ssh/id_ed25519"
      echo
      echo -e "  ${BOLD}Paso 4 — Conectar:${RESET}"
      echo
      echo "      ssh vps"
      echo
      msg_info "Con el alias, también funcionan directo: scp archivo vps:/ruta/  y  rsync."
      echo
      msg_warn "Verificado el acceso por clave, deshabilita las contraseñas:"
      msg_warn "Seguridad → Habilitar/Deshabilitar acceso SSH por contraseña → opción 2."
      ;;

    3)
      echo
      if [[ "$n_keys" -eq 0 ]]; then
        msg_warn "No hay claves autorizadas."
      else
        msg_info "Claves en ${auth_keys}:"
        echo
        local i=1
        while IFS= read -r line; do
          [[ "$line" =~ ^(ssh-|ecdsa-|sk-) ]] || continue
          local ktype kcomment kfp
          ktype="$(awk '{print $1}' <<< "$line")"
          kcomment="$(awk '{print $3}' <<< "$line")"
          kfp="$(ssh-keygen -lf /dev/stdin <<< "$line" 2>/dev/null | awk '{print $2}')"
          printf "  %d) %-14s %-24s %s\n" "$i" "$ktype" "${kcomment:-—}" "${kfp:-}"
          ((i++))
        done < "$auth_keys"
      fi
      ;;

    4)
      echo
      local keys=() labels=()
      while IFS= read -r line; do
        [[ "$line" =~ ^(ssh-|ecdsa-|sk-) ]] || continue
        keys+=("$line")
        labels+=("$(awk '{print $1" "$3}' <<< "$line")")
      done < "$auth_keys"

      if [[ "${#keys[@]}" -eq 0 ]]; then
        msg_warn "No hay claves autorizadas."; return 0
      fi

      echo "  Selecciona la clave a eliminar:"; echo
      local i=1
      for l in "${labels[@]}"; do
        printf "  %d) %s\n" "$i" "$l"; ((i++))
      done
      echo "  0) Cancelar"; echo

      local kopt
      read -rp "  Opción: " kopt
      [[ "$kopt" == "0" ]] && return 0
      if ! [[ "$kopt" =~ ^[0-9]+$ ]] || (( kopt < 1 || kopt > ${#keys[@]} )); then
        msg_error "Opción inválida."; return 1
      fi

      if [[ "${#keys[@]}" -eq 1 ]]; then
        msg_warn "Es la ÚNICA clave autorizada. Si el acceso por contraseña está"
        msg_warn "deshabilitado, quedarás fuera del servidor."
        prompt_yes_no "¿Eliminar de todas formas?" "n"
        [[ "$REPLY_YESNO" != "s" ]] && { msg_warn "Cancelado."; return 0; }
      fi

      local target="${keys[$((kopt-1))]}"
      grep -vF "$target" "$auth_keys" > "${auth_keys}.tmp" && mv "${auth_keys}.tmp" "$auth_keys"
      chmod 600 "$auth_keys"
      msg_ok "Clave eliminada: ${labels[$((kopt-1))]}"
      ;;

    0) return 0 ;;
    *) msg_error "Opción inválida." ;;
  esac
}

sec_nginx_headers() {
  ensure_web_stack_installed || return 1
  msg_section "Headers de seguridad Nginx"

  install -d -m 0755 /etc/nginx/snippets

  cat > "$NGINX_SEC_SNIPPET" <<'EOF'
# Generado por DevLab Manager — headers de seguridad
add_header X-Frame-Options        "SAMEORIGIN"                          always;
add_header X-Content-Type-Options "nosniff"                             always;
add_header Referrer-Policy        "strict-origin-when-cross-origin"     always;
add_header Permissions-Policy     "camera=(), microphone=(), geolocation=()" always;
add_header X-XSS-Protection       "1; mode=block"                       always;
EOF
  msg_ok "Snippet creado: ${NGINX_SEC_SNIPPET}"

  # Ocultar versión de Nginx globalmente
  if ! grep -q "server_tokens off" /etc/nginx/conf.d/security.conf 2>/dev/null; then
    echo "server_tokens off;" > /etc/nginx/conf.d/security.conf
    msg_ok "server_tokens off (versión de Nginx oculta en headers y errores)."
  fi

  # Incluir el snippet en cada sitio que no lo tenga
  local sites=() patched=0
  mapfile -t sites < <(
    find /etc/nginx/sites-available -maxdepth 1 -type f -printf '%f\n' \
      | grep -Ev '^default$|^000-catch-all$|\.maintenance$' | sort
  )
  for site in "${sites[@]}"; do
    local conf="/etc/nginx/sites-available/${site}"
    if ! grep -q "security-headers.conf" "$conf"; then
      sed -i "/server_name /a\\    include snippets/security-headers.conf;" "$conf"
      msg_ok "Headers agregados a: ${site}"
      ((patched++)) || true
    else
      msg_info "${site}: ya incluye los headers."
    fi
  done

  if nginx -t >/dev/null 2>&1; then
    systemctl reload nginx
    msg_ok "Nginx recargado. Sitios actualizados: ${patched}."
  else
    msg_error "nginx -t falló. Revisa la configuración."
    return 1
  fi
  echo
  msg_info "Verifica con: curl -I https://tudominio.cl"
}

sec_auto_updates() {
  msg_section "Actualizaciones de seguridad automáticas"

  if ! dpkg -s unattended-upgrades >/dev/null 2>&1; then
    msg_info "Instalando unattended-upgrades..."
    apt-get install -y unattended-upgrades apt-listchanges
  else
    msg_ok "unattended-upgrades ya está instalado."
  fi

  cat > /etc/apt/apt.conf.d/20auto-upgrades <<'EOF'
APT::Periodic::Update-Package-Lists "1";
APT::Periodic::Unattended-Upgrade "1";
APT::Periodic::AutocleanInterval "7";
EOF

  systemctl enable --now unattended-upgrades >/dev/null 2>&1 || true

  msg_ok "Actualizaciones de seguridad automáticas habilitadas (diarias)."
  echo
  msg_info "Solo se instalan parches de seguridad de Debian; el resto queda manual."
  msg_info "Log: /var/log/unattended-upgrades/"
}

sec_audit() {
  msg_section "Auditoría de seguridad del entorno"
  local warn_count=0

  _chk() {  # _chk "descripcion" ok|warn "detalle"
    local desc="$1" state="$2" detail="$3"
    if [[ "$state" == "ok" ]]; then
      printf "  ${GREEN}✔${RESET} %-46s %s\n" "$desc" "$detail"
    else
      printf "  ${RED}✖${RESET} %-46s ${YELLOW}%s${RESET}\n" "$desc" "$detail"
      ((warn_count++)) || true
    fi
  }

  echo -e "  ${BOLD}── Firewall y red ──${RESET}"
  if command -v ufw >/dev/null 2>&1 && ufw status 2>/dev/null | grep -q "Status: active"; then
    _chk "UFW firewall" ok "activo"
  else
    _chk "UFW firewall" warn "inactivo o no instalado (Seguridad → 6)"
  fi
  if dpkg -s fail2ban >/dev/null 2>&1 && systemctl is-active --quiet fail2ban; then
    _chk "fail2ban" ok "activo"
  else
    _chk "fail2ban" warn "inactivo o no instalado (Seguridad → 7)"
  fi

  echo; echo -e "  ${BOLD}── SSH ──${RESET}"
  local prl pauth
  prl="$(awk '/^PermitRootLogin/ {print $2; exit}' /etc/ssh/sshd_config 2>/dev/null)"
  pauth="$(awk '/^PasswordAuthentication/ {print $2; exit}' /etc/ssh/sshd_config 2>/dev/null)"
  case "$prl" in
    no|prohibit-password) _chk "PermitRootLogin" ok "$prl" ;;
    yes)                  _chk "PermitRootLogin" warn "yes — root con contraseña (Seguridad → 2)" ;;
    *)                    _chk "PermitRootLogin" warn "${prl:-default} — revisar" ;;
  esac
  [[ "$pauth" == "no" ]] \
    && _chk "PasswordAuthentication" ok "no (solo claves)" \
    || _chk "PasswordAuthentication" warn "${pauth:-yes} — contraseñas permitidas"

  echo; echo -e "  ${BOLD}── Nginx ──${RESET}"
  [[ -f "$NGINX_SEC_SNIPPET" ]] \
    && _chk "Headers de seguridad" ok "snippet instalado" \
    || _chk "Headers de seguridad" warn "sin configurar (Seguridad → 8)"
  grep -rq "server_tokens off" /etc/nginx/ 2>/dev/null \
    && _chk "server_tokens" ok "off (versión oculta)" \
    || _chk "server_tokens" warn "versión de Nginx expuesta"

  echo; echo -e "  ${BOLD}── Sitios (archivos sensibles) ──${RESET}"
  local found_debug=0
  while IFS= read -r f; do
    _chk "Archivo de diagnóstico" warn "$f"
    found_debug=1
  done < <(find /var/www -maxdepth 3 \( -name "info.php" -o -name "test-db.php" \) 2>/dev/null)
  [[ $found_debug -eq 0 ]] && _chk "info.php / test-db.php" ok "ninguno expuesto"

  local bad_env=0
  while IFS= read -r f; do
    local perms; perms="$(stat -c '%a' "$f" 2>/dev/null)"
    if [[ "$perms" != "640" && "$perms" != "600" ]]; then
      _chk "Permisos .env" warn "${f} (${perms})"
      bad_env=1
    fi
  done < <(find /var/www -maxdepth 2 -name ".env" 2>/dev/null)
  [[ $bad_env -eq 0 ]] && _chk "Permisos .env" ok "correctos (640/600)"

  echo; echo -e "  ${BOLD}── MariaDB ──${RESET}"
  if mariadb_installed; then
    local bind
    bind="$(awk -F'=' '/^bind-address/ {gsub(/ /,"",$2); print $2; exit}' "$MARIADB_CNF" 2>/dev/null)"
    case "$bind" in
      127.0.0.1) _chk "bind-address" ok "127.0.0.1 (solo local)" ;;
      0.0.0.0)   _chk "bind-address" warn "0.0.0.0 — expuesto a todas las interfaces" ;;
      *)         _chk "bind-address" ok "${bind:-no definido}" ;;
    esac
    local anon
    anon="$(mariadb -sNe "SELECT COUNT(*) FROM mysql.user WHERE User='';" 2>/dev/null || echo '?')"
    [[ "$anon" == "0" ]] \
      && _chk "Usuarios anónimos" ok "ninguno" \
      || _chk "Usuarios anónimos" warn "${anon} — ejecuta mysql_secure_installation"
    local wide
    wide="$(mariadb -sNe "SELECT COUNT(*) FROM mysql.user WHERE Host='%' AND User NOT IN ('root','mariadb.sys','mysql');" 2>/dev/null || echo '?')"
    [[ "$wide" == "0" ]] \
      && _chk "Usuarios con host %" ok "ninguno" \
      || _chk "Usuarios con host %" warn "${wide} usuario(s) aceptan conexión desde cualquier IP"
  else
    _chk "MariaDB" ok "no instalado en este LXC"
  fi

  echo; echo -e "  ${BOLD}── Sistema ──${RESET}"
  dpkg -s unattended-upgrades >/dev/null 2>&1 \
    && _chk "Actualizaciones automáticas" ok "habilitadas" \
    || _chk "Actualizaciones automáticas" warn "sin configurar (Seguridad → 9)"
  local pending
  pending="$(apt list --upgradable 2>/dev/null | grep -c "security" || true)"
  [[ "${pending:-0}" -eq 0 ]] \
    && _chk "Parches de seguridad pendientes" ok "0" \
    || _chk "Parches de seguridad pendientes" warn "${pending} pendiente(s) — Sistema → 4"

  echo
  if [[ $warn_count -eq 0 ]]; then
    echo -e "  ${BOLD}${GREEN}╔══════════════════════════════════════════╗${RESET}"
    echo -e "  ${BOLD}${GREEN}║   Entorno blindado: 0 advertencias  ✔    ║${RESET}"
    echo -e "  ${BOLD}${GREEN}╚══════════════════════════════════════════╝${RESET}"
  else
    msg_warn "Auditoría completada: ${warn_count} punto(s) por corregir (indicados arriba)."
  fi
}

sec_harden_all() {
  msg_section "Blindaje completo del entorno"
  echo "  Se aplicarán en secuencia (cada paso pide su propia confirmación):"
  echo
  echo "    1. Firewall UFW"
  echo "    2. fail2ban"
  echo "    3. Endurecer SSH"
  echo "    4. Headers de seguridad Nginx"
  echo "    5. Actualizaciones de seguridad automáticas"
  echo "    6. Auditoría final"
  echo
  prompt_yes_no "¿Comenzar el blindaje completo?" "s"
  [[ "$REPLY_YESNO" != "s" ]] && { msg_warn "Cancelado."; return 0; }

  echo; sec_install_ufw       || true
  echo; sec_install_fail2ban  || true
  echo; sec_harden_ssh        || true
  echo; sec_nginx_headers     || true
  echo; sec_auto_updates      || true
  echo; sec_audit             || true
}

header_seguridad() {
  echo -e "${BOLD}${RED}╔══════════════════════════════════════════════╗${RESET}"
  echo -e "${BOLD}${RED}║${WHITE}  [ 6 ] Seguridad — Blindaje del entorno    ${RED}║${RESET}"
  echo -e "${BOLD}${RED}╚══════════════════════════════════════════════╝${RESET}"
}

menu_seguridad() {
  local opt
  while true; do
    clear
    header_seguridad; echo
    menu_cat "Acción rápida" "$RED"
    echo -e "  ${RED}1)${RESET} ${BOLD}Blindaje completo${RESET}  (firewall + fail2ban + SSH + Nginx + updates + auditoría)"
    menu_cat "Acceso SSH (prioridad alta)" "$RED"
    echo -e "  ${RED}2)${RESET} Endurecer SSH  (root sin password, límites de intentos)"
    echo -e "  ${RED}3)${RESET} Acceso por clave SSH desde tu Mac  (autorizar clave + guía)"
    echo -e "  ${RED}4)${RESET} Habilitar / Deshabilitar acceso SSH por contraseña"
    echo -e "  ${RED}5)${RESET} Cambiar puerto SSH"
    menu_cat "Red y fuerza bruta" "$RED"
    echo -e "  ${RED}6)${RESET} Firewall UFW  (deny incoming + SSH/HTTP/HTTPS)"
    echo -e "  ${RED}7)${RESET} fail2ban  (anti fuerza bruta: SSH + Nginx)"
    menu_cat "Web y sistema" "$RED"
    echo -e "  ${RED}8)${RESET} Headers de seguridad Nginx  (+ ocultar versión)"
    echo -e "  ${RED}9)${RESET} Actualizaciones de seguridad automáticas"
    menu_cat "Verificación" "$RED"
    echo -e "  ${RED}10)${RESET} Auditoría de seguridad  (chequeo completo del entorno)"
    echo
    echo -e "  ${RED}0)${RESET} ← Volver al menú principal"
    echo
    read -rp "  Opción: " opt
    case "$opt" in
      1)  run_item header_seguridad sec_harden_all ;;
      2)  run_item header_seguridad sec_harden_ssh ;;
      3)  run_item header_seguridad sec_ssh_key_access ;;
      4)  run_item header_seguridad sec_ssh_password_toggle ;;
      5)  run_item header_seguridad sec_change_ssh_port ;;
      6)  run_item header_seguridad sec_install_ufw ;;
      7)  run_item header_seguridad sec_install_fail2ban ;;
      8)  run_item header_seguridad sec_nginx_headers ;;
      9)  run_item header_seguridad sec_auto_updates ;;
      10) run_item header_seguridad sec_audit ;;
      0)  return ;;
      *)  msg_error "Opción inválida."; pause ;;
    esac
  done
}

# ══════════════════════════════════════════════════════════════════════════════
# MONITOR — DASHBOARD EN VIVO (estilo htop)
# ══════════════════════════════════════════════════════════════════════════════

_hbytes() {
  local b=${1:-0}
  if   (( b >= 1073741824 )); then printf "%d.%d GB" $(( b / 1073741824 )) $(( (b % 1073741824) * 10 / 1073741824 ))
  elif (( b >= 1048576 ));    then printf "%d.%d MB" $(( b / 1048576 ))    $(( (b % 1048576) * 10 / 1048576 ))
  elif (( b >= 1024 ));       then printf "%d KB" $(( b / 1024 ))
  else                             printf "%d B" "$b"
  fi
}

_bar() {
  local pct=${1:-0} width=${2:-22}
  (( pct < 0 )) && pct=0
  (( pct > 100 )) && pct=100
  local filled=$(( pct * width / 100 )) color="$GREEN" i out=""
  (( pct >= 60 )) && color="$YELLOW"
  (( pct >= 85 )) && color="$RED"
  for (( i=0; i<filled; i++ )); do out+="█"; done
  for (( i=filled; i<width; i++ )); do out+="░"; done
  printf '%b%s%b' "$color" "$out" "$RESET"
}

_dot() {
  systemctl is-active --quiet "$1" 2>/dev/null \
    && printf '%b●%b' "$GREEN" "$RESET" \
    || printf '%b●%b' "$RED" "$RESET"
}

_MON_PIDLE=0; _MON_PTOTAL=0
_mon_cpu() {  # → MON_CPU (porcentaje)
  local -a f
  read -r -a f < /proc/stat
  local idle=$(( f[4] + f[5] )) total=0 v
  for v in "${f[@]:1:8}"; do total=$(( total + v )); done
  local di=$(( idle - _MON_PIDLE )) dt=$(( total - _MON_PTOTAL ))
  _MON_PIDLE=$idle; _MON_PTOTAL=$total
  if (( dt > 0 )); then MON_CPU=$(( (dt - di) * 100 / dt )); else MON_CPU=0; fi
}

_MON_PRX=0; _MON_PTX=0; _MON_PT=0
_mon_net() {  # → MON_RXS MON_TXS (B/s) MON_RXT MON_TXT (totales) MON_IFACE
  local iface rx tx now
  iface="$(ip route get 1.1.1.1 2>/dev/null | grep -oP 'dev \K\S+' | head -1)"
  MON_IFACE="${iface:-?}"
  read -r rx tx < <(awk -v i="$iface" '$0 ~ i":" {sub(/^[^:]*:/,""); print $1, $9; exit}' /proc/net/dev)
  rx=${rx:-0}; tx=${tx:-0}
  now=$(date +%s)
  local dt=$(( now - _MON_PT ))
  (( dt <= 0 )) && dt=1
  if (( _MON_PRX > 0 )); then
    MON_RXS=$(( (rx - _MON_PRX) / dt ))
    MON_TXS=$(( (tx - _MON_PTX) / dt ))
  else
    MON_RXS=0; MON_TXS=0
  fi
  (( MON_RXS < 0 )) && MON_RXS=0
  (( MON_TXS < 0 )) && MON_TXS=0
  _MON_PRX=$rx; _MON_PTX=$tx; _MON_PT=$now
  MON_RXT=$rx; MON_TXT=$tx
}

_mon_site_row() {  # site → "req 2xx 4xx 5xx ultimo"
  local site="$1"
  local log="/var/log/nginx/${site}.access.log"
  [[ -s "$log" ]] || { echo "0 0 0 0 —"; return; }
  local sample
  sample="$(tail -n 4000 "$log" 2>/dev/null | grep -E "\[(${MON_PAT})" || true)"
  local last
  if [[ -z "$sample" ]]; then
    last="$(tail -n 1 "$log" | grep -oE ':[0-9]{2}:[0-9]{2}:[0-9]{2}' | head -1 | cut -c2- || true)"
    echo "0 0 0 0 ${last:-—}"
    return
  fi
  local counts
  counts="$(awk '{ n++; c=substr($9,1,1); if(c=="2")a++; else if(c=="4")b++; else if(c=="5")e++ }
            END{ printf "%d %d %d %d", n+0, a+0, b+0, e+0 }' <<< "$sample")"
  last="$(tail -n 1 <<< "$sample" | grep -oE ':[0-9]{2}:[0-9]{2}:[0-9]{2}' | head -1 | cut -c2- || true)"
  echo "${counts} ${last:-—}"
}

_mon_render() {
  local now host up load
  now="$(date '+%H:%M:%S')"
  host="$(hostname)"
  up="$(uptime -p 2>/dev/null | sed 's/^up //')"
  load="$(cut -d' ' -f1-3 /proc/loadavg)"

  local mt mu mp st su sp=0
  read -r mt mu < <(free -b | awk '/^Mem/  {print $2, $3}')
  read -r st su < <(free -b | awk '/^Swap/ {print $2, $3}')
  mp=$(( mu * 100 / mt ))
  (( st > 0 )) && sp=$(( su * 100 / st ))

  local dp dus dts
  read -r dp dus dts < <(df -h / | awk 'NR==2 {gsub("%","",$5); print $5, $3, $2}')

  echo -e "${BOLD}${BLUE}╔═ DevLab Monitor ══ ${WHITE}${host}${BLUE} ══ ${WHITE}${now}${BLUE} ══ refresco ${MON_INTERVAL}s ═╗${RESET}"
  echo
  printf "  ${BOLD}CPU${RESET}    %s %3d%%    ${DIM}Load${RESET} %s    ${DIM}Uptime${RESET} %s\n" \
    "$(_bar "$MON_CPU")" "$MON_CPU" "$load" "$up"
  printf "  ${BOLD}RAM${RESET}    %s %3d%%    %s / %s    ${DIM}Swap${RESET} %d%%\n" \
    "$(_bar "$mp")" "$mp" "$(_hbytes "$mu")" "$(_hbytes "$mt")" "$sp"
  printf "  ${BOLD}Disco${RESET}  %s %3d%%    %s / %s\n" \
    "$(_bar "$dp")" "$dp" "$dus" "$dts"
  printf "  ${BOLD}Red${RESET}    ↓ %s/s   ↑ %s/s   ${DIM}(%s)${RESET}   Σ↓ %s   Σ↑ %s\n" \
    "$(_hbytes "$MON_RXS")" "$(_hbytes "$MON_TXS")" "$MON_IFACE" \
    "$(_hbytes "$MON_RXT")" "$(_hbytes "$MON_TXT")"
  echo

  local php_dot="${YELLOW}●${RESET}" ufw_dot="${RED}●${RESET}"
  [[ -n "$PHP_VERSION" ]] && php_dot="$(_dot "php${PHP_VERSION}-fpm")"
  ufw status 2>/dev/null | grep -q "Status: active" && ufw_dot="${GREEN}●${RESET}"
  local nconn nphp ndb="—"
  nconn="$(ss -Htn state established 2>/dev/null | wc -l | tr -d ' ')"
  nphp="$(pgrep -c php-fpm 2>/dev/null || echo 0)"
  if mariadb_installed && mariadb_running; then
    ndb="$(mariadb -sNe 'SELECT COUNT(*) FROM information_schema.processlist' 2>/dev/null || echo '?')"
  fi
  echo -e "  ${BOLD}Servicios${RESET}   Nginx $(_dot nginx)   PHP-FPM ${php_dot}   MariaDB $(_dot mariadb)   Cloudflared $(_dot cloudflared)   fail2ban $(_dot fail2ban)   UFW ${ufw_dot}"
  echo -e "  ${DIM}Conexiones TCP: ${nconn}    Procesos PHP: ${nphp}    Conexiones DB: ${ndb}${RESET}"
  echo

  echo -e "  ${BOLD}Sitios — actividad últimos 5 min${RESET}"
  printf "  ${DIM}%-24s %-2s %6s %6s %6s %6s   %-9s %9s${RESET}\n" \
    "SITIO" "ON" "REQ" "2xx" "4xx" "5xx" "ÚLTIMO" "DISCO"
  if [[ ${#MON_SITES[@]} -eq 0 ]]; then
    echo -e "  ${DIM}No hay sitios configurados.${RESET}"
  else
    local s on req s2 s4 s5 lastt rcolor
    for s in "${MON_SITES[@]}"; do
      [[ -L "/etc/nginx/sites-enabled/${s}" ]] \
        && on="${GREEN}●${RESET}" || on="${RED}●${RESET}"
      read -r req s2 s4 s5 lastt <<< "$(_mon_site_row "$s")"
      rcolor="$RESET"
      (( s5 > 0 )) && rcolor="$RED"
      (( s5 == 0 && s4 > 0 )) && rcolor="$YELLOW"
      printf "  %-24s %b %b%6s%b %6s %6s %6s   %-9s %9s\n" \
        "$s" "$on" "$rcolor" "$req" "$RESET" "$s2" "$s4" "$s5" "$lastt" "${MON_DU[$s]:-—}"
    done
  fi
  echo
  echo -e "  ${DIM}[q] salir   [r] refrescar ahora   [+/-] intervalo${RESET}"
}

run_dashboard() {
  local interval=3 cycles=0 key frame s i p pat
  mapfile -t MON_SITES < <(
    find /etc/nginx/sites-available -maxdepth 1 -type f -printf '%f\n' 2>/dev/null \
      | grep -Ev '^default$|^000-catch-all$|\.maintenance$' | sort
  )
  declare -gA MON_DU=()
  for s in "${MON_SITES[@]}"; do
    [[ -d "/var/www/${s}" ]] && MON_DU[$s]="$(du -sh "/var/www/${s}" 2>/dev/null | cut -f1)"
  done
  _MON_PIDLE=0; _MON_PTOTAL=0; _MON_PRX=0; _MON_PTX=0; _MON_PT=0
  _mon_cpu; _mon_net
  tput civis 2>/dev/null || true

  while true; do
    pat=""
    for i in 0 1 2 3 4; do
      p="$(date -d "-${i} min" '+%d/%b/%Y:%H:%M' 2>/dev/null || true)"
      [[ -n "$p" ]] && pat+="${pat:+|}${p}"
    done
    MON_PAT="$pat"
    MON_INTERVAL="$interval"
    _mon_cpu
    _mon_net
    frame="$(_mon_render)"
    printf '\033[H\033[2J%s\n' "$frame"

    key=""
    read -rsn1 -t "$interval" key || true
    case "$key" in
      q|Q) break ;;
      +|=) (( interval < 10 )) && (( interval++ )) || true ;;
      -|_) (( interval > 1 ))  && (( interval-- )) || true ;;
    esac
    (( cycles++ )) || true
    if (( cycles % 20 == 0 )); then
      for s in "${MON_SITES[@]}"; do
        [[ -d "/var/www/${s}" ]] && MON_DU[$s]="$(du -sh "/var/www/${s}" 2>/dev/null | cut -f1)"
      done
    fi
  done

  tput cnorm 2>/dev/null || true
  clear
}

# ══════════════════════════════════════════════════════════════════════════════
# DEV TOOLS — UTILIDADES PARA DESARROLLO WEB
# ══════════════════════════════════════════════════════════════════════════════

dev_live_logs() {
  ensure_web_stack_installed || return 1
  choose_site || return 0
  local site="$CHOSEN_SITE"
  local alog="/var/log/nginx/${site}.access.log"
  local elog="/var/log/nginx/${site}.error.log"
  msg_section "Logs en vivo — ${site}"
  msg_info "access + error en tiempo real. Ctrl+C para volver al menú."
  echo
  trap ':' INT
  tail -n 15 -F "$alog" "$elog" 2>/dev/null || true
  trap on_interrupt INT
  echo
}

dev_traffic() {
  ensure_web_stack_installed || return 1
  choose_site || return 0
  local site="$CHOSEN_SITE"
  local log="/var/log/nginx/${site}.access.log"
  [[ -s "$log" ]] || { msg_warn "Sin datos en ${log}"; return 0; }

  local sample n_sample
  sample="$(tail -n 5000 "$log")"
  n_sample="$(wc -l <<< "$sample" | tr -d ' ')"
  msg_section "Análisis de tráfico — ${site} (muestra: últimas ${n_sample} solicitudes)"

  local today; today="$(date '+%d/%b/%Y')"
  echo "  Solicitudes hoy: $(grep -c "\[${today}" "$log" 2>/dev/null || echo 0)"
  echo
  echo -e "  ${BOLD}── Códigos de respuesta ──${RESET}"
  awk '{print $9}' <<< "$sample" | sort | uniq -c | sort -rn | head -8 \
    | awk '{printf "  %6d  %s\n", $1, $2}'
  echo
  echo -e "  ${BOLD}── Top 10 IPs ──${RESET}"
  awk '{print $1}' <<< "$sample" | sort | uniq -c | sort -rn | head -10 \
    | awk '{printf "  %6d  %s\n", $1, $2}'
  echo
  echo -e "  ${BOLD}── Top 10 URLs ──${RESET}"
  awk '{print $7}' <<< "$sample" | sort | uniq -c | sort -rn | head -10 \
    | awk '{printf "  %6d  %.70s\n", $1, $2}'
  echo
  echo -e "  ${BOLD}── Top 5 User-Agents ──${RESET}"
  awk -F'"' '{print $6}' <<< "$sample" | sort | uniq -c | sort -rn | head -5 \
    | awk '{c=$1; $1=""; printf "  %6d %.80s\n", c, $0}'
}

dev_php_errors() {
  ensure_web_stack_installed || return 1
  msg_section "Errores PHP recientes"
  local flog="/var/log/php${PHP_VERSION}-fpm.log"
  if [[ -f "$flog" ]]; then
    echo -e "  ${BOLD}── ${flog} (últimas 20 líneas) ──${RESET}"
    tail -n 20 "$flog" | sed 's/^/  /'
  else
    msg_warn "No existe ${flog}"
  fi
  echo
  echo -e "  ${BOLD}── Errores PHP en logs de Nginx (últimos 25) ──${RESET}"
  grep -h "PHP" /var/log/nginx/*error.log 2>/dev/null | tail -n 25 | sed 's/^/  /' \
    || echo "  (sin errores PHP registrados)"
}

dev_benchmark() {
  ensure_web_stack_installed || return 1
  choose_site || return 0
  local site="$CHOSEN_SITE"
  local sn
  sn="$(awk '/server_name / && !/default_server/ {print $2; exit}' \
        "/etc/nginx/sites-available/${site}" | tr -d ';')"
  local path
  read -rp "  Ruta a probar [/]: " path
  path="${path:-/}"
  [[ "$path" != /* ]] && path="/${path}"

  msg_section "Benchmark — ${sn}${path} (5 solicitudes locales)"
  printf "  ${DIM}%-4s %12s %12s %12s %12s %8s${RESET}\n" \
    "N" "DNS" "Conexión" "TTFB" "Total" "Código"
  local i out results=""
  for i in 1 2 3 4 5; do
    out="$(curl -o /dev/null -sS \
      -w '%{time_namelookup} %{time_connect} %{time_starttransfer} %{time_total} %{http_code}' \
      -H "Host: ${sn}" "http://127.0.0.1${path}" 2>/dev/null || echo "0 0 0 0 ERR")"
    results+="${out}"$'\n'
    read -r t1 t2 t3 t4 code <<< "$out"
    printf "  %-4s %11ss %11ss %11ss %11ss %8s\n" "$i" "$t1" "$t2" "$t3" "$t4" "$code"
  done
  echo
  awk 'NF==5 && $5 != "ERR" { d+=$1; c+=$2; f+=$3; t+=$4; n++ }
       END { if (n>0) printf "  Promedio:  DNS %.4fs   Conexión %.4fs   TTFB %.4fs   Total %.4fs  (%d muestras)\n", d/n, c/n, f/n, t/n, n }' \
    <<< "$results"
  echo
  msg_info "TTFB alto → revisa consultas SQL o OPcache. Total ≫ TTFB → payload grande."
}

dev_maintenance() {
  ensure_web_stack_installed || return 1
  choose_site || return 0
  local site="$CHOSEN_SITE"
  local enabled_link="/etc/nginx/sites-enabled/${site}"
  local maint_conf="/etc/nginx/sites-available/${site}.maintenance"
  local sn
  sn="$(awk '/server_name / && !/default_server/ {print $2; exit}' \
        "/etc/nginx/sites-available/${site}" | tr -d ';')"

  msg_section "Modo mantenimiento — ${site}"

  if [[ "$(readlink -f "$enabled_link" 2>/dev/null)" == "$maint_conf" ]]; then
    msg_warn "El sitio está EN MANTENIMIENTO."
    prompt_yes_no "¿Desactivar el modo mantenimiento?" "s"
    [[ "$REPLY_YESNO" != "s" ]] && return 0
    ln -sf "/etc/nginx/sites-available/${site}" "$enabled_link"
    nginx -t >/dev/null 2>&1 && systemctl reload nginx
    msg_ok "Mantenimiento DESACTIVADO — ${sn} vuelve a estar en línea."
    return 0
  fi

  msg_info "El sitio está en línea."
  prompt_yes_no "¿Activar modo mantenimiento (responde 503 con página amigable)?" "n"
  [[ "$REPLY_YESNO" != "s" ]] && return 0

  mkdir -p /var/www/devlab-maintenance
  if [[ ! -f /var/www/devlab-maintenance/index.html ]]; then
    cat > /var/www/devlab-maintenance/index.html <<'HTML'
<!DOCTYPE html>
<html lang="es">
<head>
<meta charset="UTF-8">
<meta name="viewport" content="width=device-width, initial-scale=1.0">
<title>Mantenimiento</title>
<style>
  body { margin:0; min-height:100vh; display:flex; align-items:center; justify-content:center;
         font-family:-apple-system,Segoe UI,Roboto,sans-serif;
         background:linear-gradient(135deg,#1a1a2e,#16213e); color:#eaeaea; text-align:center; }
  .card { padding:3rem 2.5rem; max-width:480px; }
  .icon { font-size:4rem; margin-bottom:1rem; }
  h1 { font-size:1.6rem; margin:0 0 .8rem; }
  p  { color:#9aa5b1; line-height:1.6; margin:0; }
</style>
</head>
<body>
  <div class="card">
    <div class="icon">🛠️</div>
    <h1>Sitio en mantenimiento</h1>
    <p>Estamos realizando mejoras. Volveremos a estar en línea en breve.<br>Gracias por tu paciencia.</p>
  </div>
</body>
</html>
HTML
  fi

  cat > "$maint_conf" <<EOF
server {
    listen 80;
    server_name ${sn};
    root /var/www/devlab-maintenance;
    location / { return 503; }
    error_page 503 @maintenance;
    location @maintenance { rewrite ^ /index.html break; }
}
EOF

  ln -sf "$maint_conf" "$enabled_link"
  if nginx -t >/dev/null 2>&1; then
    systemctl reload nginx
    msg_ok "Mantenimiento ACTIVADO — ${sn} responde 503 con página amigable."
    msg_info "Vuelve a esta opción para desactivarlo."
  else
    ln -sf "/etc/nginx/sites-available/${site}" "$enabled_link"
    systemctl reload nginx 2>/dev/null || true
    msg_error "nginx -t falló. Se restauró el sitio original."
    return 1
  fi
}

dev_basic_auth() {
  ensure_web_stack_installed || return 1
  choose_site || return 0
  local site="$CHOSEN_SITE"
  local conf="/etc/nginx/sites-available/${site}"
  local htfile="/etc/nginx/.htpasswd_${site}"

  msg_section "Protección con contraseña (Basic Auth) — ${site}"

  if grep -q "auth_basic" "$conf"; then
    msg_warn "El sitio YA está protegido con contraseña."
    prompt_yes_no "¿Quitar la protección?" "n"
    [[ "$REPLY_YESNO" != "s" ]] && return 0
    sed -i '/auth_basic/d' "$conf"
    nginx -t >/dev/null 2>&1 && systemctl reload nginx
    msg_ok "Protección eliminada. (${htfile} se conservó por si la reactivas)"
    return 0
  fi

  msg_info "Útil para sitios en desarrollo/staging que no deben ser públicos."
  prompt_yes_no "¿Proteger '${site}' con usuario y contraseña?" "s"
  [[ "$REPLY_YESNO" != "s" ]] && return 0

  command -v htpasswd >/dev/null 2>&1 || apt-get install -y apache2-utils

  local user
  read -rp "  Usuario: " user
  [[ -z "$user" ]] && { msg_error "Usuario obligatorio."; return 1; }
  htpasswd -c "$htfile" "$user"
  chown root:www-data "$htfile"
  chmod 640 "$htfile"

  sed -i "/server_name /a\\    auth_basic \"Acceso restringido\";\\n    auth_basic_user_file ${htfile};" "$conf"

  if nginx -t >/dev/null 2>&1; then
    systemctl reload nginx
    msg_ok "Sitio protegido. El navegador pedirá usuario/contraseña."
  else
    sed -i '/auth_basic/d' "$conf"
    systemctl reload nginx 2>/dev/null || true
    msg_error "nginx -t falló. Cambios revertidos."
    return 1
  fi
}

dev_opcache_clear() {
  ensure_web_stack_installed || return 1
  msg_section "Limpiar OPcache"
  msg_info "Recarga PHP-FPM ${PHP_VERSION} (graceful): vacía OPcache sin cortar peticiones."
  systemctl reload "php${PHP_VERSION}-fpm" \
    && msg_ok "OPcache limpio. Los cambios en código PHP se aplican de inmediato." \
    || msg_error "No se pudo recargar php${PHP_VERSION}-fpm."
}

dev_php_limits() {
  ensure_web_stack_installed || return 1
  msg_section "Límites y extensiones PHP ${PHP_VERSION} (FPM)"
  local ini="/etc/php/${PHP_VERSION}/fpm/php.ini"
  [[ -f "$ini" ]] || { msg_warn "No existe ${ini}"; return 0; }
  local k
  for k in memory_limit upload_max_filesize post_max_size max_execution_time \
           max_input_vars display_errors error_reporting session.gc_maxlifetime; do
    printf "  %-28s %s\n" "${k}:" \
      "$(awk -F'=' -v key="$k" '$0 ~ "^"key"[[:space:]]*=" {gsub(/^[ \t]+/,"",$2); print $2; exit}' "$ini")"
  done
  echo
  echo -e "  ${BOLD}Extensiones cargadas:${RESET}"
  "php${PHP_VERSION}" -m 2>/dev/null | grep -v '^\[' | grep -v '^$' \
    | tr '\n' ' ' | fold -s -w 90 | sed 's/^/  /'
  echo
}

header_devtools() {
  echo -e "${BOLD}${CYAN}╔══════════════════════════════════════════════╗${RESET}"
  echo -e "${BOLD}${CYAN}║${WHITE}  [ 8 ] Dev Tools — Desarrollo Web          ${CYAN}║${RESET}"
  echo -e "${BOLD}${CYAN}╚══════════════════════════════════════════════╝${RESET}"
}

menu_devtools() {
  local opt
  while true; do
    clear
    header_devtools; echo
    menu_cat "Observabilidad" "$CYAN"
    echo -e "  ${CYAN}1)${RESET} Logs en vivo de un sitio  (access + error)"
    echo -e "  ${CYAN}2)${RESET} Análisis de tráfico  (top IPs, URLs, códigos, bots)"
    echo -e "  ${CYAN}3)${RESET} Errores PHP recientes"
    echo -e "  ${CYAN}4)${RESET} Benchmark de un sitio  (DNS, conexión, TTFB, total)"
    menu_cat "Control del sitio" "$CYAN"
    echo -e "  ${CYAN}5)${RESET} Modo mantenimiento ON/OFF  (página 503 amigable)"
    echo -e "  ${CYAN}6)${RESET} Proteger sitio con contraseña  (Basic Auth)"
    menu_cat "PHP" "$CYAN"
    echo -e "  ${CYAN}7)${RESET} Limpiar OPcache  (aplica cambios de código al instante)"
    echo -e "  ${CYAN}8)${RESET} Límites y extensiones PHP activos"
    echo
    echo -e "  ${CYAN}0)${RESET} ← Volver al menú principal"
    echo
    read -rp "  Opción: " opt
    case "$opt" in
      1) run_item header_devtools dev_live_logs ;;
      2) run_item header_devtools dev_traffic ;;
      3) run_item header_devtools dev_php_errors ;;
      4) run_item header_devtools dev_benchmark ;;
      5) run_item header_devtools dev_maintenance ;;
      6) run_item header_devtools dev_basic_auth ;;
      7) run_item header_devtools dev_opcache_clear ;;
      8) run_item header_devtools dev_php_limits ;;
      0) return ;;
      *) msg_error "Opción inválida."; pause ;;
    esac
  done
}

# ══════════════════════════════════════════════════════════════════════════════
# ESTADO GENERAL
# ══════════════════════════════════════════════════════════════════════════════

show_system_status() {
  msg_section "Estado general del sistema"
  local ng_status
  systemctl is-active --quiet nginx 2>/dev/null \
    && ng_status="${GREEN}activo${RESET}" || ng_status="${RED}inactivo${RESET}"
  printf "  %-28s %b\n" "Nginx:" "$ng_status"

  local installed=()
  mapfile -t installed < <(detect_installed_php_versions)
  if [[ "${#installed[@]}" -gt 0 ]]; then
    for ver in "${installed[@]}"; do
      local fpm_status active_mark=""
      systemctl is-active --quiet "php${ver}-fpm" 2>/dev/null \
        && fpm_status="${GREEN}activo${RESET}" || fpm_status="${RED}inactivo${RESET}"
      [[ "$ver" == "$PHP_VERSION" ]] && active_mark=" ${CYAN}← activa${RESET}"
      printf "  %-28s %b%b\n" "PHP ${ver}-FPM:" "$fpm_status" "$active_mark"
    done
  else
    printf "  %-28s %b\n" "PHP-FPM:" "${YELLOW}no instalado${RESET}"
  fi

  local db_status
  if mariadb_installed; then
    mariadb_running \
      && db_status="${GREEN}activo${RESET}" || db_status="${RED}inactivo${RESET}"
  else
    db_status="${YELLOW}no instalado${RESET}"
  fi
  printf "  %-28s %b\n" "MariaDB:" "$db_status"

  local cf_status_s
  if cf_installed; then
    cf_running \
      && cf_status_s="${GREEN}activo${RESET}" \
      || cf_status_s="${YELLOW}instalado/inactivo${RESET}"
  else
    cf_status_s="${RED}no instalado${RESET}"
  fi
  printf "  %-28s %b\n" "cloudflared:" "$cf_status_s"

  local ip; ip="$(detect_primary_ip 2>/dev/null || echo 'no detectada')"
  printf "  %-28s %s\n" "IP del LXC:" "$ip"

  local n_sites
  n_sites="$(find /etc/nginx/sites-enabled -maxdepth 1 -type l 2>/dev/null \
    | grep -Ev '000-catch-all|default' | wc -l || true)"
  printf "  %-28s %s\n" "Sitios activos:" "${n_sites//[^0-9]/}"

  printf "  %-28s %s\n" "Zona horaria:" \
    "$(timedatectl show --property=Timezone --value 2>/dev/null || echo 'desconocida')"
  printf "  %-28s %s\n" "Hora:" "$(date '+%Y-%m-%d %H:%M:%S %Z')"
  echo
}

# ══════════════════════════════════════════════════════════════════════════════
# GIT / DEPLOY
# ══════════════════════════════════════════════════════════════════════════════

git_is_installed() { command -v git >/dev/null 2>&1; }

require_git() {
  if ! git_is_installed; then
    msg_warn "Git no está instalado. Instalando..."
    apt-get install -y git
    msg_ok "Git instalado: $(git --version)"
  fi
  # Evitar el error "dubious ownership" cuando root opera repos de www-data
  git config --global --add safe.directory '*' 2>/dev/null || true
}

_is_git_repo() { [[ -d "${1}/.git" ]]; }

git_show_key() {
  if [[ ! -f "${GIT_DEPLOY_KEY}.pub" ]]; then
    msg_warn "No existe clave SSH. Genera una primero (opción 1)."
    return 1
  fi
  msg_section "Clave pública SSH de este servidor"
  echo
  cat "${GIT_DEPLOY_KEY}.pub"
  echo
  echo -e "${BOLD}  Dónde agregarla en GitHub (elige UNA de las dos opciones):${RESET}"
  echo
  echo -e "  ${GREEN}★ RECOMENDADO — Clave de cuenta (sirve para TODOS tus repositorios):${RESET}"
  echo "    GitHub → avatar → Settings → SSH and GPG keys → New SSH key"
  echo "    Title: VPS-$(hostname)   |   Key type: Authentication Key"
  echo
  echo -e "  ${DIM}  Alternativa — Deploy key (solo para UN repositorio):${RESET}"
  echo "    GitHub → Repositorio → Settings → Deploy keys → Add deploy key"
  echo "    (repetir en cada repo; útil si el VPS no es tuyo)"
  echo
  msg_info "Con la clave de cuenta agregas una vez y todos tus repos quedan disponibles."
}

git_setup_key() {
  msg_section "Configurar clave SSH para GitHub"

  if [[ -f "${GIT_DEPLOY_KEY}.pub" ]]; then
    echo
    msg_ok "Este servidor ya tiene una clave SSH generada."
    echo
    echo -e "  ${CYAN}Una sola clave funciona para TODOS tus repositorios.${RESET}"
    echo "  No es necesario generar una nueva por cada proyecto."
    echo
    git_show_key
    echo
    prompt_yes_no "¿Regenerar la clave de todas formas? (deberás actualizarla en GitHub)" "n"
    [[ "$REPLY_YESNO" != "s" ]] && return 0
  fi

  require_git

  local email=""
  read -rp "  Email o etiqueta para la clave (ej: vps-produccion): " email
  [[ -z "$email" ]] && email="deploy@$(hostname)"

  mkdir -p /root/.ssh
  ssh-keygen -t ed25519 -C "$email" -f "$GIT_DEPLOY_KEY" -N "" -q
  chmod 600 "$GIT_DEPLOY_KEY"
  chmod 644 "${GIT_DEPLOY_KEY}.pub"

  local ssh_cfg="/root/.ssh/config"
  if ! grep -q "Host github.com" "$ssh_cfg" 2>/dev/null; then
    cat >> "$ssh_cfg" <<EOF

Host github.com
    HostName github.com
    User git
    IdentityFile ${GIT_DEPLOY_KEY}
    StrictHostKeyChecking no
EOF
    chmod 600 "$ssh_cfg"
    msg_ok "~/.ssh/config configurado para GitHub."
  fi

  msg_ok "Clave generada: ${GIT_DEPLOY_KEY}"
  echo
  git_show_key
}

git_clone_site() {
  ensure_web_stack_installed || return 1
  msg_section "Clonar repositorio en un sitio"

  require_git

  choose_site || return 0
  local site="$CHOSEN_SITE"
  local site_dir="/var/www/${site}"

  if _is_git_repo "$site_dir"; then
    msg_warn "${site_dir} ya es un repositorio git."
    local remote; remote="$(git -C "$site_dir" remote get-url origin 2>/dev/null || echo '—')"
    msg_info "Remoto actual: ${remote}"
    prompt_yes_no "¿Hacer git pull en lugar de clonar?" "s"
    [[ "$REPLY_YESNO" == "s" ]] && { _git_pull_dir "$site" "$site_dir"; return $?; }
    return 0
  fi

  echo
  echo "  Formato SSH:   git@github.com:usuario/repositorio.git"
  echo "  Formato HTTPS: https://github.com/usuario/repositorio.git"
  echo
  local repo_url=""
  while true; do
    read -rp "  URL del repositorio: " repo_url
    [[ -n "$repo_url" ]] && break
    msg_error "La URL es obligatoria."
  done

  local branch="main"
  read -rp "  Rama a desplegar [main]: " branch
  branch="${branch:-main}"

  if [[ -n "$(ls -A "$site_dir" 2>/dev/null)" ]]; then
    msg_warn "${site_dir} no está vacío."
    prompt_yes_no "¿Limpiar el directorio antes de clonar? (se perderán archivos actuales)" "n"
    if [[ "$REPLY_YESNO" != "s" ]]; then
      msg_error "Operación cancelada. Limpia el directorio manualmente o usa un sitio nuevo."; return 1
    fi
    rm -rf "${site_dir:?}"/*
    rm -rf "${site_dir}"/.[!.]* 2>/dev/null || true
    msg_warn "Directorio limpiado."
  fi

  msg_info "Clonando ${repo_url} (rama: ${branch}) en ${site_dir}..."
  if git clone --branch "$branch" "$repo_url" "$site_dir" 2>&1; then
    msg_ok "Repositorio clonado."
  else
    msg_error "Falló el clone. Verifica la URL y que la deploy key esté añadida en GitHub."
    return 1
  fi

  chown -R www-data:www-data "$site_dir"
  find "$site_dir" -not -path "${site_dir}/.git/*" -type d -exec chmod 755 {} \;
  find "$site_dir" -not -path "${site_dir}/.git/*" -type f -exec chmod 644 {} \;
  _apply_writable_perms "$site_dir"

  echo
  msg_info "Últimos commits:"
  git -C "$site_dir" log --oneline -5 2>/dev/null || true
  echo

  _git_post_deploy_prompt "$site" "$site_dir"
}

_git_pull_dir() {
  local site="$1" site_dir="$2"
  local branch; branch="$(git -C "$site_dir" rev-parse --abbrev-ref HEAD 2>/dev/null || echo 'main')"

  msg_info "Branch: ${branch}  —  ejecutando git pull..."
  if ! git -C "$site_dir" pull origin "$branch" 2>&1; then
    msg_error "git pull falló. Verifica conectividad y que la deploy key esté activa en GitHub."
    return 1
  fi

  msg_ok "Pull completado."
  echo
  msg_info "Últimos 5 commits:"
  git -C "$site_dir" log --oneline -5 2>/dev/null || true
  echo

  chown -R www-data:www-data "$site_dir"
  _apply_writable_perms "$site_dir"

  _git_post_deploy_prompt "$site" "$site_dir"
}

git_pull_site() {
  ensure_web_stack_installed || return 1
  msg_section "Pull / Deploy desde GitHub"
  require_git

  choose_site || return 0
  local site="$CHOSEN_SITE"
  local site_dir="/var/www/${site}"

  if ! _is_git_repo "$site_dir"; then
    msg_error "${site_dir} no es un repositorio git."
    msg_info "Usa 'Clonar repositorio' primero (opción 2)."; return 1
  fi

  local remote; remote="$(git -C "$site_dir" remote get-url origin 2>/dev/null || echo '—')"
  msg_info "Sitio:  ${site}"
  msg_info "Remoto: ${remote}"
  echo

  _git_pull_dir "$site" "$site_dir"
}

_git_post_deploy_prompt() {
  local site="$1" site_dir="$2"
  echo
  echo "  ¿Ejecutar acciones post-deploy?"
  echo
  echo "  1) Recargar Nginx + PHP-FPM"
  echo "  2) npm install && npm run build  (assets JS/CSS)"
  echo "  3) Todo: npm build + recarga de servicios"
  echo "  0) Omitir"
  echo
  local opt; read -rp "  Opción: " opt
  case "$opt" in
    1) [[ -n "$PHP_VERSION" ]] && reload_services \
         || msg_warn "Ninguna versión PHP activa seleccionada." ;;
    2) _deploy_npm "$site_dir" ;;
    3)
      _deploy_npm "$site_dir"
      [[ -n "$PHP_VERSION" ]] && reload_services || true
      ;;
    0) return 0 ;;
    *) msg_warn "Opción ignorada. Post-deploy omitido." ;;
  esac
}

_deploy_npm() {
  local dir="$1"
  [[ ! -f "${dir}/package.json" ]] \
    && { msg_warn "package.json no encontrado en ${dir}"; return 0; }
  command -v npm >/dev/null 2>&1 \
    || { msg_warn "npm no está instalado en el servidor."; return 1; }
  msg_info "Ejecutando npm install..."
  npm install --prefix "$dir" 2>&1 \
    && msg_ok "npm install completado." \
    || { msg_error "npm install falló."; return 1; }
  msg_info "Ejecutando npm run build..."
  npm run build --prefix "$dir" 2>&1 \
    && msg_ok "npm run build completado." \
    || { msg_error "npm run build falló."; return 1; }
}

git_status_site() {
  msg_section "Estado Git del sitio"
  require_git

  choose_site || return 0
  local site="$CHOSEN_SITE"
  local site_dir="/var/www/${site}"

  if ! _is_git_repo "$site_dir"; then
    msg_warn "${site_dir} no es un repositorio git."; return 0
  fi

  local remote; remote="$(git -C "$site_dir" remote get-url origin 2>/dev/null || echo '—')"
  local branch; branch="$(git -C "$site_dir" rev-parse --abbrev-ref HEAD 2>/dev/null || echo '—')"

  printf "  %-16s %s\n" "Sitio:"       "$site"
  printf "  %-16s %s\n" "Directorio:"  "$site_dir"
  printf "  %-16s %s\n" "Remoto:"      "$remote"
  printf "  %-16s %s\n" "Branch:"      "$branch"
  echo
  msg_info "Últimos 10 commits:"
  git -C "$site_dir" log --oneline -10 2>/dev/null || true
  echo
  msg_info "Estado del working directory:"
  git -C "$site_dir" status --short 2>/dev/null || true
}

# ══════════════════════════════════════════════════════════════════════════════
# SUBMENÚS
# ══════════════════════════════════════════════════════════════════════════════

uninstall_web_stack() {
  msg_section "Eliminar TODO el Stack Web (limpiar la máquina)"

  # Inventario de lo que se eliminaría
  local sites=() php_versions=()
  mapfile -t sites < <(
    find /etc/nginx/sites-available -maxdepth 1 -type f -printf '%f\n' 2>/dev/null \
      | grep -Ev '^default$|^000-catch-all$|\.maintenance$' | sort
  )
  mapfile -t php_versions < <(detect_installed_php_versions)

  echo -e "  ${BOLD}${RED}╔══════════════════════════════════════════════════╗${RESET}"
  echo -e "  ${BOLD}${RED}║   ⚠  ADVERTENCIA — OPERACIÓN DESTRUCTIVA  ⚠      ║${RESET}"
  echo -e "  ${BOLD}${RED}╚══════════════════════════════════════════════════╝${RESET}"
  echo
  msg_warn "Esta acción eliminará por completo el stack web de esta máquina:"
  echo
  echo -e "    ${RED}•${RESET} Nginx (paquete + configuración /etc/nginx)"
  echo -e "    ${RED}•${RESET} PHP-FPM y todos los paquetes php* instalados"
  echo -e "    ${RED}•${RESET} Repositorio Sury (/etc/apt/sources.list.d/php.list)"
  echo -e "    ${RED}•${RESET} Todos los sitios y su contenido en /var/www"
  echo
  echo -e "  ${BOLD}Inventario actual detectado:${RESET}"
  echo
  if [[ "${#sites[@]}" -gt 0 ]]; then
    echo -e "    ${YELLOW}Sitios (${#sites[@]}):${RESET}"
    for s in "${sites[@]}"; do
      local dir="/var/www/${s}"
      local sz="—"
      [[ -d "$dir" ]] && sz="$(du -sh "$dir" 2>/dev/null | cut -f1)"
      printf "      - %-24s %s\n" "$s" "$dir (${sz})"
    done
  else
    echo -e "    ${DIM}Sin sitios configurados.${RESET}"
  fi
  echo
  if [[ "${#php_versions[@]}" -gt 0 ]]; then
    echo -e "    ${YELLOW}Versiones PHP-FPM:${RESET} ${php_versions[*]}"
  else
    echo -e "    ${DIM}Sin PHP-FPM instalado.${RESET}"
  fi
  dpkg -s nginx >/dev/null 2>&1 \
    && echo -e "    ${YELLOW}Nginx:${RESET} instalado" \
    || echo -e "    ${DIM}Nginx: no instalado${RESET}"
  echo

  msg_error "Esta operación NO se puede deshacer. Los datos en /var/www se perderán."
  echo
  msg_info "Se recomienda respaldar bases de datos y /var/www antes de continuar."
  echo

  # Primera confirmación
  prompt_yes_no "¿Deseas continuar con la eliminación del Stack Web?" "n"
  [[ "$REPLY_YESNO" != "s" ]] && { msg_ok "Cancelado. No se eliminó nada."; return 0; }
  echo

  # Preguntar si conserva /var/www
  prompt_yes_no "¿Eliminar también el contenido de /var/www (sitios y archivos)?" "n"
  local remove_www="$REPLY_YESNO"
  echo

  # Segunda confirmación con frase explícita
  msg_warn "Confirmación final: escribe exactamente  ELIMINAR  para proceder."
  local phrase=""
  read -rp "  > " phrase
  if [[ "$phrase" != "ELIMINAR" ]]; then
    msg_ok "Frase incorrecta. Operación cancelada. No se eliminó nada."; return 0
  fi
  echo

  # ── Ejecución ──────────────────────────────────────────────────────────────
  msg_info "[1/6] Deteniendo servicios..."
  systemctl stop nginx 2>/dev/null || true
  local v
  for v in "${php_versions[@]}"; do
    systemctl stop "php${v}-fpm" 2>/dev/null || true
  done

  msg_info "[2/6] Eliminando sitios de Nginx..."
  for s in "${sites[@]}"; do
    cleanup_site_residue "$s" "$remove_www"
  done
  rm -f /etc/nginx/sites-enabled/000-catch-all "$CATCH_ALL_FILE" 2>/dev/null || true

  msg_info "[3/6] Purgando paquetes PHP..."
  local php_pkgs=()
  mapfile -t php_pkgs < <(dpkg -l 'php*' 2>/dev/null | awk '/^ii/{print $2}')
  if [[ "${#php_pkgs[@]}" -gt 0 ]]; then
    apt-get purge -y "${php_pkgs[@]}" 2>/dev/null || true
  fi

  msg_info "[4/6] Purgando Nginx..."
  apt-get purge -y nginx nginx-common nginx-core 2>/dev/null || true
  rm -rf /etc/nginx 2>/dev/null || true

  msg_info "[5/6] Eliminando repositorio Sury..."
  rm -f /etc/apt/sources.list.d/php.list \
        /usr/share/keyrings/deb.sury.org-php.gpg 2>/dev/null || true

  msg_info "[6/6] Limpiando dependencias huérfanas..."
  apt-get autoremove -y 2>/dev/null || true
  apt-get update 2>/dev/null || true

  # Reset de la versión PHP activa en el script
  PHP_VERSION=""

  echo
  msg_ok "Stack Web eliminado."
  [[ "$remove_www" == "s" ]] \
    && msg_warn "Contenido de /var/www eliminado." \
    || msg_info "El contenido de /var/www se conservó."
  echo
  msg_info "MariaDB y Cloudflared NO fueron tocados (usa sus menús si deseas eliminarlos)."
}

header_web_stack() {
  echo -e "${BOLD}${CYAN}╔══════════════════════════════════════════════╗${RESET}"
  echo -e "${BOLD}${CYAN}║${WHITE}  [ 1 ] Stack Web — Nginx + PHP             ${CYAN}║${RESET}"
  echo -e "${BOLD}${CYAN}╚══════════════════════════════════════════════╝${RESET}"
}

menu_web_stack() {
  local opt
  while true; do
    clear
    header_web_stack; echo
    menu_cat "Instalación" "$CYAN"
    echo -e "  ${CYAN} 1)${RESET} Instalar stack base (Nginx + PHP)"
    echo -e "  ${CYAN} 2)${RESET} Instalar extensión PHP adicional"
    menu_cat "Sitios" "$CYAN"
    echo -e "  ${CYAN} 3)${RESET} Crear sitio con dominio personalizado"
    echo -e "  ${CYAN} 4)${RESET} Listar sitios"
    echo -e "  ${CYAN} 5)${RESET} Probar sitio"
    echo -e "  ${CYAN} 6)${RESET} Eliminar sitio"
    echo -e "  ${CYAN} 7)${RESET} Eliminar archivos de diagnóstico (info.php, test-db.php)"
    echo -e "  ${CYAN} 8)${RESET} Reparar permisos storage/uploads"
    menu_cat "Servicios y PHP" "$CYAN"
    echo -e "  ${CYAN} 9)${RESET} Recargar Nginx + PHP-FPM"
    echo -e "  ${CYAN}10)${RESET} Cambiar límite de subida de archivos"
    echo -e "  ${CYAN}11)${RESET} Configurar duración de sesión PHP"
    echo -e "  ${CYAN}12)${RESET} Estado y versiones PHP"
    echo -e "  ${CYAN}13)${RESET} Cambiar versión PHP activa"
    menu_cat "Zona de peligro" "$RED"
    echo -e "  ${RED}14)${RESET} Eliminar TODO el Stack Web (limpiar la máquina)"
    echo
    echo -e "  ${CYAN} 0)${RESET} ← Volver al menú principal"
    echo
    read -rp "  Opción: " opt
    case "$opt" in
      1)  run_item header_web_stack install_base_stack ;;
      2)  run_item header_web_stack install_php_extension ;;
      3)  run_item header_web_stack create_site_custom_domain ;;
      4)  run_item header_web_stack list_sites ;;
      5)  run_item header_web_stack test_site ;;
      6)  run_item header_web_stack delete_site ;;
      7)  run_item header_web_stack remove_debug_files ;;
      8)  run_item header_web_stack fix_storage_permissions ;;
      9)  run_item header_web_stack reload_services ;;
      10) run_item header_web_stack change_upload_limits ;;
      11) run_item header_web_stack configure_session_lifetime ;;
      12) run_item header_web_stack show_php_status ;;
      13) run_item header_web_stack select_php_version switch ;;
      14) run_item header_web_stack uninstall_web_stack ;;
      0)  return ;;
      *)  msg_error "Opción inválida."; pause ;;
    esac
  done
}

header_mariadb() {
  echo -e "${BOLD}${MAGENTA}╔══════════════════════════════════════════════╗${RESET}"
  echo -e "${BOLD}${MAGENTA}║${WHITE}  [ 2 ] MariaDB — Base de Datos             ${MAGENTA}║${RESET}"
  echo -e "${BOLD}${MAGENTA}╚══════════════════════════════════════════════╝${RESET}"
}

menu_mariadb() {
  local opt
  while true; do
    clear
    header_mariadb; echo
    menu_cat "Instalación" "$MAGENTA"
    echo -e "  ${MAGENTA} 1)${RESET} Instalar MariaDB"
    echo -e "  ${MAGENTA} 2)${RESET} Configurar bind-address"
    menu_cat "Bases de datos" "$MAGENTA"
    echo -e "  ${MAGENTA} 3)${RESET} Crear base de datos + usuario"
    echo -e "  ${MAGENTA} 4)${RESET} Crear solo base de datos"
    echo -e "  ${MAGENTA} 5)${RESET} Crear solo usuario y asignarlo"
    echo -e "  ${MAGENTA} 6)${RESET} Crear usuario dual (localhost + remoto)"
    menu_cat "Consultas" "$MAGENTA"
    echo -e "  ${MAGENTA} 7)${RESET} Listar bases de datos"
    echo -e "  ${MAGENTA} 8)${RESET} Listar usuarios"
    echo -e "  ${MAGENTA} 9)${RESET} Ver grants de un usuario"
    echo -e "  ${MAGENTA}10)${RESET} Tamaño de bases de datos"
    echo -e "  ${MAGENTA}11)${RESET} Conexiones activas"
    menu_cat "Gestión de usuarios" "$MAGENTA"
    echo -e "  ${MAGENTA}12)${RESET} Cambiar contraseña de usuario"
    echo -e "  ${MAGENTA}13)${RESET} Cambiar host de usuario  (localhost ↔ % ↔ IP)"
    echo -e "  ${MAGENTA}14)${RESET} Cambiar privilegios de usuario"
    menu_cat "Backup / Restauración" "$MAGENTA"
    echo -e "  ${MAGENTA}15)${RESET} Backup base de datos  (mysqldump → /var/backups/mariadb)"
    echo -e "  ${MAGENTA}16)${RESET} Restaurar base de datos desde backup"
    menu_cat "Eliminación y seguridad" "$MAGENTA"
    echo -e "  ${MAGENTA}17)${RESET} Eliminar base de datos"
    echo -e "  ${MAGENTA}18)${RESET} Eliminar usuario"
    echo -e "  ${MAGENTA}19)${RESET} Recordatorio mysql_secure_installation"
    echo
    echo -e "  ${MAGENTA} 0)${RESET} ← Volver al menú principal"
    echo
    read -rp "  Opción: " opt
    case "$opt" in
      1)  run_item header_mariadb install_mariadb ;;
      2)  run_item header_mariadb configure_bind_address ;;
      3)  run_item header_mariadb create_user_and_grant ;;
      4)  run_item header_mariadb create_database_only ;;
      5)  run_item header_mariadb create_user_only ;;
      6)  run_item header_mariadb create_dual_user ;;
      7)  run_item header_mariadb list_databases ;;
      8)  run_item header_mariadb list_users ;;
      9)  run_item header_mariadb show_grants_for_user ;;
      10) run_item header_mariadb show_db_sizes ;;
      11) run_item header_mariadb show_active_connections ;;
      12) run_item header_mariadb change_user_password ;;
      13) run_item header_mariadb change_user_host ;;
      14) run_item header_mariadb change_user_grants ;;
      15) run_item header_mariadb dump_database ;;
      16) run_item header_mariadb restore_database ;;
      17) run_item header_mariadb delete_database ;;
      18) run_item header_mariadb delete_user ;;
      19) run_item header_mariadb mariadb_secure_hint ;;
      0)  return ;;
      *)  msg_error "Opción inválida."; pause ;;
    esac
  done
}

header_cloudflared() {
  local cf_s
  if ! cf_installed; then cf_s="${RED}● no instalado${RESET}"
  elif cf_running;   then cf_s="${GREEN}● activo${RESET}"
  else                    cf_s="${YELLOW}● instalado/inactivo${RESET}"
  fi
  echo -e "${BOLD}${YELLOW}╔══════════════════════════════════════════════╗${RESET}"
  echo -e "${BOLD}${YELLOW}║${WHITE}  [ 3 ] Cloudflare Tunnel                   ${YELLOW}║${RESET}"
  echo -e "${BOLD}${YELLOW}╚══════════════════════════════════════════════╝${RESET}"
  echo -e "  cloudflared ${cf_s}"
}

menu_cloudflared() {
  local opt
  while true; do
    clear
    header_cloudflared; echo
    menu_cat "Instalación y autenticación" "$YELLOW"
    echo -e "  ${YELLOW}1)${RESET} Instalar cloudflared"
    echo -e "  ${YELLOW}2)${RESET} Autenticar con Cloudflare"
    menu_cat "Configuración del tunnel" "$YELLOW"
    echo -e "  ${YELLOW}3)${RESET} Crear tunnel + generar config.yml"
    echo -e "  ${YELLOW}4)${RESET} Regenerar config.yml desde sitios Nginx"
    echo -e "  ${YELLOW}5)${RESET} Ver config.yml actual"
    echo -e "  ${YELLOW}6)${RESET} Eliminar sitio del tunnel  (solo quita el hostname del config.yml)"
    echo -e "  ${YELLOW}7)${RESET} Eliminar tunnel completo de Cloudflare"
    menu_cat "Servicio" "$YELLOW"
    echo -e "  ${YELLOW}8)${RESET} Estado del tunnel"
    echo -e "  ${YELLOW}9)${RESET} Iniciar / Detener / Reiniciar servicio"
    echo -e "  ${YELLOW}10)${RESET} Ver logs"
    echo -e "  ${YELLOW}11)${RESET} Reparar servicio (instalado con --token)"
    menu_cat "Zona de peligro" "$RED"
    echo -e "  ${RED}12)${RESET} Eliminar cloudflared de la máquina"
    echo
    echo -e "  ${YELLOW}0)${RESET} ← Volver al menú principal"
    echo
    read -rp "  Opción: " opt
    case "$opt" in
      1)  run_item header_cloudflared cf_install ;;
      2)  run_item header_cloudflared cf_login ;;
      3)  run_item header_cloudflared cf_create_tunnel ;;
      4)  run_item header_cloudflared cf_regen_config ;;
      5)  run_item header_cloudflared cf_show_config ;;
      6)  run_item header_cloudflared cf_remove_site ;;
      7)  run_item header_cloudflared cf_delete_tunnel ;;
      8)  run_item header_cloudflared cf_status ;;
      9)  run_item header_cloudflared cf_service_control ;;
      10) run_item header_cloudflared cf_logs ;;
      11) run_item header_cloudflared cf_fix_service ;;
      12) run_item header_cloudflared cf_uninstall ;;
      0)  return ;;
      *)  msg_error "Opción inválida."; pause ;;
    esac
  done
}

header_git() {
  local key_mark
  [[ -f "${GIT_DEPLOY_KEY}.pub" ]] \
    && key_mark="${GREEN}● deploy key OK${RESET}" \
    || key_mark="${YELLOW}● sin deploy key${RESET}"
  echo -e "${BOLD}${GREEN}╔══════════════════════════════════════════════╗${RESET}"
  echo -e "${BOLD}${GREEN}║${WHITE}  [ 4 ] Git / Deploy                        ${GREEN}║${RESET}"
  echo -e "${BOLD}${GREEN}╚══════════════════════════════════════════════╝${RESET}"
  echo -e "  ${key_mark}"
}

menu_git() {
  local opt
  while true; do
    clear
    header_git; echo
    menu_cat "SSH / Autenticación" "$GREEN"
    echo -e "  ${GREEN}1)${RESET} Generar clave SSH del servidor  (una sola para todos los repos)"
    echo -e "  ${GREEN}2)${RESET} Ver clave pública + instrucciones para agregarla en GitHub"
    menu_cat "Repositorio" "$GREEN"
    echo -e "  ${GREEN}3)${RESET} Clonar repositorio en un sitio"
    echo -e "  ${GREEN}4)${RESET} Pull / Deploy → actualizar sitio desde GitHub"
    echo -e "  ${GREEN}5)${RESET} Estado del repositorio (log + status)"
    echo
    echo -e "  ${GREEN}0)${RESET} ← Volver al menú principal"
    echo
    read -rp "  Opción: " opt
    case "$opt" in
      1) run_item header_git git_setup_key ;;
      2) run_item header_git git_show_key ;;
      3) run_item header_git git_clone_site ;;
      4) run_item header_git git_pull_site ;;
      5) run_item header_git git_status_site ;;
      0) return ;;
      *) msg_error "Opción inválida."; pause ;;
    esac
  done
}

header_sistema() {
  echo -e "${BOLD}${WHITE}╔══════════════════════════════════════════════╗${RESET}"
  echo -e "${BOLD}${WHITE}║${CYAN}  [ 5 ] Sistema — Utilidades                ${WHITE}║${RESET}"
  echo -e "${BOLD}${WHITE}╚══════════════════════════════════════════════╝${RESET}"
}

menu_sistema() {
  local opt
  while true; do
    clear
    header_sistema; echo
    printf "  Hora actual: %s\n" "$(date '+%Y-%m-%d %H:%M:%S %Z')"
    echo
    menu_cat "Zona horaria y NTP" "$WHITE"
    echo -e "  ${WHITE}1)${RESET} Ver hora y zona horaria"
    echo -e "  ${WHITE}2)${RESET} Cambiar zona horaria"
    echo -e "  ${WHITE}3)${RESET} Configurar sincronización NTP"
    menu_cat "Sistema" "$WHITE"
    echo -e "  ${WHITE}4)${RESET} Actualizar sistema (apt upgrade)"
    echo -e "  ${WHITE}5)${RESET} Información del sistema"
    menu_cat "Comando global" "$WHITE"
    echo -e "  ${WHITE}6)${RESET} Instalar comando  ${BOLD}devlab${RESET}  (acceso desde cualquier ruta)"
    echo -e "  ${WHITE}7)${RESET} Eliminar comando global"
    echo
    echo -e "  ${WHITE}0)${RESET} ← Volver al menú principal"
    echo
    read -rp "  Opción: " opt
    case "$opt" in
      1) run_item header_sistema sys_show_time ;;
      2) run_item header_sistema sys_set_timezone ;;
      3) run_item header_sistema sys_configure_ntp ;;
      4) run_item header_sistema sys_update ;;
      5) run_item header_sistema sys_info ;;
      6) run_item header_sistema install_global_command ;;
      7) run_item header_sistema remove_global_command ;;
      0) return ;;
      *) msg_error "Opción inválida."; pause ;;
    esac
  done
}

# ══════════════════════════════════════════════════════════════════════════════
# MENÚ PRINCIPAL
# ══════════════════════════════════════════════════════════════════════════════

main_menu() {
  if [[ -z "$PHP_VERSION" ]]; then
    local _d=()
    mapfile -t _d < <(detect_installed_php_versions)
    [[ "${#_d[@]}" -eq 1 ]] && PHP_VERSION="${_d[0]}"
  fi

  local opt
  while true; do
    local php_lbl="${PHP_VERSION:-—}"
    local deb_lbl="${DEBIAN_CODENAME:-desconocido}"

    clear
    echo -e "${BOLD}${BLUE}╔══════════════════════════════════════════════════╗${RESET}"
    echo -e "${BOLD}${BLUE}║${WHITE}   DevLab Manager v${SCRIPT_VERSION}  ${BLUE}║${RESET}"
    echo -e "${BOLD}${BLUE}║${WHITE}   Nginx · PHP ${php_lbl} · MariaDB · Debian ${deb_lbl} ${BLUE}║${RESET}"
    echo -e "${BOLD}${BLUE}╚══════════════════════════════════════════════════╝${RESET}"
    echo

    local ng_s db_s php_s cf_s
    if systemctl is-active --quiet nginx 2>/dev/null; then ng_s="${GREEN}●${RESET}"; else ng_s="${RED}●${RESET}"; fi
    if mariadb_installed && mariadb_running;           then db_s="${GREEN}●${RESET}"; else db_s="${RED}●${RESET}"; fi
    if cf_installed && cf_running;                     then cf_s="${GREEN}●${RESET}"; else cf_s="${RED}●${RESET}"; fi
    if [[ -z "$PHP_VERSION" ]]; then
      php_s="${YELLOW}●${RESET}"
    elif systemctl is-active --quiet "php${PHP_VERSION}-fpm" 2>/dev/null; then
      php_s="${GREEN}●${RESET}"
    else
      php_s="${RED}●${RESET}"
    fi
    echo -e "  Nginx ${ng_s}   PHP-FPM ${php_s}   MariaDB ${db_s}   Cloudflared ${cf_s}"
    echo

    local ip_local ip_publica
    ip_local="$(detect_primary_ip 2>/dev/null || echo '—')"
    ip_publica="$(curl -s --max-time 3 https://api.ipify.org 2>/dev/null || echo '—')"
    printf "  ${DIM}IP local:${RESET}  ${CYAN}%-18s${RESET}  ${DIM}IP pública:${RESET}  ${CYAN}%s${RESET}\n" \
      "$ip_local" "$ip_publica"
    echo

    echo -e "  ${CYAN}1)${RESET} ${BOLD}Stack Web${RESET}      — Nginx, PHP-FPM, sitios"
    echo -e "  ${MAGENTA}2)${RESET} ${BOLD}MariaDB${RESET}        — Instalación, bases, usuarios"
    echo -e "  ${YELLOW}3)${RESET} ${BOLD}Cloudflare${RESET}     — Tunnel, config, DNS"
    echo -e "  ${GREEN}4)${RESET} ${BOLD}Git / Deploy${RESET}   — Deploy key, clone, pull, post-deploy"
    echo -e "  ${WHITE}5)${RESET} ${BOLD}Sistema${RESET}        — Hora, zona horaria, actualizaciones"
    echo -e "  ${RED}6)${RESET} ${BOLD}Seguridad${RESET}      — Firewall, fail2ban, SSH, auditoría"
    echo -e "  ${GREEN}7)${RESET} ${BOLD}Monitor${RESET}        — Dashboard en vivo (CPU, RAM, red, sitios)"
    echo -e "  ${CYAN}8)${RESET} ${BOLD}Dev Tools${RESET}      — Logs, tráfico, benchmark, mantenimiento"
    echo -e "  ${WHITE}9)${RESET} ${BOLD}Estado${RESET}         — Resumen estático de servicios"
    echo -e "  ${WHITE}0)${RESET} Salir"
    echo
    read -rp "  Selecciona [0-9] (m = monitor): " opt; echo

    case "$opt" in
      1) menu_web_stack    || true ;;
      2) menu_mariadb      || true ;;
      3) menu_cloudflared  || true ;;
      4) menu_git          || true ;;
      5) menu_sistema      || true ;;
      6) menu_seguridad    || true ;;
      7|m|M) run_dashboard || true ;;
      8) menu_devtools     || true ;;
      9) show_system_status || true; pause ;;
      0) echo; msg_ok "Hasta luego."; echo; exit 0 ;;
      *) msg_error "Opción inválida."; pause ;;
    esac
  done
}

# ══════════════════════════════════════════════════════════════════════════════
# PUNTO DE ENTRADA
# ══════════════════════════════════════════════════════════════════════════════

usage() {
  cat <<EOF
DevLab Manager v${SCRIPT_VERSION}
Gestor interactivo del stack web: Nginx · PHP-FPM · MariaDB · Cloudflared (Debian 12/13)

Uso: $(basename "$0") [opción]

Opciones:
  -h, --help        Muestra esta ayuda y termina
  -v, --version     Muestra la versión y termina
      --no-color    Desactiva los colores de la salida

Sin opciones inicia el menú interactivo (requiere root y una terminal).
EOF
}

NO_COLOR_FORCE="n"
while [[ $# -gt 0 ]]; do
  case "$1" in
    -h|--help)    usage; exit 0 ;;
    -v|--version) echo "DevLab Manager v${SCRIPT_VERSION}"; exit 0 ;;
    --no-color)   NO_COLOR_FORCE="s"; shift ;;
    --)           shift; break ;;
    *)            echo "Opción desconocida: $1" >&2; echo; usage; exit 2 ;;
  esac
done

setup_colors

on_interrupt() {
  tput cnorm 2>/dev/null || true
  echo
  msg_warn "Interrumpido por el usuario. Saliendo..."
  exit 130
}
trap on_interrupt INT TERM

if [[ "$(id -u)" -ne 0 ]]; then
  msg_error "Debes ejecutar este script como root (ej: sudo $0)."
  exit 1
fi
if ! command -v apt-get >/dev/null 2>&1; then
  msg_error "Diseñado para Debian/Ubuntu: no se encontró 'apt-get'."
  exit 1
fi
if [[ ! -t 0 ]]; then
  msg_error "El menú es interactivo y requiere una terminal (TTY)."
  exit 1
fi

detect_debian_codename
main_menu
