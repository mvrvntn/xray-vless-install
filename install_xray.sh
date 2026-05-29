#!/bin/bash

# === Конфигурационные параметры ===
XRAY_CONFIG_DIR="/usr/local/etc/xray"
CLIENT_CONFIG_DIR="/etc/xray/client_configs"
SSL_DIR="/etc/ssl/vless"
MARKER_FILE="/etc/xray/.installed"
GENERATE_SCRIPT="/usr/local/bin/generate_client_config"
SUB_SERVER_SCRIPT="/usr/local/bin/xray_sub_server.py"
INSTALL_LOG="/var/log/xray/install.log"

# === Проверка прав root ===
if [ "$(id -u)" != "0" ]; then
    echo "❌ Этот скрипт должен запускаться с правами root"
    exit 1
fi

# === Проверка предыдущей установки (до запроса данных) ===
if [ -f "$MARKER_FILE" ]; then
    main_menu() {
        echo -e "\n==== Xray Меню ===="
        echo "1. Показать QR-код / Ссылки"
        echo "2. Удалить Xray"
        echo "3. Выйти"
        read -p "Выбор: " choice
        case $choice in
            1) "$GENERATE_SCRIPT" ;;
            2) uninstall_all ;;
            3) exit 0 ;;
            *) echo "Неверный выбор"; main_menu ;;
        esac
    }

    uninstall_all() {
        echo "🧹 Удаление Xray и конфигураций..."
        
        systemctl stop xray-sub >/dev/null 2>&1
        systemctl disable xray-sub >/dev/null 2>&1
        rm -f /etc/systemd/system/xray-sub.service
        systemctl daemon-reload >/dev/null 2>&1
        rm -f "$SUB_SERVER_SCRIPT"

        bash -c "$(curl -L https://github.com/XTLS/Xray-install/raw/main/install-release.sh)" @ remove
        rm -rf "$XRAY_CONFIG_DIR" "$CLIENT_CONFIG_DIR" "$SSL_DIR" "$GENERATE_SCRIPT"
        rm -f /var/log/xray/{access.log,error.log}
        if crontab -l &>/dev/null; then
            crontab -l | grep -v "certbot renew" | crontab -
        fi
        ufw delete allow 443/tcp > /dev/null
        ufw delete allow 443/udp > /dev/null
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
    local val1=$(( $(printf "%d" "$c1") - 65 + 127462 ))
    local val2=$(( $(printf "%d" "$c2") - 65 + 127462 ))
    
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
    apt install -y curl qrencode ufw cron certbot python3 jq lsof > /dev/null
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
    ufw allow 443/udp > /dev/null
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

    # Создаём симлинки на сертификаты
    ln -sf "/etc/letsencrypt/live/$DOMAIN/fullchain.pem" "$SSL_DIR/fullchain.cer"
    ln -sf "/etc/letsencrypt/live/$DOMAIN/privkey.pem" "$SSL_DIR/private.key"

    # Устанавливаем права
    chmod 644 "$SSL_DIR/fullchain.cer"
    chmod 600 "$SSL_DIR/private.key"

    # Добавляем обновление сертификатов в cron (только рестарт Xray)
    (crontab -l 2>/dev/null | grep -v 'certbot renew'; \
     echo "0 3 * * * certbot renew --quiet --post-hook \"systemctl restart xray\"") | crontab -
}

