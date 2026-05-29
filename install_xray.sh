#!/bin/bash

# === Конфигурационные параметры ===
XRAY_CONFIG_DIR="/usr/local/etc/xray"
CLIENT_CONFIG_DIR="/etc/xray/client_configs"
SSL_DIR="/etc/ssl/vless"
MARKER_FILE="/etc/xray/.installed"
GENERATE_SCRIPT="/usr/local/bin/generate_client_config"
SUB_SERVER_SCRIPT="/usr/local/bin/xray_sub_server.py"
INSTALL_LOG="/var/log/xray/install.log"

# Объявление глобального ассоциативного массива для UUID
declare -A UUIDs

# === Проверка прав root ===
if [ "$(id -u)" != "0" ]; then
    echo "❌ Этот скрипт должен запускаться с правами root"
    exit 1
fi

# === Вспомогательные функции для работы с маркером ===
get_installed_var() {
    local var_name="$1"
    if [ -f "$MARKER_FILE" ]; then
        grep "^${var_name}=" "$MARKER_FILE" | cut -d= -f2-
    fi
}

update_marker_val() {
    local var_name="$1"
    local new_val="$2"
    mkdir -p "$(dirname "$MARKER_FILE")"
    touch "$MARKER_FILE"
    if grep -q "^${var_name}=" "$MARKER_FILE"; then
        local escaped_val=$(echo "$new_val" | sed 's/[\/&]/\\&/g')
        sed -i "s/^${var_name}=.*/${var_name}=${escaped_val}/" "$MARKER_FILE"
    else
        echo "${var_name}=${new_val}" >> "$MARKER_FILE"
    fi
}

update_geoblock_list() {
    local list_file="/etc/xray/geoblock.lst"
    local temp_file=$(mktemp)
    
    echo "📥 Обновление списка геоблокированных доменов..."
    # Пытаемся скачать с GitHub
    if curl -sSL --connect-timeout 8 "https://raw.githubusercontent.com/itdoginfo/allow-domains/refs/heads/main/Categories/geoblock.lst" -o "$temp_file" && [ -s "$temp_file" ]; then
        # Нормализуем переводы строк и убираем пробелы
        sed -i 's/\r//g' "$temp_file"
        if ! cmp -s "$temp_file" "$list_file" 2>/dev/null; then
            mkdir -p /etc/xray
            mv "$temp_file" "$list_file"
            echo "✅ Список доменов успешно обновлен."
            rm -f "$temp_file"
            return 0
        fi
    fi
    rm -f "$temp_file"
    
    # Если файла еще нет (первая установка), создаем базовый дефолтный список
    if [ ! -f "$list_file" ]; then
        mkdir -p /etc/xray
        cat > "$list_file" <<EOF
4pda.to
habr.com
claude.ai
claude.com
anthropic.com
openai.com
chatgpt.com
oaistatic.com
oaiusercontent.com
notion.so
notion.site
notion.com
notion-static.com
copilot.microsoft.com
designer.microsoft.com
netflix.com
netflix.net
nflxext.com
nflximg.net
nflxvideo.net
primevideo.com
instagram.com
facebook.com
fbcdn.net
twitter.com
x.com
twimg.com
spotify.com
deepl.com
openrouter.ai
trae.ai
windsurf.com
elevenlabs.io
EOF
        echo "✅ Создан базовый список геоблокированных доменов."
        return 0
    fi
    echo "ℹ️ Обновление не требуется (список совпадает с текущим или недоступен GitHub)."
    return 1
}

install_warp() {
    echo "🌀 Установка Cloudflare WARP..."
    if ! command -v wg-quick &>/dev/null || ! command -v wireguard &>/dev/null; then
        echo "📦 Установка WireGuard..."
        apt update >/dev/null
        apt install -y wireguard wireguard-tools resolvconf >/dev/null
    fi

    if [ ! -f "/etc/wireguard/warp.conf" ]; then
        echo "📥 Загрузка и запуск скрипта установки warp-native..."
        local temp_dir=$(mktemp -d)
        local success=false

        # Устанавливаем git если его нет
        if ! command -v git &>/dev/null; then
            echo "📦 Установка git..."
            apt update >/dev/null
            apt install -y git >/dev/null
        fi

        # Попытка 1: Клонирование репозитория через git (самый надежный способ со всеми зависимыми файлами)
        echo "📥 Клонирование репозитория warp-native..."
        if git clone --depth 1 https://github.com/distillium/warp-native.git "$temp_dir/repo" >/dev/null 2>&1; then
            if [ -f "$temp_dir/repo/install.sh" ]; then
                chmod +x "$temp_dir/repo/install.sh"
                (cd "$temp_dir/repo" && printf "1\n\n\n" | bash install.sh)
                success=true
            fi
        fi

        # Попытка 2: Резервный curl (main)
        if [ "$success" = false ]; then
            echo "⚠️ git clone не удался, пробуем скачать install.sh через curl (main)..."
            curl -sSL --connect-timeout 10 https://raw.githubusercontent.com/distillium/warp-native/main/install.sh -o "$temp_dir/install.sh"
            if [ -s "$temp_dir/install.sh" ]; then
                chmod +x "$temp_dir/install.sh"
                (cd "$temp_dir" && printf "1\n\n\n" | bash install.sh)
                success=true
            fi
        fi

        # Попытка 3: Резервный curl (master)
        if [ "$success" = false ]; then
            echo "⚠️ Пробуем скачать install.sh через curl (master)..."
            curl -sSL --connect-timeout 10 https://raw.githubusercontent.com/distillium/warp-native/master/install.sh -o "$temp_dir/install.sh"
            if [ -s "$temp_dir/install.sh" ]; then
                chmod +x "$temp_dir/install.sh"
                (cd "$temp_dir" && printf "1\n\n\n" | bash install.sh)
                success=true
            fi
        fi

        rm -rf "$temp_dir"
    fi

    if [ -f "/etc/wireguard/warp.conf" ]; then
        # Отключаем глобальную маршрутизацию через WARP (выборочно маршрутизируем через Xray)
        if ! grep -q "Table = off" /etc/wireguard/warp.conf; then
            sed -i '/\[Interface\]/a Table = off' /etc/wireguard/warp.conf
        fi
        # Удаляем DNS из конфигурации WireGuard, чтобы wg-quick не ломал DNS в /etc/resolv.conf
        sed -i '/^DNS\s*=/d' /etc/wireguard/warp.conf

        systemctl enable wg-quick@warp >/dev/null 2>&1
        systemctl start wg-quick@warp >/dev/null 2>&1
        update_geoblock_list
        
        # Добавляем обновление списка геоблокировок в cron
        local script_path=$(realpath "$0")
        (crontab -l 2>/dev/null | grep -v 'update-geoblocks'; \
         echo "30 3 * * * bash $script_path --update-geoblocks >/dev/null 2>&1") | crontab -

        echo "✅ Cloudflare WARP успешно установлен и запущен!"
        update_marker_val "WARP_INSTALLED" "true"
        update_marker_val "WARP_ENABLED" "true"
    else
        echo "❌ Ошибка при генерации конфигурации WARP"
        return 1
    fi
}

