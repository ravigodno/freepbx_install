# freepbx_install

Неофициальный wrapper для установки **FreePBX 17 на Debian 12 без проблемной коммерческой цепочки**:

```text
sangomaconnect → restapps → endpoint
```

Скрипты загружают актуальный официальный установщик FreePBX, проверяют его структуру и создают временную изменённую копию. Официальный установщик в этом репозитории не хранится.

## Зафиксированная проблема

Официальная установка может остановиться на Endpoint Manager:

```text
Installing Missing Dependency of: endpoint
Checking database tables...Done
Migrating tables as required...Done
Checking Settings and Defaults...
```

Выявлены две цепочки, которые повторно устанавливают удалённый `endpoint`.

### Через массовое обновление модулей

```text
fwconsole ma upgradeall
  restapps
    Detected Missing Dependency of: endpoint
```

### Через финальное обновление подписей

```text
fwconsole ma refreshsignatures
  sangomaconnect
    Detected Missing Dependency of: restapps
      Detected Missing Dependency of: endpoint
```

Поэтому простого удаления `endpoint` недостаточно.

## Что делает версия 0.4.0

`install.sh`:

1. исключает `sangomaconnect`, `restapps` и `endpoint` до `installlocal`;
2. полностью пропускает `fwconsole ma upgradeall`;
3. полностью пропускает массовый `fwconsole ma refreshsignatures`;
4. проверяет, что активные вызовы этих операций действительно удалены из временного скрипта;
5. продолжает остальные официальные этапы установки и проверки.

`resume.sh` предназначен для системы, где официальный или предыдущий изменённый установщик уже завис. Он:

- сохраняет диагностику и последний журнал;
- с `--stop-stuck` останавливает только известные процессы установщика, `upgradeall`, `refreshsignatures`, `sangomaconnect`, `restapps` и `endpoint`;
- сохраняет резервные копии трёх исключаемых модулей;
- удаляет их штатно и убирает оставшиеся каталоги;
- загружает `install.sh` версии 0.4.0;
- повторно запускает установку без обеих проблемных цепочек;
- проверяет FreePBX и основные службы.

## Новая установка

```bash
su -
cd /tmp
wget "https://raw.githubusercontent.com/ravigodno/freepbx_install/main/install.sh?$(date +%s)" \
  -O install-freepbx17.sh
chmod +x install-freepbx17.sh
bash install-freepbx17.sh --version
bash install-freepbx17.sh --dry-run
bash install-freepbx17.sh
```

Ожидаемая версия:

```text
0.4.0
```

## Доустановка после зависания

```bash
su -
cd /tmp
wget "https://raw.githubusercontent.com/ravigodno/freepbx_install/main/resume.sh?$(date +%s)" \
  -O resume-freepbx17.sh
chmod +x resume-freepbx17.sh
bash resume-freepbx17.sh --version
bash resume-freepbx17.sh --dry-run
```

Если процессы зависшей установки ещё активны и журнал перестал изменяться:

```bash
bash /tmp/resume-freepbx17.sh --stop-stuck
```

Если активных процессов уже нет:

```bash
bash /tmp/resume-freepbx17.sh
```

## Диагностика зависания

```bash
LOG=$(ls -1t /var/log/pbx/freepbx17-install-*.log | head -1)
stat -c 'Изменён: %y Размер: %s байт' "$LOG"
tail -n 80 "$LOG"
pgrep -af 'sng_freepbx_debian_install|fwconsole ma|sangomaconnect|restapps|endpoint'
```

## Резервные копии

`resume.sh` создаёт каталог:

```text
/root/freepbx-install-recovery-YYYYMMDD-HHMMSS/
```

В него сохраняются:

- диагностика системы;
- последний журнал установки и его хвост;
- архивы каталогов `sangomaconnect`, `restapps`, `endpoint`;
- журналы штатного удаления модулей;
- оставшиеся каталоги модулей, если штатное удаление их не убрало.

## Проверка после завершения

```bash
/usr/sbin/fwconsole --version
/usr/sbin/fwconsole ma list | grep -iE 'sangomaconnect|endpoint|restapps|framework|core'
systemctl is-active asterisk freepbx apache2 mariadb
curl -I --max-time 15 http://127.0.0.1/
```

Ожидается:

- `framework` и `core` включены;
- `sangomaconnect`, `restapps`, `endpoint` отсутствуют либо не установлены;
- `asterisk`, `freepbx`, `apache2`, `mariadb` активны.

## Ограничения

- Без `endpoint` недоступен Endpoint Manager.
- Без `restapps` и `sangomaconnect` недоступны связанные коммерческие приложения Sangoma для телефонов и Sangoma Connect.
- Массовые `upgradeall` и `refreshsignatures` во время установки пропускаются намеренно.
- После установки модули следует обновлять выборочно, не устанавливая исключённую цепочку.
- Поддерживается только Debian 12.
- Проект не является продуктом Sangoma/FreePBX и не заменяет официальную поддержку.

## Лицензия

Код wrapper распространяется по MIT. Официальный установщик загружается отдельно и сохраняет собственную лицензию и авторские права.
