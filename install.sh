#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
#
# FreePBX 17 installer wrapper without the commercial dependency chain
# sangomaconnect -> restapps -> endpoint.

set -Eeuo pipefail

readonly WRAPPER_VERSION="0.4.0"
readonly OFFICIAL_URL="https://raw.githubusercontent.com/FreePBX/sng_freepbx_debian_install/master/sng_freepbx_debian_install.sh"
readonly WORK_DIR="/tmp/freepbx-install-no-endpoint"
readonly OFFICIAL_SCRIPT="${WORK_DIR}/sng_freepbx_debian_install.sh"
readonly PATCHED_SCRIPT="${WORK_DIR}/sng_freepbx_debian_install.no-endpoint.sh"
readonly INSTALLLOCAL_MARKER='setCurrentStep "Installing all local modules"'
readonly UPGRADE_STEP_MARKER='setCurrentStep "Upgrading FreePBX 17 modules"'
readonly UPGRADE_COMMAND_MARKER='fwconsole ma upgradeall >> "$log"'
readonly SIGNATURE_STEP_MARKER='setCurrentStep "Refreshing modules signatures."'
readonly SUCCESS_STEP_MARKER='setCurrentStep "FreePBX 17 Installation finished successfully."'

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
  if ((exit_code != 0)); then
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

((EUID == 0)) || fail "запустите скрипт от root: su -"
[[ -r /etc/os-release ]] || fail "не найден /etc/os-release"

# shellcheck disable=SC1091
source /etc/os-release
[[ "${ID:-}" == "debian" && "${VERSION_ID:-}" == "12" ]] || \
  fail "поддерживается только Debian 12; обнаружено: ${PRETTY_NAME:-неизвестно}"

for command_name in wget awk grep sha256sum pgrep timeout; do
  command -v "$command_name" >/dev/null 2>&1 || \
    fail "не найдена обязательная команда: $command_name"
done

if pgrep -af '[s]ng_freepbx_debian_install[^ ]*\.sh|[f]wconsole ma (upgradeall|refreshsignatures|install|installlocal)' >/dev/null 2>&1; then
  pgrep -af '[s]ng_freepbx_debian_install[^ ]*\.sh|[f]wconsole ma (upgradeall|refreshsignatures|install|installlocal)' >&2 || true
  fail "обнаружен уже запущенный установщик или менеджер модулей FreePBX"
fi

install -d -m 0700 "$WORK_DIR"
rm -f "$OFFICIAL_SCRIPT" "$PATCHED_SCRIPT"

log "Скачиваю актуальный официальный установщик FreePBX 17"
wget --https-only --secure-protocol=TLSv1_2 --timeout=30 --tries=3 \
  "$OFFICIAL_URL" -O "$OFFICIAL_SCRIPT"

[[ -s "$OFFICIAL_SCRIPT" ]] || fail "официальный скрипт скачан пустым"
grep -q '^#!/bin/bash' "$OFFICIAL_SCRIPT" || fail "неожиданное содержимое официального скрипта"

installlocal_count=$(grep -F -c "$INSTALLLOCAL_MARKER" "$OFFICIAL_SCRIPT" || true)
upgrade_step_count=$(grep -F -c "$UPGRADE_STEP_MARKER" "$OFFICIAL_SCRIPT" || true)
upgrade_command_count=$(grep -F -c "$UPGRADE_COMMAND_MARKER" "$OFFICIAL_SCRIPT" || true)
signature_step_count=$(grep -F -c "$SIGNATURE_STEP_MARKER" "$OFFICIAL_SCRIPT" || true)
success_step_count=$(grep -F -c "$SUCCESS_STEP_MARKER" "$OFFICIAL_SCRIPT" || true)

[[ "$installlocal_count" == "1" ]] || fail "структура официального скрипта изменилась: installlocal-маркеров $installlocal_count"
[[ "$upgrade_step_count" == "1" ]] || fail "структура официального скрипта изменилась: upgrade-шагов $upgrade_step_count"
[[ "$upgrade_command_count" == "1" ]] || fail "структура официального скрипта изменилась: upgradeall-команд $upgrade_command_count"
[[ "$signature_step_count" == "1" ]] || fail "структура официального скрипта изменилась: signature-шагов $signature_step_count"
[[ "$success_step_count" == "1" ]] || fail "структура официального скрипта изменилась: success-шагов $success_step_count"

log "SHA-256 официального скрипта: $(sha256sum "$OFFICIAL_SCRIPT" | awk '{print $1}')"
log "Создаю временную версию без sangomaconnect/restapps/endpoint, upgradeall и refreshsignatures"

