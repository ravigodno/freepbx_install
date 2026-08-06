#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
#
# FreePBX 17 installer wrapper without the commercial dependency chain
# sangomaconnect -> restapps -> endpoint.

set -Eeuo pipefail

readonly WRAPPER_VERSION="0.5.0"
readonly SANE_PATH="/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"
readonly OFFICIAL_URL="https://raw.githubusercontent.com/FreePBX/sng_freepbx_debian_install/master/sng_freepbx_debian_install.sh"
readonly WORK_DIR="/tmp/freepbx-install-no-endpoint"
readonly OFFICIAL_SCRIPT="${WORK_DIR}/sng_freepbx_debian_install.sh"
readonly PATCHED_SCRIPT="${WORK_DIR}/sng_freepbx_debian_install.no-endpoint.sh"
readonly PID_FILE="/var/run/freepbx17_installer.pid"
readonly APT_RETRY_CONFIG="/etc/apt/apt.conf.d/99freepbx-download-retry"
readonly INSTALLLOCAL_MARKER='setCurrentStep "Installing all local modules"'
readonly UPGRADE_STEP_MARKER='setCurrentStep "Upgrading FreePBX 17 modules"'
readonly UPGRADE_COMMAND_MARKER='fwconsole ma upgradeall >> "$log"'
readonly SIGNATURE_STEP_MARKER='setCurrentStep "Refreshing modules signatures."'
readonly SUCCESS_STEP_MARKER='setCurrentStep "FreePBX 17 Installation finished successfully."'

export PATH="$SANE_PATH"
export DEBIAN_FRONTEND=noninteractive

DRY_RUN=false
OFFICIAL_ARGS=()

usage() {
  cat <<'USAGE'
Использование:
  bash install.sh [--dry-run] [аргументы официального установщика]

Параметры wrapper:
  --dry-run    Скачать и подготовить изменённый скрипт, но не запускать его
               и не изменять системные настройки APT.
  -h, --help   Показать справку.
  -V, --version
               Показать версию wrapper.

Wrapper автоматически:
  - исключает sangomaconnect, restapps и endpoint;
  - пропускает upgradeall и refreshsignatures;
  - переводит deb.freepbx.org с HTTP на HTTPS;
  - включает повторы, IPv4 и увеличенные тайм-ауты APT.

Остальные параметры передаются официальному установщику FreePBX.
Параметр --skipversion добавляется автоматически.
USAGE
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

configure_apt_reliability() {
  log "Настраиваю устойчивую загрузку пакетов FreePBX через HTTPS"

  cat >"$APT_RETRY_CONFIG" <<'APTCONF'
Acquire::Retries "30";
Acquire::ForceIPv4 "true";
Acquire::http::Timeout "300";
Acquire::https::Timeout "300";
Acquire::http::Pipeline-Depth "0";
Acquire::https::Pipeline-Depth "0";
Acquire::Queue-Mode "access";
DPkg::Lock::Timeout "300";
APTCONF

  while IFS= read -r -d '' source_file; do
    sed -i 's#http://deb\.freepbx\.org#https://deb.freepbx.org#g' "$source_file"
  done < <(
    grep -RIlZ 'http://deb\.freepbx\.org' \
      /etc/apt/sources.list /etc/apt/sources.list.d 2>/dev/null || true
  )

  rm -f "$PID_FILE"
}

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

((EUID == 0)) || fail "запустите скрипт от root через su -"
[[ -r /etc/os-release ]] || fail "не найден /etc/os-release"

# shellcheck disable=SC1091
source /etc/os-release
[[ "${ID:-}" == "debian" && "${VERSION_ID:-}" == "12" ]] || \
  fail "поддерживается только Debian 12; обнаружено: ${PRETTY_NAME:-неизвестно}"

for command_name in wget awk grep sed sha256sum pgrep timeout install; do
  command -v "$command_name" >/dev/null 2>&1 || \
    fail "не найдена обязательная команда: $command_name; PATH=$PATH"
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
log "Создаю временную версию без коммерческой цепочки и с HTTPS-репозиторием"

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
' "$OFFICIAL_SCRIPT" >"$PATCHED_SCRIPT"

sed -i 's#http://deb\.freepbx\.org#https://deb.freepbx.org#g' "$PATCHED_SCRIPT"
chmod 0700 "$PATCHED_SCRIPT"

grep -Fq 'Modules sangomaconnect, restapps and endpoint excluded from this installation' "$PATCHED_SCRIPT" || \
  fail "не удалось добавить исключение модулей"
grep -Fq 'Bulk module upgrade skipped: sangomaconnect/restapps/endpoint are excluded' "$PATCHED_SCRIPT" || \
  fail "не удалось заменить массовое обновление"
grep -Fq 'Bulk signature refresh skipped: it would reinstall sangomaconnect -> restapps -> endpoint' "$PATCHED_SCRIPT" || \
  fail "не удалось отключить массовое обновление подписей"
grep -Fq 'https://deb.freepbx.org' "$PATCHED_SCRIPT" || \
  fail "в официальном скрипте не найден HTTPS-репозиторий FreePBX"

if grep -Fq 'http://deb.freepbx.org' "$PATCHED_SCRIPT"; then
  fail "в изменённом скрипте остался HTTP-репозиторий FreePBX"
fi
if grep -Eq '^[[:space:]]*fwconsole ma upgradeall([[:space:]]|$)' "$PATCHED_SCRIPT"; then
  fail "в изменённом скрипте осталась активная команда upgradeall"
fi
if grep -Eq '^[[:space:]]*refresh_signatures([[:space:]&]|$)' "$PATCHED_SCRIPT"; then
  fail "в изменённом скрипте остался активный вызов refresh_signatures"
fi

log "SHA-256 изменённого скрипта: $(sha256sum "$PATCHED_SCRIPT" | awk '{print $1}')"
log "Изменённый скрипт сохранён: $PATCHED_SCRIPT"

if [[ "$DRY_RUN" == "true" ]]; then
  log "Проверка завершена. Запуск и изменение APT пропущены из-за --dry-run"
  exit 0
fi

configure_apt_reliability

log "Запускаю установку FreePBX 17 через HTTPS без проблемной коммерческой цепочки"
exec bash "$PATCHED_SCRIPT" --skipversion "${OFFICIAL_ARGS[@]}"
