# 🌐 Автоматическая установка Xray (VLESS TCP / gRPC) & Hysteria 2 с поддержкой подписок, WARP и Opera Proxy

<p align="center">
  <img src="https://img.shields.io/badge/Xray-Core%20v1.8.0+-blue?style=for-the-badge&logo=linux&logoColor=white" alt="Xray Version">
  <img src="https://img.shields.io/badge/Hysteria-2--latest-cyan?style=for-the-badge" alt="Hysteria Version">
  <img src="https://img.shields.io/badge/Security-XTLS--Vision%20%2F%20gRPC-brightgreen?style=for-the-badge" alt="Security Protocols">
  <img src="https://img.shields.io/badge/WARP-Smart%20%2F%20Full%20Routing-purple?style=for-the-badge" alt="WARP Routing">
  <img src="https://img.shields.io/badge/Opera--Proxy-OpenAI%20Bypass-orange?style=for-the-badge" alt="Opera Proxy">
</p>

Скрипт `install_xray.sh` — решение «всё в одном» (All-in-One) для быстрой развертки и автоматической настройки прокси-серверов **VLESS TCP XTLS-Vision**, **VLESS gRPC** и **Hysteria 2** на вашем VPS.

Проект спроектирован с упором на надежность, максимальную скорость обхода DPI-блокировок и простоту администрирования. Главная особенность: скрипт безопасен для параллельной установки на один сервер с VPN-комплексами вроде **AntiZapret**.

---

## 🛠️ Технологический стек (Tech Stack)

- **Языки и автоматизация**: Bash 5.x, Python 3 (для сервера подписок)
- **Прокси-ядра**: Xray-core (VLESS + XTLS-Vision на порту 443, VLESS + gRPC на порту 8443), Hysteria 2 (UDP QUIC на порту 443)
- **Поддерживаемые ОС**: Debian 11 / 12 / 13, Ubuntu 20.04 / 22.04 / 24.04 (x86_64)
- **Ядро и Сеть**: Xanmod Kernel (x64v1-v3), TCP BBR, ZRAM (LZ4) + Disk Swap, PMTU MSS Clamping, Systemd/Journald Tuning
- **Маршрутизация и обход**: Cloudflare WARP (WireGuard), Opera Residential SOCKS5 Proxy, списки блокировок Роскомнадзора (Geoblock)
- **Маскировка (Decoy)**: Локальный веб-сервер с имитацией портала Atlassian Confluence (RU/EN)

---

## 📋 Требования к серверу (Prerequisites)

1. **Операционная система**: Чистая Debian 11/12/13 или Ubuntu 20.04/22.04/24.04 с правами `root`.
2. **Домен и DNS**: Зарегистрированный домен с настроенной **A-записью**, указывающей на публичный IPv4-адрес вашего VPS (например, `sub.domain.com -> 1.2.3.4`).
3. **Открытые порты**:
   - `80/tcp` — получение SSL-сертификата Let's Encrypt / Certbot.
   - `443/tcp` — вход VLESS TCP XTLS-Vision.
   - `443/udp` — вход Hysteria 2 (QUIC).
   - `8443/tcp` — вход VLESS gRPC (запасной/резервный протокол).

---

## 📐 Архитектура трафика (Architecture)

```text
               ┌────────────────────────────────────────────────────────┐
               │              Входящий трафик клиентов                 │
               └───────────────────┬────────────────────────────────────┘
                                   │ (Порт 443 TCP / 443 UDP / 8443 TCP)
                                   ▼
                       ┌───────────────────────┐
                       │  Xray-core / Hysteria2 │
                       └───────────┬───────────┘
                                   │
         ┌─────────────────────────┼─────────────────────────┐
         │ (Российские ресурсы)    │ (Блокировки РКН / IP)   │ (OpenAI / Claude)
         ▼                         ▼                         ▼
┌──────────────────┐    ┌────────────────────┐    ┌─────────────────────┐
│ Прямой исходящий │    │  Cloudflare WARP   │    │     Opera Proxy     │
│   трафик VPS     │    │  (WireGuard tun)   │    │  (SOCKS5 40001)     │
└──────────────────┘    └────────────────────┘    └─────────────────────┘
```

---

## ✨ Ключевые возможности

* 🚀 **Протокол VLESS TCP XTLS-Vision (Порт 443 TCP)**: Маскирует прокси-трафик под легитимное TLS 1.3 соединение. Случайный отпечаток TLS (`fp=random` по умолчанию, с возможностью ручного выбора `chrome`, `ios`, `firefox`).
* ⚡ **Hysteria 2 (Порт 443 UDP)**: Ультра-быстрый протокол на базе UDP/QUIC для работы в нестабильных мобильных сетях. Поддерживает автоматическую настройку без оверинжиниринга.
* 🚀 **Протокол VLESS gRPC (Порт 8443 TCP)**: Надежный резервный канал поверх gRPC и TLS с поддержкой мультиплексирования.
* 📱 **Динамический сервер подписок (Base64)**: Локальный Python-демон раздает автоматически генерируемые подписки (`https://ваш-домен.com/sub/UUID`). Нативно поддерживается клиентами **Happ**, **Incy**, **Hiddify**, **v2rayN**, **Shadowrocket**, **Clash/Mihomo**, **SingBox**.
* 🌀 **Интеллектуальный обход блокировок через Cloudflare WARP**:
  * **Smart (Рекомендуемый)**: Заворачивает в WARP только заблокированные домены РФ и детекторы утечки IP.
  * **Full**: Заворачивает весь исходящий трафик сервера через Cloudflare.
