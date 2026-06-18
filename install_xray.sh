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

# === Оптимизация VPS (Xanmod + Limits + Sysctl) ===
optimize_vps() {
    echo -e "\n${BOLD}${CYAN}🔧 Запуск оптимизации VPS...${NC}"
    
    # Установка системных лимитов (ulimit)
    echo -e "${YELLOW}Настройка системных лимитов...${NC}"
    local prof_path="/etc/profile"
    sed -i '/ulimit -n/d' $prof_path
    sed -i '/ulimit -s/d' $prof_path
    echo "ulimit -n 1048576" | tee -a $prof_path >/dev/null
    echo "ulimit -s -H 65536" | tee -a $prof_path >/dev/null
    echo "ulimit -s 32768" | tee -a $prof_path >/dev/null
    
    # Обновление лимитов systemd
    local sys_conf="/etc/systemd/system.conf"
    local usr_conf="/etc/systemd/user.conf"
    
    for conf in "$sys_conf" "$usr_conf"; do
        if grep -q "^DefaultLimitNOFILE=" "$conf"; then
            sed -i "s/^DefaultLimitNOFILE=.*/DefaultLimitNOFILE=1048576/" "$conf"
        else
            echo "DefaultLimitNOFILE=1048576" >> "$conf"
        fi
        if grep -q "^DefaultLimitNPROC=" "$conf"; then
            sed -i "s/^DefaultLimitNPROC=.*/DefaultLimitNPROC=1048576/" "$conf"
        else
            echo "DefaultLimitNPROC=1048576" >> "$conf"
        fi
    done
    systemctl daemon-reexec

    # Установка расширенных сетевых параметров (sysctl)
    echo -e "${YELLOW}Настройка расширенных сетевых параметров...${NC}"
    local sysctl_opt_file="/etc/sysctl.d/99-xray-optimize.conf"
    cat <<EOF > "$sysctl_opt_file"
# File system settings
fs.file-max = 67108864

# Network core settings
net.core.somaxconn = 65536
net.core.netdev_max_backlog = 32768
net.core.optmem_max = 262144

# TCP and UDP memory limits
net.ipv4.tcp_rmem = 16384 1048576 33554432
net.ipv4.tcp_wmem = 16384 1048576 33554432
net.ipv4.tcp_mem = 65536 1048576 33554432
net.ipv4.udp_mem = 65536 1048576 33554432
EOF
    sysctl -p "$sysctl_opt_file" > /dev/null 2>&1

    # Установка ядра Xanmod
    echo -e "${YELLOW}Определение архитектуры процессора и установка ядра Xanmod...${NC}"
    apt update && apt install -y ca-certificates curl gnupg lsb-release gawk
    
    local cpu_level
    cpu_level=$(awk -f - <<'EOF'
    BEGIN {
        while (!/flags/) if (getline < "/proc/cpuinfo" != 1) exit 1
        if (/lm/&&/cmov/&&/cx8/&&/fpu/&&/fxsr/&&/mmx/&&/syscall/&&/sse2/) level = 1
        if (level == 1 && /cx16/&&/lahf/&&/popcnt/&&/sse4_1/&&/sse4_2/&&/ssse3/) level = 2
        if (level == 2 && /avx/&&/avx2/&&/bmi1/&&/bmi2/&&/f16c/&&/fma/&&/abm/&&/movbe/&&/xsave/) level = 3
        if (level == 3 && /avx512f/&&/avx512bw/&&/avx512cd/&&/avx512dq/&&/avx512vl/) level = 4
        if (level > 0) { print level; exit level + 1 }
        exit 1
    }
EOF
    )

    if [ -z "$cpu_level" ] || [ "$cpu_level" -lt 1 ]; then
        echo -e "${RED}❌ Не удалось определить уровень CPU или архитектура не поддерживается.${NC}"
    else
        echo -e "${GREEN}👉 Определен уровень CPU: v${cpu_level}${NC}"
        
        # Переопределяем v4 на v3
        if [ "$cpu_level" -eq 4 ]; then
            echo -e "${YELLOW}👉 Уровень CPU v4 понижен до v3 по требованию стабильности.${NC}"
            cpu_level=3
        fi

        if curl -fsSL https://dl.xanmod.org/archive.key | gpg --dearmor -yes -o /etc/apt/keyrings/xanmod-archive-keyring.gpg; then
            echo "deb [signed-by=/etc/apt/keyrings/xanmod-archive-keyring.gpg] http://deb.xanmod.org $(lsb_release -sc) main" > /etc/apt/sources.list.d/xanmod-release.list
            apt update
            
            echo -e "${YELLOW}Установка linux-xanmod-x64v${cpu_level}...${NC}"
            apt install -y "linux-xanmod-x64v${cpu_level}"
            if [ $? -eq 0 ]; then
                echo -e "${GREEN}✅ Ядро Xanmod успешно установлено!${NC}"
            else
                echo -e "${RED}❌ Ошибка при установке ядра Xanmod. Продолжаем работу...${NC}"
            fi
        else
             echo -e "${RED}❌ Не удалось скачать ключ Xanmod. Пропускаем установку ядра.${NC}"
        fi
    fi

    echo -e "\n${BOLD}${GREEN}✅ Оптимизация завершена! Сервер будет перезагружен.${NC}"
    echo -e "${BOLD}${YELLOW}ВАЖНО: После перезагрузки запустите скрипт установки Xray СНОВА, чтобы продолжить!${NC}"
    read -p "Нажмите Enter для перезагрузки..."
    reboot
    exit 0
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
    local temp_geoblock=$(mktemp)
    local temp_google_ai=$(mktemp)
    
    echo "📥 Обновление списка геоблокированных доменов (itdog геоблок и google ai)..."
    
    # Пытаемся скачать оба списка с GitHub
    local download_success=false
    curl -sSL --connect-timeout 8 "https://raw.githubusercontent.com/itdoginfo/allow-domains/refs/heads/main/Categories/geoblock.lst" -o "$temp_geoblock"
    curl -sSL --connect-timeout 8 "https://raw.githubusercontent.com/itdoginfo/allow-domains/refs/heads/main/Services/google_ai.lst" -o "$temp_google_ai"
    
    # Если хотя бы один файл скачался успешно и не пуст, объединяем их
    if [ -s "$temp_geoblock" ] || [ -s "$temp_google_ai" ]; then
        cat "$temp_geoblock" "$temp_google_ai" 2>/dev/null > "$temp_file"
        # Очищаем от Windows CRLF
        sed -i 's/\r//g' "$temp_file"
        # Удаляем пустые строки и комментарии, сортируем и убираем дубликаты
        grep -v '^[[:space:]]*$' "$temp_file" | grep -v '^[[:space:]]*#' | sort -u > "${temp_file}.clean"
        mv "${temp_file}.clean" "$temp_file"
        
        if [ -s "$temp_file" ]; then
            download_success=true
        fi
    fi
    
    rm -f "$temp_geoblock" "$temp_google_ai"
    
    if [ "$download_success" = true ]; then
        if ! cmp -s "$temp_file" "$list_file" 2>/dev/null; then
            mkdir -p /etc/xray
            mv "$temp_file" "$list_file"
            echo "✅ Список доменов успешно обновлен."
            rm -f "$temp_file"
            return 0
        fi
        rm -f "$temp_file"
    else
        rm -f "$temp_file"
    fi
    
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
gemini.google.com
generativelapis-pa.googleapis.com
generativeai.googleapis.com
proactivebackend-pa.googleapis.com
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

install_opera_proxy() {
    echo -e "\n${BOLD}${GREEN}🌀 Установка Opera Proxy...${NC}"
    local arch=$(uname -m)
    local binary_url
    if [ "$arch" == "x86_64" ]; then
        binary_url="https://github.com/Alexey71/opera-proxy/releases/latest/download/opera-proxy-linux-amd64"
    elif [ "$arch" == "aarch64" ] || [ "$arch" == "arm64" ]; then
        binary_url="https://github.com/Alexey71/opera-proxy/releases/latest/download/opera-proxy-linux-arm64"
    else
        echo -e "${RED}❌ Неподдерживаемая архитектура процессора: $arch${NC}"
        return 1
    fi

    echo "📥 Скачивание бинарного файла Opera Proxy..."
    if curl -sSL -L "$binary_url" -o /usr/local/bin/opera-proxy; then
        chmod +x /usr/local/bin/opera-proxy
        echo "✅ Бинарный файл успешно скачан и установлен."
    else
        echo -e "${RED}❌ Ошибка при скачивании Opera Proxy.${NC}"
        return 1
    fi

    echo "⚙️ Создание службы systemd..."
    cat > /etc/systemd/system/opera-proxy.service <<EOF
[Unit]
Description=Opera Proxy Daemon
After=network.target

[Service]
Type=simple
User=nobody
ExecStart=/usr/local/bin/opera-proxy -bind 127.0.0.1:40001 -socks-mode
Restart=always
RestartSec=5

[Install]
WantedBy=multi-user.target
EOF

    systemctl daemon-reload
    systemctl enable opera-proxy >/dev/null 2>&1
    systemctl restart opera-proxy >/dev/null 2>&1

    # Создание списка доменов
    if [ ! -f "/etc/xray/opera.lst" ]; then
        mkdir -p /etc/xray
        cat > /etc/xray/opera.lst <<EOF
openai.com
chatgpt.com
oaistatic.com
oaiusercontent.com
sentry.io
EOF
    fi

    update_marker_val "OPERA_INSTALLED" "true"
    update_marker_val "OPERA_ENABLED" "true"
    
    echo -e "${GREEN}✅ Opera Proxy успешно установлен и запущен!${NC}"
    
    DOMAIN=$(get_installed_var "DOMAIN")
    NUM_DEVICES=$(get_installed_var "NUM_DEVICES")
    generate_server_config
    return 0
}

toggle_opera_proxy() {
    local current_status=$(get_installed_var "OPERA_ENABLED")
    if [ "$current_status" == "true" ]; then
        echo -e "\n${BOLD}${YELLOW}📴 Отключение Opera Proxy...${NC}"
        update_marker_val "OPERA_ENABLED" "false"
        systemctl stop opera-proxy >/dev/null 2>&1
    else
        echo -e "\n${BOLD}${GREEN}🌀 Включение Opera Proxy...${NC}"
        if [ "$(get_installed_var "OPERA_INSTALLED")" != "true" ]; then
            install_opera_proxy || return 1
        fi
        systemctl start opera-proxy >/dev/null 2>&1
        update_marker_val "OPERA_ENABLED" "true"
    fi

    DOMAIN=$(get_installed_var "DOMAIN")
    NUM_DEVICES=$(get_installed_var "NUM_DEVICES")
    generate_server_config
    echo -e "${GREEN}✅ Статус Opera Proxy обновлен и Xray перезапущен!${NC}"
}

uninstall_opera_proxy() {
    echo -e "\n${BOLD}${RED}🧹 Полное удаление Opera Proxy с сервера...${NC}"
    systemctl stop opera-proxy >/dev/null 2>&1
    systemctl disable opera-proxy >/dev/null 2>&1
    rm -f /etc/systemd/system/opera-proxy.service
    rm -f /usr/local/bin/opera-proxy
    rm -f /etc/xray/opera.lst
    systemctl daemon-reload

    update_marker_val "OPERA_INSTALLED" "false"
    update_marker_val "OPERA_ENABLED" "false"

    DOMAIN=$(get_installed_var "DOMAIN")
    NUM_DEVICES=$(get_installed_var "NUM_DEVICES")
    generate_server_config
    echo -e "${GREEN}✅ Opera Proxy успешно удален!${NC}"
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
    # Оптимизация буферов UDP для Hysteria 2 (QUIC)
    if ! grep -q "net.core.rmem_max" /etc/sysctl.conf; then
        echo "net.core.rmem_max=8388608" >> /etc/sysctl.conf
        echo "net.core.wmem_max=8388608" >> /etc/sysctl.conf
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

# === Установка Hysteria 2 ===
install_hysteria() {
    echo "🚀 Установка Hysteria 2..."
    systemctl stop hysteria-server >/dev/null 2>&1 || true
    local latest_ver=$(curl -s "https://api.github.com/repos/apernet/hysteria/releases/latest" | grep '"tag_name":' | sed -E 's/.*"([^"]+)".*/\1/')
    if [ -z "$latest_ver" ]; then
        latest_ver="v2.6.0"
    fi
    echo "Загрузка Hysteria 2 ($latest_ver)..."
    local download_url="https://github.com/apernet/hysteria/releases/download/${latest_ver}/hysteria-linux-amd64"
    rm -f /usr/local/bin/hysteria
    if curl -sSL -o /usr/local/bin/hysteria "$download_url"; then
        chmod +x /usr/local/bin/hysteria
        echo "✅ Hysteria 2 успешно установлена."
    else
        echo "❌ Ошибка при скачивании Hysteria 2."
    fi
}

# === Настройка фаервола ===
setup_firewall() {
    # Проверяем наличие AntiZapret (через правила iptables или запущенные службы)
    local antizapret_detected=false
    if iptables -t nat -S 2>/dev/null | grep -qi "antizapret" || systemctl list-units --all --quiet 2>/dev/null | grep -q "antizapret" || systemctl is-active --quiet openvpn-server@antizapret-tcp || systemctl is-active --quiet openvpn-server@antizapret-udp; then
        antizapret_detected=true
    fi

    if [ "$antizapret_detected" = "true" ]; then
        echo "⚠️ Обнаружен AntiZapret-VPN! Для предотвращения сбоев маршрутизации UFW не будет включен."
        echo "🔌 Отключаем UFW и разрешаем порты в iptables напрямую..."
        ufw disable >/dev/null 2>&1 || true
        
        # Гарантируем доступ к нужным портам в iptables напрямую
        local ipt_path=$(which iptables 2>/dev/null || echo "/sbin/iptables")
        if [ -x "$ipt_path" ]; then
            $ipt_path -C INPUT -p tcp --dport 443 -j ACCEPT >/dev/null 2>&1 || $ipt_path -I INPUT 1 -p tcp --dport 443 -j ACCEPT
            $ipt_path -C INPUT -p udp --dport 443 -j ACCEPT >/dev/null 2>&1 || $ipt_path -I INPUT 1 -p udp --dport 443 -j ACCEPT
            $ipt_path -C INPUT -p udp --dport 20000:50000 -j ACCEPT >/dev/null 2>&1 || $ipt_path -I INPUT 1 -p udp --dport 20000:50000 -j ACCEPT
            $ipt_path -C INPUT -p tcp --dport 80 -j ACCEPT >/dev/null 2>&1 || $ipt_path -I INPUT 1 -p tcp --dport 80 -j ACCEPT
        fi
        return 0
    fi

    echo "🛡 Настройка UFW..."
    ufw allow 443/tcp > /dev/null
    ufw allow 443/udp > /dev/null
    ufw allow 20000:50000/udp > /dev/null
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
    
    # Проверяем, есть ли уже клиенты
    if [ -d "$CLIENT_CONFIG_DIR" ] && [ "$(find "$CLIENT_CONFIG_DIR" -maxdepth 1 -name '*.json' 2>/dev/null | wc -l)" -gt 0 ]; then
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
    
    # Проверяем статус WARP и Opera Proxy
    local warp_enabled=$(get_installed_var "WARP_ENABLED")
    local warp_mode=$(get_installed_var "WARP_MODE")
    [ -z "$warp_mode" ] && warp_mode="smart"
    local opera_enabled=$(get_installed_var "OPERA_ENABLED")
    local DOMAIN=$(get_installed_var "DOMAIN" | tr -d '[:space:]')
    
    # Загружаем настройки Reality (Принудительно отключено для стабильности)
    local reality_enabled="false"
    local reality_sni=$(get_installed_var "REALITY_SNI" | tr -d '[:space:]')
    local reality_dest=$(get_installed_var "REALITY_DEST" | tr -d '[:space:]')
    local reality_priv=$(get_installed_var "REALITY_PRIVATE_KEY" | tr -d '[:space:]')
    local reality_pub=$(get_installed_var "REALITY_PUBLIC_KEY" | tr -d '[:space:]')
    local reality_sid=$(get_installed_var "REALITY_SHORT_ID" | tr -d '[:space:]')

    if [ "$reality_enabled" == "true" ]; then
        # Гарантируем наличие ключей и short ID
        if [[ -z "$reality_priv" || -z "$reality_pub" ]]; then
            local keys=$(which xray &>/dev/null && xray x25519 2>/dev/null || /usr/local/bin/xray x25519 2>/dev/null || xray x25519 2>/dev/null)
            reality_priv=$(echo "$keys" | grep -i "private" | cut -d: -f2- | tr -d '[:space:]')
            reality_pub=$(echo "$keys" | grep -i "public" | cut -d: -f2- | tr -d '[:space:]')
            update_marker_val "REALITY_PRIVATE_KEY" "$reality_priv"
            update_marker_val "REALITY_PUBLIC_KEY" "$reality_pub"
        fi
        if [[ -z "$reality_sid" ]]; then
            reality_sid=$(head -c 8 /dev/urandom | od -An -tx1 | tr -d ' \n')
            update_marker_val "REALITY_SHORT_ID" "$reality_sid"
        fi
        if [[ -z "$reality_sni" ]]; then
            reality_sni="max.ru"
            update_marker_val "REALITY_SNI" "$reality_sni"
        fi
        if [[ -z "$reality_dest" ]]; then
            reality_dest="max.ru:443"
            update_marker_val "REALITY_DEST" "$reality_dest"
        fi
    fi

    local outbounds_list=()

    # Сначала добавим DIRECT как первый outbound (или WARP, если warp_mode == "full")
    if [ "$warp_enabled" == "true" ] && [ "$warp_mode" == "full" ]; then
        outbounds_list+=('{
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
    }')
        outbounds_list+=('{
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
    }')
    else
        outbounds_list+=('{
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
    }')
        if [ "$warp_enabled" == "true" ]; then
            outbounds_list+=('{
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
    }')
        fi
    fi

    # Добавляем OPERA прокси, если включен
    if [ "$opera_enabled" == "true" ]; then
        outbounds_list+=('{
      "tag": "OPERA",
      "protocol": "socks",
      "settings": {
        "servers": [
          {
            "address": "127.0.0.1",
            "port": 40001
          }
        ]
      }
    }')
    fi

    # Всегда добавляем BLOCK в конец
    outbounds_list+=('{
      "tag": "BLOCK",
      "protocol": "blackhole"
    }')

    local outbounds_str=$(IFS=,; echo "[${outbounds_list[*]}]")
    
    local routing_rules_list=()

    # Базовые правила блокировки
    routing_rules_list+=('{
        "ip": [
          "geoip:private"
        ],
        "outboundTag": "BLOCK"
      }')
    routing_rules_list+=('{
        "domain": [
          "geosite:private"
        ],
        "outboundTag": "BLOCK"
      }')
    routing_rules_list+=('{
        "protocol": [
          "bittorrent"
        ],
        "outboundTag": "BLOCK"
      }')

    # Правило для Opera Proxy (приоритет выше, чем у WARP)
    if [ "$opera_enabled" == "true" ]; then
        local opera_domains=()
        if [ -f "/etc/xray/opera.lst" ]; then
            while IFS= read -r line || [ -n "$line" ]; do
                line=$(echo "$line" | tr -d '\r' | xargs)
                if [[ -z "$line" || "$line" =~ ^# ]]; then
                    continue
                fi
                opera_domains+=("\"domain:$line\"")
            done < "/etc/xray/opera.lst"
        else
            mkdir -p /etc/xray
            cat > "/etc/xray/opera.lst" <<EOF
openai.com
chatgpt.com
oaistatic.com
oaiusercontent.com
sentry.io
EOF
            opera_domains+=("\"domain:openai.com\"" "\"domain:chatgpt.com\"" "\"domain:oaistatic.com\"" "\"domain:oaiusercontent.com\"" "\"domain:sentry.io\"")
        fi
        
        opera_domains+=("\"geosite:openai\"")
        
        local opera_domains_joined=$(IFS=,; echo "${opera_domains[*]}")
        routing_rules_list+=("{
        \"type\": \"field\",
        \"domain\": [
          $opera_domains_joined
        ],
        \"outboundTag\": \"OPERA\"
      }")
    fi

    # Правила для WARP
    if [ "$warp_enabled" == "true" ]; then
        if [ "$warp_mode" == "smart" ]; then
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
            
            geoblocks+=("\"geosite:netflix\"" "\"geosite:facebook\"" "\"geosite:instagram\"" "\"geosite:twitter\"" "\"geosite:disney\"" "\"geosite:spotify\"")
            if [ "$opera_enabled" != "true" ]; then
                geoblocks+=("\"geosite:openai\"")
            fi
            
            local geoblocks_joined=$(IFS=,; echo "${geoblocks[*]}")
            routing_rules_list+=("{
        \"type\": \"field\",
        \"domain\": [
          $geoblocks_joined
        ],
        \"outboundTag\": \"WARP\"
      }")
        fi

        local check_domains=()
        for dom in whoer.net browserleaks.com 2ip.io 2ip.ru 2ip.ua ipleak.net ipinfo.io whatismyip.com whatismyipaddress.com iplocation.net dnsleaktest.com dnsleak.com am.i.mullvad.net myip.com myip.ru ip.me ifconfig.me ident.me checkip.amazonaws.com ip-api.com ipify.org icanhazip.com ip-score.com doileak.com bash.ws f.vision amiunique.org deviceinfo.me coveryourtracks.eff.org showmyip.com ip8.com gemini.google.com generativelanguage.googleapis.com accounts.google.com googleapis.com gstatic.com googleusercontent.com webrtc.org stun.l.google.com; do
            check_domains+=("\"domain:$dom\"")
        done
        local check_domains_joined=$(IFS=,; echo "${check_domains[*]}")
        routing_rules_list+=("{
        \"type\": \"field\",
        \"domain\": [
          $check_domains_joined
        ],
        \"outboundTag\": \"WARP\"
      }")
    fi

    local routing_rules_str=$(IFS=,; echo "${routing_rules_list[*]}")
    
    # Fallback-маршруты для VLESS TCP (перенаправление на сервер подписок)
    local fallbacks_str='[
          {
            "path": "/sub/",
            "dest": 10080
          },
          {
            "dest": 10080
          }
        ]'

    # Генерация inbounds секции в зависимости от активности Reality
    local inbounds_str=""
    if [ "$reality_enabled" == "true" ]; then
        inbounds_str='[
    {
      "port": 443,
      "protocol": "vless",
      "settings": {
        "decryption": "none",
        "fallbacks": [
          {
            "name": "'"$DOMAIN"'",
            "dest": 4433
          },
          {
            "name": "'"$reality_sni"'",
            "dest": 4434
          },
          {
            "dest": "'"$reality_dest"'"
          }
        ]
      },
      "streamSettings": {
        "network": "tcp",
        "security": "none"
      }
    },
    {
      "listen": "127.0.0.1",
      "port": 4433,
      "protocol": "vless",
      "settings": {
        "clients": ['"$vless_clients_str"'],
        "decryption": "none",
        "fallbacks": '"$fallbacks_str"'
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
            "certificateFile": "'"$SSL_DIR"'/fullchain.cer",
            "keyFile": "'"$SSL_DIR"'/private.key"
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
    },
    {
      "listen": "127.0.0.1",
      "port": 4434,
      "protocol": "vless",
      "settings": {
        "clients": ['"$vless_clients_str"'],
        "decryption": "none"
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
        "security": "reality",
        "realitySettings": {
          "show": false,
          "dest": "'"$reality_dest"'",
          "xver": 0,
          "serverNames": [
            "'"$reality_sni"'"
          ],
          "privateKey": "'"$reality_priv"'",
          "shortIds": [
            "'"$reality_sid"'"
          ]
        },
        "sockopt": {
          "tcpFastOpen": true,
          "tcpcongestion": "bbr",
          "tcpKeepAliveIdle": 300
        }
      }
    }
  ]'
    else
        inbounds_str='[
    {
      "port": 443,
      "protocol": "vless",
      "settings": {
        "clients": ['"$vless_clients_str"'],
        "decryption": "none",
        "fallbacks": '"$fallbacks_str"'
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
            "certificateFile": "'"$SSL_DIR"'/fullchain.cer",
            "keyFile": "'"$SSL_DIR"'/private.key"
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
    }
  ]'
    fi

    # Генерация конфигурационного файла
    cat > "$config_file" <<EOF
{
  "log": {
    "loglevel": "warning",
    "access": "/var/log/xray/access.log",
    "error": "/var/log/xray/error.log"
  },
  "inbounds": $inbounds_str,
  "outbounds": $outbounds_str,
  "routing": {
    "rules": [
      $routing_rules_str
    ]
  }
}
EOF

    systemctl restart xray
}

