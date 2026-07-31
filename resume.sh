#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
#
# Resume a partially completed FreePBX 17 installation that stalled while
# upgrading the Sangoma Endpoint Manager module or a dependent module.

set -Eeuo pipefail

readonly RESUME_VERSION="0.3.0"
readonly INSTALLER_URL="https://raw.githubusercontent.com/ravigodno/freepbx_install/main/install.sh"
readonly WORK_ROOT="/root"
readonly RUN_ID="$(date '+%Y%m%d-%H%M%S')"
readonly RECOVERY_DIR="${WORK_ROOT}/freepbx-install-recovery-${RUN_ID}"
readonly INSTALLER_PATH="/tmp/freepbx-install-no-endpoint.sh"
readonly PID_FILE="/var/run/freepbx17_installer.pid"
readonly MODULE_ROOT="/var/www/html/admin/modules"
readonly EXCLUDED_MODULES=(restapps endpoint)

DRY_RUN=false
STOP_STUCK=false
INSTALLER_ARGS=()
FWCONSOLE=""

usage() {
  cat <<'USAGE'
Использование:
  bash resume.sh [--dry-run] [--stop-stuck] [аргументы официального установщика]

Параметры:
  --dry-run      Собрать диагностику и показать найденные процессы.
                 Процессы, пакеты и системная конфигурация не изменяются.
  --stop-stuck   Остановить только известные зависшие процессы установщика,
                 endpoint/restapps и upgradeall, затем продолжить восстановление.
  -h, --help     Показать справку.
  -V, --version  Показать версию.

Остальные параметры передаются install.sh, а затем официальному установщику.
USAGE
}

log() {
  printf '[freepbx_resume] %s\n' "$*"
}

fail() {
  printf '[freepbx_resume] ОШИБКА: %s\n' "$*" >&2
  exit 1
}

find_stuck_pids() {
  {
    pgrep -f '[s]ng_freepbx_debian_install[^ ]*\.sh' || true
    pgrep -f '[f]wconsole ma upgradeall' || true
    pgrep -f "[f]wconsole ma install ['\"]?(endpoint|restapps)['\"]?" || true
  } | sort -nu
}

show_stuck_processes() {
  pgrep -af '[s]ng_freepbx_debian_install[^ ]*\.sh' || true
  pgrep -af '[f]wconsole ma upgradeall' || true
  pgrep -af "[f]wconsole ma install ['\"]?(endpoint|restapps)['\"]?" || true
}

collect_diagnostics() {
  install -d -m 0700 "$RECOVERY_DIR"

  {
    printf 'Collected: %s\n\n' "$(date --iso-8601=seconds)"
    uname -a
    printf '\n=== OS ===\n'
    cat /etc/os-release
    printf '\n=== MATCHED PROCESSES ===\n'
    show_stuck_processes
    printf '\n=== FREEPBX VERSION ===\n'
    timeout 60 "$FWCONSOLE" --version || true
    printf '\n=== CORE MODULES ===\n'
    timeout 60 "$FWCONSOLE" ma list | grep -iE 'endpoint|restapps|framework|core' || true
    printf '\n=== PACKAGE STATE ===\n'
    dpkg-query -W -f='${Package}\t${Status}\t${Version}\n' freepbx17 2>/dev/null || true
  } >"${RECOVERY_DIR}/diagnostics.txt" 2>&1

  local latest_log=""
  latest_log=$(ls -1t /var/log/pbx/freepbx17-install-*.log 2>/dev/null | head -1 || true)
  if [[ -n "$latest_log" && -f "$latest_log" ]]; then
    cp -a "$latest_log" "$RECOVERY_DIR/"
    tail -n 250 "$latest_log" >"${RECOVERY_DIR}/latest-install-log-tail.txt" || true
  fi

  log "Диагностика сохранена: $RECOVERY_DIR"
}