# === Генерация UUID и серверного конфигурационного файла ===
generate_server_config() {
    echo "🧩 Генерация конфигурации Xray..."
    local config_file="$XRAY_CONFIG_DIR/config.json"
    
    # Инициализация массивов для клиентов
    local vless_clients=()
    local hysteria_users=()
    
    # Генерация уникальных UUID для каждого устройства
    for i in $(seq 1 "$NUM_DEVICES"); do
        local uuid=$(xray uuid)
        UUIDs[$i]="$uuid"
        
        vless_clients+=("{
          \"id\": \"$uuid\",
          \"flow\": \"xtls-rprx-vision\",
          \"email\": \"client-$i\"
        }")
        
        hysteria_users+=("{
          \"auth\": \"$uuid\"
        }")
    done
    
    local vless_clients_str=$(IFS=,; echo "${vless_clients[*]}")
    local hysteria_users_str=$(IFS=,; echo "${hysteria_users[*]}")
    
    # Генерация конфигурационного файла с тремя протоколами
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
            "path": "/xhttppath/",
            "dest": "127.0.0.1:10000"
          },
          {
            "path": "/sub/",
            "dest": "127.0.0.1:10080"
          }
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
        }
      }
    },
    {
      "listen": "127.0.0.1",
      "port": 10000,
      "protocol": "vless",
      "settings": {
        "clients": [$vless_clients_str],
        "decryption": "none"
      },
      "streamSettings": {
        "network": "xhttp",
        "xhttpSettings": {
          "mode": "auto",
          "path": "/xhttppath/",
          "extra": {
            "noSSEHeader": true,
            "xPaddingBytes": "100-1000",
            "scMaxBufferedPosts": 30,
            "scMaxEachPostBytes": 1000000,
            "scStreamUpServerSecs": "20-80"
          }
        }
      }
    },
    {
      "port": 443,
      "protocol": "hysteria",
      "settings": {
        "version": 2,
        "users": [$hysteria_users_str]
      },
      "streamSettings": {
        "network": "hysteria",
        "security": "tls",
        "hysteriaSettings": {
          "version": 2
        },
        "tlsSettings": {
          "alpn": ["h3"],
          "certificates": [{
            "certificateFile": "$SSL_DIR/fullchain.cer",
            "keyFile": "$SSL_DIR/private.key"
          }]
        }
      }
    }
  ],
  "outbounds": [{
    "protocol": "freedom"
  }]
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
      "security": "tls"
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
import json

PORT = 10080
CONFIG_DIR = "/etc/xray/client_configs"
INSTALLED_FILE = "/etc/xray/.installed"

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
        # Парсим URL, чтобы убрать query-параметры (например, ?flag=1)
        parsed_url = urllib.parse.urlparse(self.path)
        parts = parsed_url.path.strip("/").split("/")
        
        if len(parts) != 2 or parts[0] != "sub":
            self.send_response(404)
            self.end_headers()
            return
        
        uuid_param = parts[1]
        
        # Проверяем UUID среди сохраненных клиентских конфигов
        client_name = ""
        found = False
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
            self.send_response(404)
            self.end_headers()
            return
        
        domain, emoji = get_domain_and_emoji()
        if not domain:
            domain = self.headers.get('Host', '').split(':')[0]

        # Генерация ссылок по структуре:
        # ФЛАГ🌐 VLESS-TCP (имя)
        # ФЛАГ🛡️ XHTTP (имя)
        # ФЛАГ⚡ HYSTERIA2 (имя)
        if emoji:
            remark_vision = f"{emoji}🌐 VLESS-TCP ({client_name})"
            remark_xhttp = f"{emoji}🛡️ XHTTP ({client_name})"
            remark_hy2 = f"{emoji}⚡ HYSTERIA2 ({client_name})"
        else:
            remark_vision = f"🌐 VLESS-TCP ({client_name})"
            remark_xhttp = f"🛡️ XHTTP ({client_name})"
            remark_hy2 = f"⚡ HYSTERIA2 ({client_name})"

        encoded_remark_vision = urllib.parse.quote(remark_vision)
        encoded_remark_xhttp = urllib.parse.quote(remark_xhttp)
        encoded_remark_hy2 = urllib.parse.quote(remark_hy2)
        
        vless_vision = f"vless://{uuid_param}@{domain}:443?flow=xtls-rprx-vision&security=tls&type=tcp&fp=chrome#{encoded_remark_vision}"
        vless_xhttp = f"vless://{uuid_param}@{domain}:443?security=tls&type=xhttp&path=%2Fxhttppath%2F&fp=chrome#{encoded_remark_xhttp}"
        hysteria2 = f"hysteria2://{uuid_param}@{domain}:443/?sni={domain}&alpn=h3#{encoded_remark_hy2}"
        
        sub_content = f"{vless_vision}\n{vless_xhttp}\n{hysteria2}\n"
        b64_content = base64.b64encode(sub_content.encode("utf-8")).decode("utf-8")
        
        self.send_response(200)
        self.send_header("Content-Type", "text/plain; charset=utf-8")
        self.send_header("Cache-Control", "no-store")
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
FINGERPRINT="chrome"
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
  remark_vision="${EMOJI}🌐 VLESS-TCP (${remarks})"
  remark_xhttp="${EMOJI}🛡️ XHTTP (${remarks})"
  remark_hy2="${EMOJI}⚡ HYSTERIA2 (${remarks})"
