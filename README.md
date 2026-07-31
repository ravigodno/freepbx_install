# freepbx_install

Независимый wrapper для установки **FreePBX 17 на Debian 12 без коммерческого модуля Sangoma Endpoint Manager (`endpoint`)**.

> Это неофициальный проект и не является продуктом Sangoma Technologies или FreePBX. Скрипты используют актуальный официальный установщик FreePBX, но исключают проблемный модуль `endpoint`.

## Зафиксированная проблема

На чистой установке Debian 12 официальный установщик может успешно установить пакеты `sangoma-pbx17`, `ffmpeg`, `freepbx17` и перейти к этапу:

```text
Upgrading FreePBX 17 modules
```

После этого обновление Endpoint Manager доходит до:

```text
Upgrading module 'endpoint' from 17.0.3 to 17.0.16.3
Downloading module 'endpoint'
...
Checking database tables...Done
Migrating tables as required...Done
Checking Settings and Defaults...
```

Дальнейшего вывода нет, а журнал установки перестаёт изменяться. При этом остаются процессы вида:

```text
php /usr/sbin/fwconsole ma upgradeall
sh -c /usr/sbin/fwconsole ma install 'endpoint'
php /usr/sbin/fwconsole ma install endpoint
```

Состояние модулей после прерывания может выглядеть так:

```text
core       17.0.18.49  Enabled
framework  17.0.30     Enabled
endpoint   17.0.3      Disabled; Pending upgrade to 17.0.16.3
```

То есть сам FreePBX уже частично установлен, но официальный скрипт не выполняет завершающие шаги после `fwconsole ma upgradeall`.

## Что находится в репозитории

### `install.sh`

Используется для новой установки. Он:

1. проверяет Debian 12 и права `root`;
2. запрещает параллельный запуск установщиков;
3. скачивает свежий официальный скрипт FreePBX;
4. проверяет ожидаемую структуру официального скрипта;
5. исключает `endpoint` перед `fwconsole ma installlocal`;
6. запускает остальные штатные шаги официального установщика.

### `resume.sh`

Используется, если установка уже запускалась официальным скриптом и зависла на `endpoint`. Он:

1. проверяет наличие установленного пакета `freepbx17` и `/usr/sbin/fwconsole`;
2. сохраняет диагностику и журнал в `/root/freepbx-install-recovery-ДАТА-ВРЕМЯ`;
3. в режиме `--dry-run` ничего не останавливает и не меняет в системе;
4. по явному флагу `--stop-stuck` завершает только известные зависшие процессы;
5. сохраняет резервную копию каталога Endpoint Manager;
6. исключает `endpoint`;
7. запускает актуальный `install.sh`, чтобы официальный процесс повторно проверил уже установленные пакеты и выполнил оставшиеся шаги;
8. проверяет `fwconsole` и состояние основных служб.

## Новая установка

Сначала войдите в полноценное окружение `root`:

```bash
su -
```

Затем выполните:

```bash
cd /tmp
wget https://raw.githubusercontent.com/ravigodno/freepbx_install/main/install.sh \
  -O install-freepbx17.sh
chmod +x install-freepbx17.sh
bash install-freepbx17.sh --dry-run
bash install-freepbx17.sh
```

## Доустановка после зависания официального скрипта

### 1. Скачать `resume.sh`

```bash
cd /tmp
wget https://raw.githubusercontent.com/ravigodno/freepbx_install/main/resume.sh \
  -O resume-freepbx17.sh
chmod +x resume-freepbx17.sh
```

### 2. Выполнить безопасную диагностику

```bash
bash /tmp/resume-freepbx17.sh --dry-run
```

Скрипт покажет найденные процессы и сохранит диагностический каталог в `/root`. Процессы, пакеты и системная конфигурация не изменяются.

### 3. Если зависшие процессы ещё активны

Перед остановкой убедитесь, что размер и время изменения журнала не меняются:

```bash
LOG=$(ls -1t /var/log/pbx/freepbx17-install-*.log | head -1)
stat -c 'Изменён: %y Размер: %s байт' "$LOG"
tail -n 30 "$LOG"
```

После подтверждения зависания:

```bash
bash /tmp/resume-freepbx17.sh --stop-stuck
```

Флаг `--stop-stuck` останавливает только процессы, соответствующие следующим командам:

```text
sng_freepbx_debian_install.sh
fwconsole ma upgradeall
fwconsole ma install endpoint
```

Сначала отправляется `TERM`, затем после ожидания — `KILL` только оставшимся совпавшим процессам.

### 4. Если старые процессы уже остановлены

```bash
bash /tmp/resume-freepbx17.sh
```

## Важное замечание про `su -`

Команда:

```bash
su -
```

открывает новый login-shell `root`. После появления приглашения вида:

```text
root@server:~#
```

остальные команды нужно выполнять уже в этом новом shell. Именно `su -`, а не обычный `su`, добавляет `/usr/sbin` в `PATH`. При необходимости `fwconsole` всегда можно вызвать абсолютным путём:

```bash
/usr/sbin/fwconsole --version
```

## Где сохраняются резервные копии

`resume.sh` создаёт каталог:

```text
/root/freepbx-install-recovery-YYYYMMDD-HHMMSS/
```

В него попадают:

- общая диагностика системы;
- копия последнего журнала официальной установки;
- последние 200 строк журнала;
- вывод удаления `endpoint`;
- архив каталога модуля `endpoint`;
- оставшийся каталог модуля, если штатное удаление его не удалило.

## Проверка после установки

```bash
/usr/sbin/fwconsole --version
/usr/sbin/fwconsole ma list | grep -iE 'endpoint|framework|core'
systemctl --no-pager --full status asterisk freepbx apache2 mariadb
```

Ожидается, что `framework` и `core` включены, а `endpoint` отсутствует либо не установлен.

## Что не устанавливается

Исключается только:

```text
endpoint — Sangoma Endpoint Manager
```

Он используется для централизованного provisioning поддерживаемых IP-телефонов. Маршрутизация звонков, внутренние номера, транки, очереди, CDR и основные функции FreePBX от него не зависят.

## Ограничения

- Поддерживается только Debian 12, как и в текущем официальном установщике FreePBX 17.
- Скрипты зависят от структуры официального установщика. Если Sangoma изменит нужный участок, `install.sh` остановится до запуска установки.
- `resume.sh` предназначен только для частично установленного FreePBX, когда пакет `freepbx17` и `fwconsole` уже присутствуют.
- Проект не предоставляет гарантий и не заменяет официальную поддержку FreePBX/Sangoma.

## Лицензии

Код wrapper распространяется по лицензии MIT. Официальный установщик FreePBX загружается отдельно во время выполнения и сохраняет собственные авторские права и лицензию.