# === Генерация конфигурации Hysteria 2 ===
generate_hysteria_config() {
    echo "🧩 Генерация конфигурации Hysteria 2..."
    mkdir -p /etc/hysteria
    
    local DOMAIN=$(get_installed_var "DOMAIN")
    if [ -z "$DOMAIN" ]; then
        DOMAIN="$DOMAIN"
    fi
    
    local config_yaml="/etc/hysteria/config.yaml"
    
    # Собираем userpass для Hysteria 2 (UUID используется и как имя пользователя, и как пароль)
    local userpass=()
    if [ -d "$CLIENT_CONFIG_DIR" ] && [ "$(find "$CLIENT_CONFIG_DIR" -maxdepth 1 -name '*.json' 2>/dev/null | wc -l)" -gt 0 ]; then
        for filepath in $(find "$CLIENT_CONFIG_DIR" -maxdepth 1 -name '*.json' | sort); do
            local uuid=$(python3 -c "import json, sys; print(json.load(open(sys.argv[1])).get('id', ''))" "$filepath" 2>/dev/null)
            if [ -n "$uuid" ] && [ "$uuid" != "null" ]; then
                userpass+=("    \"$uuid\": \"$uuid\"")
            fi
        done
    else
        # Первоначальная генерация (когда json файлов на диске еще нет, но UUIDs заполнен)
        for i in $(seq 1 "$NUM_DEVICES"); do
            local uuid="${UUIDs[$i]}"
            if [ -n "$uuid" ]; then
                userpass+=("    \"$uuid\": \"$uuid\"")
            fi
        done
    fi
    
    if [ ${#userpass[@]} -eq 0 ]; then
        userpass+=("    \"default\": \"default\"")
    fi
    
    local userpass_str=$(IFS=$'\n'; echo "${userpass[*]}")
    
    cat > "$config_yaml" <<EOF
listen: :443

tls:
  cert: $SSL_DIR/fullchain.cer
  key: $SSL_DIR/private.key

auth:
  type: userpass
  userpass:
$userpass_str

masquerade:
  type: proxy
  proxy:
    url: https://www.bing.com
    rewriteHost: true
EOF

    # Управляем правами
    chmod 600 "$config_yaml"
    
    # Создаём или обновляем systemd service
    local iptables_path=$(which iptables 2>/dev/null || echo "/sbin/iptables")
    local ip6tables_path=$(which ip6tables 2>/dev/null || echo "/sbin/ip6tables")

    cat > /etc/systemd/system/hysteria-server.service <<EOF
[Unit]
Description=Hysteria 2 Server
After=network.target

[Service]
Type=simple
User=root
WorkingDirectory=/etc/hysteria
ExecStartPre=-$iptables_path -t nat -D PREROUTING -p udp --dport 20000:50000 -j REDIRECT --to-ports 443
ExecStartPre=-$ip6tables_path -t nat -D PREROUTING -p udp --dport 20000:50000 -j REDIRECT --to-ports 443
ExecStartPre=-$iptables_path -t nat -A PREROUTING -p udp --dport 20000:50000 -j REDIRECT --to-ports 443
ExecStartPre=-$ip6tables_path -t nat -A PREROUTING -p udp --dport 20000:50000 -j REDIRECT --to-ports 443
ExecStart=/usr/local/bin/hysteria server --config /etc/hysteria/config.yaml
ExecStopPost=-$iptables_path -t nat -D PREROUTING -p udp --dport 20000:50000 -j REDIRECT --to-ports 443
ExecStopPost=-$ip6tables_path -t nat -D PREROUTING -p udp --dport 20000:50000 -j REDIRECT --to-ports 443
Restart=always
RestartSec=5
LimitNOFILE=1048576

[Install]
WantedBy=multi-user.target
EOF
    systemctl daemon-reload
    systemctl enable hysteria-server >/dev/null 2>&1
    
    systemctl restart hysteria-server
}

# === Генерация клиентских конфигов ===
generate_client_configs() {
    echo "📦 Генерация клиентских конфигов..."
    mkdir -p "$CLIENT_CONFIG_DIR"
    
    local DOMAIN=$(get_installed_var "DOMAIN")
    local FINGERPRINT=$(get_installed_var "FINGERPRINT")
    if [ -z "$FINGERPRINT" ]; then FINGERPRINT="random"; fi

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
    "happ": "https://raw.githubusercontent.com/hydraponique/roscomvpn-routing/main/HAPP/DEFAULT.DEEPLINK",
    "incy": "https://raw.githubusercontent.com/hydraponique/roscomvpn-routing/main/INCY/DEFAULT.DEEPLINK",
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

happ_resolver = RoscomVPNResolver("happ")
incy_resolver = RoscomVPNResolver("incy")

def get_installed_vars():
    vars = {
        "domain": "",
        "emoji": "",
        "fp": "random",
        "reality_enabled": "false",
        "reality_sni": "max.ru",
        "reality_pbk": "",
        "reality_sid": "",
        "routing_enabled": "true"
    }
    try:
        if os.path.exists(INSTALLED_FILE):
            with open(INSTALLED_FILE, "r") as f:
                for line in f:
                    parts = line.split("=", 1)
                    if len(parts) == 2:
                        key = parts[0].strip().lower()
                        val = parts[1].strip()
                        if key == "domain": vars["domain"] = val
                        elif key == "emoji": vars["emoji"] = val
                        elif key == "fingerprint": vars["fp"] = val
                        elif key == "reality_enabled": vars["reality_enabled"] = val
                        elif key == "reality_sni": vars["reality_sni"] = val
                        elif key == "reality_public_key": vars["reality_pbk"] = val
                        elif key == "reality_short_id": vars["reality_sid"] = val
                        elif key == "routing_enabled": vars["routing_enabled"] = val
    except Exception:
        pass
    if not vars["fp"]:
        vars["fp"] = "random"
    return vars

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
        
        ivars = get_installed_vars()
        domain = ivars["domain"]
        emoji = ivars["emoji"]
        fp = ivars["fp"]
        if not domain:
            domain = self.headers.get('Host', '').split(':')[0]

        if emoji:
            remark_vision = f"{emoji} VLESS-TCP"
            remark_hy2 = f"{emoji} Hysteria2"
            remark_reality = f"{emoji} VLESS-Reality ({ivars['reality_sni']})"
        else:
            remark_vision = "🌐 VLESS-TCP"
            remark_hy2 = "⚡ Hysteria2"
            remark_reality = f"🛡️ VLESS-Reality ({ivars['reality_sni']})"

        encoded_remark_vision = urllib.parse.quote(remark_vision)
        encoded_remark_hy2 = urllib.parse.quote(remark_hy2)
        encoded_remark_reality = urllib.parse.quote(remark_reality)
        
        vless_vision = f"vless://{uuid_param}@{domain}:443?flow=xtls-rprx-vision&security=tls&type=tcp&fp={fp}&alpn=http%2F1.1#{encoded_remark_vision}"
        hy2_link = f"hysteria2://{uuid_param}:{uuid_param}@{domain}:443?sni={domain}&hop=20000-50000#{encoded_remark_hy2}"
        
        sub_content_links = vless_vision + "\n" + hy2_link + "\n"
        if ivars["reality_enabled"] == "true":
            vless_reality = f"vless://{uuid_param}@{domain}:443?flow=xtls-rprx-vision&security=reality&sni={ivars['reality_sni']}&pbk={ivars['reality_pbk']}&sid={ivars['reality_sid']}&fp={fp}&type=tcp#{encoded_remark_reality}"
            sub_content_links += vless_reality + "\n"
            
        client_display = f"❯ {client_name}"
        b64_client_display = "base64:" + base64.b64encode(client_display.encode('utf-8')).decode('utf-8')
        
        announce_text = f"Профиль: {client_name} • Локации: VLESS (TCP), Hysteria2 (UDP) • Коридор: https://mvrvntn.github.io/koridor/ • Нет сети? ➔ Обновите ↻"
        b64_announce = "base64:" + base64.b64encode(announce_text.encode('utf-8')).decode('utf-8')
        
        support_url = "https://t.me/mavrtunbot"

        user_agent = self.headers.get("User-Agent", "").lower()
        if "v2ray" in user_agent or "clash" in user_agent:
            sub_content = sub_content_links
        else:
            # Задаем комментарии с метаданными подписки (используем base64 для безопасной передачи кириллицы в Incy/Happ)
            sub_content = f"#profile-title: {b64_client_display}\n#profile-update-interval: 1\n#support-url: {support_url}\n#profile-web-page-url: https://mvrvntn.github.io/koridor/\n#announce: {b64_announce}\n#fragmentation-enable: 1\n#fragmentation-packets: tlshello\n#fragmentation-length: 10-30\n#fragmentation-interval: 10-20\n{sub_content_links}"
            
        b64_content = base64.b64encode(sub_content.encode("utf-8")).decode("utf-8")
        
        routing_enabled = ivars.get("routing_enabled", "true") != "false"
        _routing = ""
        if routing_enabled:
            if "incy" in user_agent:
                _routing = incy_resolver.get()
            else:
                _routing = happ_resolver.get()

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

        if routing_enabled and _routing:
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
  DOMAIN=$(grep "^DOMAIN=" /etc/xray/.installed | cut -d= -f2 | tr -d '[:space:]')
  EMOJI=$(grep "^EMOJI=" /etc/xray/.installed | cut -d= -f2 | tr -d '[:space:]')
  FLOW="xtls-rprx-vision"
  FINGERPRINT=$(grep "^FINGERPRINT=" /etc/xray/.installed | cut -d= -f2 | tr -d '[:space:]')
  if [ -z "$FINGERPRINT" ]; then FINGERPRINT="random"; fi
  PORT=443

  REALITY_ENABLED=$(grep "^REALITY_ENABLED=" /etc/xray/.installed | cut -d= -f2 | tr -d '[:space:]')
  REALITY_SNI=$(grep "^REALITY_SNI=" /etc/xray/.installed | cut -d= -f2 | tr -d '[:space:]')
  REALITY_PBK=$(grep "^REALITY_PUBLIC_KEY=" /etc/xray/.installed | cut -d= -f2 | tr -d '[:space:]')
  REALITY_SID=$(grep "^REALITY_SHORT_ID=" /etc/xray/.installed | cut -d= -f2 | tr -d '[:space:]')

mapfile -t config_files < <(find "$CONFIG_DIR" -maxdepth 1 -name '*.json' | sort)

if [ ${#config_files[@]} -eq 0 ]; then
  echo -e "${RED}❌ Конфиги не найдены!${NC}"
  exit 1
fi

echo -e "\n${BOLD}${CYAN}📱  ДОСТУПНЫЕ УСТРОЙСТВА${NC}"
echo -e "${CYAN}──────────────────────────────────────────────────────────${NC}"
for i in "${!config_files[@]}"; do
  remarks=$(python3 -c "import json, sys; print(json.load(open(sys.argv[1])).get('remarks', ''))" "${config_files[$i]}" 2>/dev/null)
  if [ -z "$remarks" ] || [ "$remarks" = "null" ]; then
    remarks="${config_files[$i]##*/}"
    remarks="${remarks%.json}"
  fi
  echo -e " ${BOLD}${YELLOW}$((i+1)).${NC} $remarks"
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
  remark_hy2="${EMOJI} Hysteria2"
  remark_reality="${EMOJI} VLESS-Reality (${REALITY_SNI})"
else
  remark_vision="🌐 VLESS-TCP"
  remark_hy2="⚡ Hysteria2"
  remark_reality="🛡️ VLESS-Reality (${REALITY_SNI})"
fi

urlencode() {
  python3 -c "import urllib.parse, sys; print(urllib.parse.quote(sys.argv[1]), end='')" "$1" 2>/dev/null || echo -n "$1"
}

encoded_remark_vision=$(urlencode "$remark_vision")
encoded_remark_hy2=$(urlencode "$remark_hy2")
encoded_remark_reality=$(urlencode "$remark_reality")

# Ссылки для подключения
VLESS_VISION="vless://${UUID}@${DOMAIN}:${PORT}?flow=${FLOW}&security=tls&type=tcp&fp=${FINGERPRINT}&alpn=http%2F1.1#${encoded_remark_vision}"
HY2_LINK="hysteria2://${UUID}:${UUID}@${DOMAIN}:443?sni=${DOMAIN}&hop=20000-50000#${encoded_remark_hy2}"
SUBSCRIPTION_URL="https://${DOMAIN}/sub/${UUID}"

if [ "$REALITY_ENABLED" = "true" ]; then
  VLESS_REALITY="vless://${UUID}@${DOMAIN}:${PORT}?flow=${FLOW}&security=reality&sni=${REALITY_SNI}&pbk=${REALITY_PBK}&sid=${REALITY_SID}&fp=${FINGERPRINT}&type=tcp#${encoded_remark_reality}"
fi

echo -e "\n${BOLD}${PURPLE}🔗  ССЫЛКИ ДЛЯ ПОДКЛЮЧЕНИЯ${NC}"
echo -e "${PURPLE}──────────────────────────────────────────────────────────${NC}"
echo -e " ${BOLD}${YELLOW}1. VLESS TCP Vision (Для смартфонов и ПК):${NC}"
echo -e "    ${GREEN}$VLESS_VISION${NC}"
echo -e " ${BOLD}${YELLOW}2. Hysteria2 (UDP, быстрый обход):${NC}"
echo -e "    ${GREEN}$HY2_LINK${NC}"
if [ "$REALITY_ENABLED" = "true" ]; then
echo -e " ${BOLD}${YELLOW}3. VLESS Reality (Маскировка ${REALITY_SNI}):${NC}"
echo -e "    ${GREEN}$VLESS_REALITY${NC}"
fi

echo -e "\n ${BOLD}${YELLOW}Ссылка подписки (импорт в клиент):${NC}"
echo -e "    ${CYAN}$SUBSCRIPTION_URL${NC}"
echo -e "${PURPLE}──────────────────────────────────────────────────────────${NC}"

echo -e "\n${BOLD}${CYAN}🔳  ГЕНЕРАЦИЯ QR-КОДА${NC}"
echo -e "${CYAN}──────────────────────────────────────────────────────────${NC}"
echo -e " Выберите, для чего отобразить QR-код:"
echo -e " ${BOLD}${YELLOW}1.${NC} VLESS TCP Vision"
echo -e " ${BOLD}${YELLOW}2.${NC} Hysteria2"
if [ "$REALITY_ENABLED" = "true" ]; then
echo -e " ${BOLD}${YELLOW}3.${NC} VLESS Reality"
echo -e " ${BOLD}${YELLOW}4.${NC} Ссылка подписки"
else
echo -e " ${BOLD}${YELLOW}3.${NC} Ссылка подписки"
fi
echo -e "${CYAN}──────────────────────────────────────────────────────────${NC}"
read -p "Ваш выбор: " qr_choice
if [ "$REALITY_ENABLED" = "true" ]; then
  case "$qr_choice" in
    1) qrencode -t UTF8 "$VLESS_VISION" ;;
    2) qrencode -t UTF8 "$HY2_LINK" ;;
    3) qrencode -t UTF8 "$VLESS_REALITY" ;;
    4) qrencode -t UTF8 "$SUBSCRIPTION_URL" ;;
    *) echo -e "${RED}Выход без вывода QR-кода${NC}" ;;
  esac
