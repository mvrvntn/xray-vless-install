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

# === Цветовая схема терминала ===
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
BLUE='\033[0;34m'
PURPLE='\033[0;35m'
CYAN='\033[0;36m'
BOLD='\033[1m'
NC='\033[0m' # No Color

# Регистрация команды xry
install_xry_command() {
    local target_bin="/usr/local/bin/xry"
    if cp "$0" "$target_bin" 2>/dev/null; then
        chmod +x "$target_bin"
        echo -e "${GREEN}🚀 Команда быстрого запуска 'xry' успешно зарегистрирована! Используйте её для вызова этого меню из любой директории. ${NC}"
    else
        ln -sf "$(realpath "$0")" "$target_bin" 2>/dev/null
    fi
}

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
        apt install -y wireguard wireguard-tools >/dev/null
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

# === Проверка домена ===
echo "🔍 Проверка резолва домена..."
check_domain() {
    if ! getent hosts "$DOMAIN" >/dev/null; then
        echo "⚠️ Локальное разрешение домена не удалось, выполняем резервную проверку через внешние DNS..."
        local resolved_ip
        
        # Запрос к Cloudflare DNS-over-HTTPS напрямую по IP 1.1.1.1 (не требует работающего DNS на сервере)
        resolved_ip=$(curl -sH "accept: application/dns-json" --connect-timeout 5 "https://1.1.1.1/dns-query?name=$DOMAIN&type=A" | python3 -c "import json, sys; print(json.load(sys.stdin).get('Answer', [{}])[0].get('data', ''))" 2>/dev/null)
        if [[ "$resolved_ip" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
            echo "ℹ️ Внешняя проверка через 1.1.1.1 подтвердила IP домена: $resolved_ip"
            return 0
        fi
        
        # Запрос к Google DNS-over-HTTPS напрямую по IP 8.8.8.8
        resolved_ip=$(curl -sH "accept: application/dns-json" --connect-timeout 5 "https://8.8.8.8/resolve?name=$DOMAIN&type=A" | python3 -c "import json, sys; print(json.load(sys.stdin).get('Answer', [{}])[0].get('data', ''))" 2>/dev/null)
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
    
    # 1. Проверка стандартных веб-серверов
    for svc in nginx apache2 caddy httpd; do
        if systemctl is-active --quiet "$svc"; then
            echo -e "⚠️ Служба $svc запущена и занимает порты 80/443."
            echo "🛑 Отключаем и останавливаем $svc, чтобы Xray и Certbot могли запуститься..."
            systemctl stop "$svc" >/dev/null 2>&1
            systemctl disable "$svc" >/dev/null 2>&1
            conflict=true
        fi
    done
    
    # 2. Проверка OpenVPN TCP служб AntiZapret
    for antizapret_svc in openvpn-server@antizapret-tcp openvpn-server@antizapret-no-vpn-tcp openvpn-server@server-tcp; do
        if systemctl is-active --quiet "$antizapret_svc"; then
            echo -e "⚠️ Обнаружена активная служба AntiZapret TCP: $antizapret_svc (занимает порт 443 TCP)."
            echo "🛑 Останавливаем и отключаем $antizapret_svc для освобождения порта 443 под VLESS..."
            systemctl stop "$antizapret_svc" >/dev/null 2>&1
            systemctl disable "$antizapret_svc" >/dev/null 2>&1
            conflict=true
        fi
    done
    
    # 3. Глубокое сканирование через ss на наличие любых других процессов на порту 443 или 80
    local port_443_pid=$(ss -tlnp 'sport = :443' 2>/dev/null | grep -oE 'pid=[0-9]+' | cut -d= -f2 | head -n 1)
    if [ -n "$port_443_pid" ]; then
        local proc_name=$(ps -p "$port_443_pid" -o comm= 2>/dev/null)
        echo -e "❌ Порт 443 TCP занят сторонним процессом '$proc_name' (PID: $port_443_pid)."
        read -p "Попытаться автоматически завершить процесс '$proc_name' для продолжения установки? [y/N]: " kill_choice
        if [[ "$kill_choice" =~ ^[Yy]$ ]]; then
            kill -9 "$port_443_pid"
            echo "✅ Процесс '$proc_name' принудительно завершен."
        else
            echo "❌ Установка остановлена из-за конфликта портов."
            exit 1
        fi
    fi
    
    local port_80_pid=$(ss -tlnp 'sport = :80' 2>/dev/null | grep -oE 'pid=[0-9]+' | cut -d= -f2 | head -n 1)
    if [ -n "$port_80_pid" ]; then
        local proc_name=$(ps -p "$port_80_pid" -o comm= 2>/dev/null)
        echo -e "❌ Порт 80 TCP занят сторонним процессом '$proc_name' (PID: $port_80_pid)."
        read -p "Попытаться автоматически завершить процесс '$proc_name' для продолжения установки? [y/N]: " kill_choice
        if [[ "$kill_choice" =~ ^[Yy]$ ]]; then
            kill -9 "$port_80_pid"
            echo "✅ Процесс '$proc_name' принудительно завершен."
        else
            echo "❌ Установка остановлена из-за конфликта портов."
            exit 1
        fi
    fi
    
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
    
    # Динамически определяем запущенные и настроенные порты SSH, чтобы не заблокировать пользователя
    local ssh_ports=$( (ss -tlnp 2>/dev/null | grep -E '("sshd"|:22\s)' | awk '{print $4}' | awk -F':' '{print $NF}'; grep -hE '^\s*Port\s+' /etc/ssh/sshd_config /etc/ssh/sshd_config.d/*.conf 2>/dev/null | awk '{print $2}') | sort -u )
    if [ -n "$ssh_ports" ]; then
        for port in $ssh_ports; do
            if [[ "$port" =~ ^[0-9]+$ ]]; then
                ufw allow "$port"/tcp > /dev/null
            fi
        done
    else
        ufw allow 22/tcp > /dev/null
    fi
    
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
    local vless_xhttp_clients=()
    
    # Проверяем, есть ли уже клиенты
    if [ -d "$CLIENT_CONFIG_DIR" ] && [ "$(find "$CLIENT_CONFIG_DIR" -name '*.json' 2>/dev/null | wc -l)" -gt 0 ]; then
        local idx=1
        for filepath in $(find "$CLIENT_CONFIG_DIR" -maxdepth 1 -name '*.json' | sort); do
            local uuid=$(python3 -c "import json, sys; print(json.load(open(sys.argv[1])).get('id', ''))" "$filepath" 2>/dev/null)
            if [ -n "$uuid" ] && [ "$uuid" != "null" ]; then
                UUIDs[$idx]="$uuid"
                vless_clients+=("{
                  \"id\": \"$uuid\",
                  \"flow\": \"xtls-rprx-vision\",
                  \"email\": \"client-$idx\"
                }")
                vless_xhttp_clients+=("{
                  \"id\": \"$uuid\",
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
            vless_xhttp_clients+=("{
              \"id\": \"$uuid\",
              \"email\": \"client-$i\"
            }")
        done
    fi
    
    local vless_clients_str=$(IFS=,; echo "${vless_clients[*]}")
    local vless_xhttp_clients_str=$(IFS=,; echo "${vless_xhttp_clients[*]}")
    
    # Проверяем статус WARP
    local warp_enabled=$(get_installed_var "WARP_ENABLED")
    local warp_mode=$(get_installed_var "WARP_MODE")
    [ -z "$warp_mode" ] && warp_mode="smart"
    
    local outbounds_str
    local routing_rules_str=""
    local warp_check_rules_str=""
    
    if [ "$warp_enabled" == "true" ]; then
        warp_check_rules_str=",
      {
        \"type\": \"field\",
        \"domain\": [
          \"domain:whoer.net\",
          \"domain:browserleaks.com\",
          \"domain:2ip.io\",
          \"domain:2ip.ru\",
          \"domain:2ip.ua\",
          \"domain:ipleak.net\",
          \"domain:ipinfo.io\",
          \"domain:whatismyip.com\",
          \"domain:whatismyipaddress.com\",
          \"domain:iplocation.net\",
          \"domain:dnsleaktest.com\",
          \"domain:dnsleak.com\",
          \"domain:am.i.mullvad.net\",
          \"domain:myip.com\",
          \"domain:myip.ru\",
          \"domain:ip.me\",
          \"domain:ifconfig.me\",
          \"domain:ident.me\",
          \"domain:checkip.amazonaws.com\",
          \"domain:ip-api.com\",
          \"domain:ipify.org\",
          \"domain:icanhazip.com\",
          \"domain:ip-score.com\",
          \"domain:doileak.com\",
          \"domain:bash.ws\",
          \"domain:f.vision\",
          \"domain:amiunique.org\",
          \"domain:deviceinfo.me\",
          \"domain:coveryourtracks.eff.org\",
          \"domain:showmyip.com\",
          \"domain:ip8.com\",
          \"domain:gemini.google.com\",
          \"domain:generativelanguage.googleapis.com\",
          \"domain:accounts.google.com\",
          \"domain:googleapis.com\",
          \"domain:gstatic.com\",
          \"domain:googleusercontent.com\",
          \"domain:webrtc.org\",
          \"domain:stun.l.google.com\"
        ],
        \"outboundTag\": \"WARP\"
      }"
    fi
    
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
          "tcpFastOpen": true,
          "tcpcongestion": "bbr",
          "tcpKeepAliveIdle": 300
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
          "tcpFastOpen": true,
          "tcpcongestion": "bbr",
          "tcpKeepAliveIdle": 300
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
          "tcpFastOpen": true,
          "tcpcongestion": "bbr",
          "tcpKeepAliveIdle": 300
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
          "tcpFastOpen": true,
          "tcpcongestion": "bbr",
          "tcpKeepAliveIdle": 300
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
          "tcpFastOpen": true,
          "tcpcongestion": "bbr",
          "tcpKeepAliveIdle": 300
        }
      }
    },
    {
      "tag": "BLOCK",
      "protocol": "blackhole"
    }
  ]'
    fi
    
    # Читаем CDN_DOMAIN
    local cdn_domain=$(get_installed_var "CDN_DOMAIN")
    [ -z "$cdn_domain" ] && cdn_domain="none"

    local fallbacks_str='[
          {
            "path": "/sub/",
            "dest": "127.0.0.1:10080"
          },
          {
            "dest": "127.0.0.1:10080"
          }
        ]'
    local extra_inbound=""
    if [ "$cdn_domain" != "none" ] && [ -n "$cdn_domain" ]; then
        fallbacks_str='[
          {
            "path": "/sub/",
            "dest": "127.0.0.1:10080"
          },
          {
            "path": "/xh",
            "dest": "127.0.0.1:10085",
            "xver": 1
          },
          {
            "dest": "127.0.0.1:10080"
          }
        ]'
        extra_inbound=",
    {
      \"port\": 10085,
      \"listen\": \"127.0.0.1\",
      \"protocol\": \"vless\",
      \"settings\": {
        \"clients\": [$vless_xhttp_clients_str],
        \"decryption\": \"none\"
      },
      \"streamSettings\": {
        \"network\": \"xhttp\",
        \"acceptProxyProtocol\": true,
        \"xhttpSettings\": {
          \"path\": \"/xh\",
          \"mode\": \"packet-up\"
        }
      }
    }"
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
        "fallbacks": $fallbacks_str
      },
      "sniffing": {
        "enabled": true,
        "destOverride": [
          "http",
          "tls",
          "quic"
        ],
        "routeOnly": true
      },
      "streamSettings": {
        "network": "tcp",
        "security": "tls",
        "tlsSettings": {
          "certificates": [{
            "certificateFile": "$SSL_DIR/fullchain.cer",
            "keyFile": "$SSL_DIR/private.key"
          }],
          "alpn": [
            "http/1.1"
          ],
          "minVersion": "1.3"
        },
        "sockopt": {
          "tcpFastOpen": true,
          "tcpcongestion": "bbr",
          "tcpKeepAliveIdle": 300
        }
      }
    }${extra_inbound}
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
      }${routing_rules_str}${warp_check_rules_str}
    ]
  }
}
EOF

    systemctl restart xray
}

# === Генерация клиентских конфигов ===
generate_client_configs() {
    echo "📦 Генерация клиентских конфигов..."
    mkdir -p "$CLIENT_CONFIG_DIR"
    
    local DOMAIN=$(get_installed_var "DOMAIN")
    local FINGERPRINT=$(get_installed_var "FINGERPRINT")
    if [ -z "$FINGERPRINT" ]; then FINGERPRINT="ios"; fi

    if [ -d "$CLIENT_CONFIG_DIR" ] && [ "$(find "$CLIENT_CONFIG_DIR" -maxdepth 1 -name '*.json' 2>/dev/null | wc -l)" -gt 0 ]; then
        # Обновляем существующие конфиги (идемпотентность)
        for filepath in "$CLIENT_CONFIG_DIR"/*.json; do
            [ -e "$filepath" ] || continue
            
            local uuid=$(python3 -c "import json, sys; print(json.load(open(sys.argv[1])).get('id', ''))" "$filepath" 2>/dev/null)
            local name=$(python3 -c "import json, sys; print(json.load(open(sys.argv[1])).get('remarks', ''))" "$filepath" 2>/dev/null)
            
            if [ -z "$uuid" ] || [ "$uuid" == "null" ]; then continue; fi
            if [ -z "$name" ] || [ "$name" == "null" ]; then
                name="${filepath##*/}"
                name="${name%.json}"
            fi

            cat > "$filepath" <<EOF
{
  "remarks": "$name",
  "id": "$uuid",
  "outbounds": [{
    "protocol": "vless",
    "settings": {
      "vnext": [{
        "address": "$DOMAIN",
        "port": 443,
        "users": [{
          "id": "$uuid",
          "flow": "xtls-rprx-vision"
        }]
      }]
    },
    "streamSettings": {
      "network": "tcp",
      "security": "tls",
      "tlsSettings": {
        "fingerprint": "$FINGERPRINT",
        "minVersion": "1.3"
      },
      "sockopt": {
          "tcpFastOpen": true,
          "tcpcongestion": "bbr",
          "tcpKeepAliveIdle": 300
        }
    }
  }]
}
EOF
        done
    else
        # Генерация первичных конфигов (установка с нуля)
        for i in $(seq 1 "$NUM_DEVICES"); do
            local name="${DEVICE_NAMES[$i]}"
            local uuid="${UUIDs[$i]}"
            
            [[ -z "$uuid" ]] && uuid=$(cat /proc/sys/kernel/random/uuid)
            [[ -z "$name" ]] && name="Device_$i"

            local filename="client_$i"
            local safe_filename=$(echo "$name" | tr -cd '[:alnum:]_.-' | tr '[:upper:]' '[:lower:]')
            if [[ -n "$safe_filename" ]]; then
                filename="$safe_filename"
            fi

            cat > "$CLIENT_CONFIG_DIR/${filename}.json" <<EOF
{
  "remarks": "$name",
  "id": "$uuid",
  "outbounds": [{
    "protocol": "vless",
    "settings": {
      "vnext": [{
        "address": "$DOMAIN",
        "port": 443,
        "users": [{
          "id": "$uuid",
          "flow": "xtls-rprx-vision"
        }]
      }]
    },
    "streamSettings": {
      "network": "tcp",
      "security": "tls",
      "tlsSettings": {
        "fingerprint": "$FINGERPRINT",
        "minVersion": "1.3"
      },
      "sockopt": {
          "tcpFastOpen": true,
          "tcpcongestion": "bbr",
          "tcpKeepAliveIdle": 300
        }
    }
  }]
}
EOF
        done
    fi

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
        self._source = default_source
        self._is_fetching = False

    def _bg_fetch(self):
        url = _ROSCOMVPN_URLS.get(self._source)
        if not url:
            return
        try:
            req = urllib.request.Request(url, headers={'User-Agent': 'Mozilla/5.0'})
            with urllib.request.urlopen(req, timeout=5) as response:
                val = response.read().decode('utf-8').strip()
            with self._lock:
                self._value = val
                self._fetched_at = _time.monotonic()
        except Exception:
            with self._lock:
                # В случае сетевой ошибки делаем задержку в 60 секунд перед следующей попыткой запроса
                self._fetched_at = _time.monotonic() - 540.0
        finally:
            with self._lock:
                self._is_fetching = False

    def get(self) -> str:
        now = _time.monotonic()
        if (not self._value or (now - self._fetched_at) > 600) and not self._is_fetching:
            with self._lock:
                if not self._is_fetching:
                    self._is_fetching = True
                    threading.Thread(target=self._bg_fetch, daemon=True).start()
        return self._value

roscomvpn_resolver = RoscomVPNResolver("default")

def get_domain_emoji_fp():
    domain = ""
    emoji = ""
    fp = "chrome"
    cdn_domain = ""
    try:
        if os.path.exists(INSTALLED_FILE):
            with open(INSTALLED_FILE, "r") as f:
                for line in f:
                    if line.startswith("DOMAIN="):
                        domain = line.split("=", 1)[1].strip()
                    elif line.startswith("EMOJI="):
                        emoji = line.split("=", 1)[1].strip()
                    elif line.startswith("FINGERPRINT="):
                        fp = line.split("=", 1)[1].strip()
                    elif line.startswith("CDN_DOMAIN="):
                        cdn_domain = line.split("=", 1)[1].strip()
    except Exception:
        pass
    if not fp:
        fp = "chrome"
    return domain, emoji, fp, cdn_domain

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
        
        domain, emoji, fp, cdn_domain = get_domain_emoji_fp()
        if not domain:
            domain = self.headers.get('Host', '').split(':')[0]

        if emoji:
            remark_vision = f"{emoji} VLESS-TCP"
            remark_xhttp = f"⚡ {emoji} VLESS-XHTTP"
        else:
            remark_vision = "🌐 VLESS-TCP"
            remark_xhttp = "⚡ VLESS-XHTTP"

        encoded_remark_vision = urllib.parse.quote(remark_vision)
        vless_vision = f"vless://{uuid_param}@{domain}:443?flow=xtls-rprx-vision&security=tls&type=tcp&fp={fp}&alpn=http/1.1#{encoded_remark_vision}"
        
        sub_content_links = vless_vision + "\n"
        if cdn_domain and cdn_domain != "none" and cdn_domain != "":
            encoded_remark_xhttp = urllib.parse.quote(remark_xhttp)
            vless_xhttp = f"vless://{uuid_param}@{cdn_domain}:443?security=tls&type=xhttp&fp={fp}&alpn=h2&path=%2Fxh&mode=packet-up#{encoded_remark_xhttp}"
            sub_content_links += vless_xhttp + "\n"
            
        client_display = f"{client_name}"
        b64_client_display = "base64:" + base64.b64encode(client_display.encode('utf-8')).decode('utf-8')
        
        announce_text = (
            "➔ Нет соединения? Нажмите ↻ Обновить\n"
            "➔ коридор: https://mvrvntn.github.io/koridor/"
        )
        b64_announce = "base64:" + base64.b64encode(announce_text.encode('utf-8')).decode('utf-8')
        
        support_url = "https://t.me/mavrtunbot" # Замените на реальный линк, если нужно

        user_agent = self.headers.get("User-Agent", "").lower()
        if "v2ray" in user_agent or "clash" in user_agent:
            sub_content = sub_content_links
        else:
            # Задаем комментарии с метаданными подписки (название, страница информации, анонсы)
            sub_content = f"#profile-title: {client_display}\n#profile-update-interval: 1\n#support-url: {support_url}\n#profile-web-page-url: https://mvrvntn.github.io/koridor/\n#announce: {announce_text}\n#fragmentation-enable: 1\n#fragmentation-packets: tlshello\n#fragmentation-length: 10-30\n#fragmentation-interval: 10-20\n{sub_content_links}"
            
        b64_content = base64.b64encode(sub_content.encode("utf-8")).decode("utf-8")
        
        _routing = roscomvpn_resolver.get()

        self.send_response(200)
        self.send_header("Content-Type", "text/plain; charset=utf-8")
        self.send_header("Cache-Control", "no-store")
        
        # Передаем заголовки для отображения названия подписки и переходов по кнопкам
        self.send_header("profile-title", b64_client_display)
        self.send_header("profile-update-interval", "1")
        self.send_header("support-url", support_url)
        self.send_header("profile-web-page-url", "https://mvrvntn.github.io/koridor/")
        self.send_header("announce", b64_announce)
        
        # Улучшение UX (Авто-обновление и пинг)
        self.send_header("subscription-auto-update-enable", "1")
        self.send_header("subscription-ping-onopen-enabled", "1")
        self.send_header("subscription-autoconnect", "1")
        self.send_header("subscription-autoconnect-type", "lastused")
        
        # Анти-DPI фрагментация на стороне клиента (для Incy/Happ)
        self.send_header("fragmentation-enable", "1")
        self.send_header("fragmentation-packets", "tlshello")
        self.send_header("fragmentation-length", "10-30")
        self.send_header("fragmentation-interval", "10-20")

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
    systemctl restart xray-sub
}

# === Установка утилиты генерации ссылок ===
install_generate_script() {
    cat > "$GENERATE_SCRIPT" <<'EOF'
#!/bin/bash

# Цвета для красивого вывода
BOLD='\033[1m'
NC='\033[0m'
CYAN='\033[0;36m'
PURPLE='\033[0;35m'
YELLOW='\033[0;33m'
GREEN='\033[0;32m'
RED='\033[0;31m'

  CONFIG_DIR="/etc/xray/client_configs"
  DOMAIN=$(grep DOMAIN /etc/xray/.installed | cut -d= -f2)
  CDN_DOMAIN=$(grep CDN_DOMAIN /etc/xray/.installed | cut -d= -f2 2>/dev/null)
  EMOJI=$(grep EMOJI /etc/xray/.installed | cut -d= -f2)
  FLOW="xtls-rprx-vision"
  FINGERPRINT=$(grep FINGERPRINT /etc/xray/.installed | cut -d= -f2)
  if [ -z "$FINGERPRINT" ]; then FINGERPRINT="ios"; fi
  PORT=443

mapfile -t config_files < <(find "$CONFIG_DIR" -maxdepth 1 -name '*.json' | sort)

if [ ${#config_files[@]} -eq 0 ]; then
  echo -e "${RED}❌ Конфиги не найдены!${NC}"
  exit 1
fi

echo -e "\n${BOLD}${CYAN}┌────────────────────────────────────────────────────────┐${NC}"
echo -e "${BOLD}${CYAN}│                 Доступные устройства                  │${NC}"
echo -e "${BOLD}${CYAN}└────────────────────────────────────────────────────────┘${NC}"
for i in "${!config_files[@]}"; do
  remarks=$(python3 -c "import json, sys; print(json.load(open(sys.argv[1])).get('remarks', ''))" "${config_files[$i]}" 2>/dev/null)
  if [ -z "$remarks" ] || [ "$remarks" = "null" ]; then
    remarks="${config_files[$i]##*/}"
    remarks="${remarks%.json}"
  fi
  echo -e " ${BOLD}${YELLOW}$((i+1)).${NC} 📱 $remarks"
done
echo -e "${CYAN}──────────────────────────────────────────────────────────${NC}"

read -p "Выберите устройство (1-${#config_files[@]}): " choice
if ! [[ "$choice" =~ ^[0-9]+$ ]] || [ "$choice" -lt 1 ] || [ "$choice" -gt ${#config_files[@]} ]; then
  echo -e "${RED}❌ Неверный выбор!${NC}"
  exit 1
fi

selected="${config_files[$((choice-1))]}"
UUID=$(python3 -c "import json, sys; print(json.load(open(sys.argv[1])).get('id', ''))" "$selected" 2>/dev/null)
remarks=$(python3 -c "import json, sys; print(json.load(open(sys.argv[1])).get('remarks', ''))" "$selected" 2>/dev/null)
if [ -z "$remarks" ] || [ "$remarks" = "null" ]; then
  remarks="${selected##*/}"
  remarks="${remarks%.json}"
fi

# Генерация названий с новыми эмодзи-символами и скобками
if [ -n "$EMOJI" ]; then
  remark_vision="${EMOJI} VLESS-TCP"
  remark_xhttp="⚡ ${EMOJI} VLESS-XHTTP"
else
  remark_vision="🌐 VLESS-TCP"
  remark_xhttp="⚡ VLESS-XHTTP"
fi

urlencode() {
  python3 -c "import urllib.parse, sys; print(urllib.parse.quote(sys.argv[1]), end='')" "$1" 2>/dev/null || echo -n "$1"
}

encoded_remark_vision=$(urlencode "$remark_vision")
encoded_remark_xhttp=$(urlencode "$remark_xhttp")

# Ссылки для подключения
VLESS_VISION="vless://${UUID}@${DOMAIN}:${PORT}?flow=${FLOW}&security=tls&type=tcp&fp=${FINGERPRINT}&alpn=http/1.1#${encoded_remark_vision}"
SUBSCRIPTION_URL="https://${DOMAIN}/sub/${UUID}"

echo -e "\n${BOLD}${PURPLE}┌────────────────────────────────────────────────────────┐${NC}"
echo -e "${BOLD}${PURPLE}│                Ссылки для подключения                  │${NC}"
echo -e "${BOLD}${PURPLE}└────────────────────────────────────────────────────────┘${NC}"
echo -e " ${BOLD}${YELLOW}1. VLESS TCP Vision (Стандарт, напрямую):${NC}"
echo -e "    ${GREEN}$VLESS_VISION${NC}"

has_cdn=false
if [ -n "$CDN_DOMAIN" ] && [ "$CDN_DOMAIN" != "none" ] && [ "$CDN_DOMAIN" != "" ]; then
  has_cdn=true
  VLESS_XHTTP="vless://${UUID}@${CDN_DOMAIN}:${PORT}?security=tls&type=xhttp&fp=${FINGERPRINT}&alpn=h2&path=%2Fxh&mode=packet-up#${encoded_remark_xhttp}"
  echo -e "\n ${BOLD}${YELLOW}2. VLESS XHTTP (Подключение через CDN, Тестовый режим):${NC}"
  echo -e "    ${GREEN}$VLESS_XHTTP${NC}"
fi

echo -e "\n ${BOLD}${YELLOW}Ссылка подписки (импорт в клиент):${NC}"
echo -e "    ${CYAN}$SUBSCRIPTION_URL${NC}"
echo -e "${PURPLE}──────────────────────────────────────────────────────────${NC}"

echo -e "\n${BOLD}${CYAN}┌────────────────────────────────────────────────────────┐${NC}"
echo -e "${BOLD}${CYAN}│                   Генерация QR-кода                    │${NC}"
echo -e "${BOLD}${CYAN}└────────────────────────────────────────────────────────┘${NC}"
echo -e " Выберите, для чего отобразить QR-код:"
echo -e " ${BOLD}${YELLOW}1.${NC} 📱 VLESS TCP Vision"
if [ "$has_cdn" = true ]; then
  echo -e " ${BOLD}${YELLOW}2.${NC} ⚡ VLESS XHTTP (Тестовый режим)"
  echo -e " ${BOLD}${YELLOW}3.${NC} 🔄 Ссылка подписки"
  echo -e "${CYAN}──────────────────────────────────────────────────────────${NC}"
  read -p "Ваш выбор (1-3): " qr_choice
  case "$qr_choice" in
    1) qrencode -t UTF8 "$VLESS_VISION" ;;
    2) qrencode -t UTF8 "$VLESS_XHTTP" ;;
    3) qrencode -t UTF8 "$SUBSCRIPTION_URL" ;;
    *) echo -e "${RED}Выход без вывода QR-кода${NC}" ;;
  esac
else
  echo -e " ${BOLD}${YELLOW}2.${NC} 🔄 Ссылка подписки"
  echo -e "${CYAN}──────────────────────────────────────────────────────────${NC}"
  read -p "Ваш выбор (1-2): " qr_choice
  case "$qr_choice" in
    1) qrencode -t UTF8 "$VLESS_VISION" ;;
    2) qrencode -t UTF8 "$SUBSCRIPTION_URL" ;;
    *) echo -e "${RED}Выход без вывода QR-кода${NC}" ;;
  esac
fi
EOF

    chmod +x "$GENERATE_SCRIPT"
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

    run_diagnostics() {
        echo -e "\n${BOLD}${CYAN}┌────────────────────────────────────────────────────────┐${NC}"
        echo -e "${BOLD}${CYAN}│             ДИАГНОСТИКА И ПОИСК НЕИСПРАВНОСТЕЙ         │${NC}"
        echo -e "${BOLD}${CYAN}└────────────────────────────────────────────────────────┘${NC}"
        
        # 1. Проверка конфликтов портов 443 и 80
        echo -e "\n${BOLD}[1] Проверка сетевых портов:${NC}"
        local port_443_process=$(ss -tlnp 'sport = :443' 2>/dev/null | grep -v 'Local Address' | awk '{print $NF}')
        local port_80_process=$(ss -tlnp 'sport = :80' 2>/dev/null | grep -v 'Local Address' | awk '{print $NF}')
        
        if [ -n "$port_443_process" ]; then
            echo -e " 🟢 Порт 443 (TCP) успешно занят процессом: ${GREEN}$port_443_process${NC}"
            if [[ "$port_443_process" =~ "openvpn" ]]; then
                echo -e "  ${RED}⚠️ ВНИМАНИЕ! Порт 443 занят процессом OpenVPN. Это приведет к неработоспособности Xray!${NC}"
            fi
        else
            echo -e " 🔴 ${RED}Порт 443 (TCP) Свободен или Xray не запущен!${NC}"
        fi
        
        if [ -n "$port_80_process" ]; then
            echo -e " 🟢 Порт 80 (TCP) успешно занят процессом: ${GREEN}$port_80_process${NC}"
        else
            echo -e " 🟡 Порт 80 (TCP) свободен (требуется Certbot для обновления сертификатов)."
        fi

        # 2. Проверка служб
        echo -e "\n${BOLD}[2] Статус системных служб:${NC}"
        if systemctl is-active --quiet xray; then
            echo -e " Xray Service: 🟢 ${GREEN}ACTIVE (Запущен)${NC}"
        else
            echo -e " Xray Service: 🔴 ${RED}INACTIVE (Остановлен)${NC}"
            journalctl -u xray -n 10 --no-pager
        fi
        
        if systemctl is-active --quiet xray-sub; then
            echo -e " Sub Service:  🟢 ${GREEN}ACTIVE (Запущен)${NC}"
        else
            echo -e " Sub Service:  🔴 ${RED}INACTIVE (Остановлен)${NC}"
            journalctl -u xray-sub -n 10 --no-pager
        fi

        # 3. Проверка резолва домена и подмены DNS (dnsmap)
        echo -e "\n${BOLD}[3] Анализ DNS-маршрутизации и домена:${NC}"
        local domain=$(get_installed_var "DOMAIN")
        if [ -n "$domain" ]; then
            echo -e " Текущий домен сервера: ${CYAN}$domain${NC}"
            local resolved_ip=$(getent hosts "$domain" | awk '{print $1}' | head -n 1)
            if [ -n "$resolved_ip" ]; then
                echo -e " Домен резолвится локально в IP: ${GREEN}$resolved_ip${NC}"
                if [[ "$resolved_ip" =~ ^10\.224\. ]]; then
                    echo -e "  ${RED}⚠️ ВНИМАНИЕ! Обнаружена подмена IP через dnsmap (сеть 10.224.x.x от AntiZapret).${NC}"
                    echo -e "  Xray использует локальный DNS хоста и может направлять трафик некорректно."
                fi
            else
                echo -e " 🔴 ${RED}Ошибка: Домен не резолвится локально!${NC}"
            fi
        else
            echo -e " 🔴 ${RED}Ошибка: Домен не зарегистрирован в системе маркеров.${NC}"
        fi

        # 4. Проверка интеграции Cloudflare WARP
        echo -e "\n${BOLD}[4] Статус Cloudflare WARP:${NC}"
        if [ "$(get_installed_var "WARP_INSTALLED")" == "true" ]; then
            if ip link show warp >/dev/null 2>&1; then
                echo -e " Интерфейс warp: 🟢 ${GREEN}UP (Поднят)${NC}"
                echo -e " Выполняем тест пинга и маршрутизации через интерфейс warp..."
                local warp_test=$(curl --interface warp -s --connect-timeout 4 https://www.cloudflare.com/cdn-cgi/trace | grep -E "(ip=|warp=)")
                if [ -n "$warp_test" ]; then
                    echo -e " 🟢 ${GREEN}Сеть WARP успешно отвечает:${NC}"
                    echo "$warp_test" | sed 's/^/   /'
                else
                    echo -e " 🔴 ${RED}Сеть WARP не пропускает трафик! Проверьте wg-quick@warp.${NC}"
                fi
            else
                echo -e " Интерфейс warp: 🔴 ${RED}DOWN (Сеть WireGuard отключена)${NC}"
            fi
        else
            echo -e " Cloudflare WARP: 🔘 Не установлен."
        fi

        # 5. Проверка сертификатов SSL
        echo -e "\n${BOLD}[5] Проверка SSL-сертификатов Let's Encrypt:${NC}"
        if [ -f "$SSL_DIR/fullchain.cer" ] && [ -f "$SSL_DIR/private.key" ]; then
            echo -e " Файлы SSL: 🟢 ${GREEN}Присутствуют в директории $SSL_DIR${NC}"
            local end_date=$(openssl x509 -enddate -noout -in "$SSL_DIR/fullchain.cer" 2>/dev/null | cut -d= -f2)
            echo -e " Срок действия сертификата до: ${YELLOW}$end_date${NC}"
        else
            echo -e " Файлы SSL: 🔴 ${RED}ОТСУТСТВУЮТ! Xray не сможет работать без TLS-сертификатов.${NC}"
        fi

        # 6. Проверка Фаерволов и Правил IPTables
        echo -e "\n${BOLD}[6] Состояние системных фаерволов:${NC}"
        if ufw status | grep -q "Status: active"; then
            echo -e " UFW Firewall: 🟢 ${GREEN}ACTIVE (Включен)${NC}"
            # Проверяем, есть ли правила AntiZapret
            if iptables -t nat -S | grep -qi "antizapret"; then
                echo -e "  ${YELLOW}⚠️ ПРЕДУПРЕЖДЕНИЕ: UFW активен одновременно с правилами NAT AntiZapret.${NC}"
                echo -e "  Это может вызывать сбои маршрутизации. Рекомендуется выполнить: ${CYAN}ufw disable${NC}"
            fi
        else
            echo -e " UFW Firewall: 🔘 ${YELLOW}DISABLED (Отключен)${NC}"
            echo -e " Убедитесь, что порты 443 и 80 разрешены напрямую в ваших правилах iptables."
        fi

        echo -e "\n${BOLD}Диагностика завершена. Нажмите Enter, чтобы вернуться назад...${NC}"
        read
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
        local FINGERPRINT=$(get_installed_var "FINGERPRINT")
        if [ -z "$FINGERPRINT" ]; then FINGERPRINT="ios"; fi

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
      "tlsSettings": {
        "fingerprint": "$FINGERPRINT",
        "minVersion": "1.3"
      },
      "sockopt": {
          "tcpFastOpen": true,
          "tcpcongestion": "bbr",
          "tcpKeepAliveIdle": 300
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
        echo -e "\n${BOLD}${RED}┌────────────────────────────────────────────────────────┐${NC}"
        echo -e "${BOLD}${RED}│                  Удаление клиента                      │${NC}"
        echo -e "${BOLD}${RED}└────────────────────────────────────────────────────────┘${NC}"
        mapfile -t config_files < <(find "$CLIENT_CONFIG_DIR" -maxdepth 1 -name '*.json' | sort)
        if [ ${#config_files[@]} -eq 0 ]; then
            echo -e " ${RED}❌ Нет доступных клиентов для удаления${NC}"
            return
        fi

        for i in "${!config_files[@]}"; do
            remarks=$(python3 -c "import json, sys; print(json.load(open(sys.argv[1])).get('remarks', ''))" "${config_files[$i]}" 2>/dev/null)
            if [ -z "$remarks" ]; then
                remarks="${config_files[$i]##*/}"
                remarks="${remarks%.json}"
            fi
            echo -e " ${BOLD}${YELLOW}$((i+1)).${NC} $remarks"
        done
        echo -e " ${BOLD}${CYAN}0.${NC} ↩️ Отмена и возврат назад"
        echo -e "${RED}──────────────────────────────────────────────────────────${NC}"

        read -p "Выберите клиента для удаления (1-${#config_files[@]}, или 0 для выхода): " choice
        if [ "$choice" == "0" ] || [ -z "$choice" ]; then
            return
        fi

        if ! [[ "$choice" =~ ^[0-9]+$ ]] || [ "$choice" -lt 1 ] || [ "$choice" -gt ${#config_files[@]} ]; then
            echo -e " ${RED}❌ Неверный выбор!${NC}"
            return
        fi

        selected="${config_files[$((choice-1))]}"
        remarks=$(python3 -c "import json, sys; print(json.load(open(sys.argv[1])).get('remarks', ''))" "$selected" 2>/dev/null)
        if [ -z "$remarks" ]; then
            remarks="${selected##*/}"
            remarks="${remarks%.json}"
        fi

        read -p "Вы действительно хотите безвозвратно удалить '$remarks'? [y/N]: " confirm
        if [[ "$confirm" =~ ^[Yy]$ ]]; then
            rm -f "$selected"
            # Обновляем конфиг сервера и перезапускаем xray
            generate_server_config

            # Обновляем маркер
            local current_num=$(find "$CLIENT_CONFIG_DIR" -maxdepth 1 -name '*.json' | wc -l)
            update_marker_val "NUM_DEVICES" "$current_num"

            echo -e " ${GREEN}✅ Клиент '$remarks' успешно удален из системы!${NC}"
            sleep 1
        else
            echo "Отменено."
        fi
    }

    show_status_dashboard() {
        local domain=$(get_installed_var "DOMAIN")
        local clients_count=$(find "$CLIENT_CONFIG_DIR" -maxdepth 1 -name '*.json' 2>/dev/null | wc -l)
        
        # Статусы системных служб
        local xray_status="${RED}OFF${NC}"
        systemctl is-active xray >/dev/null 2>&1 && xray_status="${GREEN}ACTIVE${NC}"
        
        local sub_status="${RED}OFF${NC}"
        systemctl is-active xray-sub >/dev/null 2>&1 && sub_status="${GREEN}ACTIVE${NC}"
        
        local warp_installed=$(get_installed_var "WARP_INSTALLED")
        local warp_enabled=$(get_installed_var "WARP_ENABLED")
        local warp_mode=$(get_installed_var "WARP_MODE")
        [ -z "$warp_mode" ] && warp_mode="smart"
        
        local warp_status="${RED}NOT INSTALLED${NC}"
        if [ "$warp_installed" == "true" ]; then
            if [ "$warp_enabled" == "true" ]; then
                if [ "$warp_mode" == "full" ]; then
                    warp_status="${GREEN}ON (FULL)${NC}"
                else
                    warp_status="${GREEN}ON (SMART)${NC}"
                fi
            else
                warp_status="${YELLOW}DISABLED${NC}"
            fi
        fi

        echo -e "\n${BOLD}${CYAN}┌────────────────────────────────────────────────────────┐${NC}"
        echo -e "${BOLD}${CYAN}│${NC}  ${BOLD}Сервер:${NC} ${GREEN}$domain${NC}"
        echo -e "${BOLD}${CYAN}│${NC}  ${BOLD}Службы:${NC} Xray: [$xray_status] | Sub-Server: [$sub_status]"
        echo -e "${BOLD}${CYAN}│${NC}  ${BOLD}WARP:${NC}   [$warp_status]"
        echo -e "${BOLD}${CYAN}│${NC}  ${BOLD}Клиенты:${NC} Активных устройств: ${BOLD}${YELLOW}$clients_count${NC}"
        echo -e "${BOLD}${CYAN}└────────────────────────────────────────────────────────┘${NC}"
    }

    change_fingerprint() {
        echo -e "\n${BOLD}${CYAN}┌────────────────────────────────────────────────────────┐${NC}"
        echo -e "${BOLD}${CYAN}│               Выбор отпечатка TLS (Fingerprint)        │${NC}"
        echo -e "${BOLD}${CYAN}└────────────────────────────────────────────────────────┘${NC}"
        echo -e " ${BOLD}${YELLOW}1.${NC} chrome (Рекомендуется, самый стабильный)"
        echo -e " ${BOLD}${YELLOW}2.${NC} safari (Apple устройства)"
        echo -e " ${BOLD}${YELLOW}3.${NC} ios (Мобильный Apple)"
        echo -e " ${BOLD}${YELLOW}4.${NC} android (Мобильный Android)"
        echo -e " ${BOLD}${YELLOW}5.${NC} edge (Microsoft Edge)"
        echo -e " ${BOLD}${YELLOW}6.${NC} firefox (Mozilla Firefox)"
        echo -e " ${BOLD}${YELLOW}7.${NC} 360 (Браузер 360)"
        echo -e " ${BOLD}${YELLOW}8.${NC} qq (Браузер QQ)"
        echo -e " ${BOLD}${YELLOW}9.${NC} random (Случайный из списка браузеров)"
        echo -e " ${BOLD}${YELLOW}10.${NC} randomized (Полная рандомизация - может вызывать обрывы)"
        echo -e "${CYAN}──────────────────────────────────────────────────────────${NC}"
        read -p "Выберите отпечаток (1-10): " fp_choice
        case $fp_choice in
            1) new_fp="chrome" ;;
            2) new_fp="safari" ;;
            3) new_fp="ios" ;;
            4) new_fp="android" ;;
            5) new_fp="edge" ;;
            6) new_fp="firefox" ;;
            7) new_fp="360" ;;
            8) new_fp="qq" ;;
            9) new_fp="random" ;;
            10) new_fp="randomized" ;;
            *) echo -e "${RED}❌ Неверный выбор!${NC}" ; sleep 1 ; return ;;
        esac

        update_marker_val "FINGERPRINT" "$new_fp"
        echo -e "${GREEN}✅ Отпечаток изменен на ${BOLD}${new_fp}${NC}"
        
        echo -e "🔄 Перегенерация конфигураций..."
        generate_server_config
        setup_subscription_server
        generate_client_configs
        install_generate_script
        
        echo -e "${GREEN}✅ Сервер обновлен! Обязательно обновите подписку в ваших клиентах.${NC}"
        sleep 2
    }

    domain_management_menu() {
        local current_domain=$(get_installed_var "DOMAIN")
        local current_cdn=$(get_installed_var "CDN_DOMAIN")
        [ -z "$current_cdn" ] && current_cdn="none"

        echo -e "\n${BOLD}${CYAN}┌────────────────────────────────────────────────────────┐${NC}"
        echo -e "${BOLD}${CYAN}│                 Управление доменами                    │${NC}"
        echo -e "${BOLD}${CYAN}└────────────────────────────────────────────────────────┘${NC}"
        echo -e " Текущий домен (Direct TCP): ${GREEN}$current_domain${NC}"
        if [ "$current_cdn" == "none" ] || [ -z "$current_cdn" ]; then
            echo -e " CDN-домен (XHTTP):          ${RED}Не настроен${NC}"
            echo -e "\n ${BOLD}${YELLOW}1.${NC} 🌐 Изменить основной домен (Direct TCP) с перевыпуском SSL"
            echo -e " ${BOLD}${YELLOW}2.${NC} ⚡ Добавить/Настроить CDN-домен (XHTTP) ${YELLOW}(Тестовый режим)${NC}"
        else
            echo -e " CDN-домен (XHTTP):          ${GREEN}$current_cdn${NC} ${YELLOW}(Тестовый режим)${NC}"
            echo -e "\n ${BOLD}${YELLOW}1.${NC} 🌐 Изменить основной домен (Direct TCP) с перевыпуском SSL"
            echo -e " ${BOLD}${YELLOW}2.${NC} ⚙️ Изменить CDN-домен (XHTTP) ${YELLOW}(Тестовый режим)${NC}"
            echo -e " ${BOLD}${YELLOW}3.${NC} 🗑️ Удалить CDN-домен (отключить XHTTP)"
        fi
        echo -e " ${BOLD}${CYAN}0.${NC} ↩️ Вернуться в главное меню"
        echo -e "${CYAN}──────────────────────────────────────────────────────────${NC}"
        
        local max_choice=2
        if [ "$current_cdn" != "none" ] && [ -n "$current_cdn" ]; then
            max_choice=3
        fi
        
        read -p "Выберите действие (0-$max_choice): " dchoice
        case $dchoice in
            0) main_menu ;;
            1)
                echo -e "\n${BOLD}--- Смена основного домена ---${NC}"
                echo -e "Для смены домена потребуется перевыпустить SSL сертификат."
                echo -e "Убедитесь, что новый домен направлен A-записью на IP вашего сервера."
                read -p "Введите новый домен (например, vless.mydomain.com): " new_domain
                new_domain=$(echo "$new_domain" | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//' -e 's|^https\?://||' -e 's|/.*$||' -e 's|:.*$||')
                if [[ -z "$new_domain" ]]; then
                    echo -e "${RED}❌ Домен не может быть пустым.${NC}"
                    sleep 1
                    domain_management_menu
                    return
                fi
                if [ "$new_domain" == "$current_domain" ]; then
                    echo -e "${YELLOW}Этот домен уже является основным.${NC}"
                    sleep 1
                    domain_management_menu
                    return
                fi
                
                # Проверим резолв нового домена
                local DOMAIN="$new_domain"
                check_domain
                
                # Временно остановим xray, чтобы освободить 80 порт для certbot
                echo "🛑 Останавливаем xray для перевыпуска SSL..."
                systemctl stop xray
                
                local EMAIL=$(get_installed_var "EMAIL")
                echo "🔐 Запуск Certbot для получения нового сертификата..."
                if certbot certonly --standalone -d "$new_domain" --email "$EMAIL" --agree-tos --non-interactive --key-type ecdsa; then
                    echo "✅ SSL-сертификат получен успешно!"
                    
                    # Копируем сертификаты
                    cp "/etc/letsencrypt/live/$new_domain/fullchain.pem" "$SSL_DIR/fullchain.cer"
                    cp "/etc/letsencrypt/live/$new_domain/privkey.pem" "$SSL_DIR/private.key"
                    
                    chown -R nobody:nogroup "$SSL_DIR"
                    chmod 644 "$SSL_DIR/fullchain.cer"
                    chmod 600 "$SSL_DIR/private.key"
                    
                    # Обновляем крон для автопродления
                    (crontab -l 2>/dev/null | grep -v 'certbot renew'; \
                     echo "0 3 * * * certbot renew --quiet --post-hook \"cp /etc/letsencrypt/live/$new_domain/fullchain.pem $SSL_DIR/fullchain.cer && cp /etc/letsencrypt/live/$new_domain/privkey.pem $SSL_DIR/private.key && chown -R nobody:nogroup $SSL_DIR && chmod 644 $SSL_DIR/fullchain.cer && chmod 600 $SSL_DIR/private.key && systemctl restart xray\"") | crontab -
                    
                    # Обновляем маркер
                    update_marker_val "DOMAIN" "$new_domain"
                    
                    # Обновляем конфигурации
                    DOMAIN="$new_domain"
                    NUM_DEVICES=$(get_installed_var "NUM_DEVICES")
                    generate_server_config
                    setup_subscription_server
                    generate_client_configs
                    install_generate_script
                    
                    echo -e "${GREEN}✅ Основной домен успешно изменен на $new_domain!${NC}"
                    sleep 2
                else
                    echo -e "${RED}❌ Не удалось перевыпустить SSL-сертификат для $new_domain.${NC}"
                    echo "Возвращаем запуск Xray с прежним доменом..."
                    systemctl start xray
                    sleep 2
                fi
                domain_management_menu
                ;;
            2)
                echo -e "\n${BOLD}--- Настройка CDN-домена (XHTTP) ---${NC}"
                echo -e "CDN-домен используется для обхода жестких блокировок по IP/протоколу."
                echo -e "Требования:"
                echo -e "1. Создайте дополнительный поддомен (например, cf-$current_domain)."
                echo -e "2. В Cloudflare (или другой CDN) включите для него проксирование (Proxied - оранжевое облако)."
                echo -e "3. Направьте этот поддомен A-записью на IP этого сервера."
                echo -e "4. Настройки TLS в Cloudflare: режим 'Полный' (Full) или 'Полный (строгий)' (Full strict)."
                echo -e "5. В настройках Cloudflare -> Network (Сеть) обязательно включите поддержку gRPC."
                echo -e "⚠️ ВНИМАНИЕ: Основной домен ($current_domain) при этом должен оставаться в режиме DNS Only (серое облако)!"
                echo -e "Подробную инструкцию см. в README.md."
                echo -e "──────────────────────────────────────────────────────────"
                read -p "Введите поддомен CDN (например, cf-$current_domain): " new_cdn
                new_cdn=$(echo "$new_cdn" | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//' -e 's|^https\?://||' -e 's|/.*$||' -e 's|:.*$||')
                if [[ -z "$new_cdn" ]]; then
                    echo -e "${RED}❌ Домен не может быть пустым.${NC}"
                    sleep 1
                    domain_management_menu
                    return
                fi
                if [ "$new_cdn" == "$current_domain" ]; then
                    echo -e "${RED}❌ CDN-домен не должен совпадать с основным доменом!${NC}"
                    sleep 2
                    domain_management_menu
                    return
                fi
                
                # Обновляем маркер
                update_marker_val "CDN_DOMAIN" "$new_cdn"
                
                # Перегенерируем конфигурацию
                DOMAIN="$current_domain"
                NUM_DEVICES=$(get_installed_var "NUM_DEVICES")
                generate_server_config
                setup_subscription_server
                generate_client_configs
                install_generate_script
                
                echo -e "${GREEN}✅ CDN-домен успешно настроен: $new_cdn${NC}"
                echo -e "${YELLOW}Не забудьте обновить подписку или конфигурации на ваших устройствах!${NC}"
                sleep 3
                domain_management_menu
                ;;
            3)
                if [ "$max_choice" -lt 3 ]; then
                    echo -e "${RED}❌ Неверный выбор!${NC}"
                    sleep 1
                    domain_management_menu
                    return
                fi
                echo -e "\n${BOLD}--- Отключение CDN-домена (XHTTP) ---${NC}"
                read -p "Вы уверены, что хотите удалить CDN-домен и отключить XHTTP? [y/N]: " confirm_del
                if [[ "$confirm_del" =~ ^[Yy]$ ]]; then
                    update_marker_val "CDN_DOMAIN" "none"
                    
                    # Перегенерируем конфигурацию
                    DOMAIN="$current_domain"
                    NUM_DEVICES=$(get_installed_var "NUM_DEVICES")
                    generate_server_config
                    setup_subscription_server
                    generate_client_configs
                    install_generate_script
                    
                    echo -e "${GREEN}✅ CDN-домен удален, протокол VLESS XHTTP отключен.${NC}"
                    sleep 2
                fi
                domain_management_menu
                ;;
            *)
                echo -e "${RED}❌ Неверный выбор!${NC}"
                sleep 1
                domain_management_menu
                ;;
        esac
    }

    main_menu() {
        show_status_dashboard
        echo -e "${BOLD}${CYAN}┌────────────────────────────────────────────────────────┐${NC}"
        echo -e "${BOLD}${CYAN}│                      ГЛАВНОЕ МЕНЮ                      │${NC}"
        echo -e "${BOLD}${CYAN}└────────────────────────────────────────────────────────┘${NC}"
        echo -e " ${BOLD}${YELLOW}1.${NC} 📱 Показать QR-коды и ссылки подключения"
        echo -e " ${BOLD}${YELLOW}2.${NC} 👤 Добавить нового пользователя / устройство"
        echo -e " ${BOLD}${YELLOW}3.${NC} 🗑️ Удалить существующего пользователя"
        echo -e " ${BOLD}${YELLOW}4.${NC} 🌀 Управление обходом Cloudflare WARP"
        echo -e " ${BOLD}${YELLOW}5.${NC} 📰 Просмотреть системные логи служб"
        echo -e " ${BOLD}${YELLOW}6.${NC} 📊 Мониторинг активных соединений (port 443)"
        echo -e " ${BOLD}${YELLOW}7.${NC} 🛠️ Запустить полную диагностику системы (Troubleshooting)"
        echo -e " ${BOLD}${YELLOW}8.${NC} 🔄 Обновить скрипт с GitHub и применить новые фиксы"
        echo -e " ${BOLD}${YELLOW}9.${NC} 🌐 Изменить отпечаток TLS (Fingerprint)"
        echo -e " ${BOLD}${YELLOW}10.${NC} 🌐 Управление доменами (Прямое подключение / CDN)"
        echo -e " ${BOLD}${RED}11. 🗑️ Полностью удалить всю установку Xray с сервера${NC}"
        echo -e " ${BOLD}${CYAN}12.${NC} 🚪 Выйти из терминала"
        echo -e "${CYAN}──────────────────────────────────────────────────────────${NC}"
        read -p "Выберите действие (1-12): " choice
        case $choice in
            1) "$GENERATE_SCRIPT" ; main_menu ;;
            2) add_client ; main_menu ;;
            3) remove_client ; main_menu ;;
            4) warp_menu ;;
            5) show_logs ; main_menu ;;
            6) show_connections ; main_menu ;;
            7) run_diagnostics ; main_menu ;;
            8) 
                echo -e "\n${BOLD}${GREEN}🔄 Загрузка последней версии скрипта...${NC}"
                cd /root || exit
                curl -s -o install_xray.sh -L "https://raw.githubusercontent.com/mvrvntn/vless-server-install/main/install_xray.sh?v=$RANDOM" && chmod +x install_xray.sh
                echo -e "${GREEN}✅ Скрипт обновлен! Применяем обновления ядра и конфигурации...${NC}"
                /root/install_xray.sh --update-core
                exit 0
                ;;
            9) change_fingerprint ; main_menu ;;
            10) domain_management_menu ;;
            11) 
                echo -e "\n${BOLD}${RED}⚠️ ВНИМАНИЕ! Это действие удалит Xray, все конфигурации и WARP!${NC}"
                read -p "Вы уверены? (y/n): " uconf
                if [[ "$uconf" =~ ^[Yy]$ ]]; then
                    uninstall_all
                else
                    main_menu
                fi
                ;;
            12) exit 0 ;;
            *) echo -e "${RED}❌ Неверный выбор!${NC}" ; sleep 1 ; main_menu ;;
        esac
    }

    uninstall_warp() {
        echo -e "\n${BOLD}${RED}🧹 Полное удаление Cloudflare WARP с сервера...${NC}"
        
        systemctl stop wg-quick@warp >/dev/null 2>&1
        systemctl disable wg-quick@warp >/dev/null 2>&1
        rm -f /etc/cron.d/warp-native
        rm -rf /opt/warp-native
        rm -f /usr/local/bin/warp
        rm -f /etc/wireguard/warp.conf
        rm -f /usr/local/bin/wgcf
        rm -f /root/wgcf-account.toml /root/wgcf-profile.conf
        rm -f /etc/xray/geoblock.lst
        
        # Удаление задачи автообновления из cron
        if crontab -l &>/dev/null; then
            crontab -l | grep -v "update-geoblocks" | crontab -
        fi
        
        update_marker_val "WARP_INSTALLED" "false"
        update_marker_val "WARP_ENABLED" "false"
        update_marker_val "WARP_MODE" "smart"
        
        DOMAIN=$(get_installed_var "DOMAIN")
        NUM_DEVICES=$(get_installed_var "NUM_DEVICES")
        generate_server_config
        
        echo -e "${GREEN}✅ Cloudflare WARP успешно и полностью удален с сервера!${NC}"
        sleep 1.5
    }

    warp_menu() {
        local warp_installed=$(get_installed_var "WARP_INSTALLED")
        local warp_enabled=$(get_installed_var "WARP_ENABLED")
        local warp_mode=$(get_installed_var "WARP_MODE")
        [ -z "$warp_mode" ] && warp_mode="smart"
        
        echo -e "\n${BOLD}${PURPLE}┌────────────────────────────────────────────────────────┐${NC}"
        echo -e "${BOLD}${PURPLE}│                  Управление WARP                       │${NC}"
        echo -e "${BOLD}${PURPLE}└────────────────────────────────────────────────────────┘${NC}"
        
        if [ "$warp_installed" != "true" ]; then
            echo -e " ${RED}Cloudflare WARP в данный момент не установлен на сервере.${NC}"
            echo -e "\n ${BOLD}${YELLOW}1.${NC} 📥 Установить и активировать Cloudflare WARP"
            echo -e " ${BOLD}${CYAN}2.${NC} ↩️ Вернуться в главное меню"
            echo -e "${PURPLE}──────────────────────────────────────────────────────────${NC}"
            read -p "Выберите действие (1-2): " wchoice
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
                    echo -e "${RED}❌ Неверный выбор!${NC}"
                    warp_menu
                    ;;
            esac
        else
            local status_text="${RED}Выключен${NC}"
            [ "$warp_enabled" == "true" ] && status_text="${GREEN}Активен${NC}"
            
            local mode_text="${CYAN}Smart-обход (только заблокированные сайты)${NC}"
            [ "$warp_mode" == "full" ] && mode_text="${PURPLE}Full-обход (весь исходящий трафик сервера)${NC}"
            
            echo -e " ${BOLD}Статус:${NC} $status_text"
            echo -e " ${BOLD}Режим маршрутизации:${NC} $mode_text"
            echo -e "${PURPLE}──────────────────────────────────────────────────────────${NC}"
            
            if [ "$warp_enabled" == "true" ]; then
                echo -e " ${BOLD}${YELLOW}1.${NC} 📴 Отключить WARP (прямой выход в интернет)"
            else
                echo -e " ${BOLD}${YELLOW}1.${NC} 🌀 Включить и запустить WARP"
            fi
            echo -e " ${BOLD}${YELLOW}2.${NC} ⚙️ Переключить режим работы WARP (Smart / Full)"
            echo -e " ${BOLD}${YELLOW}3.${NC} 🔄 Принудительно обновить список геоблокировок"
            echo -e " ${BOLD}${YELLOW}4.${NC} ⚡ Переустановить/Обновить WireGuard профиль WARP"
            echo -e " ${BOLD}${RED}5.${NC} 🗑️ Полностью удалить Cloudflare WARP с сервера"
            echo -e " ${BOLD}${CYAN}6.${NC} ↩️ Назад в главное меню"
            echo -e "${PURPLE}──────────────────────────────────────────────────────────${NC}"
            read -p "Выберите действие (1-6): " wchoice
            case $wchoice in
                1)
                    toggle_warp
                    warp_menu
                    ;;
                2)
                    echo -e "\n${BOLD}Выберите новый режим исходящего трафика:${NC}"
                    echo -e " ${BOLD}${YELLOW}1.${NC} Smart-обход (маршрутизируются только сайты из списка блокировок)"
                    echo -e " ${BOLD}${YELLOW}2.${NC} Full-обход (абсолютно весь трафик сервера оборачивается в WARP)"
                    read -p "Режим (1-2): " mchoice
                    if [ "$mchoice" == "1" ]; then
                        update_marker_val "WARP_MODE" "smart"
                        echo -e "${GREEN}✅ Успешно изменен на Smart-обход${NC}"
                    elif [ "$mchoice" == "2" ]; then
                        update_marker_val "WARP_MODE" "full"
                        echo -e "${GREEN}✅ Успешно изменен на Full-обход${NC}"
                    else
                        echo -e "${RED}❌ Отменено: неверный выбор${NC}"
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
                    echo -e "${GREEN}✅ Список блокировок успешно обновлен!${NC}"
                    sleep 1
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
                    uninstall_warp
                    warp_menu
                    ;;
                6)
                    main_menu
                    ;;
                *)
                    echo -e "${RED}❌ Неверный выбор!${NC}"
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
    
    # Самодиагностика и исправление пустых/отсутствующих UUID
    repaired=false
    if [ -d "$CLIENT_CONFIG_DIR" ] && [ "$(find "$CLIENT_CONFIG_DIR" -name '*.json' 2>/dev/null | wc -l)" -gt 0 ]; then
        repair_output=$(python3 -c '
import json, sys, os, uuid, re
domain = "domain.com"
try:
    if os.path.exists("/etc/xray/.installed"):
        with open("/etc/xray/.installed", "r") as inf:
            for l in inf:
                if l.startswith("DOMAIN="):
                    domain = l.split("=", 1)[1].strip()
except Exception:
    pass

for filepath in sys.argv[1:]:
    if not filepath.endswith(".json") or not os.path.exists(filepath):
        continue
    need_repair = False
    data = {}
    try:
        with open(filepath, "r") as f:
            data = json.load(f)
        uid = data.get("id", "")
        if not re.match(r"^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$", str(uid), re.I):
            need_repair = True
    except Exception:
        need_repair = True
    
    if not need_repair:
        try:
            if "outbounds" not in data or not isinstance(data["outbounds"], list) or len(data["outbounds"]) == 0:
                need_repair = True
            elif data["outbounds"][0]["settings"]["vnext"][0]["users"][0]["id"] != data["id"]:
                need_repair = True
        except Exception:
            need_repair = True
            
    if need_repair:
        try:
            new_uuid = data.get("id", "")
            if not re.match(r"^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$", str(new_uuid), re.I):
                new_uuid = str(uuid.uuid4())
            remarks = data.get("remarks", "")
            if not remarks:
                remarks = os.path.splitext(os.path.basename(filepath))[0]
            
            data = {
              "remarks": remarks,
              "id": new_uuid,
              "outbounds": [{
                "protocol": "vless",
                "settings": {
                  "vnext": [{
                    "address": domain,
                    "port": 443,
                    "users": [{
                      "id": new_uuid,
                      "flow": "xtls-rprx-vision"
                    }]
                  }]
                },
                "streamSettings": {
                  "network": "tcp",
                  "security": "tls",
                  "sockopt": {
                    "tcpFastOpen": True
                  }
                }
              }]
            }
            with open(filepath, "w") as f:
                json.dump(data, f, indent=2)
            print(f"REPAIRED:{filepath}")
        except Exception:
            pass
' "$CLIENT_CONFIG_DIR"/*.json 2>/dev/null)

        if [ -n "$repair_output" ]; then
            repaired=true
            echo "$repair_output" | while read -r line; do
                if [[ "$line" =~ REPAIRED:(.+) ]]; then
                    path="${BASH_REMATCH[1]}"
                    echo "⚙️ Восстановлен корректный UUID в $(basename "$path")"
                    chown nobody:nogroup "$path"
                    chmod 644 "$path"
                fi
            done
        fi
    fi

    # Автоматически регистрируем быструю команду 'xry'
    install_xry_command >/dev/null 2>&1

    if [ "$repaired" = true ]; then
        echo "🔄 Пересборка конфигурации сервера после исправления..."
        DOMAIN=$(get_installed_var "DOMAIN")
        NUM_DEVICES=$(get_installed_var "NUM_DEVICES")
        generate_server_config
        install_generate_script
        echo "✅ Восстановление успешно завершено!"
    fi

    if [ "$1" != "--update-core" ] && [ "$1" != "--update-geoblocks" ]; then
        main_menu
        exit 0
    fi
fi

# === Логгирование ===
mkdir -p /var/log/xray
exec > >(tee -a "$INSTALL_LOG") 2>&1

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

# === Обработка флага обновления ядра (update) ===
if [ "$1" == "--update-core" ]; then
    echo "🔄 Запуск автоматического обновления компонентов сервера..."
    DOMAIN=$(get_installed_var "DOMAIN")
    EMAIL=$(get_installed_var "EMAIL")
    NUM_DEVICES=$(get_installed_var "NUM_DEVICES")
    if [[ -z "$DOMAIN" || -z "$EMAIL" || -z "$NUM_DEVICES" ]]; then
        echo "❌ Ошибка: Не найдены данные предыдущей установки в /etc/xray/.installed"
        exit 1
    fi
    FLAG_EMOJI=$(get_flag_emoji)
    install_dependencies
    install_xray
    generate_server_config
    setup_subscription_server
    generate_client_configs
    install_generate_script
    install_xry_command
    echo "✅ Сервер успешно обновлен до последней версии! Можете вызвать xry для проверки."
    exit 0
fi

# === Обработка флага headless ===
if [ "$1" == "--headless" ]; then
    DOMAIN="$2"
    EMAIL="$3"
    NUM_DEVICES="$4"
    CDN_DOMAIN="none"
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
    echo -e "\n${BOLD}${CYAN}┌────────────────────────────────────────────────────────┐${NC}"
    echo -e "${BOLD}${CYAN}│             🚀 Установка Xray VLESS Сервера            │${NC}"
    echo -e "${BOLD}${CYAN}└────────────────────────────────────────────────────────┘${NC}"
    echo -e " Добро пожаловать! Давайте настроим ваш новый VPN-сервер."
    echo -e "${CYAN}──────────────────────────────────────────────────────────${NC}"
    
    # 1. Ввод домена с валидацией
    while true; do
        echo -e " ${BOLD}${YELLOW}Шаг 1 из 4:${NC} Укажите ваш домен"
        read -p " 🌐 Введите домен (например, sub.domain.com): " DOMAIN
        DOMAIN=$(echo "$DOMAIN" | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//' -e 's|^https\?://||' -e 's|/.*$||' -e 's|:.*$||')
        if [[ -n "$DOMAIN" ]]; then
            break
        fi
        echo -e " ${RED}❌ Домен не может быть пустым. Пожалуйста, укажите валидный домен.${NC}"
    done
    
    # 2. Ввод Email с валидацией
    while true; do
        echo -e "\n ${BOLD}${YELLOW}Шаг 2 из 4:${NC} Укажите Email для SSL-сертификата Let's Encrypt"
        read -p " 📧 Email: " EMAIL
        EMAIL=$(echo "$EMAIL" | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//')
        if [[ "$EMAIL" =~ ^[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}$ ]]; then
            break
        fi
        echo -e " ${RED}❌ Некорректный формат Email. Попробуйте еще раз (например: myemail@mail.com).${NC}"
    done
    
    # 3. Ввод количества устройств с валидацией
    while true; do
        echo -e "\n ${BOLD}${YELLOW}Шаг 3 из 4:${NC} Сколько клиентских устройств добавить?"
        read -p " 📱 Количество устройств: " NUM_DEVICES
        if [[ "$NUM_DEVICES" =~ ^[1-9][0-9]*$ ]]; then
            break
        fi
        echo -e " ${RED}❌ Пожалуйста, введите положительное целое число.${NC}"
    done
    
    echo -e "\n ${BOLD}${YELLOW}Шаг 4 из 4:${NC} Задайте имена для ваших устройств"
    DEVICE_NAMES=()
    for i in $(seq 1 "$NUM_DEVICES"); do
        read -p " 👤 Имя для устройства $i (по умолчанию client_$i): " dev_name
        dev_name=$(echo "$dev_name" | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//')
        if [[ -z "$dev_name" ]]; then
            DEVICE_NAMES[$i]="client_$i"
        else
            DEVICE_NAMES[$i]="$dev_name"
        fi
    done

    echo -e "\n${BOLD}${CYAN}┌────────────────────────────────────────────────────────┐${NC}"
    echo -e "${BOLD}${CYAN}│ 🔌 Настройка VLESS XHTTP через CDN (Тестовый режим)    │${NC}"
    echo -e "${BOLD}${CYAN}└────────────────────────────────────────────────────────┘${NC}"
    echo -e " Для использования VLESS XHTTP требуется дополнительный поддомен"
    echo -e " в Cloudflare (или другой CDN) с включенным проксированием"
    echo -e " (оранжевое облако - Proxied, например: cf-${DOMAIN})."
    echo -e " Основной домен ($DOMAIN) должен оставаться DNS Only (серое облако)."
    echo -e " Полные инструкции по настройке DNS, TLS и gRPC находятся в README.md."
    echo -e "${CYAN}──────────────────────────────────────────────────────────${NC}"
    read -p " Хотите настроить CDN-домен для VLESS XHTTP сейчас? (Тестовый режим) [y/N]: " setup_cdn
    CDN_DOMAIN="none"
    if [[ "$setup_cdn" =~ ^[Yy]$ ]]; then
        while true; do
            read -p " 🌐 Введите CDN-домен (например, cf-$DOMAIN): " cdn_input
            cdn_input=$(echo "$cdn_input" | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//' -e 's|^https\?://||' -e 's|/.*$||' -e 's|:.*$||')
            if [[ -n "$cdn_input" ]]; then
                if [ "$cdn_input" == "$DOMAIN" ]; then
                    echo -e " ${RED}❌ CDN-домен не должен совпадать с основным доменом!${NC}"
                else
                    CDN_DOMAIN="$cdn_input"
                    break
                fi
            else
                echo -e " ${RED}❌ Домен не может быть пустым. Пожалуйста, укажите валидный домен.${NC}"
            fi
        done
    fi
    echo -e "${CYAN}──────────────────────────────────────────────────────────${NC}"
    echo -e "${BOLD}${GREEN}⚙️ Запуск процесса автоматической сборки и установки...${NC}\n"
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

echo -e "DOMAIN=$DOMAIN\nEMAIL=$EMAIL\nNUM_DEVICES=$NUM_DEVICES\nEMOJI=$FLAG_EMOJI\nCDN_DOMAIN=$CDN_DOMAIN" > "$MARKER_FILE"
chmod 644 "$MARKER_FILE"

# Регистрация быстрой команды xry
install_xry_command

echo -e "\n✅ Установка полностью завершена! Вы можете управлять сервером в любое время, просто введя в терминале: ${BOLD}${YELLOW}xry${NC}"
main_menu