else
  remark_vision="🌐 VLESS-TCP (${remarks})"
  remark_xhttp="🛡️ XHTTP (${remarks})"
  remark_hy2="⚡ HYSTERIA2 (${remarks})"
fi

urlencode() {
  echo -n "$1" | jq -s -R -r @uri
}

encoded_remark_vision=$(urlencode "$remark_vision")
encoded_remark_xhttp=$(urlencode "$remark_xhttp")
encoded_remark_hy2=$(urlencode "$remark_hy2")

# Ссылки для подключения
VLESS_VISION="vless://${UUID}@${DOMAIN}:${PORT}?flow=${FLOW}&security=tls&type=tcp&fp=${FINGERPRINT}#${encoded_remark_vision}"
VLESS_XHTTP="vless://${UUID}@${DOMAIN}:${PORT}?security=tls&type=xhttp&path=%2Fxhttppath%2F&fp=${FINGERPRINT}#${encoded_remark_xhttp}"
HYSTERIA2="hysteria2://${UUID}@${DOMAIN}:${PORT}/?sni=${DOMAIN}&alpn=h3#${encoded_remark_hy2}"
SUBSCRIPTION_URL="https://${DOMAIN}/sub/${UUID}"

echo -e "\n=== Ссылки для подключения ==="
echo -e "\n1. VLESS TCP Vision (Стандарт):"
echo "$VLESS_VISION"
echo -e "\n2. VLESS XHTTP (Через HTTP/2 обход блокировок):"
echo "$VLESS_XHTTP"
echo -e "\n3. Hysteria 2 (QUIC / UDP протокол):"
echo "$HYSTERIA2"
echo -e "\n4. Ссылка подписки (все 3 конфига одной ссылкой):"
echo "$SUBSCRIPTION_URL"

echo -e "\n=== Генерация QR-кода ==="
echo "Выберите, для чего отобразить QR-код:"
echo "1. VLESS TCP Vision"
echo "2. VLESS XHTTP"
echo "3. Hysteria 2"
echo "4. Ссылка подписки (импорт в клиент)"
read -p "Выбор (1-4): " qr_choice
case "$qr_choice" in
  1) qrencode -t UTF8 "$VLESS_VISION" ;;
  2) qrencode -t UTF8 "$VLESS_XHTTP" ;;
  3) qrencode -t UTF8 "$HYSTERIA2" ;;
  4) qrencode -t UTF8 "$SUBSCRIPTION_URL" ;;
  *) echo "Выход без вывода QR-кода" ;;
esac
EOF

    chmod +x "$GENERATE_SCRIPT"
}

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

# Объявление массива для хранения UUID
declare -A UUIDs

generate_server_config
setup_subscription_server
generate_client_configs
install_generate_script

echo -e "DOMAIN=$DOMAIN\nEMAIL=$EMAIL\nNUM_DEVICES=$NUM_DEVICES\nEMOJI=$FLAG_EMOJI" > "$MARKER_FILE"
chmod 644 "$MARKER_FILE"

echo -e "\n✅ Установка завершена! Используйте 'generate_client_config' для вывода конфигов."