toggle_warp() {
    local current_status=$(get_installed_var "WARP_ENABLED")
    if [ "$current_status" == "true" ]; then
        echo "📴 Отключение обхода через WARP (возврат к прямому выходу)..."
        update_marker_val "WARP_ENABLED" "false"
        systemctl stop wg-quick@warp >/dev/null 2>&1
    else
        echo "🌀 Включение обхода через WARP..."
        if [ "$(get_installed_var "WARP_INSTALLED")" != "true" ]; then
            install_warp || return 1
        fi
        systemctl start wg-quick@warp >/dev/null 2>&1
        update_marker_val "WARP_ENABLED" "true"
    fi

    DOMAIN=$(get_installed_var "DOMAIN")
    EMAIL=$(get_installed_var "EMAIL")
    NUM_DEVICES=$(get_installed_var "NUM_DEVICES")
    generate_server_config
    echo "✅ Статус WARP обновлен и Xray перезапущен!"
}

# === Проверка предыдущей установки (до запроса данных) ===
if [ -f "$MARKER_FILE" ]; then
    show_connections() {
        echo -e "\n--- Активные подключения к Xray ---"
        local conns=$(ss -tnp | grep -E ':443\s' | grep -v '127.0.0.1')
        if [ -z "$conns" ]; then
            echo "Нет активных подключений на порт 443."
        else
            echo "Состояние Локальный_Адрес Удаленный_Адрес Процесс"
            echo "$conns" | awk '{print $1, $4, $5, $6}'
        fi
    }

    show_logs() {
        echo -e "\n--- Выберите лог для просмотра ---"
        echo "1. Лог Xray (systemd)"
        echo "2. Лог Сервера подписок (systemd)"
        echo "3. Лог ошибок Xray (/var/log/xray/error.log)"
        echo "4. Назад"
        read -p "Выбор (1-4): " lchoice
        case $lchoice in
            1) journalctl -u xray -n 50 --no-pager ;;
            2) journalctl -u xray-sub -n 50 --no-pager ;;
            3) tail -n 50 /var/log/xray/error.log ;;
            4) return ;;
            *) echo "Неверный выбор" ;;
        esac
    }

    add_client() {
        echo -e "\n--- Добавление нового клиента ---"
        read -p "Введите имя нового устройства (например: client_new): " new_name
        new_name=$(echo "$new_name" | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//')
        if [[ -z "$new_name" ]]; then
            echo "❌ Имя не может быть пустым"
            return
        fi

        local safe_filename=$(echo "$new_name" | tr -cd '[:alnum:]_.-' | tr '[:upper:]' '[:lower:]')
        if [[ -z "$safe_filename" ]]; then
            safe_filename="client_new"
        fi

        if [ -f "$CLIENT_CONFIG_DIR/${safe_filename}.json" ]; then
            echo "❌ Клиент с таким именем уже существует!"
            return
        fi

        local new_uuid=$(xray uuid)
        DOMAIN=$(get_installed_var "DOMAIN")

        cat > "$CLIENT_CONFIG_DIR/${safe_filename}.json" <<EOF
{
  "remarks": "$new_name",
  "id": "$new_uuid",
  "outbounds": [{
    "protocol": "vless",
    "settings": {
      "vnext": [{
        "address": "$DOMAIN",
        "port": 443,
        "users": [{
          "id": "$new_uuid",
          "flow": "xtls-rprx-vision"
        }]
      }]
    },
    "streamSettings": {
      "network": "tcp",
      "security": "tls",
      "sockopt": {
        "tcpFastOpen": true
      }
    }
  }]
}
EOF
        # Устанавливаем права
        chmod 644 "$CLIENT_CONFIG_DIR/${safe_filename}.json"
        chown nobody:nogroup "$CLIENT_CONFIG_DIR/${safe_filename}.json"

        # Обновляем конфиг сервера и перезапускаем xray
        generate_server_config

        # Обновляем маркер
        local current_num=$(find "$CLIENT_CONFIG_DIR" -maxdepth 1 -name '*.json' | wc -l)
        update_marker_val "NUM_DEVICES" "$current_num"

        echo "✅ Клиент '$new_name' успешно добавлен!"
    }

    remove_client() {
        echo -e "\n--- Удаление клиента ---"
        mapfile -t config_files < <(find "$CLIENT_CONFIG_DIR" -maxdepth 1 -name '*.json' | sort)
        if [ ${#config_files[@]} -eq 0 ]; then
            echo "❌ Нет доступных клиентов для удаления"
            return
        fi

        for i in "${!config_files[@]}"; do
            remarks=$(grep -oP '(?<="remarks": ")[^"]+' "${config_files[$i]}" | head -1)
            if [ -z "$remarks" ]; then
                remarks="${config_files[$i]##*/}"
                remarks="${remarks%.json}"
            fi
            echo "$((i+1)). $remarks"
        done

        read -p "Выберите клиента для удаления (1-${#config_files[@]}): " choice
        if ! [[ "$choice" =~ ^[0-9]+$ ]] || [ "$choice" -lt 1 ] || [ "$choice" -gt ${#config_files[@]} ]; then
            echo "❌ Неверный выбор"
            return
        fi

        selected="${config_files[$((choice-1))]}"
        remarks=$(grep -oP '(?<="remarks": ")[^"]+' "$selected" | head -1)
        if [ -z "$remarks" ]; then
            remarks="${selected##*/}"
            remarks="${remarks%.json}"
        fi

        read -p "Вы уверены, что хотите удалить клиента '$remarks'? (y/n): " confirm
        if [[ "$confirm" =~ ^[Yy]$ ]]; then
            rm -f "$selected"
            # Обновляем конфиг сервера и перезапускаем xray
            generate_server_config

            # Обновляем маркер
            local current_num=$(find "$CLIENT_CONFIG_DIR" -maxdepth 1 -name '*.json' | wc -l)
            update_marker_val "NUM_DEVICES" "$current_num"

            echo "✅ Клиент '$remarks' успешно удален!"
        else
            echo "Отмена."
        fi
    }

    main_menu() {
        local warp_installed=$(get_installed_var "WARP_INSTALLED")
        local warp_enabled=$(get_installed_var "WARP_ENABLED")
        local warp_status="Не установлен"
        if [ "$warp_installed" == "true" ]; then
            if [ "$warp_enabled" == "true" ]; then
                warp_status="Включен"
            else
                warp_status="Выключен"
            fi
        fi

        echo -e "\n==== Xray Меню ===="
        echo "1. Показать QR-код / Ссылки"
        echo "2. Добавить нового клиента"
        echo "3. Удалить существующего клиента"
        echo "4. Управление Cloudflare WARP (Статус: $warp_status)"
        echo "5. Просмотреть логи"
        echo "6. Активные подключения"
        echo "7. Удалить Xray из системы"
        echo "8. Выйти"
        read -p "Выбор: " choice
        case $choice in
            1) "$GENERATE_SCRIPT" ; main_menu ;;
            2) add_client ; main_menu ;;
            3) remove_client ; main_menu ;;
            4) warp_menu ;;
            5) show_logs ; main_menu ;;
            6) show_connections ; main_menu ;;
            7) uninstall_all ;;
            8) exit 0 ;;
            *) echo "Неверный выбор"; main_menu ;;
        esac
    }

    warp_menu() {
        local warp_installed=$(get_installed_var "WARP_INSTALLED")
        local warp_enabled=$(get_installed_var "WARP_ENABLED")
        local warp_mode=$(get_installed_var "WARP_MODE")
        [ -z "$warp_mode" ] && warp_mode="smart"
        
        echo -e "\n--- Управление Cloudflare WARP ---"
        if [ "$warp_installed" != "true" ]; then
            echo "1. Установить и включить WARP"
            echo "2. Назад"
            read -p "Выбор: " wchoice
            case $wchoice in
                1)
                    install_warp
                    DOMAIN=$(get_installed_var "DOMAIN")
                    NUM_DEVICES=$(get_installed_var "NUM_DEVICES")
                    generate_server_config
                    warp_menu
                    ;;
                2)
                    main_menu
                    ;;
                *)
                    echo "Неверный выбор"
                    warp_menu
                    ;;
            esac
        else
            local status_text="Отключен"
            [ "$warp_enabled" == "true" ] && status_text="Включен"
            
            local mode_text="Избирательный обход (Smart)"
            [ "$warp_mode" == "full" ] && mode_text="Весь трафик через WARP (Full)"
            
            echo "Текущий статус: $status_text"
            echo "Текущий режим: $mode_text"
            echo "----------------------------------"
            if [ "$warp_enabled" == "true" ]; then
                echo "1. Отключить WARP (прямой выход)"
            else
                echo "1. Включить WARP"
            fi
            echo "2. Изменить режим работы WARP (Smart / Full)"
            echo "3. Обновить список геоблокируемых доменов"
            echo "4. Переустановить/Обновить WARP"
            echo "5. Назад"
            read -p "Выбор: " wchoice
            case $wchoice in
                1)
                    toggle_warp
                    warp_menu
                    ;;
                2)
                    echo -e "\nВыберите режим работы WARP:"
                    echo "1. Избирательный обход (Smart) - через WARP идут только заблокированные/геоблокированные ресурсы, пинг на остальные ресурсы не растет."
                    echo "2. Весь трафик (Full) - весь исходящий трафик VPS идет через сеть WARP."
                    read -p "Выбор (1-2): " mchoice
                    if [ "$mchoice" == "1" ]; then
                        update_marker_val "WARP_MODE" "smart"
                        echo "✅ Выбран режим Smart"
                    elif [ "$mchoice" == "2" ]; then
                        update_marker_val "WARP_MODE" "full"
                        echo "✅ Выбран режим Full"
                    else
                        echo "❌ Неверный выбор"
                    fi
                    DOMAIN=$(get_installed_var "DOMAIN")
                    NUM_DEVICES=$(get_installed_var "NUM_DEVICES")
                    generate_server_config
                    warp_menu
                    ;;
                3)
                    update_geoblock_list
                    DOMAIN=$(get_installed_var "DOMAIN")
                    NUM_DEVICES=$(get_installed_var "NUM_DEVICES")
                    generate_server_config
                    echo "✅ Список обновлен и применен."
                    warp_menu
                    ;;
                4)
                    install_warp
                    DOMAIN=$(get_installed_var "DOMAIN")
                    NUM_DEVICES=$(get_installed_var "NUM_DEVICES")
                    generate_server_config
                    warp_menu
                    ;;
                5)
                    main_menu
                    ;;
                *)
                    echo "Неверный выбор"
                    warp_menu
                    ;;
            esac
        fi
    }

    uninstall_all() {
        echo "🧹 Удаление Xray и конфигураций..."
        
        systemctl stop xray-sub >/dev/null 2>&1
        systemctl disable xray-sub >/dev/null 2>&1
        rm -f /etc/systemd/system/xray-sub.service
        systemctl daemon-reload >/dev/null 2>&1
        rm -f "$SUB_SERVER_SCRIPT"

        # Удаление Cloudflare WARP
        systemctl stop wg-quick@warp >/dev/null 2>&1
        systemctl disable wg-quick@warp >/dev/null 2>&1
        rm -f /etc/cron.d/warp-native
        rm -rf /opt/warp-native
        rm -f /usr/local/bin/warp
        rm -f /etc/wireguard/warp.conf
        rm -f /usr/local/bin/wgcf
        rm -f /root/wgcf-account.toml /root/wgcf-profile.conf

        bash -c "$(curl -L https://github.com/XTLS/Xray-install/raw/main/install-release.sh)" @ remove
        rm -rf "$XRAY_CONFIG_DIR" "$CLIENT_CONFIG_DIR" "$SSL_DIR" "$GENERATE_SCRIPT"
        rm -f /var/log/xray/{access.log,error.log}
        if crontab -l &>/dev/null; then
            crontab -l | grep -v "certbot renew" | crontab -
        fi
        ufw delete allow 443/tcp > /dev/null
        ufw delete allow 80/tcp > /dev/null
        rm -f "$MARKER_FILE"
        echo "✅ Удалено"
    }

    echo "⚠️ Xray уже установлен"
    main_menu
    exit 0
