# Graph Report - vless_server_instal  (2026-07-10)

## Corpus Check
- 5 files · ~21,206 words
- Verdict: corpus is large enough that graph structure adds value.

## Summary
- 158 nodes · 408 edges · 15 communities
- Extraction: 100% EXTRACTED · 0% INFERRED · 0% AMBIGUOUS
- Token cost: 0 input · 0 output

## Graph Freshness
- Built from commit: `b6c7a0d5`
- Run `git rev-parse HEAD` and compare to check if the graph is stale.
- Run `graphify update .` after code changes (no API cost).

## Community Hubs (Navigation)
- [[_COMMUNITY_Community 0|Community 0]]
- [[_COMMUNITY_Community 1|Community 1]]
- [[_COMMUNITY_Community 2|Community 2]]
- [[_COMMUNITY_Community 3|Community 3]]
- [[_COMMUNITY_Community 4|Community 4]]
- [[_COMMUNITY_Community 5|Community 5]]
- [[_COMMUNITY_Community 6|Community 6]]
- [[_COMMUNITY_Community 7|Community 7]]
- [[_COMMUNITY_Community 8|Community 8]]
- [[_COMMUNITY_Community 9|Community 9]]

## God Nodes (most connected - your core abstractions)
1. `uninstall_all()` - 20 edges
2. `main_menu()` - 19 edges
3. `main()` - 18 edges
4. `get_installed_var()` - 18 edges
5. `bypass_menu()` - 18 edges
6. `final()` - 17 edges
7. `update_marker_val()` - 15 edges
8. `generate_server_config()` - 15 edges
9. `green_msg()` - 14 edges
10. `yellow_msg()` - 14 edges

## Surprising Connections (you probably didn't know these)
- `generate_hysteria_config()` --calls--> `get_installed_var()`  [EXTRACTED]
  install_xray.sh → install_xray.sh  _Bridges community 5 → community 9_
- `generate_client_configs()` --calls--> `get_installed_var()`  [EXTRACTED]
  install_xray.sh → install_xray.sh  _Bridges community 5 → community 4_
- `run_diagnostics()` --calls--> `get_installed_var()`  [EXTRACTED]
  install_xray.sh → install_xray.sh  _Bridges community 5 → community 2_
- `domain_management_menu()` --calls--> `check_domain()`  [EXTRACTED]
  install_xray.sh → install_xray.sh  _Bridges community 2 → community 4_
- `uninstall_all()` --calls--> `generate_hysteria_config()`  [EXTRACTED]
  install_xray.sh → install_xray.sh  _Bridges community 9 → community 2_

## Communities (15 total, 0 thin omitted)

### Community 0 - "Community 0"
Cohesion: 0.14
Nodes (31): apply_sysctl_changes(), ask_bbr_version(), ask_bbr_version_1(), ask_reboot(), benchmark(), check_Hybla(), check_qdisc_support(), complete_update() (+23 more)

### Community 1 - "Community 1"
Cohesion: 0.37
Nodes (20): apply_everything(), ask_reboot(), BEGIN(), check_if_running_as_root(), complete_update(), enable_packages(), find_ssh_port(), green_msg() (+12 more)

### Community 2 - "Community 2"
Cohesion: 0.15
Nodes (18): check_domain(), check_media_unlock(), check_port_conflicts(), create_directories(), get_flag_emoji(), install_dependencies(), install_hysteria(), install_xray() (+10 more)

### Community 3 - "Community 3"
Cohesion: 0.1
Nodes (19): ✨ Что внутри, 📂 Структура проекта на сервере, 📂 Где лежат файлы на сервере, 🛑 Полное удаление проекта с сервера, 🛑 Как удалить проект, 1. Headless-режим (установка одной командой), 2. Ручное обновление списков для обхода блокировок, 3. Безопасное обновление без потери данных (+11 more)

### Community 4 - "Community 4"
Cohesion: 0.45
Nodes (13): change_fingerprint(), domain_management_menu(), generate_client_configs(), install_generate_script(), main_menu(), manage_provider_id(), reality_management_menu(), setup_subscription_server() (+5 more)

### Community 5 - "Community 5"
Cohesion: 0.52
Nodes (12): add_client(), bypass_menu(), generate_server_config(), get_installed_var(), install_opera_proxy(), install_warp(), toggle_opera_proxy(), toggle_warp() (+4 more)

### Community 6 - "Community 6"
Cohesion: 0.21
Nodes (12): Как так получается?, 📝 Как поставить их вместе, Шаг 1. Освобождение порта 443 TCP в AntiZapret, Шаг 1. Освобождаем порты 443 (TCP и UDP) в AntiZapret, Шаг 2. Ставим VLESS TCP, Шаг 3. Исключение конфликта фаерволов, Шаг 3. Решаем вопросы с фаерволом, 🤝 Установка вместе с AntiZapret-VPN (+4 more)

### Community 7 - "Community 7"
Cohesion: 0.53
Nodes (10): check_if_running_as_root(), fix_dns(), fix_etc_hosts(), get_location_info(), green_msg(), install_dependencies_debian_based(), install_dependencies_rhel_based(), red_msg() (+2 more)

### Community 8 - "Community 8"
Cohesion: 0.67
Nodes (4): body(), button(), detectLanguage(), h2()

### Community 9 - "Community 9"
Cohesion: 0.67
Nodes (3): generate_hysteria_config(), remove_client(), ui_item_color()

## Knowledge Gaps
- **15 isolated node(s):** `✨ Что внутри`, `code:bash (curl -fsSL "https://raw.githubusercontent.com/mvrvntn/xray-v)`, `code:bash (xry)`, `code:text (┌────────────────────────────────────────────────────────┐)`, `code:bash (sudo bash install_xray.sh --headless <домен> <email> <кол-во)` (+10 more)
  These have ≤1 connection - possible missing edges or undocumented components.

## Suggested Questions
_Questions this graph is uniquely positioned to answer:_

- **Why does `🌐 Автоматическая установка Xray (VLESS TCP XTLS-Vision) & Hysteria 2 с поддержкой подписок, WARP и Opera Proxy` connect `Community 3` to `Community 6`?**
  _High betweenness centrality (0.031) - this node is a cross-community bridge._
- **Why does `🤝 Установка вместе с AntiZapret-VPN` connect `Community 6` to `Community 3`?**
  _High betweenness centrality (0.019) - this node is a cross-community bridge._
- **What connects `✨ Что внутри`, `code:bash (curl -fsSL "https://raw.githubusercontent.com/mvrvntn/xray-v)`, `code:bash (xry)` to the rest of the system?**
  _15 weakly-connected nodes found - possible documentation gaps or missing edges._
- **Should `Community 0` be split into smaller, more focused modules?**
  _Cohesion score 0.14 - nodes in this community are weakly interconnected._
- **Should `Community 3` be split into smaller, more focused modules?**
  _Cohesion score 0.1 - nodes in this community are weakly interconnected._