* 🌀 **Opera Proxy для OpenAI / ChatGPT и Claude**: Обходит блокировки провайдеров и защиту Cloudflare/OpenAI за счет маршрутизации через домашние прокси-узлы.
* ⚡ **Комплексная оптимизация VPS**:
  * **Гибридная память**: ZRAM (50-60% RAM с LZ4) + 2GB Disk Swap.
  * **Сетевой стек**: Тюнинг `sysctl` (`fs.file-max=67M`, BBR, TCP Fast Open, очереди до 32MB).
  * **PMTU Fix**: Автоматический TCP MSS Clamping против зависаний пакетов.
  * **Ядро Xanmod**: Автовыбор архитектуры CPU (v1-v3).

---

## 🛠️ Быстрый старт

Установка выполняется одной командой:

```bash
curl -fsSL "https://raw.githubusercontent.com/mvrvntn/xray-vless-install/main/install_xray.sh?v=$(date +%s)" -o /tmp/install_xray.sh && sudo bash /tmp/install_xray.sh
```

---

## 🖥️ Дашборд управления `xry`

После завершения установки введите в терминале:

```bash
xry
```

Откроется дашборд администратора:

```text
┌────────────────────────────────────────────────────────┐
│  Сервер: sub.domain.com
│  Службы: Xray: [🟢 ACTIVE] | Hysteria 2: [🟢 ACTIVE] | Sub-Server: [🟢 ACTIVE]
│  Обход:  WARP: [🟢 ON (SMART)] | Opera Proxy: [🟢 ON]
│  Клиенты: Активных устройств: 3
└────────────────────────────────────────────────────────┘
┌────────────────────────────────────────────────────────┐
│                      ГЛАВНОЕ МЕНЮ                      │
└────────────────────────────────────────────────────────┘
 1. 📱 Показать QR-коды и ссылки подключения
 2. 👤 Добавить нового пользователя / устройство
 3. 🗑️ Удалить существующего пользователя
 4. 🌀 Управление обходами блокировок (WARP & Opera Proxy)
 5. 📰 Просмотреть системные логи служб
 6. 📊 Мониторинг active-соединений (порты 443 / 8443)
 7. 🛠️ Запустить полную диагностику системы (Troubleshooting)
 8. 🔄 Обновить скрипт с GitHub и применить новые фиксы
 9. 🌐 Изменить отпечаток TLS (Fingerprint)
 10. 🌐 Смена основного домена (SSL)
 11. 🔑 Управление Provider ID (happ-proxy.com)
 12. 🗑️ Полностью удалить всю установку Xray с сервера
 13. 🚪 Выйти из терминала
──────────────────────────────────────────────────────────
Выберите действие (1-13):
```

---

## 🛠️ Дополнительные режимы запуска

### Headless-режим (Автоматическая установка без вопросов)

```bash
sudo bash install_xray.sh --headless <домен> <email> <кол-во_устройств> [имена_устройств...]
```

*Пример:*
```bash
sudo bash install_xray.sh --headless vpn.mysite.com admin@mail.com 3 "iPhone" "Macbook" "HomePC"
```

### Ручное обновление списков блокировок

```bash
sudo bash install_xray.sh --update-geoblocks
```

---

## 🤝 Совместимость с AntiZapret-VPN

Проект полностью совместим с **AntiZapret-VPN** на одном VPS. 

Инсталлятор автоматически обнаруживает AntiZapret, отключает UFW (чтобы не сломать правила NAT `iptables` AntiZapret) и безопасно добавляет порты Xray/Hysteria напрямую в цепочки `iptables`.

---

## 📂 Расположение файлов на сервере

| Назначение | Путь к файлу / директории |
|---|---|
| 💾 Конфигурация Xray | `/usr/local/etc/xray/config.json` |
| ⚡ Конфигурация Hysteria 2 | `/etc/hysteria/config.yaml` |
| 🌐 SSL-сертификаты | `/etc/ssl/vless/` |
| 🔒 Скрипт автопродления SSL | `/usr/local/bin/xray-cert-renew.sh` |
| 👥 Профили пользователей | `/etc/xray/client_configs/*.json` |
| 🔑 Утилита управления | `/usr/local/bin/xry` |
| ⚙️ Демон подписок | `/usr/local/bin/xray_sub_server.py` |
| 🔄 Служба подписок Systemd | `/etc/systemd/system/xray-sub.service` |
| 📝 Логи Xray | `/var/log/xray/` |

---

## 🛑 Удаление

Для полного удаления всех компонентов выберите пункт **`12`** в меню `xry`. Скрипт очистит службы, конфигурации и cron-задачи без затрагивания сторонних сервисов сервера.
