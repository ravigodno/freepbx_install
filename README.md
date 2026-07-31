# freepbx_install

Независимый wrapper для установки **FreePBX 17 на Debian 12 без коммерческого модуля Sangoma Endpoint Manager (`endpoint`)**.

> Это неофициальный проект и не является продуктом Sangoma Technologies или FreePBX. Wrapper скачивает актуальный официальный установщик FreePBX, создаёт временную локальную копию, исключает модуль `endpoint` и запускает установку.

## Зачем это нужно

На некоторых установках обновление модулей FreePBX 17 останавливается на Endpoint Manager на этапе:

```text
Upgrading module 'endpoint'
Checking Settings and Defaults...
```

При этом модуль остаётся в состоянии `Disabled; Pending upgrade`, а официальный установщик не переходит к завершающим действиям.

Этот wrapper:

1. проверяет, что система работает на Debian 12 и скрипт запущен от `root`;
2. запрещает запуск второй установки параллельно;
3. скачивает свежий официальный скрипт FreePBX;
4. проверяет ожидаемую структуру скрипта;
5. перед `fwconsole ma installlocal` удаляет `endpoint` и его каталог;
6. запускает остальные штатные шаги официального установщика;
7. сохраняет исходную и изменённую копии в `/tmp/freepbx-install-no-endpoint`.

## Быстрая установка

Войдите под `root` через полноценное окружение:

```bash
su -
```

Скачайте и запустите wrapper:

```bash
cd /tmp
wget https://raw.githubusercontent.com/ravigodno/freepbx_install/main/install.sh \
  -O install-freepbx17.sh
chmod +x install-freepbx17.sh
bash install-freepbx17.sh
```

## Предварительная проверка без установки

```bash
bash install-freepbx17.sh --dry-run
```

Wrapper скачает официальный скрипт, проверит и изменит его, но не запустит установку.

## Передача параметров официальному установщику

Все неизвестные wrapper параметры передаются официальному скрипту без изменений. Например:

```bash
bash install-freepbx17.sh --nochrony
```

Параметр `--skipversion` wrapper добавляет автоматически, поскольку локальная временная копия официального скрипта намеренно отличается от оригинала.

## Повторный запуск после зависания на `endpoint`

Сначала проверьте процессы:

```bash
pgrep -af 'sng_freepbx_debian_install|fwconsole ma|endpoint'
```

Если старый установщик действительно не меняет лог продолжительное время, завершите только связанные процессы:

```bash
pkill -TERM -f '[s]ng_freepbx_debian_install.sh' 2>/dev/null || true
pkill -TERM -f '[f]wconsole ma upgradeall' 2>/dev/null || true
pkill -TERM -f '[f]wconsole ma install endpoint' 2>/dev/null || true
sleep 10
pgrep -af 'sng_freepbx_debian_install|fwconsole ma|endpoint' || true
```

После остановки старого установщика:

```bash
rm -f /var/run/freepbx17_installer.pid
dpkg --configure -a
apt-get -f install -y
bash /tmp/install-freepbx17.sh
```

Официальный установщик повторно проверяет уже установленные пакеты, поэтому завершённые пакетные этапы обычно не устанавливаются заново.

## Проверка после установки

```bash
/usr/sbin/fwconsole --version
/usr/sbin/fwconsole ma list | grep -iE 'endpoint|framework|core'
systemctl --no-pager --full status asterisk freepbx apache2 mariadb
```

Ожидается, что `framework` и `core` включены, а `endpoint` отсутствует либо не установлен.

## Что не устанавливается

Исключается только модуль:

```text
endpoint — Sangoma Endpoint Manager
```

Он используется для централизованного provisioning поддерживаемых IP-телефонов. Маршрутизация звонков, внутренние номера, транки, очереди, CDR и основные функции FreePBX от него не зависят.

## Ограничения

- Поддерживается только Debian 12, как и в текущем официальном установщике FreePBX 17.
- Wrapper зависит от структуры официального скрипта. Если Sangoma изменит нужный участок, wrapper остановится до запуска установки.
- Установка выполняется с правами `root` и меняет системные пакеты и конфигурацию. Используйте резервную копию или снимок виртуальной машины.
- Проект не предоставляет гарантий и не заменяет официальную поддержку FreePBX/Sangoma.

## Лицензии

Код wrapper распространяется по лицензии MIT. Официальный установщик FreePBX загружается отдельно во время выполнения и сохраняет собственные авторские права и лицензию.