else
  case "$qr_choice" in
    1) qrencode -t UTF8 "$VLESS_VISION" ;;
    2) qrencode -t UTF8 "$HY2_LINK" ;;
    3) qrencode -t UTF8 "$SUBSCRIPTION_URL" ;;
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
        echo -e "\n${BOLD}${CYAN}🛠️  ДИАГНОСТИКА И ПОИСК НЕИСПРАВНОСТЕЙ${NC}"
        echo -e "${CYAN}──────────────────────────────────────────────────────────${NC}"
        
        # 1. Проверка конфликтов портов 443 и 80
        echo -e "\n${BOLD}[1] Проверка сетевых портов:${NC}"
        local port_443_process=$(ss -tlnp 'sport = :443' 2>/dev/null | grep -v 'Local Address' | awk '{print $NF}')
        local port_443_udp_process=$(ss -ulnp 'sport = :443' 2>/dev/null | grep -v 'Local Address' | awk '{print $NF}')
        local port_80_process=$(ss -tlnp 'sport = :80' 2>/dev/null | grep -v 'Local Address' | awk '{print $NF}')
        
        if [ -n "$port_443_process" ]; then
            echo -e " 🟢 Порт 443 (TCP) успешно занят процессом: ${GREEN}$port_443_process${NC}"
            if [[ "$port_443_process" =~ "openvpn" ]]; then
                echo -e "  ${RED}⚠️ ВНИМАНИЕ! Порт 443 занят процессом OpenVPN. Это приведет к неработоспособности Xray!${NC}"
            fi
        else
            echo -e " 🔴 ${RED}Порт 443 (TCP) Свободен или Xray не запущен!${NC}"
        fi

        if [ -n "$port_443_udp_process" ]; then
            echo -e " 🟢 Порт 443 (UDP) успешно занят процессом: ${GREEN}$port_443_udp_process${NC}"
        else
            echo -e " 🔴 ${RED}Порт 443 (UDP) Свободен или Hysteria 2 не запущена!${NC}"
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
        
        if systemctl is-active --quiet hysteria-server; then
            echo -e " Hysteria 2:   🟢 ${GREEN}ACTIVE (Запущен)${NC}"
        else
            echo -e " Hysteria 2:   🔴 ${RED}INACTIVE (Остановлен)${NC}"
            journalctl -u hysteria-server -n 10 --no-pager
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

        # 5. Проверка разблокировки медиа-ресурсов
        echo -e "\n${BOLD}[5] Разблокировка медиа-ресурсов (Netflix, YouTube, ChatGPT):${NC}"
        check_media_unlock() {
            local label="$1"
            local iface="$2"
            local curl_opts=""
            if [ -n "$iface" ]; then
                curl_opts="--interface $iface"
            fi

            # Netflix
            local nf_code=$(curl $curl_opts -s -o /dev/null -w "%{http_code}" --connect-timeout 4 https://www.netflix.com/title/80018499)
            local nf_res="${RED}🔴 Заблокирован${NC}"
            if [ "$nf_code" == "200" ]; then
                nf_res="${GREEN}🟢 Доступен (Оригиналы + Каталог)${NC}"
            elif [ "$nf_code" == "301" ] || [ "$nf_code" == "302" ]; then
                nf_res="${YELLOW}🟡 Доступны только собственные релизы${NC}"
            fi

            # ChatGPT
            local gpt_code=$(curl $curl_opts -s -o /dev/null -w "%{http_code}" --connect-timeout 4 https://chatgpt.com)
            local gpt_res="${RED}🔴 Заблокирован${NC}"
            if [ "$gpt_code" == "200" ] || [ "$gpt_code" == "302" ]; then
                gpt_res="${GREEN}🟢 Доступен${NC}"
            fi

            # YouTube Region
            local yt_region=$(curl $curl_opts -s --connect-timeout 4 https://www.youtube.com/premium 2>/dev/null | grep -o 'countryCode":"[^"]*"' | cut -d'"' -f3)
            local yt_res="${RED}🔴 Не удалось определить регион${NC}"
            if [ -n "$yt_region" ]; then
                yt_res="${GREEN}🟢 Доступен (Регион: $yt_region)${NC}"
            fi

            echo -e "   👉 ${CYAN}$label:${NC}"
            echo -e "      - Netflix: $nf_res"
            echo -e "      - ChatGPT: $gpt_res"
            echo -e "      - YouTube: $yt_res"
        }
        check_media_unlock "Основной IP сервера" ""
        if [ "$(get_installed_var "WARP_INSTALLED")" == "true" ] && ip link show warp >/dev/null 2>&1; then
            check_media_unlock "Через интерфейс WARP" "warp"
        fi

        # 6. Проверка сертификатов SSL
        echo -e "\n${BOLD}[6] Проверка SSL-сертификатов Let's Encrypt:${NC}"
        if [ -f "$SSL_DIR/fullchain.cer" ] && [ -f "$SSL_DIR/private.key" ]; then
            echo -e " Файлы SSL: 🟢 ${GREEN}Присутствуют в директории $SSL_DIR${NC}"
            local end_date=$(openssl x509 -enddate -noout -in "$SSL_DIR/fullchain.cer" 2>/dev/null | cut -d= -f2)
            echo -e " Срок действия сертификата до: ${YELLOW}$end_date${NC}"
        else
            echo -e " Файлы SSL: 🔴 ${RED}ОТСУТСТВУЮТ! Xray не сможет работать без TLS-сертификатов.${NC}"
        fi

        # 7. Проверка Фаерволов и Правил IPTables
        echo -e "\n${BOLD}[7] Состояние системных фаерволов и Port Hopping:${NC}"
        if ufw status | grep -q "Status: active"; then
            echo -e " UFW Firewall: 🟢 ${GREEN}ACTIVE (Включен)${NC}"
            if iptables -t nat -S | grep -qi "antizapret"; then
                echo -e "  ${YELLOW}⚠️ ПРЕДУПРЕЖДЕНИЕ: UFW активен одновременно с правилами NAT AntiZapret.${NC}"
                echo -e "  Это может вызывать сбои маршрутизации. Рекомендуется выполнить: ${CYAN}ufw disable${NC}"
            fi
        else
            echo -e " UFW Firewall: 🔘 ${YELLOW}DISABLED (Отключен)${NC}"
            echo -e " Убедитесь, что порты 443 и 80 разрешены напрямую в ваших правилах iptables."
        fi

        # Проверка правил Port Hopping
        local ipt_path=$(which iptables 2>/dev/null || echo "/sbin/iptables")
        if $ipt_path -t nat -S 2>/dev/null | grep -q "20000:50000"; then
            echo -e " Port Hopping (IPv4 NAT): 🟢 ${GREEN}АКТИВЕН (Перенаправление 20000-50000 -> 443)${NC}"
        else
            echo -e " Port Hopping (IPv4 NAT): 🔴 ${RED}НЕАКТИВЕН${NC}"
        fi
        
        local ipt6_path=$(which ip6tables 2>/dev/null || echo "/sbin/ip6tables")
        if $ipt6_path -t nat -S &>/dev/null; then
            if $ipt6_path -t nat -S 2>/dev/null | grep -q "20000:50000"; then
                echo -e " Port Hopping (IPv6 NAT): 🟢 ${GREEN}АКТИВЕН (Перенаправление 20000-50000 -> 443)${NC}"
            else
                echo -e " Port Hopping (IPv6 NAT): 🔴 ${RED}НЕАКТИВЕН${NC}"
            fi
        fi

        # 8. Использование системных ресурсов
        echo -e "\n${BOLD}[8] Использование ресурсов процессами Xray и Hysteria 2:${NC}"
        local xray_pid=$(systemctl show --property=MainPID --value xray)
        local hysteria_pid=$(systemctl show --property=MainPID --value hysteria-server)
        
        if [ -n "$xray_pid" ] && [ "$xray_pid" -ne 0 ] && ps -p "$xray_pid" >/dev/null; then
            local xray_mem=$(ps -o rss= -p "$xray_pid" | awk '{print int($1/1024)}')
            local xray_cpu=$(ps -o %cpu= -p "$xray_pid")
            echo -e " Xray (PID $xray_pid):   CPU: ${GREEN}${xray_cpu}%${NC} | Memory: ${GREEN}${xray_mem} MB${NC}"
        else
            echo -e " Xray: 🔴 Процесс не запущен"
        fi
        
        if [ -n "$hysteria_pid" ] && [ "$hysteria_pid" -ne 0 ] && ps -p "$hysteria_pid" >/dev/null; then
            local hysteria_mem=$(ps -o rss= -p "$hysteria_pid" | awk '{print int($1/1024)}')
            local hysteria_cpu=$(ps -o %cpu= -p "$hysteria_pid")
            echo -e " Hysteria 2 (PID $hysteria_pid): CPU: ${GREEN}${hysteria_cpu}%${NC} | Memory: ${GREEN}${hysteria_mem} MB${NC}"
        else
            echo -e " Hysteria 2: 🔴 Процесс не запущен"
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
        if [ -z "$FINGERPRINT" ]; then FINGERPRINT="random"; fi

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

        # Обновляем конфиг сервера и перезапускаем xray и hysteria
        generate_server_config
        generate_hysteria_config

        # Обновляем маркер
        local current_num=$(find "$CLIENT_CONFIG_DIR" -maxdepth 1 -name '*.json' | wc -l)
        update_marker_val "NUM_DEVICES" "$current_num"

        echo "✅ Клиент '$new_name' успешно добавлен!"
    }

    # === UI ФУНКЦИИ ===
    ui_header() {
        local title="$1"
        local color="${2:-${CYAN}}"
        echo -e "\n${color}╭─────── ${BOLD}${title}${NC} ${color}─────────────────────────────────────────${NC}"
        echo -e "${color}│${NC}"
    }

    ui_footer() {
        local color="${1:-${CYAN}}"
        echo -e "${color}│${NC}"
        echo -e "${color}╰────────────────────────────────────────────────────────────${NC}"
    }

    ui_divider() {
        local color="${1:-${CYAN}}"
        echo -e "${color}│${NC}"
        echo -e "${color}├────────────────────────────────────────────────────────────${NC}"
        echo -e "${color}│${NC}"
    }

    ui_item() {
        local num="$1"
        local text="$2"
        local color="${3:-${YELLOW}}"
        if [ -z "$num" ]; then
             echo -e "${CYAN}│${NC}  ${text}"
        else
             echo -e "${CYAN}│${NC}  ${BOLD}${color}${num}.${NC} ${text}"
        fi
    }

    ui_item_color() {
        local num="$1"
        local text="$2"
        local num_color="${3:-${YELLOW}}"
        local border_color="${4:-${CYAN}}"
        if [ -z "$num" ]; then
             echo -e "${border_color}│${NC}  ${text}"
        else
             echo -e "${border_color}│${NC}  ${BOLD}${num_color}${num}.${NC} ${text}"
        fi
    }

    ui_status() {
        local icon="$1"
        local key="$2"
        local val="$3"
        printf "${CYAN}│${NC} %s ${BOLD}%-12s${NC} %b\n" "$icon" "$key:" "$val"
    }

    remove_client() {
        ui_header "🗑️  УДАЛЕНИЕ ПОЛЬЗОВАТЕЛЯ" "${RED}"
        
        mapfile -t config_files < <(find "$CLIENT_CONFIG_DIR" -maxdepth 1 -name '*.json' | sort)
        if [ ${#config_files[@]} -eq 0 ]; then
            ui_item_color "" "❌ Нет доступных клиентов для удаления" "" "${RED}"
            ui_footer "${RED}"
            return
        fi

        for i in "${!config_files[@]}"; do
            remarks=$(python3 -c "import json, sys; print(json.load(open(sys.argv[1])).get('remarks', ''))" "${config_files[$i]}" 2>/dev/null)
            if [ -z "$remarks" ]; then
                remarks="${config_files[$i]##*/}"
                remarks="${remarks%.json}"
            fi
            ui_item_color "$((i+1))" "$remarks" "${YELLOW}" "${RED}"
        done
        ui_item_color "0" "↩️ Отмена и возврат назад" "${CYAN}" "${RED}"
        ui_footer "${RED}"

        read -p " Выберите клиента (1-${#config_files[@]}, или 0 для выхода): " choice
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

        read -p " Вы действительно хотите удалить '$remarks'? [y/N]: " confirm
        if [[ "$confirm" =~ ^[Yy]$ ]]; then
            rm -f "$selected"
            # Обновляем конфиг сервера и перезапускаем xray и hysteria
            generate_server_config
            generate_hysteria_config

            # Обновляем маркер
            local current_num=$(find "$CLIENT_CONFIG_DIR" -maxdepth 1 -name '*.json' | wc -l)
            update_marker_val "NUM_DEVICES" "$current_num"

            echo -e " ${GREEN}✅ Клиент '$remarks' успешно удален из системы!${NC}"
            sleep 1
        else
            echo " Отменено."
        fi
    }

    show_status_dashboard() {
        local domain=$(get_installed_var "DOMAIN")
        local clients_count=$(find "$CLIENT_CONFIG_DIR" -maxdepth 1 -name '*.json' 2>/dev/null | wc -l)
        
        # Статусы системных служб
        local xray_ver=""
        if [ -f "/usr/local/bin/xray" ]; then
            xray_ver=$(/usr/local/bin/xray version 2>/dev/null | head -n 1 | awk '{print $2}')
        elif command -v xray >/dev/null 2>&1; then
            xray_ver=$(xray version 2>/dev/null | head -n 1 | awk '{print $2}')
        fi

        local xray_status="${RED}OFF${NC}"
        if [ -n "$xray_ver" ]; then
            systemctl is-active xray >/dev/null 2>&1 && xray_status="${GREEN}ACTIVE${NC} (v$xray_ver)" || xray_status="${RED}OFF${NC} (v$xray_ver)"
        else
            systemctl is-active xray >/dev/null 2>&1 && xray_status="${GREEN}ACTIVE${NC}" || xray_status="${RED}OFF${NC}"
        fi
        
        local sub_status="${RED}OFF${NC}"
        systemctl is-active xray-sub >/dev/null 2>&1 && sub_status="${GREEN}ACTIVE${NC}"
        
        local hy2_status="${RED}OFF${NC}"
        systemctl is-active hysteria-server >/dev/null 2>&1 && hy2_status="${GREEN}ACTIVE${NC}"
        
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

        local opera_installed=$(get_installed_var "OPERA_INSTALLED")
        local opera_enabled=$(get_installed_var "OPERA_ENABLED")
        local opera_status="${RED}NOT INSTALLED${NC}"
        if [ "$opera_installed" == "true" ]; then
            if [ "$opera_enabled" == "true" ]; then
                opera_status="${GREEN}ON${NC}"
            else
                opera_status="${YELLOW}DISABLED${NC}"
            fi
        fi

        local reality_enabled=$(get_installed_var "REALITY_ENABLED")
        local reality_sni=$(get_installed_var "REALITY_SNI")
        [ -z "$reality_sni" ] && reality_sni="max.ru"
        local reality_status="${RED}OFF${NC}"
        if [ "$reality_enabled" == "true" ]; then
            reality_status="${GREEN}ON (${reality_sni})${NC}"
        fi

        ui_header "🖥️  СТАТУС СЕРВЕРА"
        ui_status "🌐" "Сервер" "${GREEN}$domain${NC}"
        ui_status "⚙️ " "Службы" "Xray: [$xray_status] | Hysteria 2: [$hy2_status] | Sub: [$sub_status]"
        ui_status "🌀" "Обходы" "WARP: [$warp_status] | Opera: [$opera_status]"
        ui_status "👥" "Клиенты" "${BOLD}${YELLOW}$clients_count${NC} активных устройств"
        ui_footer
    }

    change_fingerprint() {
        ui_header "🛠️  ВЫБОР ОТПЕЧАТКА TLS (FINGERPRINT)"
        ui_item "1" "chrome (Рекомендуется, самый стабильный)"
        ui_item "2" "safari (Apple устройства)"
        ui_item "3" "ios (Мобильный Apple)"
        ui_item "4" "android (Мобильный Android)"
        ui_item "5" "edge (Microsoft Edge)"
        ui_item "6" "firefox (Mozilla Firefox)"
        ui_item "7" "360 (Браузер 360)"
        ui_item "8" "qq (Браузер QQ)"
        ui_item "9" "random (Случайный из списка браузеров)"
        ui_item "10" "randomized (Полная рандомизация - может вызывать обрывы)"
        ui_footer
        read -p " Выберите отпечаток (1-10): " fp_choice
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

        ui_header "🌐  СМЕНА ОСНОВНОГО ДОМЕНА"
        ui_item "" "Текущий домен: ${GREEN}$current_domain${NC}"
        ui_divider
        ui_item "1" "🌐 Изменить основной домен (с перевыпуском SSL)"
        ui_item "0" "↩️ Вернуться в главное меню" "${CYAN}"
        ui_footer
        
        read -p " Выберите действие (0-1): " dchoice
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
            *)
                echo -e "${RED}❌ Неверный выбор!${NC}"
                sleep 1
                domain_management_menu
                ;;
        esac
    }

    reality_management_menu() {
        local reality_enabled=$(get_installed_var "REALITY_ENABLED")
        local reality_sni=$(get_installed_var "REALITY_SNI")
        [ -z "$reality_sni" ] && reality_sni="max.ru"
        local reality_dest=$(get_installed_var "REALITY_DEST")
        [ -z "$reality_dest" ] && reality_dest="max.ru:443"

        ui_header "🛡️  МАСКИРОВКА ТРАФИКА (VLESS-REALITY)"
        local status_text="${RED}Выключена${NC}"
        [ "$reality_enabled" == "true" ] && status_text="${GREEN}Активна${NC}"
        ui_item "" "Текущий статус: $status_text"
        ui_item "" "Маскировочный SNI: ${CYAN}$reality_sni${NC}"
        ui_item "" "Адрес назначения (DEST): ${CYAN}$reality_dest${NC}"
        ui_divider
        if [ "$reality_enabled" == "true" ]; then
            ui_item "1" "📴 Отключить маскировку Reality (возврат к прямому VLESS-TLS)"
        else
            ui_item "1" "🛡️ Включить маскировку Reality (маскироваться под $reality_sni)"
        fi
        ui_item "2" "⚙️ Изменить маскировочный сайт (SNI и DEST)"
        ui_item "0" "↩️ Вернуться в главное меню" "${CYAN}"
        ui_footer

        read -p " Выберите действие (0-2): " rchoice
        case $rchoice in
            0) main_menu ;;
            1)
                if [ "$reality_enabled" == "true" ]; then
                    echo "📴 Отключение маскировки Reality..."
                    update_marker_val "REALITY_ENABLED" "false"
                else
                    echo "🛡️ Включение маскировки Reality..."
                    update_marker_val "REALITY_ENABLED" "true"
                    # Инициализируем дефолты если пусты
                    if [ -z "$(get_installed_var "REALITY_SNI")" ]; then
                        update_marker_val "REALITY_SNI" "max.ru"
                    fi
                    if [ -z "$(get_installed_var "REALITY_DEST")" ]; then
                        update_marker_val "REALITY_DEST" "max.ru:443"
                    fi
                fi
                
                echo "🔄 Пересборка конфигурации сервера..."
                generate_server_config
                setup_subscription_server
                generate_client_configs
                install_generate_script
                
                echo -e "${GREEN}✅ Настройки маскировки применены!${NC}"
                sleep 1.5
                reality_management_menu
                ;;
            2)
                echo -e "\n${BOLD}--- Изменение маскировочного сайта ---${NC}"
                echo "Введите домен для маскировки (например, max.ru):"
                read -p " SNI (по умолчанию max.ru): " new_sni
                new_sni=$(echo "$new_sni" | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//' -e 's/\/$//')
                [ -z "$new_sni" ] && new_sni="max.ru"

                echo "Введите адрес назначения (по умолчанию $new_sni:443):"
                read -p " DEST (по умолчанию $new_sni:443): " new_dest
                new_dest=$(echo "$new_dest" | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//' -e 's/\/$//')
                [ -z "$new_dest" ] && new_dest="$new_sni:443"

                update_marker_val "REALITY_SNI" "$new_sni"
                update_marker_val "REALITY_DEST" "$new_dest"

                echo -e "${GREEN}✅ Настройки изменены на SNI: $new_sni | DEST: $new_dest${NC}"
                
                # Если Reality уже включен, пересоберем
                if [ "$(get_installed_var "REALITY_ENABLED")" == "true" ]; then
                    echo "🔄 Пересборка конфигурации..."
                    generate_server_config
                    setup_subscription_server
                    generate_client_configs
                    install_generate_script
                fi
                sleep 1.5
                reality_management_menu
                ;;
            *)
                echo -e "${RED}❌ Неверный выбор!${NC}"
                sleep 1
                reality_management_menu
                ;;
        esac
    }

    main_menu() {
        show_status_dashboard
        ui_header "⚡  ГЛАВНОЕ МЕНЮ"
        ui_item "1" "📱 Показать QR-коды и ссылки подключения"
        ui_item "2" "👤 Добавить нового пользователя / устройство"
        ui_item "3" "🗑️ Удалить существующего пользователя"
        ui_item "4" "🌀 Управление обходами блокировок (WARP & Opera Proxy)"
        ui_divider
        ui_item "5" "📰 Просмотреть системные логи служб"
        ui_item "6" "📊 Мониторинг active-соединений (port 443)"
        ui_item "7" "🛠️ Запустить полную диагностику системы (Troubleshooting)"
        ui_divider
        ui_item "8" "🔄 Обновить скрипт с GitHub и применить новые фиксы"
        ui_item "9" "🌐 Изменить отпечаток TLS (Fingerprint)"
        ui_item "10" "🌐 Смена основного домена (SSL)"
        ui_divider
        ui_item_color "11" "${RED}🗑️ Полностью удалить всю установку Xray с сервера${NC}" "${RED}" "${CYAN}"
        ui_item "12" "🚪 Выйти из терминала" "${CYAN}"
        ui_footer
        read -p " Выберите действие (1-12): " choice
        case $choice in
            1) "$GENERATE_SCRIPT" ; main_menu ;;
            2) add_client ; main_menu ;;
            3) remove_client ; main_menu ;;
            4) bypass_menu ;;
            5) show_logs ; main_menu ;;
            6) show_connections ; main_menu ;;
            7) run_diagnostics ; main_menu ;;
            8) 
                echo -e "\n${BOLD}${GREEN}🔄 Загрузка последней версии скрипта...${NC}"
                cd /root || exit
                curl -s -o install_xray.sh -L "https://raw.githubusercontent.com/mvrvntn/xray-vless-install/main/install_xray.sh?v=$RANDOM" && chmod +x install_xray.sh
                echo -e "${GREEN}✅ Скрипт обновлен! Применяем обновления ядра и конфигурации...${NC}"
                /root/install_xray.sh --update-core
                exit 0
                ;;
            9) change_fingerprint ; main_menu ;;
            10) domain_management_menu ;;
            11) 
                echo -e "\n${BOLD}${RED}⚠️ ВНИМАНИЕ! Это действие удалит Xray, все конфигурации, WARP и Opera Proxy!${NC}"
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

    toggle_warp_auto_update() {
        local script_path=$(realpath "$0")
        if crontab -l 2>/dev/null | grep -q 'update-geoblocks'; then
            echo "📴 Отключение автообновления геоблокировок..."
            (crontab -l 2>/dev/null | grep -v 'update-geoblocks') | crontab -
            echo -e "${GREEN}✅ Автообновление отключено${NC}"
        else
            echo "🔄 Включение автообновления геоблокировок..."
            (crontab -l 2>/dev/null | grep -v 'update-geoblocks'; echo "30 3 * * * bash $script_path --update-geoblocks >/dev/null 2>&1") | crontab -
            echo -e "${GREEN}✅ Автообновление включено (ежедневно в 03:30)${NC}"
        fi
        sleep 1.5
    }

    bypass_menu() {
        local warp_installed=$(get_installed_var "WARP_INSTALLED")
        local warp_enabled=$(get_installed_var "WARP_ENABLED")
        local warp_mode=$(get_installed_var "WARP_MODE")
        [ -z "$warp_mode" ] && warp_mode="smart"

        local opera_installed=$(get_installed_var "OPERA_INSTALLED")
        local opera_enabled=$(get_installed_var "OPERA_ENABLED")

        ui_header "🌀  УПРАВЛЕНИЕ ОБХОДАМИ БЛОКИРОВОК" "${PURPLE}"
        
        # Секция Cloudflare WARP
        ui_item_color "" "${BOLD}[ Cloudflare WARP ]${NC}" "" "${PURPLE}"
        if [ "$warp_installed" != "true" ]; then
            ui_item_color "" "Статус: ${RED}Не установлен${NC}" "" "${PURPLE}"
            ui_item_color "1" "📥 Установить и активировать Cloudflare WARP" "${YELLOW}" "${PURPLE}"
        else
            local warp_status="${RED}Выключен${NC}"
            [ "$warp_enabled" == "true" ] && warp_status="${GREEN}Активен${NC}"
            local mode_text="${CYAN}Smart-обход${NC}"
            [ "$warp_mode" == "full" ] && mode_text="${PURPLE}Full-обход (весь трафик)${NC}"
            ui_item_color "" "Статус: $warp_status | Режим: $mode_text" "" "${PURPLE}"
            if [ "$warp_enabled" == "true" ]; then
                ui_item_color "1" "📴 Отключить WARP" "${YELLOW}" "${PURPLE}"
            else
                ui_item_color "1" "🌀 Включить WARP" "${YELLOW}" "${PURPLE}"
            fi
            ui_item_color "2" "⚙️ Изменить режим WARP (Smart / Full)" "${YELLOW}" "${PURPLE}"
            ui_item_color "3" "🔄 Обновить список геоблокировок WARP" "${YELLOW}" "${PURPLE}"
            
            local cron_status="${RED}Выключено${NC}"
            if crontab -l 2>/dev/null | grep -q 'update-geoblocks'; then
                cron_status="${GREEN}Включено${NC}"
            fi
            ui_item_color "4" "🕒 Автообновление геоблоков: $cron_status" "${YELLOW}" "${PURPLE}"
            ui_item_color "5" "⚡ Пересоздать/обновить профиль WARP" "${YELLOW}" "${PURPLE}"
            ui_item_color "6" "${RED}🗑️ Удалить Cloudflare WARP${NC}" "${RED}" "${PURPLE}"
        fi
        
        ui_divider "${PURPLE}"
        ui_item_color "" "${BOLD}[ Opera Proxy (для OpenAI/ChatGPT) ]${NC}" "" "${PURPLE}"
        
        if [ "$opera_installed" != "true" ]; then
            ui_item_color "" "Статус: ${RED}Не установлен${NC}" "" "${PURPLE}"
            ui_item_color "7" "📥 Установить и активировать Opera Proxy" "${YELLOW}" "${PURPLE}"
        else
            local opera_status="${RED}Выключен${NC}"
            [ "$opera_enabled" == "true" ] && opera_status="${GREEN}Активен${NC}"
            ui_item_color "" "Статус: $opera_status" "" "${PURPLE}"
            if [ "$opera_enabled" == "true" ]; then
                ui_item_color "7" "📴 Отключить Opera Proxy" "${YELLOW}" "${PURPLE}"
            else
                ui_item_color "7" "🌀 Включить Opera Proxy" "${YELLOW}" "${PURPLE}"
            fi
            ui_item_color "8" "📝 Редактировать список доменов Opera Proxy" "${YELLOW}" "${PURPLE}"
            ui_item_color "9" "${RED}🗑️ Удалить Opera Proxy${NC}" "${RED}" "${PURPLE}"
        fi
        
        ui_divider "${PURPLE}"
        ui_item_color "" "${BOLD}[ Настройки подписки ]${NC}" "" "${PURPLE}"
        local routing_enabled=$(get_installed_var "ROUTING_ENABLED")
        [ -z "$routing_enabled" ] && routing_enabled="true"
        local routing_status="${RED}Отключена${NC}"
        [ "$routing_enabled" == "true" ] && routing_status="${GREEN}Включена${NC}"
        ui_item_color "" "Передача маршрутов (Routing): $routing_status" "" "${PURPLE}"
        if [ "$routing_enabled" == "true" ]; then
            ui_item_color "10" "📴 Отключить передачу маршрутов в клиенты" "${YELLOW}" "${PURPLE}"
        else
            ui_item_color "10" "🌀 Включить передачу маршрутов в клиенты" "${YELLOW}" "${PURPLE}"
        fi
        
        ui_divider "${PURPLE}"
        ui_item_color "0" "↩️ Назад в главное меню" "${CYAN}" "${PURPLE}"
        ui_footer "${PURPLE}"
        
        read -p " Выберите действие (0-10): " bchoice
        case $bchoice in
            0)
                main_menu
                ;;
            1)
                if [ "$warp_installed" != "true" ]; then
                    install_warp
                    DOMAIN=$(get_installed_var "DOMAIN")
                    NUM_DEVICES=$(get_installed_var "NUM_DEVICES")
                    generate_server_config
                else
                    toggle_warp
                fi
                bypass_menu
                ;;
            2)
                if [ "$warp_installed" == "true" ]; then
                    echo -e "\n${BOLD}Выберите новый режим исходящего трафика:${NC}"
                    echo -e " ${BOLD}${YELLOW}1.${NC} Smart-обход"
                    echo -e " ${BOLD}${YELLOW}2.${NC} Full-обход"
                    read -p "Режим (1-2): " mchoice
                    if [ "$mchoice" == "1" ]; then
                        update_marker_val "WARP_MODE" "smart"
                        echo -e "${GREEN}✅ Режим изменен на Smart-обход${NC}"
                    elif [ "$mchoice" == "2" ]; then
                        update_marker_val "WARP_MODE" "full"
                        echo -e "${GREEN}✅ Режим изменен на Full-обход${NC}"
                    else
                        echo -e "${RED}❌ Неверный выбор${NC}"
                    fi
                    DOMAIN=$(get_installed_var "DOMAIN")
                    NUM_DEVICES=$(get_installed_var "NUM_DEVICES")
                    generate_server_config
                else
                    echo -e "${RED}❌ Установите WARP сначала!${NC}"
                fi
                sleep 1.5
                bypass_menu
                ;;
            3)
                if [ "$warp_installed" == "true" ]; then
                    update_geoblock_list
                    DOMAIN=$(get_installed_var "DOMAIN")
                    NUM_DEVICES=$(get_installed_var "NUM_DEVICES")
                    generate_server_config
                    echo -e "${GREEN}✅ Список блокировок успешно обновлен!${NC}"
                else
                    echo -e "${RED}❌ Установите WARP сначала!${NC}"
                fi
                sleep 1.5
                bypass_menu
                ;;
            4)
                if [ "$warp_installed" == "true" ]; then
                    toggle_warp_auto_update
                else
                    echo -e "${RED}❌ Установите WARP сначала!${NC}"
                fi
                bypass_menu
                ;;
            5)
                if [ "$warp_installed" == "true" ]; then
                    install_warp
                    DOMAIN=$(get_installed_var "DOMAIN")
                    NUM_DEVICES=$(get_installed_var "NUM_DEVICES")
                    generate_server_config
                else
                    echo -e "${RED}❌ Установите WARP сначала!${NC}"
                fi
                sleep 1.5
                bypass_menu
                ;;
            6)
                if [ "$warp_installed" == "true" ]; then
                    uninstall_warp
                else
                    echo -e "${RED}❌ Установите WARP сначала!${NC}"
                fi
                bypass_menu
                ;;
            7)
                if [ "$opera_installed" != "true" ]; then
                    install_opera_proxy
                else
                    toggle_opera_proxy
                fi
                sleep 1.5
                bypass_menu
                ;;
            8)
                if [ "$opera_installed" == "true" ]; then
                    if command -v nano &>/dev/null; then
                        nano /etc/xray/opera.lst
                    elif command -v vi &>/dev/null; then
                        vi /etc/xray/opera.lst
                    else
                        echo -e "${RED}❌ Редактор не найден. Файл списка доменов находится в /etc/xray/opera.lst${NC}"
                    fi
                    DOMAIN=$(get_installed_var "DOMAIN")
                    NUM_DEVICES=$(get_installed_var "NUM_DEVICES")
                    generate_server_config
                else
                    echo -e "${RED}❌ Установите Opera Proxy сначала!${NC}"
                fi
                bypass_menu
                ;;
            9)
                if [ "$opera_installed" == "true" ]; then
                    uninstall_opera_proxy
                else
                    echo -e "${RED}❌ Установите Opera Proxy сначала!${NC}"
                fi
                sleep 1.5
                bypass_menu
                ;;
            10)
                local current_status=$(get_installed_var "ROUTING_ENABLED")
                if [ "$current_status" == "false" ]; then
                    update_marker_val "ROUTING_ENABLED" "true"
                    echo -e "${GREEN}✅ Передача маршрутов включена по умолчанию.${NC}"
                else
                    update_marker_val "ROUTING_ENABLED" "false"
                    echo -e "${GREEN}✅ Передача маршрутов отключена.${NC}"
                fi
                setup_subscription_server
                sleep 1.5
                bypass_menu
                ;;
            *)
                echo -e "${RED}❌ Неверный выбор!${NC}"
                sleep 1
                bypass_menu
                ;;
        esac
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

        # Удаление Opera Proxy
        systemctl stop opera-proxy >/dev/null 2>&1
        systemctl disable opera-proxy >/dev/null 2>&1
        rm -f /etc/systemd/system/opera-proxy.service
        rm -f /usr/local/bin/opera-proxy
        rm -f /etc/xray/opera.lst

        bash -c "$(curl -L https://github.com/XTLS/Xray-install/raw/main/install-release.sh)" @ remove
        rm -rf "$XRAY_CONFIG_DIR" "$CLIENT_CONFIG_DIR" "$SSL_DIR" "$GENERATE_SCRIPT"
        rm -f /var/log/xray/{access.log,error.log}
        if crontab -l &>/dev/null; then
            crontab -l | grep -v "certbot renew" | crontab -
        fi
        systemctl stop hysteria-server >/dev/null 2>&1
        systemctl disable hysteria-server >/dev/null 2>&1
        rm -f /etc/systemd/system/hysteria-server.service
        rm -rf /etc/hysteria
        rm -f /usr/local/bin/hysteria
        systemctl daemon-reload >/dev/null 2>&1

        ufw delete allow 443/tcp > /dev/null
        ufw delete allow 443/udp > /dev/null
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
        generate_hysteria_config
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
    install_hysteria
    generate_server_config
    generate_hysteria_config
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
    echo -e "\n${BOLD}${CYAN}🚀  УСТАНОВКА XRAY VLESS СЕРВЕРА${NC}"
    echo -e "${CYAN}──────────────────────────────────────────────────────────${NC}"
    echo -e " Добро пожаловать! Давайте настроим ваш новый VPN-сервер."
    echo -e "${CYAN}──────────────────────────────────────────────────────────${NC}"
    
    if [ ! -f "$MARKER_FILE" ]; then
        echo -e "\n ${BOLD}${YELLOW}ОПТИМИЗАЦИЯ VPS${NC}"
        read -p " Выполнить базовую оптимизацию VPS (установка ядра Xanmod v3 и настройка системных лимитов)? 
 Рекомендуется для чистой ОС Debian 12/13. Сервер будет перезагружен. [y/N]: " opt_choice
        if [[ "$opt_choice" =~ ^[Yy]$ ]]; then
            optimize_vps
        fi
        echo -e "${CYAN}──────────────────────────────────────────────────────────${NC}"
    fi
    
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

    echo -e "${CYAN}──────────────────────────────────────────────────────────${NC}"
    echo -e "${BOLD}${GREEN}⚙️ Запуск процесса автоматической сборки и установки...${NC}\n"
fi

# === Запуск установки ===
check_domain
check_port_conflicts
create_directories
install_dependencies
install_xray
install_hysteria
setup_firewall
setup_certificates

# Определяем эмодзи страны
FLAG_EMOJI=$(get_flag_emoji)

generate_server_config
generate_hysteria_config
setup_subscription_server
generate_client_configs
install_generate_script

echo -e "DOMAIN=$DOMAIN\nEMAIL=$EMAIL\nNUM_DEVICES=$NUM_DEVICES\nEMOJI=$FLAG_EMOJI\nCDN_DOMAIN=none" > "$MARKER_FILE"
chmod 644 "$MARKER_FILE"

# Регистрация быстрой команды xry
install_xry_command

echo -e "\n✅ Установка полностью завершена! Вы можете управлять сервером в любое время, просто введя в терминале: ${BOLD}${YELLOW}xry${NC}"
main_menu