awk '
  BEGIN {
    inserted_exclusions = 0
    replaced_upgrade_step = 0
    removed_upgrade_command = 0
    expect_upgrade_command = 0
    skipping_signature_block = 0
    skipped_signature_block = 0
  }

  skipping_signature_block == 1 {
    if ($0 ~ /^[[:space:]]*setCurrentStep "FreePBX 17 Installation finished successfully\."[[:space:]]*$/) {
      skipping_signature_block = 0
      skipped_signature_block = 1
      print
    }
    next
  }

  expect_upgrade_command == 1 {
    if ($0 ~ /^[[:space:]]*fwconsole ma upgradeall >> "\$log"[[:space:]]*$/) {
      print "  message \"Bulk module upgrade skipped: sangomaconnect/restapps/endpoint are excluded\""
      removed_upgrade_command = 1
      expect_upgrade_command = 0
      next
    }
    exit 43
  }

  $0 ~ /^[[:space:]]*setCurrentStep "Installing all local modules"[[:space:]]*$/ && inserted_exclusions == 0 {
    print "  setCurrentStep \"Excluding Sangoma Connect, RestApps and Endpoint Manager\""
    print "  for excluded_module in sangomaconnect restapps endpoint; do"
    print "    if command -v fwconsole >/dev/null 2>&1; then"
    print "      timeout --kill-after=15s 180s fwconsole ma -f remove \"$excluded_module\" >> \"$log\" 2>&1 || true"
    print "    fi"
    print "    rm -rf \"/var/www/html/admin/modules/$excluded_module\""
    print "  done"
    print "  message \"Modules sangomaconnect, restapps and endpoint excluded from this installation\""
    print ""
    inserted_exclusions = 1
    print
    next
  }

  $0 ~ /^[[:space:]]*setCurrentStep "Upgrading FreePBX 17 modules"[[:space:]]*$/ && replaced_upgrade_step == 0 {
    print "  setCurrentStep \"Skipping bulk FreePBX module upgrade\""
    replaced_upgrade_step = 1
    expect_upgrade_command = 1
    next
  }

  $0 ~ /^[[:space:]]*setCurrentStep "Refreshing modules signatures\."[[:space:]]*$/ && skipping_signature_block == 0 {
    print "setCurrentStep \"Skipping bulk module signature refresh\""
    print "message \"Bulk signature refresh skipped: it would reinstall sangomaconnect -> restapps -> endpoint\""
    skipping_signature_block = 1
    next
  }

  { print }

  END {
    if (inserted_exclusions != 1 ||
        replaced_upgrade_step != 1 ||
        removed_upgrade_command != 1 ||
        skipped_signature_block != 1 ||
        expect_upgrade_command != 0 ||
        skipping_signature_block != 0) {
      exit 42
    }
  }
' "$OFFICIAL_SCRIPT" > "$PATCHED_SCRIPT"

chmod 0700 "$PATCHED_SCRIPT"

grep -Fq 'Modules sangomaconnect, restapps and endpoint excluded from this installation' "$PATCHED_SCRIPT" || \
  fail "не удалось добавить исключение модулей"
grep -Fq 'Bulk module upgrade skipped: sangomaconnect/restapps/endpoint are excluded' "$PATCHED_SCRIPT" || \
  fail "не удалось заменить массовое обновление"
grep -Fq 'Bulk signature refresh skipped: it would reinstall sangomaconnect -> restapps -> endpoint' "$PATCHED_SCRIPT" || \
  fail "не удалось отключить массовое обновление подписей"

if grep -Eq '^[[:space:]]*fwconsole ma upgradeall([[:space:]]|$)' "$PATCHED_SCRIPT"; then
  fail "в изменённом скрипте осталась активная команда upgradeall"
fi
if grep -Eq '^[[:space:]]*refresh_signatures([[:space:]&]|$)' "$PATCHED_SCRIPT"; then
  fail "в изменённом скрипте остался активный вызов refresh_signatures"
fi

log "SHA-256 изменённого скрипта: $(sha256sum "$PATCHED_SCRIPT" | awk '{print $1}')"
log "Изменённый скрипт сохранён: $PATCHED_SCRIPT"

if [[ "$DRY_RUN" == "true" ]]; then
  log "Проверка завершена. Запуск пропущен из-за --dry-run"
  exit 0
fi

log "Запускаю установку FreePBX 17 без проблемной коммерческой цепочки"
exec bash "$PATCHED_SCRIPT" --skipversion "${OFFICIAL_ARGS[@]}"
