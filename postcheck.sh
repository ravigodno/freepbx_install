#!/usr/bin/env bash
# SPDX-License-Identifier: MIT

set -Eeuo pipefail

readonly POSTCHECK_VERSION="0.1.0"
readonly SANE_PATH="/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"
readonly FWCONSOLE="/usr/sbin/fwconsole"
readonly ASTERISK_BIN="/usr/sbin/asterisk"
readonly EXCLUDED_MODULE_PATTERN='^(sangomaconnect|restapps|endpoint)$'

export PATH="$SANE_PATH"

log() {
  printf '[freepbx_postcheck] %s\n' "$*"
}

fail() {
  printf '[freepbx_postcheck] ОШИБКА: %s\n' "$*" >&2
  exit 1
}

((EUID == 0)) || fail "запустите от root через su -"
[[ -x "$FWCONSOLE" ]] || fail "не найден $FWCONSOLE"
[[ -x "$ASTERISK_BIN" ]] || fail "не найден $ASTERISK_BIN"

log "Версия проверки: $POSTCHECK_VERSION"
log "Проверяю состояние пакетной системы"

dpkg-query -W -f='${Package}\t${db:Status-Abbrev}\t${Status}\t${Version}\n' \
  nodejs sangoma-pbx17 freepbx17 2>&1 || true

dpkg --audit || true
apt-get check

log "Проверяю базовые модули FreePBX"
timeout 60 "$FWCONSOLE" --version
timeout 60 "$FWCONSOLE" ma list | grep -iE 'sangomaconnect|restapps|endpoint|framework|core' || true

log "Отключаю оставшиеся задания исключённых модулей"
mapfile -t excluded_job_ids < <(
  timeout 60 "$FWCONSOLE" job --list 2>/dev/null |
    awk -F'|' -v pattern="$EXCLUDED_MODULE_PATTERN" '
      {
        id=$2
        module=$3
        gsub(/^[[:space:]]+|[[:space:]]+$/, "", id)
        gsub(/^[[:space:]]+|[[:space:]]+$/, "", module)
        if (id ~ /^[0-9]+$/ && module ~ pattern) {
          print id
        }
      }
    '
)

for job_id in "${excluded_job_ids[@]}"; do
  log "Отключаю задание ID $job_id"
  timeout 60 "$FWCONSOLE" job --disable "$job_id" || true
done

log "Проверяю процесс Asterisk"
if ! pgrep -x asterisk >/dev/null 2>&1; then
  log "Asterisk не запущен; выполняю fwconsole chown и fwconsole start"
  timeout 300 "$FWCONSOLE" chown
  timeout 180 "$FWCONSOLE" start
  sleep 5
fi

pgrep -a -x asterisk || fail "процесс Asterisk не запущен после fwconsole start"
timeout 30 "$ASTERISK_BIN" -rx 'core show version'
timeout 30 "$ASTERISK_BIN" -rx 'core show uptime'

log "Проверяю активные службы"
for service_name in freepbx apache2 mariadb; do
  systemctl is-active --quiet "$service_name" || fail "служба не активна: $service_name"
  log "Служба активна: $service_name"
done

log "Проверяю HTTP"
curl -fsS --max-time 15 -o /dev/null http://127.0.0.1/ || fail "веб-интерфейс не отвечает на http://127.0.0.1/"

log "Проверка завершена успешно"
