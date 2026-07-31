# freepbx_install

Неофициальный wrapper для установки **FreePBX 17 на Debian 12 без коммерческого Sangoma Endpoint Manager (`endpoint`)**.

Скрипты загружают актуальный официальный установщик FreePBX, проверяют ожидаемую структуру и создают временную изменённую копию. Официальный файл в репозитории не хранится.

## Зафиксированная проблема

Официальная установка может остановиться на массовом обновлении модулей:

```text
Upgrading FreePBX 17 modules
Upgrading module 'endpoint' ...
Checking Settings and Defaults...
```

После прерывания состояние обычно выглядит так:

```text
endpoint  17.0.3  Disabled; Pending upgrade to 17.0.16.3
```

Первая попытка просто удалить `endpoint` перед `upgradeall` оказалась недостаточной. Во время обновления `restapps` менеджер модулей обнаруживает отсутствующую зависимость и автоматически скачивает `endpoint` обратно:

```text
Upgrading module 'restapps' ...
Detected Missing Dependency of: endpoint
Downloading Missing Dependency of: endpoint
Installing Missing Dependency of: endpoint
Checking Settings and Defaults...
```

Поэтому версия 0.3.0 делает две обязательные вещи:

1. исключает одновременно `restapps` и `endpoint`;
2. полностью пропускает `fwconsole ma upgradeall` во время установки.

Это позволяет официальному скрипту выполнить завершающие шаги, не возвращаясь к проблемной цепочке зависимостей.

## Файлы

### `install.sh`

Для новой установки. Скрипт:

- проверяет Debian 12 и права `root`;
- запрещает параллельный запуск установщиков;
- скачивает свежий официальный установщик;
- проверяет наличие ожидаемых команд `installlocal` и `upgradeall`;
- удаляет `restapps` и `endpoint` перед `installlocal`;
- заменяет массовый `upgradeall` на информационное сообщение;
- запускает оставшуюся официальную установку с `--skipversion`.

### `resume.sh`

Для частично установленной системы после зависания официального скрипта. Скрипт:

- собирает диагностику и копию последнего журнала;
- в режиме `--dry-run` ничего не изменяет;
- с флагом `--stop-stuck` останавливает только известные процессы установщика, `upgradeall`, `restapps` и `endpoint`;
- завершает незаконченные операции `dpkg`;
- сохраняет резервные копии и удаляет `restapps`/`endpoint`;
- скачивает актуальный `install.sh`;
- продолжает установку без массового обновления модулей;
- проверяет `fwconsole` и основные службы.

## Новая установка

```bash
su -
cd /tmp
wget "https://raw.githubusercontent.com/ravigodno/freepbx_install/main/install.sh?$(date +%s)" \
  -O install-freepbx17.sh
chmod +x install-freepbx17.sh
bash install-freepbx17.sh --dry-run
bash install-freepbx17.sh
```

Перед запуском убедитесь, что версия актуальная:

```bash
bash /tmp/install-freepbx17.sh --version
```

Ожидается:

```text
0.3.0
```

## Доустановка после зависания

Скачать актуальный скрипт восстановления:

```bash
su -
cd /tmp
wget "https://raw.githubusercontent.com/ravigodno/freepbx_install/main/resume.sh?$(date +%s)" \
  -O resume-freepbx17.sh
chmod +x resume-freepbx17.sh
bash resume-freepbx17.sh --version
```

Ожидается версия `0.3.0`.

Безопасная диагностика:

```bash
bash /tmp/resume-freepbx17.sh --dry-run
```

Если процессы зависшей установки ещё активны и журнал действительно перестал изменяться:

```bash
bash /tmp/resume-freepbx17.sh --stop-stuck
```

Если процессов уже нет:

```bash
bash /tmp/resume-freepbx17.sh
```

## Проверка журнала перед остановкой процессов

```bash
LOG=$(ls -1t /var/log/pbx/freepbx17-install-*.log | head -1)
stat -c 'Изменён: %y Размер: %s байт' "$LOG"
tail -n 50 "$LOG"
pgrep -af 'sng_freepbx_debian_install|fwconsole ma|endpoint|restapps'
```

## Резервные копии

`resume.sh` создаёт каталог:

```text
/root/freepbx-install-recovery-YYYYMMDD-HHMMSS/
```

В него сохраняются:

- диагностика системы;
- последний журнал установки и его хвост;
- архивы каталогов `restapps` и `endpoint`;
- журналы штатного удаления модулей;
- оставшиеся каталоги модулей, если штатное удаление их не убрало.

## Проверка после завершения

```bash
/usr/sbin/fwconsole --version
/usr/sbin/fwconsole ma list | grep -iE 'endpoint|restapps|framework|core'
systemctl is-active asterisk freepbx apache2 mariadb
```

Ожидается:

- `framework` и `core` включены;
- `endpoint` и `restapps` отсутствуют либо не установлены;
- `asterisk`, `freepbx`, `apache2`, `mariadb` активны.

## Важные ограничения

- Без `endpoint` нельзя использовать функции Endpoint Manager.
- `restapps` исключается, потому что его установка автоматически возвращает зависимость `endpoint`.
- Массовое обновление модулей во время установки пропускается намеренно.
- После завершения модули следует обновлять выборочно и не устанавливать `endpoint`/`restapps`.
- Поддерживается только Debian 12.
- Проект не является продуктом Sangoma/FreePBX и не заменяет официальную поддержку.

## Лицензия

Код wrapper распространяется по MIT. Официальный установщик загружается отдельно и сохраняет собственную лицензию и авторские права.
