# Graph Report - vless_server_instal  (2026-06-03)

## Corpus Check
- 7 files · ~13,265 words
- Verdict: corpus is large enough that graph structure adds value.

## Summary
- 75 nodes · 68 edges · 9 communities
- Extraction: 100% EXTRACTED · 0% INFERRED · 0% AMBIGUOUS
- Token cost: 0 input · 0 output

## Graph Freshness
- Built from commit: `24b4ffbf`
- Run `git rev-parse HEAD` and compare to check if the graph is stale.
- Run `graphify update .` after code changes (no API cost).

## Community Hubs (Navigation)
- [[_COMMUNITY_Community 1|Community 1]]
- [[_COMMUNITY_Community 2|Community 2]]
- [[_COMMUNITY_Community 3|Community 3]]

## God Nodes (most connected - your core abstractions)
1. `🌐 Автоматическая установка Xray (VLESS TCP XTLS-Vision) & Hysteria 2 с поддержкой подписок, WARP и Opera Proxy` - 9 edges
2. `🛠️ Дополнительные режимы запуска` - 4 edges
3. `🖥️ Управление сервером через интерактивную консоль `xry`` - 3 edges
4. `1. Headless-режим (быстрая установка одной строкой)` - 3 edges
5. `🤝 Совместная работа рядом с AntiZapret-VPN (на одном сервере)` - 3 edges
6. `📝 Пошаговая инструкция по параллельной установке:` - 3 edges
7. `Шаг 2. Установка VLESS TCP` - 3 edges
8. `Шаг 3. Исключение конфликта фаерволов` - 3 edges
9. `🛠️ Быстрый старт (для новичков)` - 2 edges
10. `2. Ручное обновление списков обхода геоблокировок` - 2 edges

## Surprising Connections (you probably didn't know these)
- None detected - all connections are within the same source files.

## Communities (9 total, 0 thin omitted)

### Community 1 - "Community 1"
Cohesion: 0.18
Nodes (10): ✨ Ключевые возможности проекта, 📂 Структура проекта на сервере, 🛑 Полное удаление проекта с сервера, 🛠️ Быстрый старт (для новичков), code:bash (curl -fsSL "https://raw.githubusercontent.com/mvrvntn/xray-v), code:bash (xry), code:text (┌────────────────────────────────────────────────────────┐), 🛠️ Встроенная система диагностики (Troubleshooting) (+2 more)

### Community 2 - "Community 2"
Cohesion: 0.2
Nodes (10): Почему они не мешают друг другу?, 📝 Пошаговая инструкция по параллельной установке:, Шаг 1. Освобождение порта 443 TCP в AntiZapret, Шаг 2. Установка VLESS TCP, Шаг 3. Исключение конфликта фаерволов, 🤝 Совместная работа рядом с AntiZapret-VPN (на одном сервере), code:bash (sudo reboot), code:bash (sudo systemctl stop openvpn-server@antizapret-tcp openvpn-se) (+2 more)

### Community 3 - "Community 3"
Cohesion: 0.29
Nodes (7): 1. Headless-режим (быстрая установка одной строкой), 2. Ручное обновление списков обхода геоблокировок, 3. Автоматическое обновление ядра и конфигураций (без потери данных), 🛠️ Дополнительные режимы запуска, code:bash (sudo bash install_xray.sh --headless <домен> <email> <кол-во), code:bash (sudo bash install_xray.sh --headless vpn.mysite.com admin@ma), code:bash (sudo bash install_xray.sh --update-geoblocks)

## Knowledge Gaps
- **16 isolated node(s):** `✨ Ключевые возможности проекта`, `code:bash (curl -fsSL "https://raw.githubusercontent.com/mvrvntn/xray-v)`, `code:bash (xry)`, `code:text (┌────────────────────────────────────────────────────────┐)`, `code:bash (sudo bash install_xray.sh --headless <домен> <email> <кол-во)` (+11 more)
  These have ≤1 connection - possible missing edges or undocumented components.

## Suggested Questions
_Questions this graph is uniquely positioned to answer:_

- **Why does `🌐 Автоматическая установка Xray (VLESS TCP XTLS-Vision) & Hysteria 2 с поддержкой подписок, WARP и Opera Proxy` connect `Community 1` to `Community 2`, `Community 3`?**
  _High betweenness centrality (0.104) - this node is a cross-community bridge._
- **Why does `🤝 Совместная работа рядом с AntiZapret-VPN (на одном сервере)` connect `Community 2` to `Community 1`?**
  _High betweenness centrality (0.063) - this node is a cross-community bridge._
- **What connects `✨ Ключевые возможности проекта`, `code:bash (curl -fsSL "https://raw.githubusercontent.com/mvrvntn/xray-v)`, `code:bash (xry)` to the rest of the system?**
  _16 weakly-connected nodes found - possible documentation gaps or missing edges._
- **Should `Community 0` be split into smaller, more focused modules?**
  _Cohesion score 0.05 - nodes in this community are weakly interconnected._