fi

# === Логгирование ===
mkdir -p /var/log/xray
exec > >(tee -a "$INSTALL_LOG") 2>&1

# === Проверка домена ===
echo "🔍 Проверка резолва домена..."
check_domain() {
    if ! getent hosts "$DOMAIN" >/dev/null; then
        echo "⚠️ Локальное разрешение домена не удалось, выполняем резервную проверку через внешние DNS..."
        local resolved_ip
        
        # Запрос к Cloudflare DNS-over-HTTPS напрямую по IP 1.1.1.1 (не требует работающего DNS на сервере)
        resolved_ip=$(curl -sH "accept: application/dns-json" --connect-timeout 5 "https://1.1.1.1/dns-query?name=$DOMAIN&type=A" | jq -r '.Answer[0].data' 2>/dev/null)
        if [[ "$resolved_ip" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
            echo "ℹ️ Внешняя проверка через 1.1.1.1 подтвердила IP домена: $resolved_ip"
            return 0
        fi
        
        # Запрос к Google DNS-over-HTTPS напрямую по IP 8.8.8.8
        resolved_ip=$(curl -sH "accept: application/dns-json" --connect-timeout 5 "https://8.8.8.8/resolve?name=$DOMAIN&type=A" | jq -r '.Answer[0].data' 2>/dev/null)
        if [[ "$resolved_ip" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
            echo "ℹ️ Внешняя проверка через 8.8.8.8 подтвердила IP домена: $resolved_ip"
            return 0
        fi

        echo "❌ Домен '$DOMAIN' не резолвится. Проверьте DNS-записи (A-запись должна указывать на IP этого сервера)."
        exit 1
    fi
}

# === Проверка конфликтов портов ===
check_port_conflicts() {
    echo "🔍 Проверка конфликтов портов 80/443..."
    local conflict=false
    for svc in nginx apache2 caddy httpd; do
        if systemctl is-active --quiet "$svc"; then
            echo "⚠️ Служба $svc запущена и занимает порты 80/443."
            echo "🛑 Отключаем и останавливаем $svc, чтобы Xray и Certbot могли запуститься..."
            systemctl stop "$svc" >/dev/null 2>&1
            systemctl disable "$svc" >/dev/null 2>&1
            conflict=true
        fi
    done
    if [ "$conflict" = true ]; then
        echo "✅ Конфликтующие службы успешно остановлены и отключены."
    fi
}

# === Получение эмодзи флага страны ===
get_flag_emoji() {
    local country_code
    # Сначала пробуем наиболее точный ipinfo.io
    country_code=$(curl -s --connect-timeout 3 https://ipinfo.io/country | tr -d '[:space:]' | tr '[:lower:]' '[:upper:]')
    if [[ ! "$country_code" =~ ^[A-Z]{2}$ ]]; then
        # В качестве резерва используем ipapi.co
        country_code=$(curl -s --connect-timeout 3 https://ipapi.co/country/ | tr -d '[:space:]' | tr '[:lower:]' '[:upper:]')
    fi
    if [[ ! "$country_code" =~ ^[A-Z]{2}$ ]]; then
        country_code="UN"
    fi

    local c1=${country_code:0:1}
    local c2=${country_code:1:1}
    local val1=$(( $(printf "%d" "'$c1") - 65 + 127462 ))
    local val2=$(( $(printf "%d" "'$c2") - 65 + 127462 ))
    
    local flag
    printf -v flag "\\U$(printf "%08x" $val1)\\U$(printf "%08x" $val2)"
    echo "$flag"
}

# === Создание директорий ===
create_directories() {
    echo "📁 Создание директорий..."
    mkdir -p "$XRAY_CONFIG_DIR" "$CLIENT_CONFIG_DIR" "$SSL_DIR" "/var/log/xray"
    mkdir -p "/etc/xray"
    chmod 755 /etc/xray
    touch /var/log/xray/{access.log,error.log}
    chown -R nobody:nogroup /var/log/xray
    chmod -R 755 /var/log/xray
}

# === Установка зависимостей ===
install_dependencies() {
    echo "📦 Установка зависимостей..."
    apt update > /dev/null
    apt install -y curl git qrencode ufw cron certbot python3 jq lsof > /dev/null

    echo "⚡ Включение BBR и TCP Fast Open..."
    # Включаем BBR и FQ
    if ! sysctl net.ipv4.tcp_congestion_control | grep -q "bbr"; then
        echo "net.core.default_qdisc=fq" >> /etc/sysctl.conf
        echo "net.ipv4.tcp_congestion_control=bbr" >> /etc/sysctl.conf
    fi
    # Включаем TCP Fast Open (значение 3 включает и на отправку, и на прием данных)
    if ! sysctl net.ipv4.tcp_fastopen | grep -q "3"; then
        echo "net.ipv4.tcp_fastopen=3" >> /etc/sysctl.conf
    fi
    if ! sysctl net.ipv4.tcp_slow_start_after_idle | grep -q "0"; then
        echo "net.ipv4.tcp_slow_start_after_idle=0" >> /etc/sysctl.conf
    fi
    if ! sysctl net.ipv4.tcp_notsent_lowat | grep -q "16384"; then
        echo "net.ipv4.tcp_notsent_lowat=16384" >> /etc/sysctl.conf
    fi
    sysctl -p > /dev/null 2>&1
}

# === Установка Xray ===
install_xray() {
    echo "🚀 Установка Xray..."
    bash -c "$(curl -L https://github.com/XTLS/Xray-install/raw/main/install-release.sh)" @ install
    systemctl enable xray > /dev/null
}

# === Настройка фаервола ===
setup_firewall() {
    echo "🛡 Настройка UFW..."
    ufw allow 443/tcp > /dev/null
    ufw allow 80/tcp > /dev/null
    ufw allow 22/tcp > /dev/null
    ufw --force enable > /dev/null
}

# === Настройка сертификатов ===
setup_certificates() {
    echo "🔐 Получение TLS-сертификатов для $DOMAIN..."

    # Получаем сертификат через certbot
    certbot certonly --standalone -d "$DOMAIN" --email "$EMAIL" \
        --agree-tos --non-interactive --key-type ecdsa || {
        echo "❌ Ошибка получения сертификата"
        echo "Возможные причины:"
        echo "1. Домен не привязан к IP этого сервера."
        echo "2. Порт 80 занят другим приложением."
        echo "3. Временная блокировка со стороны Let's Encrypt (превышен лимит запросов)."
        exit 1
    }

    # Копируем сертификаты вместо создания симлинков
    cp "/etc/letsencrypt/live/$DOMAIN/fullchain.pem" "$SSL_DIR/fullchain.cer"
    cp "/etc/letsencrypt/live/$DOMAIN/privkey.pem" "$SSL_DIR/private.key"

    # Устанавливаем права и владельца для пользователя nobody (от имени которого работает Xray)
    chown -R nobody:nogroup "$SSL_DIR"
    chmod 755 "$SSL_DIR"
    chmod 644 "$SSL_DIR/fullchain.cer"
    chmod 600 "$SSL_DIR/private.key"

    # Добавляем обновление сертификатов в cron (копирование и рестарт Xray)
    (crontab -l 2>/dev/null | grep -v 'certbot renew'; \
     echo "0 3 * * * certbot renew --quiet --post-hook \"cp /etc/letsencrypt/live/$DOMAIN/fullchain.pem $SSL_DIR/fullchain.cer && cp /etc/letsencrypt/live/$DOMAIN/privkey.pem $SSL_DIR/private.key && chown -R nobody:nogroup $SSL_DIR && chmod 644 $SSL_DIR/fullchain.cer && chmod 600 $SSL_DIR/private.key && systemctl restart xray\"") | crontab -
}

# === Генерация UUID и серверного конфигурационного файла ===
generate_server_config() {
    echo "🧩 Генерация конфигурации Xray..."
    local config_file="$XRAY_CONFIG_DIR/config.json"
    
    # Инициализация массивов для клиентов
    local vless_clients=()
    
    # Проверяем, есть ли уже клиенты
    if [ -d "$CLIENT_CONFIG_DIR" ] && [ "$(find "$CLIENT_CONFIG_DIR" -name '*.json' 2>/dev/null | wc -l)" -gt 0 ]; then
        local idx=1
        for filepath in $(find "$CLIENT_CONFIG_DIR" -maxdepth 1 -name '*.json' | sort); do
            local uuid=$(jq -r '.id' "$filepath" 2>/dev/null)
            if [ -n "$uuid" ] && [ "$uuid" != "null" ]; then
                UUIDs[$idx]="$uuid"
                vless_clients+=("{
                  \"id\": \"$uuid\",
                  \"flow\": \"xtls-rprx-vision\",
                  \"email\": \"client-$idx\"
                }")
                idx=$((idx + 1))
            fi
        done
    else
        # Генерация уникальных UUID для каждого устройства (первоначальная установка)
        for i in $(seq 1 "$NUM_DEVICES"); do
            local uuid=$(xray uuid)
            UUIDs[$i]="$uuid"
            
            vless_clients+=("{
              \"id\": \"$uuid\",
              \"flow\": \"xtls-rprx-vision\",
              \"email\": \"client-$i\"
            }")
        done
    fi
    
    local vless_clients_str=$(IFS=,; echo "${vless_clients[*]}")
    
    # Проверяем статус WARP
    local warp_enabled=$(get_installed_var "WARP_ENABLED")
    local warp_mode=$(get_installed_var "WARP_MODE")
    [ -z "$warp_mode" ] && warp_mode="smart"
    
    local outbounds_str
    local routing_rules_str=""
    
    if [ "$warp_enabled" == "true" ]; then
        if [ "$warp_mode" == "full" ]; then
            outbounds_str='[
    {
      "tag": "WARP",
      "protocol": "freedom",
      "settings": {
        "domainStrategy": "UseIPv4"
      },
      "streamSettings": {
        "sockopt": {
          "interface": "warp",
          "tcpFastOpen": true
        }
      }
    },
    {
      "tag": "DIRECT",
      "protocol": "freedom",
      "settings": {
        "domainStrategy": "UseIPv4"
      },
      "streamSettings": {
        "sockopt": {
          "tcpFastOpen": true
        }
      }
    },
    {
      "tag": "BLOCK",
      "protocol": "blackhole"
    }
  ]'
        else
            outbounds_str='[
    {
      "tag": "DIRECT",
      "protocol": "freedom",
      "settings": {
        "domainStrategy": "UseIPv4"
      },
      "streamSettings": {
        "sockopt": {
          "tcpFastOpen": true
        }
      }
    },
    {
      "tag": "WARP",
      "protocol": "freedom",
      "settings": {
        "domainStrategy": "UseIPv4"
      },
      "streamSettings": {
        "sockopt": {
          "interface": "warp",
          "tcpFastOpen": true
        }
      }
    },
    {
      "tag": "BLOCK",
      "protocol": "blackhole"
    }
  ]'
            
            # Читаем список геоблока
            local geoblocks=()
            if [ -f "/etc/xray/geoblock.lst" ]; then
                while IFS= read -r line || [ -n "$line" ]; do
                    line=$(echo "$line" | tr -d '\r' | xargs)
                    if [[ -z "$line" || "$line" =~ ^# ]]; then
                        continue
                    fi
                    geoblocks+=("\"domain:$line\"")
                done < "/etc/xray/geoblock.lst"
            fi
            
            # Добавим встроенные правила Xray для надежности
            geoblocks+=("\"geosite:openai\"" "\"geosite:netflix\"" "\"geosite:facebook\"" "\"geosite:instagram\"" "\"geosite:twitter\"" "\"geosite:disney\"" "\"geosite:spotify\"")
            
            local geoblocks_joined=$(IFS=,; echo "${geoblocks[*]}")
            routing_rules_str=",
      {
        \"type\": \"field\",
        \"domain\": [
          $geoblocks_joined
        ],
        \"outboundTag\": \"WARP\"
      }"
        fi
    else
        outbounds_str='[
    {
      "tag": "DIRECT",
      "protocol": "freedom",
      "settings": {
        "domainStrategy": "UseIPv4"
      },
      "streamSettings": {
        "sockopt": {
          "tcpFastOpen": true
        }
      }
    },
    {
      "tag": "BLOCK",
      "protocol": "blackhole"
    }
  ]'
    fi
    
    # Генерация конфигурационного файла с VLESS TCP
    cat > "$config_file" <<EOF
{
  "log": {
    "loglevel": "warning",
    "access": "/var/log/xray/access.log",
    "error": "/var/log/xray/error.log"
  },
  "inbounds": [
    {
      "port": 443,
      "protocol": "vless",
      "settings": {
        "clients": [$vless_clients_str],
        "decryption": "none",
        "fallbacks": [
          {
            "path": "/sub/",
            "dest": "127.0.0.1:10080"
          },
          {
            "dest": "127.0.0.1:10080"
          }
        ]
      },
      "sniffing": {
        "enabled": true,
        "destOverride": [
          "http",
          "tls"
        ]
      },
      "streamSettings": {
        "network": "tcp",
        "security": "tls",
        "tlsSettings": {
          "certificates": [{
            "certificateFile": "$SSL_DIR/fullchain.cer",
            "keyFile": "$SSL_DIR/private.key"
          }],
          "alpn": ["h2", "http/1.1"]
        },
        "sockopt": {
          "tcpFastOpen": true
        }
      }
    }
  ],
  "outbounds": $outbounds_str,
  "routing": {
    "rules": [
      {
        "ip": [
          "geoip:private"
        ],
        "outboundTag": "BLOCK"
      },
      {
        "domain": [
          "geosite:private"
        ],
        "outboundTag": "BLOCK"
      },
      {
        "protocol": [
          "bittorrent"
        ],
        "outboundTag": "BLOCK"
      }${routing_rules_str}
    ]
  }
}
EOF

    systemctl restart xray
}

# === Генерация клиентских конфигов ===
generate_client_configs() {
    echo "📤 Генерация клиентских конфигов..."
    mkdir -p "$CLIENT_CONFIG_DIR"

    for i in $(seq 1 "$NUM_DEVICES"); do
        local name="${DEVICE_NAMES[$i]}"
        local filename="client_$i"
        local safe_filename=$(echo "$name" | tr -cd '[:alnum:]_.-' | tr '[:upper:]' '[:lower:]')
        if [[ -n "$safe_filename" ]]; then
            filename="$safe_filename"
        fi

        cat > "$CLIENT_CONFIG_DIR/${filename}.json" <<EOF
{
  "remarks": "$name",
  "id": "${UUIDs[$i]}",
  "outbounds": [{
    "protocol": "vless",
    "settings": {
      "vnext": [{
        "address": "$DOMAIN",
        "port": 443,
        "users": [{
          "id": "${UUIDs[$i]}",
          "flow": "xtls-rprx-vision"
        }]
      }]
    },
    "streamSettings": {
      "network": "tcp",
      "security": "tls",
      "sockopt": {
        "tcpFastOpen": true
      }
    }
  }]
}
EOF
    done

    # Обеспечиваем доступ на чтение для сервиса подписок (работающего под nobody)
    chmod 755 /etc/xray
    chown -R nobody:nogroup "$CLIENT_CONFIG_DIR"
    chmod 755 "$CLIENT_CONFIG_DIR"
    chmod 644 "$CLIENT_CONFIG_DIR"/*.json
}

# === Настройка сервера подписок ===
setup_subscription_server() {
    echo "📡 Настройка сервера подписок..."
    
    # Записываем Python-скрипт сервера
    cat > "$SUB_SERVER_SCRIPT" <<'EOF'
import http.server
import socketserver
import base64
import os
import glob
import urllib.parse
import urllib.request
import json
import threading
import time as _time

PORT = 10080
CONFIG_DIR = "/etc/xray/client_configs"
INSTALLED_FILE = "/etc/xray/.installed"

_ROSCOMVPN_URLS = {
    "default": "https://raw.githubusercontent.com/hydraponique/roscomvpn-routing/main/HAPP/DEFAULT.DEEPLINK",
    "jsonsub": "https://raw.githubusercontent.com/hydraponique/roscomvpn-routing/main/HAPP/JSONSUB.DEEPLINK",
    "whitelist": "https://raw.githubusercontent.com/hydraponique/roscomvpn-routing/main/HAPP/WHITELIST.DEEPLINK",
}

DECOY_HTML = """<!DOCTYPE html>
<html>
<head>
    <meta charset="utf-8">
    <title>Вход в Confluence</title>
    <style>
        body {
            font-family: -apple-system, BlinkMacSystemFont, "Segoe UI", Roboto, Oxygen, Ubuntu, "Fira Sans", "Droid Sans", "Helvetica Neue", sans-serif;
            background-color: #f4f5f7;
            display: flex;
            justify-content: center;
            align-items: center;
            height: 100vh;
            margin: 0;
        }
        .login-container {
            background-color: white;
            padding: 40px;
            border-radius: 8px;
            box-shadow: 0 1px 3px rgba(0, 0, 0, 0.12), 0 1px 2px rgba(0, 0, 0, 0.24);
            width: 350px;
            text-align: center;
        }
        .logo { margin-bottom: 20px; }
        .logo img { width: 120px; }
        h2 { margin-bottom: 20px; font-size: 24px; color: #0052cc; }
        input[type="text"], input[type="password"] {
            width: 100%;
            padding: 10px;
            margin: 10px 0;
            border: 1px solid #dfe1e6;
            border-radius: 4px;
            box-sizing: border-box;
            font-size: 16px;
        }
        .error { border-color: red; }
        .error-message { color: red; font-size: 14px; display: none; margin-top: 10px; }
        button {
            width: 100%;
            padding: 10px;
            background-color: #0052cc;
            color: white;
            border: none;
            border-radius: 4px;
            cursor: pointer;
            font-size: 16px;
            margin-top: 20px;
        }
        button:hover { background-color: #0747a6; }
        .help-links { margin-top: 20px; font-size: 14px; }
        .help-links a { color: #0052cc; text-decoration: none; }
        .help-links a:hover { text-decoration: underline; }
        .modal {
            display: none;
            position: fixed;
            z-index: 1;
            left: 0;
            top: 0;
            width: 100%;
            height: 100%;
            overflow: auto;
            background-color: rgba(0,0,0,0.4);
            padding-top: 60px;
        }
        .modal-content {
            background-color: white;
            margin: 5% auto;
            padding: 20px;
            border: 1px solid #888;
            width: 80%;
            max-width: 400px;
            border-radius: 8px;
            text-align: center;
        }
        .close { color: #aaa; float: right; font-size: 28px; font-weight: bold; cursor: pointer; }
        .close:hover, .close:focus { color: black; text-decoration: none; cursor: pointer; }
    </style>
</head>
<body>
<div class="login-container">
    <div class="logo">
        <img src="https://cdn.icon-icons.com/icons2/2429/PNG/512/confluence_logo_icon_147305.png" alt="Confluence">
    </div>
    <h2 id="login-title">Войти в Confluence</h2>
    <form id="login-form">
        <input type="text" id="username" name="username" placeholder="Адрес электронной почты">
        <input type="password" id="password" name="password" placeholder="Введите пароль">
        <button type="submit" id="login-button">Войти</button>
    </form>
    <div id="error-message" class="error-message">Неправильное имя пользователя или пароль.</div>
    <div class="help-links">
        <a href="#" id="forgot-link">Не удается войти?</a> • <a href="#" id="create-link">Создать аккаунт</a>
    </div>
</div>
<div id="myModal" class="modal">
    <div class="modal-content">
        <span class="close">&times;</span>
        <p id="modal-text">Для создания аккаунта обратитесь к администратору.</p>
    </div>
</div>
<script>
    function setLanguage(lang) {
        const elements = {
            "ru": {
                loginTitle: "Войти в Confluence",
                usernamePlaceholder: "Адрес электронной почты",
                passwordPlaceholder: "Введите пароль",
                loginButton: "Войти",
                forgotLink: "Не удается войти?",
                createLink: "Создать аккаунт",
                createAccountText: "Для создания аккаунта обратитесь к администратору.",
                forgotPasswordText: "Для восстановления доступа обратитесь к администратору.",
                errorMessage: "Неправильное имя пользователя или пароль."
            },
            "en": {
                loginTitle: "Login to Confluence",
                usernamePlaceholder: "Email address",
                passwordPlaceholder: "Enter password",
                loginButton: "Login",
                forgotLink: "Can't log in?",
                createLink: "Create an account",
                createAccountText: "To create an account, please contact your administrator.",
                forgotPasswordText: "To recover access, please contact your administrator.",
                errorMessage: "Incorrect username or password."
            }
        };
        document.getElementById('login-title').innerText = elements[lang].loginTitle;
        document.getElementById('username').placeholder = elements[lang].usernamePlaceholder;
        document.getElementById('password').placeholder = elements[lang].passwordPlaceholder;
        document.getElementById('login-button').innerText = elements[lang].loginButton;
        document.getElementById('forgot-link').innerText = elements[lang].forgotLink;
        document.getElementById('create-link').innerText = elements[lang].createLink;
        document.getElementById('create-link').dataset.modalText = elements[lang].createAccountText;
        document.getElementById('forgot-link').dataset.modalText = elements[lang].forgotPasswordText;
        document.getElementById('error-message').innerText = elements[lang].errorMessage;
    }
    function detectLanguage() {
        const userLang = navigator.language || navigator.userLanguage;
        if (userLang.startsWith('ru')) { setLanguage('ru'); } else { setLanguage('en'); }
    }
    document.addEventListener('DOMContentLoaded', detectLanguage);
    var modal = document.getElementById("myModal");
    var span = document.getElementsByClassName("close")[0];
    function openModal(text) {
        document.getElementById('modal-text').innerText = text;
        modal.style.display = "block";
    }
    document.getElementById("create-link").onclick = function(event) {
        event.preventDefault();
        openModal(this.dataset.modalText);
    }
    document.getElementById("forgot-link").onclick = function(event) {
        event.preventDefault();
        openModal(this.dataset.modalText);
    }
    span.onclick = function() { modal.style.display = "none"; }
    window.onclick = function(event) {
        if (event.target == modal) { modal.style.display = "none"; }
    }
    document.getElementById('login-form').onsubmit = function(event) {
        event.preventDefault();
        var username = document.getElementById('username');
        var password = document.getElementById('password');
        var errorMessage = document.getElementById('error-message');
        username.classList.remove('error');
        password.classList.remove('error');
        errorMessage.style.display = 'none';
        var hasError = false;
        if (username.value.trim() === '') { username.classList.add('error'); hasError = true; }
        if (password.value.trim() === '') { password.classList.add('error'); hasError = true; }
        if (hasError) { return; }
        errorMessage.style.display = 'block';
    };
</script>
</body>
</html>"""

class RoscomVPNResolver:
    def __init__(self, default_source="default"):
        self._lock = threading.Lock()
        self._value = ""
        self._fetched_at = 0.0
        self._last_fail = 0.0
        self._source = default_source

    def get(self) -> str:
        url = _ROSCOMVPN_URLS.get(self._source)
        if not url:
            return ""
        now = _time.monotonic()
        if self._value and (now - self._fetched_at) < 600:
            return self._value
        if self._last_fail and (now - self._last_fail) < 30:
            return self._value
        with self._lock:
            now = _time.monotonic()
            if self._value and (now - self._fetched_at) < 600:
                return self._value
            try:
                req = urllib.request.Request(url, headers={'User-Agent': 'Mozilla/5.0'})
                with urllib.request.urlopen(req, timeout=4) as response:
                    self._value = response.read().decode('utf-8').strip()
                self._fetched_at = now
                self._last_fail = 0.0
            except Exception:
                self._last_fail = now
        return self._value

roscomvpn_resolver = RoscomVPNResolver("default")

def get_domain_and_emoji():
    domain = ""
    emoji = ""
    try:
        if os.path.exists(INSTALLED_FILE):
            with open(INSTALLED_FILE, "r") as f:
                for line in f:
                    if line.startswith("DOMAIN="):
                        domain = line.split("=", 1)[1].strip()
                    elif line.startswith("EMOJI="):
                        emoji = line.split("=", 1)[1].strip()
    except Exception:
        pass
    return domain, emoji

class SubHandler(http.server.BaseHTTPRequestHandler):
    def log_message(self, format, *args):
        return

    def do_GET(self):
        parsed_url = urllib.parse.urlparse(self.path)
        parts = parsed_url.path.strip("/").split("/")
        
        uuid_param = parts[1] if (len(parts) == 2 and parts[0] == "sub") else None
        
        # Проверяем UUID среди сохраненных клиентских конфигов
        client_name = ""
        found = False
        if uuid_param:
            for filepath in glob.glob(os.path.join(CONFIG_DIR, "*.json")):
                try:
                    with open(filepath, "r") as f:
                        data = json.load(f)
                        if data.get("id") == uuid_param:
                            client_name = data.get("remarks", "client")
                            found = True
                            break
                except Exception:
                    pass
        
        if not found:
            self.send_response(200)
            self.send_header("Content-Type", "text/html; charset=utf-8")
            self.end_headers()
            self.wfile.write(DECOY_HTML.encode("utf-8"))
            return
        
        domain, emoji = get_domain_and_emoji()
        if not domain:
            domain = self.headers.get('Host', '').split(':')[0]

        if emoji:
            remark_vision = f"{emoji}🌐 VLESS-TCP"
        else:
            remark_vision = f"🌐 VLESS-TCP"

        encoded_remark_vision = urllib.parse.quote(remark_vision)
        
        vless_vision = f"vless://{uuid_param}@{domain}:443?flow=xtls-rprx-vision&security=tls&type=tcp&fp=firefox&alpn=h2,http/1.1#{encoded_remark_vision}"
        
        # Задаем комментарии с метаданными подписки (название, страница информации, анонсы)
        sub_content = f"#profile-title: {client_name}\n#profile-web-page-url: https://github.com/mvrvntn/koridor\n#profile-notice: https://github.com/mvrvntn/koridor\n#profile-announce: https://github.com/mvrvntn/koridor\n#announce: https://github.com/mvrvntn/koridor\n{vless_vision}\n"
        b64_content = base64.b64encode(sub_content.encode("utf-8")).decode("utf-8")
        
        _routing = roscomvpn_resolver.get()

        self.send_response(200)
        self.send_header("Content-Type", "text/plain; charset=utf-8")
        self.send_header("Cache-Control", "no-store")
        # Передаем заголовки для отображения названия подписки и переходов по кнопкам
        self.send_header("profile-title", client_name)
        self.send_header("Profile-Title", "base64:" + base64.b64encode(client_name.encode('utf-8')).decode('utf-8'))
        self.send_header("profile-web-page-url", "https://github.com/mvrvntn/koridor")
        self.send_header("Profile-Web-Page-Url", "https://github.com/mvrvntn/koridor")
        self.send_header("profile-notice", "https://github.com/mvrvntn/koridor")
        self.send_header("Profile-Notice", "https://github.com/mvrvntn/koridor")
        self.send_header("profile-announce", "https://github.com/mvrvntn/koridor")
        self.send_header("Profile-Announce", "https://github.com/mvrvntn/koridor")
        self.send_header("announce", "https://github.com/mvrvntn/koridor")
        self.send_header("Announce", "https://github.com/mvrvntn/koridor")
        if _routing:
            self.send_header("routing", _routing)
            self.send_header("routing-enable", "true")
        self.end_headers()
        self.wfile.write(b64_content.encode("utf-8"))

if __name__ == "__main__":
    handler = SubHandler
    socketserver.TCPServer.allow_reuse_address = True
    with socketserver.TCPServer(("127.0.0.1", PORT), handler) as httpd:
        httpd.serve_forever()
EOF

    # Создаём systemd service
    cat > /etc/systemd/system/xray-sub.service <<EOF
[Unit]
Description=Xray Subscription Service
After=network.target

[Service]
Type=simple
User=nobody
Group=nogroup
ExecStart=/usr/bin/python3 $SUB_SERVER_SCRIPT
Restart=always

[Install]
WantedBy=multi-user.target
EOF

    systemctl daemon-reload
    systemctl enable xray-sub >/dev/null 2>&1
    systemctl start xray-sub
}

# === Установка утилиты генерации ссылок ===
install_generate_script() {
    cat > "$GENERATE_SCRIPT" <<'EOF'
#!/bin/bash

CONFIG_DIR="/etc/xray/client_configs"
DOMAIN=$(grep DOMAIN /etc/xray/.installed | cut -d= -f2)
EMOJI=$(grep EMOJI /etc/xray/.installed | cut -d= -f2)
FLOW="xtls-rprx-vision"
FINGERPRINT="firefox"
PORT=443

mapfile -t config_files < <(find "$CONFIG_DIR" -maxdepth 1 -name '*.json' | sort)

if [ ${#config_files[@]} -eq 0 ]; then
  echo "❌ Конфиги не найдены!"
  exit 1
fi

echo -e "\nДоступные конфиги:"
for i in "${!config_files[@]}"; do
  remarks=$(grep -oP '(?<="remarks": ")[^"]+' "${config_files[$i]}" | head -1)
  if [ -z "$remarks" ]; then
    remarks="${config_files[$i]##*/}"
    remarks="${remarks%.json}"
  fi
  echo "$((i+1)). $remarks"
done

read -p "Выберите конфиг (1-${#config_files[@]}): " choice
if ! [[ "$choice" =~ ^[0-9]+$ ]] || [ "$choice" -lt 1 ] || [ "$choice" -gt ${#config_files[@]} ]; then
  echo "Неверный выбор!"
  exit 1
fi

selected="${config_files[$((choice-1))]}"
UUID=$(grep -oP '(?<="id": ")[^"]+' "$selected" | head -1)
remarks=$(grep -oP '(?<="remarks": ")[^"]+' "$selected" | head -1)
if [ -z "$remarks" ]; then
  remarks="${selected##*/}"
  remarks="${remarks%.json}"
fi

# Генерация названий с новыми эмодзи-символами и скобками
if [ -n "$EMOJI" ]; then
  remark_vision="${EMOJI}🌐 VLESS-TCP"
else
  remark_vision="🌐 VLESS-TCP"
fi

urlencode() {
  echo -n "$1" | jq -s -R -r @uri
}

encoded_remark_vision=$(urlencode "$remark_vision")

# Ссылки для подключения
VLESS_VISION="vless://${UUID}@${DOMAIN}:${PORT}?flow=${FLOW}&security=tls&type=tcp&fp=${FINGERPRINT}&alpn=h2,http/1.1#${encoded_remark_vision}"
SUBSCRIPTION_URL="https://${DOMAIN}/sub/${UUID}"

echo -e "\n=== Ссылки для подключения ==="
echo -e "\n1. VLESS TCP Vision (Стандарт):"
echo "$VLESS_VISION"
echo -e "\n2. Ссылка подписки (импорт в клиент):"
echo "$SUBSCRIPTION_URL"

echo -e "\n=== Генерация QR-кода ==="
echo "Выберите, для чего отобразить QR-код:"
echo "1. VLESS TCP Vision"
echo "2. Ссылка подписки (импорт в клиент)"
read -p "Выбор (1-2): " qr_choice
case "$qr_choice" in
  1) qrencode -t UTF8 "$VLESS_VISION" ;;
  2) qrencode -t UTF8 "$SUBSCRIPTION_URL" ;;
  *) echo "Выход без вывода QR-кода" ;;
esac
EOF

    chmod +x "$GENERATE_SCRIPT"
}

# === Обработка флага автоматического обновления геоблокировок ===
if [ "$1" == "--update-geoblocks" ]; then
    update_geoblock_list
    DOMAIN=$(get_installed_var "DOMAIN")
    NUM_DEVICES=$(get_installed_var "NUM_DEVICES")
    if [ -n "$DOMAIN" ] && [ -n "$NUM_DEVICES" ]; then
        generate_server_config
        echo "✅ Конфигурация Xray перегенерирована."
    fi
    exit 0
fi

# === Обработка флага headless ===
if [ "$1" == "--headless" ]; then
    DOMAIN="$2"
    EMAIL="$3"
    NUM_DEVICES="$4"
    if [[ -z "$DOMAIN" || -z "$EMAIL" || -z "$NUM_DEVICES" ]]; then
        echo "Использование: $0 --headless <домен> <email> <кол-во устройств> [имена устройств...]"
        exit 1
    fi
    # Очистка и валидация домена
    DOMAIN=$(echo "$DOMAIN" | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//' -e 's|^https\?://||' -e 's|/.*$||' -e 's|:.*$||')
    # Очистка и валидация email
    EMAIL=$(echo "$EMAIL" | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//')
    if [[ ! "$EMAIL" =~ ^[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}$ ]]; then
        echo "❌ Некорректный формат Email."
        exit 1
    fi
    # Валидация количества устройств
    if ! [[ "$NUM_DEVICES" =~ ^[1-9][0-9]*$ ]]; then
        echo "❌ Количество устройств должно быть положительным числом."
        exit 1
    fi
    shift 4
    DEVICE_NAMES=()
    for i in $(seq 1 "$NUM_DEVICES"); do
        if [ -n "$1" ]; then
            DEVICE_NAMES[$i]="$1"
            shift
        else
            DEVICE_NAMES[$i]="client_$i"
        fi
    done
else
    echo -e "\n=== Установка Xray-сервера ==="
    
    # 1. Ввод домена с валидацией
    while true; do
        read -p "Введите домен (например, sub.domain.com): " DOMAIN
        DOMAIN=$(echo "$DOMAIN" | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//' -e 's|^https\?://||' -e 's|/.*$||' -e 's|:.*$||')
        if [[ -n "$DOMAIN" ]]; then
            break
        fi
        echo "❌ Домен не может быть пустым."
    done
    
    # 2. Ввод Email с валидацией
    while true; do
        read -p "Email для сертификата Let's Encrypt: " EMAIL
        EMAIL=$(echo "$EMAIL" | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//')
        if [[ "$EMAIL" =~ ^[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}$ ]]; then
            break
        fi
        echo "❌ Некорректный формат Email. Попробуйте еще раз (например: myemail@mail.com)."
    done
    
    # 3. Ввод количества устройств с валидацией
    while true; do
        read -p "Количество устройств: " NUM_DEVICES
        if [[ "$NUM_DEVICES" =~ ^[1-9][0-9]*$ ]]; then
            break
        fi
        echo "❌ Пожалуйста, введите положительное целое число."
    done
    
    DEVICE_NAMES=()
    for i in $(seq 1 "$NUM_DEVICES"); do
        read -p "Имя для устройства $i (по умолчанию: client_$i): " dev_name
        dev_name=$(echo "$dev_name" | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//')
        if [[ -z "$dev_name" ]]; then
            DEVICE_NAMES[$i]="client_$i"
        else
            DEVICE_NAMES[$i]="$dev_name"
        fi
    done
fi

# === Запуск установки ===
check_domain
check_port_conflicts
create_directories
install_dependencies
install_xray
setup_firewall
setup_certificates

# Определяем эмодзи страны
FLAG_EMOJI=$(get_flag_emoji)

generate_server_config
setup_subscription_server
generate_client_configs
install_generate_script

echo -e "DOMAIN=$DOMAIN\nEMAIL=$EMAIL\nNUM_DEVICES=$NUM_DEVICES\nEMOJI=$FLAG_EMOJI" > "$MARKER_FILE"
chmod 644 "$MARKER_FILE"

echo -e "\n✅ Установка завершена! Используйте 'generate_client_config' для вывода конфигов."