stop_known_stuck_processes() {
  mapfile -t stuck_pids < <(find_stuck_pids)
  ((${#stuck_pids[@]} > 0)) || return 0

  log "Отправляю TERM известным зависшим процессам: ${stuck_pids[*]}"
  kill -TERM "${stuck_pids[@]}" 2>/dev/null || true

  for _ in {1..15}; do
    sleep 1
    mapfile -t stuck_pids < <(find_stuck_pids)
    ((${#stuck_pids[@]} == 0)) && return 0
  done

  log "Процессы не завершились после TERM; отправляю KILL: ${stuck_pids[*]}"
  kill -KILL "${stuck_pids[@]}" 2>/dev/null || true
  sleep 2

  mapfile -t stuck_pids < <(find_stuck_pids)
  ((${#stuck_pids[@]} == 0)) || fail "не удалось остановить процессы: ${stuck_pids[*]}"
}

backup_and_exclude_modules() {
  local module_name module_dir

  for module_name in "${EXCLUDED_MODULES[@]}"; do
    module_dir="${MODULE_ROOT}/${module_name}"

    if [[ -d "$module_dir" ]]; then
      log "Сохраняю резервную копию модуля $module_name"
      tar -C "$MODULE_ROOT" -czf "${RECOVERY_DIR}/${module_name}-module.tgz" "$module_name"
    fi

    log "Пытаюсь штатно удалить модуль $module_name с ограничением 180 секунд"
    timeout --kill-after=15s 180s "$FWCONSOLE" ma -f remove "$module_name" \
      >"${RECOVERY_DIR}/${module_name}-remove.log" 2>&1 || true

    if [[ -d "$module_dir" ]]; then
      log "Перемещаю оставшийся каталог $module_name в резервную копию"
      mv "$module_dir" "${RECOVERY_DIR}/${module_name}-module-directory"
    fi

    [[ ! -d "$module_dir" ]] || fail "каталог модуля всё ещё существует: $module_dir"
  done
}

validate_environment() {
  ((EUID == 0)) || fail "запустите скрипт от root через su -"
  [[ -r /etc/os-release ]] || fail "не найден /etc/os-release"

  # shellcheck disable=SC1091
  source /etc/os-release
  [[ "${ID:-}" == "debian" && "${VERSION_ID:-}" == "12" ]] || \
    fail "поддерживается только Debian 12; обнаружено: ${PRETTY_NAME:-неизвестно}"

  for command_name in wget pgrep timeout tar dpkg-query dpkg apt-get grep sort; do
    command -v "$command_name" >/dev/null 2>&1 || fail "не найдена команда: $command_name"
  done

  if [[ -x /usr/sbin/fwconsole ]]; then
    FWCONSOLE=/usr/sbin/fwconsole
  elif command -v fwconsole >/dev/null 2>&1; then
    FWCONSOLE=$(command -v fwconsole)
  else
    fail "fwconsole не найден; для новой установки используйте install.sh"
  fi

  dpkg-query -W -f='${Status}' freepbx17 2>/dev/null | grep -q 'install ok installed' || \
    fail "пакет freepbx17 не установлен; для новой установки используйте install.sh"
}

while (($#)); do
  case "$1" in
    --dry-run)
      DRY_RUN=true
      shift
      ;;
    --stop-stuck)
      STOP_STUCK=true
      shift
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    -V|--version)
      printf '%s\n' "$RESUME_VERSION"
      exit 0
      ;;
    *)
      INSTALLER_ARGS+=("$1")
      shift
      ;;
  esac
done

validate_environment
collect_diagnostics

mapfile -t active_pids < <(find_stuck_pids)
if ((${#active_pids[@]} > 0)); then
  log "Найдены процессы незавершённой установки:"
  show_stuck_processes >&2

  if [[ "$DRY_RUN" == "true" ]]; then
    log "Dry-run завершён: процессы не остановлены"
    exit 0
  fi

  [[ "$STOP_STUCK" == "true" ]] || \
    fail "сначала убедитесь, что лог не меняется, затем запустите с --stop-stuck"

  stop_known_stuck_processes
fi

if [[ "$DRY_RUN" == "true" ]]; then
  log "Dry-run завершён: активных зависших процессов не найдено; системных изменений нет"
  exit 0
fi

if ! pgrep -f '[s]ng_freepbx_debian_install[^ ]*\.sh' >/dev/null 2>&1; then
  rm -f "$PID_FILE"
fi

log "Завершаю незаконченные операции dpkg"
dpkg --configure -a
apt-get -f install -y

backup_and_exclude_modules

log "Скачиваю актуальный install.sh"
wget --https-only --secure-protocol=TLSv1_2 --timeout=30 --tries=3 \
  "$INSTALLER_URL" -O "$INSTALLER_PATH"
[[ -s "$INSTALLER_PATH" ]] || fail "install.sh скачан пустым"
grep -q '^#!/usr/bin/env bash' "$INSTALLER_PATH" || fail "неожиданное содержимое install.sh"
chmod 0700 "$INSTALLER_PATH"

log "Повторно запускаю официальный процесс без endpoint/restapps и без upgradeall"
bash "$INSTALLER_PATH" "${INSTALLER_ARGS[@]}"

log "Проверяю результат"
timeout 60 "$FWCONSOLE" --version
if timeout 60 "$FWCONSOLE" ma list | grep -iE 'endpoint|restapps|framework|core'; then
  true
fi

for service_name in asterisk freepbx apache2 mariadb; do
  if systemctl is-active --quiet "$service_name"; then
    log "Служба активна: $service_name"
  else
    log "ПРЕДУПРЕЖДЕНИЕ: служба не активна: $service_name"
  fi
done

log "Восстановление завершено. Диагностика и резервные копии: $RECOVERY_DIR"
