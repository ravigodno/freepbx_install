#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
#
# FreePBX 17 installer wrapper without Sangoma Endpoint Manager.
# Downloads the current official installer, validates its structure,
# removes the endpoint module before installlocal, and executes the result.

set -Eeuo pipefail

readonly WRAPPER_VERSION="0.1.0"
readonly OFFICIAL_URL="https://raw.githubusercontent.com/FreePBX/sng_freepbx_debian_install/master/sng_freepbx_debian_install.sh"
readonly WORK_DIR="/tmp/freepbx-install-no-endpoint"
readonly OFFICIAL_SCRIPT="${WORK_DIR}/sng_freepbx_debian_install.sh"
readonly PATCHED_SCRIPT="${WORK_DIR}/sng_freepbx_debian_install.no-endpoint.sh"
readonly EXPECTED_MARKER='setCurrentStep "Installing all local modules"'

DRY_RUN=false
OFFICIAL_ARGS=()

usage() {
  cat <<'EOF'
Использование:
  bash install.sh [--dry-run] [аргументы официального установщика]

Параметры wrapper:
  --dry-run    Скачать и подготовить изменённый скрипт, но не запускать его.
  -h, --help   Показать справку.
  -V, --version
               Показать версию wrapper.

Остальные параметры без изменений передаются официальному установщику FreePBX.
Параметр --skipversion добавляется автоматически, поскольку временная копия
официального скрипта изменяется локально.
EOF
}

log() {
  printf '[freepbx_install] %s\n' "$*"
}

fail() {
  printf '[freepbx_install] ОШИБКА: %s\n' "$*" >&2
  exit 1
}

cleanup_on_error() {
  local exit_code=$?
  if (( exit_code != 0 )); then
    printf '[freepbx_install] Завершено с ошибкой %d. Подготовленные файлы: %s\n' \
      "$exit_code" "$WORK_DIR" >&2
  fi
  exit "$exit_code"
}
trap cleanup_on_error ERR

while (($#)); do
  case "$1" in
    --dry-run)
      DRY_RUN=true
      shift
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    -V|--version)
      printf '%s\n' "$WRAPPER_VERSION"
      exit 0
      ;;
    *)
      OFFICIAL_ARGS+=("$1")
      shift
      ;;
  esac
done

(( EUID == 0 )) || fail "запустите скрипт от root: su -"

if [[ ! -r /etc/os-release ]]; then
  fail "не найден /etc/os-release"
fi

# shellcheck disable=SC1091
source /etc/os-release
[[ "${ID:-}" == "debian" && "${VERSION_ID:-}" == "12" ]] || \
  fail "поддерживается только Debian 12; обнаружено: ${PRETTY_NAME:-неизвестно}"

for command_name in wget awk grep sha256sum pgrep timeout; do
  command -v "$command_name" >/dev/null 2>&1 || \
    fail "не найдена обязательная команда: $command_name"
done

# Do not start a second installer or module installation in parallel.
if pgrep -af '[s]ng_freepbx_debian_install|[f]wconsole ma (upgradeall|install|installlocal)' >/dev/null 2>&1; then
  pgrep -af '[s]ng_freepbx_debian_install|[f]wconsole ma (upgradeall|install|installlocal)' >&2 || true
  fail "обнаружен уже запущенный установщик или менеджер модулей FreePBX"
fi

install -d -m 0700 "$WORK_DIR"
rm -f "$OFFICIAL_SCRIPT" "$PATCHED_SCRIPT"

log "Скачиваю актуальный официальный установщик FreePBX 17"
wget --https-only --secure-protocol=TLSv1_2 --timeout=30 --tries=3 \
  "$OFFICIAL_URL" -O "$OFFICIAL_SCRIPT"

[[ -s "$OFFICIAL_SCRIPT" ]] || fail "официальный скрипт скачан пустым"
grep -q '^#!/bin/bash' "$OFFICIAL_SCRIPT" || fail "неожиданное содержимое официального скрипта"

marker_count=$(grep -F -c "$EXPECTED_MARKER" "$OFFICIAL_SCRIPT" || true)
[[ "$marker_count" == "1" ]] || \
  fail "структура официального скрипта изменилась: найдено маркеров installlocal: $marker_count"

log "SHA-256 официального скрипта: $(sha256sum "$OFFICIAL_SCRIPT" | awk '{print $1}')"
log "Создаю временную версию без Endpoint Manager"

awk '
  BEGIN { inserted = 0 }
  $0 ~ /^[[:space:]]*setCurrentStep "Installing all local modules"[[:space:]]*$/ && inserted == 0 {
    print "  setCurrentStep \"Removing Endpoint Manager module\""
    print "  if command -v fwconsole >/dev/null 2>&1; then"
    print "    timeout --kill-after=15s 180s fwconsole ma -f remove endpoint >> \"$log\" 2>&1 || true"
    print "  fi"
    print "  rm -rf /var/www/html/admin/modules/endpoint"
    print "  if [ -d /var/www/html/admin/modules/endpoint ]; then"
    print "    message \"Failed to remove Endpoint Manager module directory\""
    print "    exit 1"
    print "  fi"
    print "  message \"Endpoint Manager module excluded from this installation\""
    print ""
    inserted = 1
  }
  { print }
  END {
    if (inserted != 1) {
      exit 42
    }
  }
' "$OFFICIAL_SCRIPT" > "$PATCHED_SCRIPT"

chmod 0700 "$PATCHED_SCRIPT"

grep -Fq 'Endpoint Manager module excluded from this installation' "$PATCHED_SCRIPT" || \
  fail "не удалось применить изменение"

log "SHA-256 изменённого скрипта: $(sha256sum "$PATCHED_SCRIPT" | awk '{print $1}')"
log "Изменённый скрипт сохранён: $PATCHED_SCRIPT"

if [[ "$DRY_RUN" == "true" ]]; then
  log "Проверка завершена. Запуск пропущен из-за --dry-run"
  exit 0
fi

log "Запускаю установку FreePBX 17 без Endpoint Manager"
exec bash "$PATCHED_SCRIPT" --skipversion "${OFFICIAL_ARGS[@]}"
