#!/usr/bin/env bash

# Проверка версии интерпретатора Bash (требуется 4.0+ для declare -A)
if (( BASH_VERSINFO[0] < 4 )); then
    echo "❌ Ошибка: Требуется Bash версии 4.0 или выше (текущая: ${BASH_VERSION:-неизвестно})" >&2
    exit 1
fi

# === Конфигурационные параметры ===
readonly XRAY_CONFIG_DIR="/usr/local/etc/xray"
readonly CLIENT_CONFIG_DIR="/etc/xray/client_configs"
readonly SSL_DIR="/etc/ssl/vless"
readonly MARKER_FILE="/etc/xray/.installed"
readonly GENERATE_SCRIPT="/usr/local/bin/generate_client_config"
readonly SUB_SERVER_SCRIPT="/usr/local/bin/xray_sub_server.py"
readonly INSTALL_LOG="/var/log/xray/install.log"

SCRIPT_NAME="$(basename -- "${BASH_SOURCE[0]}")"
readonly SCRIPT_NAME
SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
# shellcheck disable=SC2034
readonly SCRIPT_DIR
export SCRIPT_DIR

# Объявление глобального ассоциативного массива для UUID
declare -A UUIDs

# === Цветовая схема терминала ===
# shellcheck disable=SC2034
RED='\033[0;31m'; # shellcheck disable=SC2034
GREEN='\033[0;32m'; # shellcheck disable=SC2034
YELLOW='\033[0;33m'; # shellcheck disable=SC2034
BLUE='\033[0;34m'; # shellcheck disable=SC2034
PURPLE='\033[0;35m'; # shellcheck disable=SC2034
CYAN='\033[0;36m'; # shellcheck disable=SC2034
BOLD='\033[1m'; # shellcheck disable=SC2034
NC='\033[0m'

# === Логирование и Traps (/bash-scripting) ===
mkdir -p "$(dirname "$INSTALL_LOG")" 2>/dev/null || true

log_info() {
    if [[ -d "$(dirname "$INSTALL_LOG")" ]]; then
        echo -e "[$(date '+%Y-%m-%d %H:%M:%S')] INFO: $*" >> "$INSTALL_LOG" 2>/dev/null || true
    fi
}

log_warn() {
    if [[ -d "$(dirname "$INSTALL_LOG")" ]]; then
        echo -e "[$(date '+%Y-%m-%d %H:%M:%S')] WARN: $*" >> "$INSTALL_LOG" 2>/dev/null || true
    fi
}

log_error() {
    if [[ -d "$(dirname "$INSTALL_LOG")" ]]; then
        echo -e "[$(date '+%Y-%m-%d %H:%M:%S')] ERROR: $*" >> "$INSTALL_LOG" 2>/dev/null || true
    fi
}

cleanup() {
    trap - SIGINT SIGTERM
    echo -ne "${NC}\n" # Сброс цвета консоли
    log_info "Скрипт прерван сигналом (SIGINT/SIGTERM)."
    exit 130
}
trap 'cleanup' SIGINT SIGTERM

usage() {
    cat <<EOF
Использование: $SCRIPT_NAME [ОПЦИИ]

Опции:
  -h, --help                                              Показать эту справку и выйти
  -v, --version                                           Показать версию скрипта
  --optimize                                              Запустить полную системную оптимизацию VPS (Xanmod, BBR, RPS, Sysctl, ZRAM)
  --headless <домен> <email> <кол-во> [имена...]          Установка в автоматическом (headless) режиме
  --update-core                                           Обновить ядро Xray, Hysteria 2 и подписки
  --update-geoblocks                                      Обновить списки блокировок Роскомнадзора и Google AI
  --renew-cert                                            Принудительно обновить SSL-сертификат и перезапустить службы
EOF
    exit 0
}


# Регистрация команды xry
install_xry_command() {
    local target_bin="/usr/local/bin/xry"
    local current_script
    current_script=$(realpath "$0" 2>/dev/null || echo "$0")
    if [[ "$current_script" == "$target_bin" ]]; then
        return 0
    fi
    if cp -f "$0" "$target_bin" 2>/dev/null; then
        chmod +x "$target_bin"
        echo -e "${GREEN}🚀 Команда быстрого запуска 'xry' успешно зарегистрирована! Используйте её для вызова этого меню из любой директории.${NC}"
    else
        ln -sf "$current_script" "$target_bin" 2>/dev/null || true
    fi
}

# === Ожидание освобождения блокировок APT/DPKG ===
wait_for_apt() {
    if command -v fuser &>/dev/null; then
        local waited=0
        while fuser /var/lib/dpkg/lock-frontend /var/lib/apt/lists/lock /var/lib/dpkg/lock >/dev/null 2>&1; do
            if (( waited >= 120 )); then
                echo -e "${YELLOW}[!] Превышен таймаут ожидания блокировок apt/dpkg. Продолжаем...${NC}"
                break
            fi
            echo -e "${YELLOW}[!] Ожидание освобождения замка apt/dpkg... [${waited}s]${NC}"
            sleep 3
            waited=$((waited + 3))
        done
    fi
}

# === Оптимизация VPS (Xanmod + Limits + Sysctl) ===
optimize_vps() {
    echo -e "\n${BOLD}${CYAN}🔧 Запуск оптимизации VPS...${NC}"
    
    local is_container=false
    local virt="none"
    if command -v systemd-detect-virt &>/dev/null; then
        virt="$(systemd-detect-virt 2>/dev/null || echo "none")"
    fi
    if [[ "$virt" =~ ^(lxc|openvz|docker|podman|container)$ ]]; then
        is_container=true
        echo -e "${YELLOW}[!] Обнаружена контейнерная виртуализация ($virt). Операции со swap и модулями ядра адаптированы.${NC}"
    fi

    # 1. Часовой пояс и синхронизация времени (NTP)
    echo -e "${YELLOW}[!] Настройка часового пояса (Europe/Moscow) и NTP...${NC}"
    timedatectl set-timezone Europe/Moscow 2>/dev/null || true
    timedatectl set-ntp true 2>/dev/null || true
    systemctl enable --now systemd-timesyncd 2>/dev/null || true
    echo -e "${GREEN}[✓] Часовой пояс и NTP синхронизация настроены.${NC}"

    # 2. Установка пакетов с ожиданием снятия блокировок apt/dpkg
    echo -e "${YELLOW}[!] Обновление кэша и установка базовых утилит...${NC}"
    wait_for_apt
    DEBIAN_FRONTEND=noninteractive apt-get update -yq
    DEBIAN_FRONTEND=noninteractive apt-get install -yq --no-install-recommends \
        curl wget jq unzip htop net-tools ufw iptables zram-tools psmisc
    echo -e "${GREEN}[✓] Утилиты установлены.${NC}"

    # 2.1. Отключение неиспользуемых и опасных служб (rpcbind, apt-daily)
    echo -e "${YELLOW}[!] Отключение фоновых автообновлений и rpcbind...${NC}"
    systemctl stop rpcbind rpcbind.socket apt-daily.timer apt-daily-upgrade.timer 2>/dev/null || true
    systemctl disable rpcbind rpcbind.socket apt-daily.timer apt-daily-upgrade.timer 2>/dev/null || true
    systemctl mask rpcbind rpcbind.socket 2>/dev/null || true

    # 2.2. Ограничение размера логов journald (до 100MB)
    mkdir -p /etc/systemd/journald.conf.d
    cat << 'EOF' > /etc/systemd/journald.conf.d/99-max-size.conf
[Journal]
SystemMaxUse=100M
RuntimeMaxUse=50M
EOF
    systemctl restart systemd-journald 2>/dev/null || true
    echo -e "${GREEN}[✓] Лишние службы отключены, логи journald ограничены 100MB.${NC}"

    # 2.3. Ограничение логов Docker и live-restore (если Docker установлен на сервере)
    if command -v docker &>/dev/null || [[ -d /etc/docker ]]; then
        mkdir -p /etc/docker
        local daemon_json="/etc/docker/daemon.json"
        if [[ ! -f "$daemon_json" ]]; then
            cat << 'EOF' > "$daemon_json"
{
  "log-driver": "json-file",
  "log-opts": {
    "max-size": "50m",
    "max-file": "3"
  },
  "live-restore": true
}
EOF
            systemctl reload docker 2>/dev/null || true
            echo -e "${GREEN}[✓] Docker daemon настроен (ротация логов 50MB, live-restore).${NC}"
        fi
    fi

    # 3. Настройка SWAP (Гибридная память: ZRAM + Disk Swap)
    echo -e "${YELLOW}[!] Настройка Swap файла...${NC}"
    if [[ "$is_container" == "false" ]]; then
        # Удаляем старые фантомные записи /swap, вызывающие сбои в systemd
        sed -i -E '\|^/swap[[:space:]]+swap|d' /etc/fstab 2>/dev/null || true
        if ! grep -q "/swapfile" /etc/fstab; then
            local free_space_mb
            free_space_mb="$(LANG=C df -BM / 2>/dev/null | awk 'NR==2 {gsub(/M/,"",$4); print $4}')"
            if [[ "${free_space_mb:-0}" -ge 4000 ]]; then
                if [[ ! -f /swapfile ]]; then
                    if ! fallocate -l 2G /swapfile 2>/dev/null; then
                        dd if=/dev/zero of=/swapfile bs=1M count=2048 status=none
                    fi
                    chmod 600 /swapfile
                    mkswap /swapfile >/dev/null 2>&1
                fi
                swapon -p -2 /swapfile 2>/dev/null || true
                echo "/swapfile   none    swap    sw,pri=-2    0   0" >> /etc/fstab
                echo -e "${GREEN}[✓] Disk Swap 2GB создан с приоритетом -2.${NC}"
            else
                echo -e "${YELLOW}[!] Свободного места на диске менее 4GB (${free_space_mb:-0}MB). Создание swapfile пропущено.${NC}"
            fi
        else
            swapon -a 2>/dev/null || true
            echo -e "${GREEN}[✓] Disk Swap уже существует.${NC}"
        fi
        systemctl daemon-reload 2>/dev/null || true
        systemctl reset-failed swap.swap 2>/dev/null || true
    fi

    # Включение и оптимизация ZRAM (lz4, умный процент в зависимости от RAM, Priority 100)
    echo -e "${YELLOW}[!] Запуск и настройка ZRAM...${NC}"
    TOTAL_RAM_MB=$(free -m 2>/dev/null | awk '/^Mem:/{print $2}' || echo "1000")
    if [[ ! "$TOTAL_RAM_MB" =~ ^[0-9]+$ ]]; then
        TOTAL_RAM_MB=1000
    fi

    if [[ "$TOTAL_RAM_MB" -gt 1200 ]]; then
        ZRAM_PERCENT=60
        echo -e "${GREEN}[✓] Детектировано ${TOTAL_RAM_MB}MB RAM (2GB+). Автоматически выбираем ZRAM = 60%.${NC}"
    else
        ZRAM_PERCENT=50
        echo -e "${GREEN}[✓] Детектировано ${TOTAL_RAM_MB}MB RAM (1GB). Выбираем ZRAM = 50%.${NC}"
    fi

    cat << EOF > /etc/default/zramswap
ALGO=lz4
PERCENT=${ZRAM_PERCENT}
PRIORITY=100
EOF
    systemctl restart zramswap 2>/dev/null || systemctl enable --now zramswap 2>/dev/null || true
    echo -e "${GREEN}[✓] ZRAM настроен (lz4, ${ZRAM_PERCENT}% RAM, Priority 100).${NC}"

    # 4. Настройка DNS (Cloudflare & Google)
    echo -e "${YELLOW}[!] Настройка DNS...${NC}"
    local dns_configured=false

    if [[ -f /etc/dhcp/dhclient.conf ]]; then
        sed -i -E '/^#?[[:space:]]*prepend domain-name-servers/d' /etc/dhcp/dhclient.conf
        echo "prepend domain-name-servers 1.1.1.1, 1.0.0.1, 8.8.8.8, 8.8.4.4;" >> /etc/dhcp/dhclient.conf
        echo -e "${GREEN}[✓] DNS внесен в dhclient.conf (Cloudflare + Google).${NC}"
        dns_configured=true
    fi

    if [[ -d /etc/systemd/resolved.conf.d ]]; then
        cat << 'EOF' > /etc/systemd/resolved.conf.d/99-dns.conf
[Resolve]
DNS=1.1.1.1 1.0.0.1
FallbackDNS=8.8.8.8 8.8.4.4
EOF
        systemctl restart systemd-resolved 2>/dev/null || true
        echo -e "${GREEN}[✓] DNS внесен в systemd-resolved drop-in.${NC}"
        dns_configured=true
    elif [[ -f /etc/systemd/resolved.conf ]]; then
        sed -i -E '/^[[:space:]]*DNS=/d' /etc/systemd/resolved.conf
        if grep -q '^\[Resolve\]' /etc/systemd/resolved.conf; then
            sed -i '/^\[Resolve\]/a DNS=1.1.1.1 1.0.0.1 8.8.8.8 8.8.4.4' /etc/systemd/resolved.conf
        else
            printf "\n[Resolve]\nDNS=1.1.1.1 1.0.0.1 8.8.8.8 8.8.4.4\n" >> /etc/systemd/resolved.conf
        fi
        systemctl restart systemd-resolved 2>/dev/null || true
        echo -e "${GREEN}[✓] DNS внесен в systemd-resolved.${NC}"
        dns_configured=true
    fi

    if [[ "$dns_configured" == false ]]; then
        if [[ ! -L /etc/resolv.conf && -f /etc/resolv.conf ]]; then
            sed -i -E '/^[[:space:]]*nameserver/d' /etc/resolv.conf
            {
                echo "nameserver 1.1.1.1"
                echo "nameserver 1.0.0.1"
                echo "nameserver 8.8.8.8"
            } >> /etc/resolv.conf
            echo -e "${GREEN}[✓] DNS внесен напрямую в resolv.conf.${NC}"
        else
            echo -e "${GREEN}[✓] resolv.conf управляется внешней системой резолвинга.${NC}"
        fi
    fi

    # 5. Настройка SSH и защита от lockout
    echo -e "${YELLOW}[!] Оптимизация SSH лимитов и безопасности...${NC}"
    if [[ -f /etc/ssh/sshd_config ]]; then
        local bak_ssh
        bak_ssh="/etc/ssh/sshd_config.bak.$(date +%Y%m%d%H%M%S)"
        cp /etc/ssh/sshd_config "$bak_ssh"
        if [[ -d /etc/ssh/sshd_config.d ]]; then
            cat << 'EOF' > /etc/ssh/sshd_config.d/99-vpn-optimization.conf
TCPKeepAlive yes
ClientAliveInterval 120
ClientAliveCountMax 3
X11Forwarding no
PermitTunnel no
GatewayPorts no
EOF
        else
            sed -i -E '/^#?[[:space:]]*(TCPKeepAlive|ClientAliveInterval|ClientAliveCountMax|X11Forwarding|PermitTunnel|GatewayPorts)/d' /etc/ssh/sshd_config
            cat << 'EOF' >> /etc/ssh/sshd_config
TCPKeepAlive yes
ClientAliveInterval 120
ClientAliveCountMax 3
X11Forwarding no
PermitTunnel no
GatewayPorts no
EOF
        fi

        local sshd_bin
        sshd_bin="$(command -v sshd || echo "/usr/sbin/sshd")"
        if [[ -x "$sshd_bin" ]] && ! "$sshd_bin" -t 2>/dev/null; then
            echo -e "${RED}[✗] Тест sshd -t завершился с ошибкой! Откат к бэкапу во избежание lockout.${NC}"
            rm -f /etc/ssh/sshd_config.d/99-vpn-optimization.conf 2>/dev/null || true
            cp "$bak_ssh" /etc/ssh/sshd_config
        else
            systemctl restart ssh 2>/dev/null || systemctl restart sshd 2>/dev/null || true
            echo -e "${GREEN}[✓] SSH оптимизирован, протестирован (sshd -t) и перезапущен.${NC}"
        fi
    fi

    # 6. Загрузка модулей ядра
    echo -e "${YELLOW}[!] Настройка модулей ядра...${NC}"
    mkdir -p /etc/modules-load.d
    cat << 'EOF' > /etc/modules-load.d/vpn-performance.conf
tcp_bbr
nf_conntrack
EOF
    if [[ "$is_container" == "false" ]]; then
        modprobe tcp_bbr 2>/dev/null || true
        modprobe nf_conntrack 2>/dev/null || true
    fi
    echo -e "${GREEN}[✓] Модули ядра добавлены.${NC}"

    # 7. Лимиты процессов и файлов (limits.conf)
    echo -e "${YELLOW}[!] Увеличение системных лимитов (limits.conf)...${NC}"
    mkdir -p /etc/security/limits.d
    cat << 'EOF' > /etc/security/limits.d/99-vpn-limits.conf
* soft nproc 1048576
* hard nproc 1048576
* soft nofile 1048576
* hard nofile 1048576
root soft nproc 1048576
root hard nproc 1048576
root soft nofile 1048576
root hard nofile 1048576
EOF

    local pam_file
    for pam_file in /etc/pam.d/common-session /etc/pam.d/common-session-noninteractive; do
        if [[ -f "$pam_file" ]]; then
            if grep -qE '^[[:space:]]*#[[:space:]]*session[[:space:]]+required[[:space:]]+pam_limits\.so' "$pam_file"; then
                sed -i -E 's/^[[:space:]]*#[[:space:]]*(session[[:space:]]+required[[:space:]]+pam_limits\.so)/\1/' "$pam_file"
            elif ! grep -qE '^[[:space:]]*session[[:space:]]+required[[:space:]]+pam_limits\.so' "$pam_file"; then
                echo "session required pam_limits.so" >> "$pam_file"
            fi
        fi
    done

    # Настройка лимитов Systemd (system.conf и user.conf)
    echo -e "${YELLOW}[!] Настройка лимитов Systemd (system.conf и user.conf)...${NC}"
    mkdir -p /etc/systemd/system.conf.d /etc/systemd/user.conf.d
    cat << 'EOF' > /etc/systemd/system.conf.d/99-vpn-limits.conf
[Manager]
DefaultLimitNOFILE=1048576
DefaultLimitNPROC=1048576
EOF
    cat << 'EOF' > /etc/systemd/user.conf.d/99-vpn-limits.conf
[Manager]
DefaultLimitNOFILE=1048576
DefaultLimitNPROC=1048576
EOF
    systemctl daemon-reexec 2>/dev/null || true
    echo -e "${GREEN}[✓] Системные лимиты обновлены.${NC}"

    # 8. Настройка Sysctl параметров с динамическими буферами под RAM
    echo -e "${YELLOW}[!] Применение оптимизаций sysctl...${NC}"
    local total_pages tcp_mem_min tcp_mem_def tcp_mem_max
    total_pages="$(getconf _PHYS_PAGES 2>/dev/null || echo "262144")"
    if [[ ! "$total_pages" =~ ^[0-9]+$ ]]; then
        total_pages=262144
    fi
    tcp_mem_min=$(( total_pages * 3 / 16 ))
    tcp_mem_def=$(( total_pages * 3 / 8 ))
    tcp_mem_max=$(( total_pages * 3 / 4 ))

    # Удаляем все старые и конфликтующие файлы от прошлых оптимизаторов
    rm -f /etc/sysctl.d/99-*.conf /etc/sysctl.d/98-*.conf 2>/dev/null || true
    if [[ -f /etc/sysctl.conf ]]; then
        local bak_sysctl
        bak_sysctl="/etc/sysctl.conf.bak.$(date +%Y%m%d%H%M%S)"
        cp /etc/sysctl.conf "$bak_sysctl" 2>/dev/null || true
    fi
    echo "# Все оптимизации перенесены в /etc/sysctl.d/99-zzz-node-optimization.conf" > /etc/sysctl.conf

    cat << EOF > /etc/sysctl.d/99-zzz-node-optimization.conf
# Forwarding
net.ipv4.ip_forward = 1
net.ipv4.conf.all.forwarding = 1
net.ipv4.conf.default.forwarding = 1

# QDisc & BBR
net.core.default_qdisc = fq
net.ipv4.tcp_congestion_control = bbr

# Limits & Buffers (До 32MB на сокет под Reality, Vision и Hysteria2)
fs.file-max = 67108864
net.core.netdev_max_backlog = 250000
net.core.optmem_max = 262144
net.core.somaxconn = 65536
net.core.rmem_max = 33554432
net.core.rmem_default = 262144
net.core.wmem_max = 33554432
net.core.wmem_default = 262144

# TCP buffers (Авто-подстройка от 4KB до 32MB)
net.ipv4.tcp_rmem = 4096 87380 33554432
net.ipv4.tcp_wmem = 4096 65536 33554432

# TCP & UDP memory thresholds (в страницах памяти под RAM хоста)
net.ipv4.tcp_mem = ${tcp_mem_min} ${tcp_mem_def} ${tcp_mem_max}
net.ipv4.udp_mem = ${tcp_mem_min} ${tcp_mem_def} ${tcp_mem_max}

# TCP Tunings & Mobile Keepalive (Защита от сбросов сотовых CGNAT РФ и спящих смартфонов)
net.ipv4.tcp_fin_timeout = 30
net.ipv4.tcp_keepalive_time = 60
net.ipv4.tcp_keepalive_probes = 4
net.ipv4.tcp_keepalive_intvl = 10
net.ipv4.tcp_max_orphans = 819200
net.ipv4.tcp_max_syn_backlog = 65535
net.ipv4.tcp_max_tw_buckets = 1440000
net.ipv4.tcp_mtu_probing = 1
net.ipv4.tcp_fastopen = 3
net.ipv4.tcp_syncookies = 1
net.ipv4.tcp_tw_reuse = 0
net.ipv4.tcp_synack_retries = 5
net.ipv4.tcp_syn_retries = 6
net.ipv4.tcp_retries2 = 15

# Conntrack (Увеличенные таймауты против сброса сессий при паузах)
net.netfilter.nf_conntrack_max = 8388608
net.netfilter.nf_conntrack_tcp_timeout_established = 86400
net.netfilter.nf_conntrack_tcp_timeout_time_wait = 60
net.netfilter.nf_conntrack_tcp_timeout_close_wait = 30
net.netfilter.nf_conntrack_tcp_timeout_fin_wait = 30
net.netfilter.nf_conntrack_udp_timeout = 60
net.netfilter.nf_conntrack_udp_timeout_stream = 300

# Kernel Hardening & Routing
net.ipv4.conf.all.accept_source_route = 0
net.ipv4.conf.default.accept_source_route = 0
net.ipv4.conf.all.rp_filter = 0
net.ipv4.conf.default.rp_filter = 0
net.ipv4.conf.all.src_valid_mark = 1
net.ipv4.conf.all.accept_redirects = 0
net.ipv4.conf.default.accept_redirects = 0
net.ipv4.conf.all.secure_redirects = 0
net.ipv4.conf.default.secure_redirects = 0
net.ipv4.icmp_echo_ignore_broadcasts = 1
net.ipv4.icmp_ignore_bogus_error_responses = 1
kernel.randomize_va_space = 2
kernel.dmesg_restrict = 1
kernel.kptr_restrict = 2
kernel.yama.ptrace_scope = 1
fs.protected_symlinks = 1
fs.protected_hardlinks = 1
fs.suid_dumpable = 0

# VM settings
vm.min_free_kbytes = 65536
vm.swappiness = 10
vm.vfs_cache_pressure = 100
vm.dirty_ratio = 15
vm.dirty_background_ratio = 5
vm.dirty_expire_centisecs = 3000
vm.dirty_writeback_centisecs = 500

# Дополнительные оптимизации TCP
net.ipv4.ip_local_port_range = 1024 65535
net.ipv4.tcp_slow_start_after_idle = 0

# Настройки кэша ARP-соседей
net.ipv4.neigh.default.gc_thresh1 = 1024
net.ipv4.neigh.default.gc_thresh2 = 4096
net.ipv4.neigh.default.gc_thresh3 = 32768
EOF

    sysctl --system 2>/dev/null || sysctl -p /etc/sysctl.d/99-zzz-node-optimization.conf 2>/dev/null || true
    echo -e "${GREEN}[✓] Параметры Sysctl успешно применены.${NC}"

    # 8.1. Receive Packet Steering (RPS) для многоядерных процессоров
    local cpus
    cpus="$(nproc 2>/dev/null || echo 1)"
    if (( cpus > 1 )); then
        echo -e "${YELLOW}[!] Настройка Receive Packet Steering (RPS) для $cpus ядер...${NC}"
        local rps_mask rps_file
        rps_mask="$(printf "%x" $(( (1 << cpus) - 1 )))"
        for rps_file in /sys/class/net/*/queues/rx-*/rps_cpus; do
            if [[ -f "$rps_file" ]]; then
                echo "$rps_mask" > "$rps_file" 2>/dev/null || true
            fi
        done
        echo -e "${GREEN}[✓] RPS настроен для параллельной обработки сетевых пакетов.${NC}"
    fi

    # 8.2. TCP MSS Clamping (Защита от зависаний пакетов при нестандартном MTU оператора)
    echo -e "${YELLOW}[!] Настройка TCP MSS Clamping (PMTU Clamp)...${NC}"
    iptables -t mangle -D FORWARD -p tcp --tcp-flags SYN,RST SYN -j TCPMSS --clamp-mss-to-pmtu 2>/dev/null || true
    iptables -t mangle -A FORWARD -p tcp --tcp-flags SYN,RST SYN -j TCPMSS --clamp-mss-to-pmtu 2>/dev/null || true
    iptables -t mangle -D POSTROUTING -p tcp --tcp-flags SYN,RST SYN -j TCPMSS --clamp-mss-to-pmtu 2>/dev/null || true
    iptables -t mangle -A POSTROUTING -p tcp --tcp-flags SYN,RST SYN -j TCPMSS --clamp-mss-to-pmtu 2>/dev/null || true

    # Внедряем персистентность PMTU Clamp в /etc/ufw/before.rules (сохраняется при перезагрузке)
    UFW_BEFORE="/etc/ufw/before.rules"
    if [[ -f "$UFW_BEFORE" ]]; then
        sed -i -E '/^\*mangle/,/^COMMIT/d' "$UFW_BEFORE" 2>/dev/null || true
        cat << 'EOF' >> "$UFW_BEFORE"

*mangle
:FORWARD ACCEPT [0:0]
:POSTROUTING ACCEPT [0:0]
-A FORWARD -p tcp --tcp-flags SYN,RST SYN -j TCPMSS --clamp-mss-to-pmtu
-A POSTROUTING -p tcp --tcp-flags SYN,RST SYN -j TCPMSS --clamp-mss-to-pmtu
COMMIT
EOF
    fi
    echo -e "${GREEN}[✓] TCP MSS Clamping применен и сохранен в автозагрузку UFW.${NC}"

    # Опциональная установка ядра Xanmod
    echo -e "\n${BOLD}${YELLOW}[?] УСТАНОВКА ЯДРА XANMOD (ОПЦИОНАЛЬНО)${NC}"
    echo -e " Все системные настройки (Sysctl, BBR, RPS, ZRAM, лимиты, PMTU) уже применены на текущем ядре."
    read -r -p " Желаете также установить кастомное ядро Xanmod (потребуется перезагрузка ОС)? [y/N]: " xanmod_choice
    
    if [[ "$xanmod_choice" =~ ^[Yy]$ ]]; then
        echo -e "${YELLOW}Определение архитектуры процессора и установка ядра Xanmod...${NC}"
        wait_for_apt
        DEBIAN_FRONTEND=noninteractive apt-get update -yq >/dev/null 2>&1
        DEBIAN_FRONTEND=noninteractive apt-get install -yq --no-install-recommends \
            ca-certificates curl gnupg lsb-release gawk >/dev/null 2>&1
        log_info "Running APT package operation..."
        
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

        if [[ -z "$cpu_level" ]] || [[ "$cpu_level" -lt 1 ]]; then
            echo -e "${RED}❌ Не удалось определить уровень CPU или архитектура не поддерживается.${NC}"
        else
            echo -e "${GREEN}👉 Определен уровень CPU: v${cpu_level}${NC}"
            
            # Переопределяем v4 на v3
            if [[ "$cpu_level" -eq 4 ]]; then
                echo -e "${YELLOW}👉 Уровень CPU v4 понижен до v3 по требованию стабильности.${NC}"
                cpu_level=3
            fi

            mkdir -p /etc/apt/keyrings
            if curl -fsSL --connect-timeout 10 https://dl.xanmod.org/archive.key | gpg --dearmor --yes -o /etc/apt/keyrings/xanmod-archive-keyring.gpg; then
                echo "deb [signed-by=/etc/apt/keyrings/xanmod-archive-keyring.gpg] http://deb.xanmod.org $(lsb_release -sc) main" > /etc/apt/sources.list.d/xanmod-release.list
                wait_for_apt
                DEBIAN_FRONTEND=noninteractive apt-get update -yq >/dev/null 2>&1
                log_info "Running APT package operation for Xanmod..."
                
                echo -e "${YELLOW}Установка linux-xanmod-x64v${cpu_level}...${NC}"
                if DEBIAN_FRONTEND=noninteractive apt-get install -yq "linux-xanmod-x64v${cpu_level}"; then
                    echo -e "${GREEN}✅ Ядро Xanmod успешно установлено!${NC}"
                else
                    echo -e "${RED}❌ Ошибка при установке ядра Xanmod. Продолжаем работу...${NC}"
                fi
            else
                echo -e "${RED}❌ Не удалось скачать ключ Xanmod. Пропускаем установку ядра.${NC}"
            fi
        fi

        echo -e "\n${BOLD}${GREEN}✅ Оптимизация завершена! Сервер будет перезагружен для загрузки нового ядра.${NC}"
        echo -e "${BOLD}${YELLOW}ВАЖНО: После перезагрузки запустите скрипт установки Xray СНОВА, чтобы продолжить!${NC}"
        read -r -p "Нажмите Enter для перезагрузки..."
        reboot
        exit 0
    else
        echo -e "\n${BOLD}${GREEN}✅ Базовая оптимизация VPS успешно применена на лету (без смены ядра и без перезагрузки)!${NC}"
        sleep 2
    fi
}

# === Проверка флагов справки и аргументов (не требуют root) ===
case "${1:-}" in
    -h|--help)
        usage
        ;;
    -v|--version)
        echo "$SCRIPT_NAME version 1.0.0"
        exit 0
        ;;
    --optimize|--renew-cert|--update-core|--update-geoblocks|--headless|"")
        # Допустимые режимы работы (требуют root)
        ;;
    -*)
        echo "❌ Неизвестная опция: $1" >&2
        echo "Используйте $SCRIPT_NAME --help для справки." >&2
        exit 1
        ;;
esac

# === Проверка прав root ===
if [[ "$(id -u)" != "0" ]]; then
    echo "❌ Этот скрипт должен запускаться с правами root"
    exit 1
fi

# === Вспомогательные функции для работы с маркером ===
get_installed_var() {
    local var_name="$1"
    if [[ -f "$MARKER_FILE" ]]; then
        awk -F= -v key="${var_name}" '$1 == key { sub(/^[^=]+=/, ""); print }' "$MARKER_FILE"
    fi
}

update_marker_val() {
    local var_name="$1"
    local new_val="$2"
    mkdir -p "$(dirname "$MARKER_FILE")"
    touch "$MARKER_FILE"
    if grep -q "^${var_name}=" "$MARKER_FILE"; then
        local escaped_val; escaped_val=$(echo "$new_val" | sed 's/[\/&]/\\&/g')
        sed -i "s/^${var_name}=.*/${var_name}=${escaped_val}/" "$MARKER_FILE"
    else
        echo "${var_name}=${new_val}" >> "$MARKER_FILE"
    fi
}

update_geoblock_list() {
    local list_file="/etc/xray/geoblock.lst"
    local temp_file; temp_file=$(mktemp)
    local temp_geoblock; temp_geoblock=$(mktemp)
    
    echo "📥 Обновление списка геоблокированных доменов (itdog геоблок)..."
    
    # Пытаемся скачать список с GitHub
    local download_success=false
    curl -sSL --connect-timeout 8 "https://raw.githubusercontent.com/itdoginfo/allow-domains/refs/heads/main/Categories/geoblock.lst" -o "$temp_geoblock"
    
    if [[ -s "$temp_geoblock" ]]; then
        cat "$temp_geoblock" 2>/dev/null > "$temp_file"
        # Очищаем от Windows CRLF
        sed -i 's/\r//g' "$temp_file"
        # Удаляем пустые строки и комментарии, сортируем и убираем дубликаты
        grep -v '^[[:space:]]*$' "$temp_file" | grep -v '^[[:space:]]*#' | sort -u > "${temp_file}.clean"
        mv "${temp_file}.clean" "$temp_file"
        
        if [[ -s "$temp_file" ]]; then
            download_success=true
        fi
    fi
    
    rm -f "$temp_geoblock"
    
    if [[ "$download_success" = true ]]; then
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
    if [[ ! -f "$list_file" ]]; then
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
        wait_for_apt
        DEBIAN_FRONTEND=noninteractive apt-get update -yq >/dev/null 2>&1
        log_info "Running APT package operation..."
        DEBIAN_FRONTEND=noninteractive apt-get install -yq --no-install-recommends \
            wireguard wireguard-tools >/dev/null 2>&1
        log_info "Running APT package operation..."
    fi

    if [[ ! -f "/etc/wireguard/warp.conf" ]]; then
        echo "📥 Загрузка и запуск скрипта установки warp-native..."
        local temp_dir; temp_dir=$(mktemp -d)
        local success=false

        # Устанавливаем git если его нет
        if ! command -v git &>/dev/null; then
            echo "📦 Установка git..."
            wait_for_apt
            DEBIAN_FRONTEND=noninteractive apt-get update -yq >/dev/null 2>&1
            DEBIAN_FRONTEND=noninteractive apt-get install -yq --no-install-recommends \
                git >/dev/null 2>&1
        fi

        # Попытка 1: Клонирование репозитория через git (самый надежный способ со всеми зависимыми файлами)
        echo "📥 Клонирование репозитория warp-native..."
        if git clone --depth 1 https://github.com/distillium/warp-native.git "$temp_dir/repo" >/dev/null 2>&1; then
            if [[ -f "$temp_dir/repo/install.sh" ]]; then
                chmod +x "$temp_dir/repo/install.sh"
                (cd "$temp_dir/repo" && printf "1\n\n\n" | bash install.sh)
                success=true
            fi
        fi

        # Попытка 2: Резервный curl (main)
        if [[ "$success" = false ]]; then
            echo "⚠️ git clone не удался, пробуем скачать install.sh через curl (main)..."
            curl -sSL --connect-timeout 10 https://raw.githubusercontent.com/distillium/warp-native/main/install.sh -o "$temp_dir/install.sh"
            if [[ -s "$temp_dir/install.sh" ]]; then
                chmod +x "$temp_dir/install.sh"
                (cd "$temp_dir" && printf "1\n\n\n" | bash install.sh)
                success=true
            fi
        fi

        # Попытка 3: Резервный curl (master)
        if [[ "$success" = false ]]; then
            echo "⚠️ Пробуем скачать install.sh через curl (master)..."
            curl -sSL --connect-timeout 10 https://raw.githubusercontent.com/distillium/warp-native/master/install.sh -o "$temp_dir/install.sh"
            if [[ -s "$temp_dir/install.sh" ]]; then
                chmod +x "$temp_dir/install.sh"
                (cd "$temp_dir" && printf "1\n\n\n" | bash install.sh)
                success=true
            fi
        fi

        [[ -n "${temp_dir:-}" && -d "$temp_dir" ]] && rm -rf -- "$temp_dir"
    fi

    if [[ -f "/etc/wireguard/warp.conf" ]]; then
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
        local script_path; script_path=$(realpath "$0")
        (crontab -l 2>/dev/null | grep -v 'update-geoblocks'; \
         echo "30 3 * * * bash \"$script_path\" --update-geoblocks >/dev/null 2>&1") | crontab -

        echo "✅ Cloudflare WARP успешно установлен и запущен!"
        update_marker_val "WARP_INSTALLED" "true"
        update_marker_val "WARP_ENABLED" "true"
    else
        echo "❌ Ошибка при генерации конфигурации WARP"
        return 1
    fi
}

toggle_warp() {
    local current_status; current_status=$(get_installed_var "WARP_ENABLED")
    if [[ "$current_status" == "true" ]]; then
        echo "📴 Отключение обхода через WARP (возврат к прямому выходу)..."
        update_marker_val "WARP_ENABLED" "false"
        systemctl stop wg-quick@warp >/dev/null 2>&1
    else
        echo "🌀 Включение обхода через WARP..."
        if [[ "$(get_installed_var "WARP_INSTALLED")" != "true" ]]; then
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
    local arch; arch=$(uname -m)
    local binary_url
    if [[ "$arch" == "x86_64" ]]; then
        binary_url="https://github.com/Alexey71/opera-proxy/releases/latest/download/opera-proxy-linux-amd64"
    elif [[ "$arch" == "aarch64" ]] || [[ "$arch" == "arm64" ]]; then
        binary_url="https://github.com/Alexey71/opera-proxy/releases/latest/download/opera-proxy-linux-arm64"
    else
        echo -e "${RED}❌ Неподдерживаемая архитектура процессора: $arch${NC}"
        return 1
    fi

    echo "📥 Скачивание бинарного файла Opera Proxy..."
    if curl -sSL --connect-timeout 15 -L "$binary_url" -o /usr/local/bin/opera-proxy; then
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
    if [[ ! -f "/etc/xray/opera.lst" ]]; then
        mkdir -p /etc/xray
        cat > /etc/xray/opera.lst <<EOF
openai.com
chatgpt.com
oaistatic.com
oaiusercontent.com
sentry.io
claude.ai
anthropic.com
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
    local current_status; current_status=$(get_installed_var "OPERA_ENABLED")
    if [[ "$current_status" == "true" ]]; then
        echo -e "\n${BOLD}${YELLOW}📴 Отключение Opera Proxy...${NC}"
        update_marker_val "OPERA_ENABLED" "false"
        systemctl stop opera-proxy >/dev/null 2>&1
    else
        echo -e "\n${BOLD}${GREEN}🌀 Включение Opera Proxy...${NC}"
        if [[ "$(get_installed_var "OPERA_INSTALLED")" != "true" ]]; then
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
check_domain() {
    echo "🔍 Проверка резолва домена..."
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
    # Проверка порта 443
    if ss -tln | grep -qE ':(443)(\s|$)'; then
        local port_443_pid; port_443_pid=$(ss -tlnp 'sport = :443' 2>/dev/null | awk -F'pid=' 'NF>1 { split($2, a, "[,)]"); print a[1]; exit }')
        local port_443_process=""
        if [[ -n "$port_443_pid" ]]; then
            port_443_process=$(ps -p "$port_443_pid" -o comm= 2>/dev/null)
        fi
        echo "⚠️ Порт 443 занят процессом: ${port_443_process:-неизвестно} (PID: ${port_443_pid:-неизвестно})"
        echo "Продолжение работы с занятым портом 443 может привести к ошибкам!"
        read -r -p "Завершить процесс $port_443_process и продолжить? [y/N]: " kill_443
        if [[ "$kill_443" =~ ^[Yy]$ ]]; then
            if [[ -n "$port_443_pid" ]]; then
                kill "$port_443_pid" 2>/dev/null || true
                sleep 0.5
                kill -0 "$port_443_pid" 2>/dev/null && kill -9 "$port_443_pid" 2>/dev/null || true
                echo "Процесс $port_443_pid завершен."
            fi
        else
            echo "Установка отменена пользователем."
            exit 1
        fi
    fi

    # Проверка порта 80
    if ss -tln | grep -qE ':(80)(\s|$)'; then
        local port_80_pid; port_80_pid=$(ss -tlnp 'sport = :80' 2>/dev/null | awk -F'pid=' 'NF>1 { split($2, a, "[,)]"); print a[1]; exit }')
        local port_80_process=""
        if [[ -n "$port_80_pid" ]]; then
            port_80_process=$(ps -p "$port_80_pid" -o comm= 2>/dev/null)
        fi
        echo "⚠️ Порт 80 занят процессом: ${port_80_process:-неизвестно} (PID: ${port_80_pid:-неизвестно})"
        read -r -p "Завершить процесс $port_80_process и продолжить? [y/N]: " kill_80
        if [[ "$kill_80" =~ ^[Yy]$ ]]; then
            if [[ -n "$port_80_pid" ]]; then
                kill "$port_80_pid" 2>/dev/null || true
                sleep 0.5
                kill -0 "$port_80_pid" 2>/dev/null && kill -9 "$port_80_pid" 2>/dev/null || true
                echo "Процесс $port_80_pid завершен."
            fi
        else
            echo "Установка отменена пользователем."
            exit 1
        fi
    fi

    # Проверка порта 8443 (VLESS gRPC)
    if ss -tln | grep -qE ':(8443)(\s|$)'; then
        local port_8443_pid; port_8443_pid=$(ss -tlnp 'sport = :8443' 2>/dev/null | awk -F'pid=' 'NF>1 { split($2, a, "[,)]"); print a[1]; exit }')
        local port_8443_process=""
        if [[ -n "$port_8443_pid" ]]; then
            port_8443_process=$(ps -p "$port_8443_pid" -o comm= 2>/dev/null)
        fi
        echo "⚠️ Порт 8443 занят процессом: ${port_8443_process:-неизвестно} (PID: ${port_8443_pid:-неизвестно})"
        read -r -p "Завершить процесс $port_8443_process и продолжить? [y/N]: " kill_8443
        if [[ "$kill_8443" =~ ^[Yy]$ ]]; then
            if [[ -n "$port_8443_pid" ]]; then
                kill "$port_8443_pid" 2>/dev/null || true
                sleep 0.5
                kill -0 "$port_8443_pid" 2>/dev/null && kill -9 "$port_8443_pid" 2>/dev/null || true
                echo "Процесс $port_8443_pid завершен."
            fi
        else
            echo "Установка отменена пользователем."
            exit 1
        fi
    fi
}

# === Получение эмодзи флага страны ===
get_flag_emoji() {
    local country_code
    # Сначала пробуем наиболее точный ipinfo.io
    country_code=$(curl -s --connect-timeout 3 https://ipinfo.io/country 2>/dev/null | tr -d '[:space:]' | tr '[:lower:]' '[:upper:]')
    if [[ ! "$country_code" =~ ^[A-Z]{2}$ ]]; then
        # В качестве резерва используем ipapi.co
        country_code=$(curl -s --connect-timeout 3 https://ipapi.co/country/ 2>/dev/null | tr -d '[:space:]' | tr '[:lower:]' '[:upper:]')
    fi
    if [[ ! "$country_code" =~ ^[A-Z]{2}$ ]]; then
        country_code="UN"
    fi

    if command -v python3 &>/dev/null; then
        python3 -c "import sys; cc = sys.argv[1]; print(''.join(chr(127397 + ord(c)) for c in cc))" "$country_code" 2>/dev/null || echo "🌐"
    else
        local c1=${country_code:0:1}
        local c2=${country_code:1:1}
        local h1 h2
        printf -v h1 "%08x" "$(( $(printf "%d" "'$c1") - 65 + 127462 ))"
        printf -v h2 "%08x" "$(( $(printf "%d" "'$c2") - 65 + 127462 ))"
        printf "%b\n" "\\U${h1}\\U${h2}"
    fi
}

# === Создание директорий ===
create_directories() {
    echo "📁 Создание директорий..."
    mkdir -p "$XRAY_CONFIG_DIR" "$CLIENT_CONFIG_DIR" "$SSL_DIR" "/var/log/xray"
    chmod 755 "$CLIENT_CONFIG_DIR"
    mkdir -p "/etc/xray"
    chmod 755 /etc/xray
    touch /var/log/xray/{access.log,error.log}
    chown -R nobody:nogroup /var/log/xray
    chmod -R 755 /var/log/xray
}

# === Установка зависимостей ===
install_dependencies() {
    echo "📦 Установка зависимостей..."
    wait_for_apt
    DEBIAN_FRONTEND=noninteractive apt-get update -yq >/dev/null 2>&1
    DEBIAN_FRONTEND=noninteractive apt-get install -yq --no-install-recommends \
        curl git qrencode ufw cron certbot python3 jq lsof >/dev/null 2>&1

    echo "⚡ Включение BBR и TCP Fast Open..."
    # Включаем BBR и FQ
    if ! sysctl net.ipv4.tcp_congestion_control 2>/dev/null | grep -q "bbr"; then
        echo "net.core.default_qdisc=fq" >> /etc/sysctl.conf
        echo "net.ipv4.tcp_congestion_control=bbr" >> /etc/sysctl.conf
    fi
    # Оптимизация буферов UDP для Hysteria 2 (QUIC)
    if ! grep -q "net.core.rmem_max" /etc/sysctl.conf 2>/dev/null; then
        echo "net.core.rmem_max=8388608" >> /etc/sysctl.conf
        echo "net.core.wmem_max=8388608" >> /etc/sysctl.conf
    fi
    # Включаем TCP Fast Open (значение 3 включает и на отправку, и на прием данных)
    if ! sysctl net.ipv4.tcp_fastopen 2>/dev/null | grep -q "3"; then
        echo "net.ipv4.tcp_fastopen=3" >> /etc/sysctl.conf
    fi
    if ! sysctl net.ipv4.tcp_slow_start_after_idle 2>/dev/null | grep -q "0"; then
        echo "net.ipv4.tcp_slow_start_after_idle=0" >> /etc/sysctl.conf
    fi
    if ! sysctl net.ipv4.tcp_notsent_lowat 2>/dev/null | grep -q "16384"; then
        echo "net.ipv4.tcp_notsent_lowat=16384" >> /etc/sysctl.conf
    fi
    sysctl -p > /dev/null 2>&1 || true
}

# === Установка Xray ===
install_xray() {
    echo "🚀 Установка Xray..."
    bash -c "$(curl -fsSL --connect-timeout 15 https://github.com/XTLS/Xray-install/raw/main/install-release.sh)" @ install
    systemctl enable xray > /dev/null
}

# === Установка Hysteria 2 ===
install_hysteria() {
    echo "🚀 Установка Hysteria 2..."
    systemctl stop hysteria-server >/dev/null 2>&1 || true
    local latest_ver; latest_ver=$(curl -sSL --connect-timeout 10 "https://api.github.com/repos/apernet/hysteria/releases/latest" | grep '"tag_name":' | sed -E 's/.*"([^"]+)".*/\1/')
    if [[ -z "$latest_ver" ]]; then
        latest_ver="v2.6.0"
    fi
    echo "Загрузка Hysteria 2 ($latest_ver)..."
    local download_url="https://github.com/apernet/hysteria/releases/download/${latest_ver}/hysteria-linux-amd64"
    rm -f /usr/local/bin/hysteria
    if curl -sSL --connect-timeout 20 -o /usr/local/bin/hysteria "$download_url"; then
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

    if [[ "$antizapret_detected" = "true" ]]; then
        echo "⚠️ Обнаружен AntiZapret-VPN! Для предотвращения сбоев маршрутизации UFW не будет включен."
        echo "🔌 Отключаем UFW и разрешаем порты Xray/Hysteria в iptables напрямую..."
        ufw disable >/dev/null 2>&1 || true
        
        # Сбрасываем блокировки AntiZapret
        if command -v ipset &>/dev/null; then
            ipset flush antizapret-block >/dev/null 2>&1 || true
        fi

        # Гарантируем доступ к нужным портам в iptables на самых первых позициях цепочки INPUT
        local ipt_path; ipt_path=$(command -v iptables 2>/dev/null || echo "/sbin/iptables")
        if [[ -x "$ipt_path" ]]; then
            $ipt_path -D INPUT -p tcp -m multiport --dports 80,443,8443 -j ACCEPT >/dev/null 2>&1 || true
            $ipt_path -I INPUT 1 -p tcp -m multiport --dports 80,443,8443 -j ACCEPT
            
            $ipt_path -D INPUT -p udp -m multiport --dports 443,20000:50000 -j ACCEPT >/dev/null 2>&1 || true
            $ipt_path -I INPUT 2 -p udp -m multiport --dports 443,20000:50000 -j ACCEPT
        fi
        return 0
    fi

    echo "🛡 Настройка UFW..."
    if [[ -f /etc/default/ufw ]]; then
        sed -i 's/IPV6=yes/IPV6=no/g' /etc/default/ufw 2>/dev/null || true
    fi

    ufw allow 443/tcp > /dev/null
    ufw allow 8443/tcp > /dev/null
    ufw allow 443/udp > /dev/null
    ufw allow 20000:50000/udp > /dev/null
    ufw allow 80/tcp > /dev/null
    
    # Динамически определяем запущенные и настроенные порты SSH, чтобы не заблокировать пользователя
    local ssh_ports; ssh_ports=$( (ss -tlnp 2>/dev/null | awk '/"sshd"|:22/ {print $4}' | awk -F: '{print $NF}'; grep -hE '^\s*Port\s+' /etc/ssh/sshd_config /etc/ssh/sshd_config.d/*.conf 2>/dev/null | awk '{print $2}') | sort -u )
    if [[ -n "$ssh_ports" ]]; then
        for port in $ssh_ports; do
            if [[ "$port" =~ ^[0-9]+$ ]]; then
                ufw allow "$port"/tcp > /dev/null
            fi
        done
    else
        ufw allow 22/tcp > /dev/null
    fi
    
    if ! ufw --force enable > /dev/null 2>&1; then
        if [[ -f /usr/share/ufw/after.rules ]]; then
            cp /usr/share/ufw/after.rules /etc/ufw/after.rules 2>/dev/null || true
            ufw --force enable > /dev/null 2>&1 || true
        fi
    fi
}

# === Настройка сертификатов ===
setup_certificates() {
    echo "🔐 Получение TLS-сертификатов для $DOMAIN..."

    # Получаем сертификат через certbot
    log_info "Requesting SSL certificate for $DOMAIN via certbot"
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

    setup_cert_renew_hook
}

# === Настройка автопродления сертификатов ===
setup_cert_renew_hook() {
    local hook_script="/usr/local/bin/xray-cert-renew.sh"
    cat > "$hook_script" <<'EOF'
#!/usr/bin/env bash
set -Eeuo pipefail

SSL_DIR="/etc/ssl/vless"
DOMAIN="${1:-}"

if [[ -z "$DOMAIN" && -f "/etc/xray/.installed" ]]; then
    DOMAIN=$(awk -F= '$1 == "DOMAIN" { sub(/^[^=]+=/, ""); print }' /etc/xray/.installed)
fi

if [[ -n "$DOMAIN" && -f "/etc/letsencrypt/live/$DOMAIN/fullchain.pem" ]]; then
    mkdir -p "$SSL_DIR"
    cp -f "/etc/letsencrypt/live/$DOMAIN/fullchain.pem" "$SSL_DIR/fullchain.cer"
    cp -f "/etc/letsencrypt/live/$DOMAIN/privkey.pem" "$SSL_DIR/private.key"
    chown -R nobody:nogroup "$SSL_DIR"
    chmod 755 "$SSL_DIR"
    chmod 644 "$SSL_DIR/fullchain.cer"
    chmod 600 "$SSL_DIR/private.key"
    systemctl restart xray 2>/dev/null || true
    systemctl restart hysteria-server 2>/dev/null || true
    systemctl restart xray-sub 2>/dev/null || true
fi
EOF
    chmod +x "$hook_script"

    # Регистрируем нативный deploy-hook Certbot (срабатывает только при фактическом обновлении)
    mkdir -p /etc/letsencrypt/renewal-hooks/deploy
    ln -sf "$hook_script" /etc/letsencrypt/renewal-hooks/deploy/xray-cert-renew.sh

    # cron резерв на случай отсутствия systemd timer, без назойливого перезапуска
    (crontab -l 2>/dev/null | grep -v 'certbot renew'; \
     echo "0 3 * * * certbot renew --quiet") | crontab -

    # Активируем системный таймер certbot, если доступен
    systemctl enable --now certbot.timer 2>/dev/null || true
}

# === Ручное / принудительное обновление сертификата ===
renew_ssl_certificate() {
    local force="${1:-false}"
    local domain; domain=$(get_installed_var "DOMAIN")
    local email; email=$(get_installed_var "EMAIL")

    if [[ -z "$domain" ]]; then
        echo -e "${RED}❌ Ошибка: Домен не определен в маркерах (/etc/xray/.installed).${NC}"
        return 1
    fi

    echo -e "\n${BOLD}${CYAN}🔐 Запуск обновления SSL-сертификата для $domain...${NC}"

    # Проверка конфликтов порта 80
    local port_80_pid
    port_80_pid=$(ss -tlnp 'sport = :80' 2>/dev/null | awk -F'pid=' 'NF>1 { split($2, a, "[,)]"); print a[1]; exit }')
    local stopped_temp_service=""
    if [[ -n "$port_80_pid" ]]; then
        local proc_name; proc_name=$(ps -p "$port_80_pid" -o comm= 2>/dev/null)
        echo -e "${YELLOW}⚠️ Порт 80 занят процессом $proc_name (PID: $port_80_pid). Временно останавливаем...${NC}"
        if systemctl is-active --quiet "$proc_name" 2>/dev/null; then
            systemctl stop "$proc_name" 2>/dev/null || true
            stopped_temp_service="$proc_name"
        fi
    fi

    local renew_success=false
    if [[ "$force" == "true" || "$force" == "--force" ]]; then
        echo "Запрос принудительного перевыпуска сертификата через Certbot..."
        if certbot certonly --standalone -d "$domain" --email "$email" --agree-tos --non-interactive --key-type ecdsa --force-renewal; then
            renew_success=true
        elif certbot renew --force-renewal; then
            renew_success=true
        fi
    else
        echo "Запуск стандартной процедуры certbot renew..."
        if certbot renew; then
            renew_success=true
        fi
    fi

    # Возврат временной службы порта 80, если была
    if [[ -n "$stopped_temp_service" ]]; then
        systemctl start "$stopped_temp_service" 2>/dev/null || true
    fi

    if [[ "$renew_success" == "true" && -f "/etc/letsencrypt/live/$domain/fullchain.pem" ]]; then
        mkdir -p "$SSL_DIR"
        cp -f "/etc/letsencrypt/live/$domain/fullchain.pem" "$SSL_DIR/fullchain.cer"
        cp -f "/etc/letsencrypt/live/$domain/privkey.pem" "$SSL_DIR/private.key"
        chown -R nobody:nogroup "$SSL_DIR"
        chmod 755 "$SSL_DIR"
        chmod 644 "$SSL_DIR/fullchain.cer"
        chmod 600 "$SSL_DIR/private.key"

        # Обновляем хук автопродления
        setup_cert_renew_hook

        # Перезапуск сервисов
        systemctl restart xray 2>/dev/null || true
        systemctl restart hysteria-server 2>/dev/null || true
        systemctl restart xray-sub 2>/dev/null || true

        local end_date; end_date=$(openssl x509 -enddate -noout -in "$SSL_DIR/fullchain.cer" 2>/dev/null | cut -d= -f2)
        echo -e "\n${GREEN}✅ SSL-сертификат успешно обновлен и применен!${NC}"
        echo -e "Срок действия: ${BOLD}${YELLOW}$end_date${NC}"
        return 0
    else
        echo -e "\n${RED}❌ Ошибка при обновлении SSL-сертификата.${NC}"
        echo "Проверьте: свободен ли порт 80 и указывает ли DNS A-запись $domain на IP сервера."
        return 1
    fi
}

# === Тестирование автопродления (Dry-Run) ===
test_ssl_renewal() {
    echo -e "\n${BOLD}${CYAN}🧪 Тестирование автопродления SSL (Dry-Run)...${NC}"
    if certbot renew --dry-run; then
        echo -e "\n${GREEN}✅ Тест пройден успешно! Автопродление настроено корректно.${NC}"
    else
        echo -e "\n${RED}❌ Тест автопродления завершился с ошибкой.${NC}"
    fi
    echo -e "\nНажмите Enter для продолжения..."
    read -r
}

# === Генерация UUID и серверного конфигурационного файла ===
generate_server_config() {
    echo "🧩 Генерация конфигурации Xray..."
    local config_file="$XRAY_CONFIG_DIR/config.json"
    
    # Инициализация массивов для клиентов
    local vless_clients=()
    local vless_grpc_clients=()
    
    # Проверяем, есть ли уже клиенты
    if [[ -d "$CLIENT_CONFIG_DIR" ]] && [[ "$(find "$CLIENT_CONFIG_DIR" -maxdepth 1 -name '*.json' 2>/dev/null | wc -l)" -gt 0 ]]; then
        local idx=1
        while IFS= read -r -d '' filepath; do
            local uuid; uuid=$(python3 -c "import json, sys; print(json.load(open(sys.argv[1])).get('id', ''))" "$filepath" 2>/dev/null)
            if [[ -n "$uuid" ]] && [[ "$uuid" != "null" ]]; then
                UUIDs[$idx]="$uuid"
                vless_clients+=("{
                  \"id\": \"$uuid\",
                  \"flow\": \"xtls-rprx-vision\",
                  \"email\": \"client-$idx\"
                }")
                vless_grpc_clients+=("{
                  \"id\": \"$uuid\",
                  \"email\": \"client-$idx\"
                }")
                idx=$((idx + 1))
            fi
        done < <(find "$CLIENT_CONFIG_DIR" -maxdepth 1 -name '*.json' -print0 | sort -z)
    else
        # Генерация уникальных UUID для каждого устройства (первоначальная установка)
        for ((i=1; i<=NUM_DEVICES; i++)); do
            local uuid; uuid=$(xray uuid)
            UUIDs[$i]="$uuid"
            
            vless_clients+=("{
              \"id\": \"$uuid\",
              \"flow\": \"xtls-rprx-vision\",
              \"email\": \"client-$i\"
            }")
            vless_grpc_clients+=("{
              \"id\": \"$uuid\",
              \"email\": \"client-$i\"
            }")
        done
    fi
    
    local vless_clients_str; vless_clients_str=$(IFS=,; echo "${vless_clients[*]}")
    local vless_grpc_clients_str; vless_grpc_clients_str=$(IFS=,; echo "${vless_grpc_clients[*]}")
    
    # Проверяем статус WARP и Opera Proxy
    local warp_enabled; warp_enabled=$(get_installed_var "WARP_ENABLED")
    local warp_mode; warp_mode=$(get_installed_var "WARP_MODE")
    [[ -z "$warp_mode" ]] && warp_mode="smart"
    local opera_enabled; opera_enabled=$(get_installed_var "OPERA_ENABLED")
    local DOMAIN; DOMAIN=$(get_installed_var "DOMAIN" | tr -d '[:space:]')
    
    # Загружаем настройки Reality (Принудительно отключено для стабильности)
    local reality_enabled="false"
    local reality_sni; reality_sni=$(get_installed_var "REALITY_SNI" | tr -d '[:space:]')
    local reality_dest; reality_dest=$(get_installed_var "REALITY_DEST" | tr -d '[:space:]')
    local reality_priv; reality_priv=$(get_installed_var "REALITY_PRIVATE_KEY" | tr -d '[:space:]')
    local reality_pub; reality_pub=$(get_installed_var "REALITY_PUBLIC_KEY" | tr -d '[:space:]')
    local reality_sid; reality_sid=$(get_installed_var "REALITY_SHORT_ID" | tr -d '[:space:]')

    if [[ "$reality_enabled" == "true" ]]; then
        # Гарантируем наличие ключей и short ID
        if [[ -z "$reality_priv" || -z "$reality_pub" ]]; then
            local keys; keys=$(command -v xray &>/dev/null && xray x25519 2>/dev/null || /usr/local/bin/xray x25519 2>/dev/null || xray x25519 2>/dev/null)
            reality_priv=$(echo "$keys" | awk -F':' '/[Pp]rivate/ { gsub(/[[:space:]]/, ""); print $2 }')
            reality_pub=$(echo "$keys" | awk -F':' '/[Pp]ublic/ { gsub(/[[:space:]]/, ""); print $2 }')
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
    if [[ "$warp_enabled" == "true" ]] && [[ "$warp_mode" == "full" ]]; then
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
        if [[ "$warp_enabled" == "true" ]]; then
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
    if [[ "$opera_enabled" == "true" ]]; then
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

    local outbounds_str; outbounds_str=$(IFS=,; echo "[${outbounds_list[*]}]")
    
    local routing_rules_list=()

    # Базовые правила блокировки
    routing_rules_list+=('{
        "type": "field",
        "ip": [
          "geoip:private"
        ],
        "outboundTag": "BLOCK"
      }')
    routing_rules_list+=('{
        "type": "field",
        "domain": [
          "geosite:private"
        ],
        "outboundTag": "BLOCK"
      }')
    routing_rules_list+=('{
        "type": "field",
        "protocol": [
          "bittorrent"
        ],
        "outboundTag": "BLOCK"
      }')
    routing_rules_list+=('{
        "type": "field",
        "domain": [
          "geosite:category-ads-all"
        ],
        "outboundTag": "BLOCK"
      }')
    routing_rules_list+=('{
        "type": "field",
        "port": "25,135,137,138,139,445,465,587",
        "network": "tcp,udp",
        "outboundTag": "BLOCK"
      }')

    # Правило для Opera Proxy (приоритет выше, чем у WARP)
    if [[ "$opera_enabled" == "true" ]]; then
        local opera_domains=()
        if [[ -f "/etc/xray/opera.lst" ]]; then
            while IFS= read -r line || [[ -n "$line" ]]; do
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
claude.ai
anthropic.com
EOF
            opera_domains+=("\"domain:openai.com\"" "\"domain:chatgpt.com\"" "\"domain:oaistatic.com\"" "\"domain:oaiusercontent.com\"" "\"domain:sentry.io\"" "\"domain:claude.ai\"" "\"domain:anthropic.com\"")
        fi
        
        opera_domains+=("\"geosite:openai\"")
        
        local opera_domains_joined; opera_domains_joined=$(IFS=,; echo "${opera_domains[*]}")
        routing_rules_list+=("{
        \"type\": \"field\",
        \"domain\": [
          $opera_domains_joined
        ],
        \"outboundTag\": \"OPERA\"
      }")
    fi

    # Правила для WARP
    if [[ "$warp_enabled" == "true" ]]; then
        if [[ "$warp_mode" == "smart" ]]; then
            local geoblocks=()
            if [[ -f "/etc/xray/geoblock.lst" ]]; then
                while IFS= read -r line || [[ -n "$line" ]]; do
                    line=$(echo "$line" | tr -d '\r' | xargs)
                    if [[ -z "$line" || "$line" =~ ^# ]]; then
                        continue
                    fi
                    geoblocks+=("\"domain:$line\"")
                done < "/etc/xray/geoblock.lst"
            fi
            
            geoblocks+=("\"geosite:netflix\"" "\"geosite:facebook\"" "\"geosite:instagram\"" "\"geosite:twitter\"" "\"geosite:disney\"" "\"geosite:spotify\"")
            if [[ "$opera_enabled" != "true" ]]; then
                geoblocks+=("\"geosite:openai\"")
            fi
            
            local geoblocks_joined; geoblocks_joined=$(IFS=,; echo "${geoblocks[*]}")
            routing_rules_list+=("{
        \"type\": \"field\",
        \"domain\": [
          $geoblocks_joined
        ],
        \"outboundTag\": \"WARP\"
      }")
        fi

        local check_domains=()
        for dom in whoer.net browserleaks.com 2ip.io 2ip.ru 2ip.ua ipleak.net ipinfo.io ipinfo.net ip.sb whatismyip.com whatismyipaddress.com iplocation.net dnsleaktest.com dnsleak.com am.i.mullvad.net myip.com myip.ru ip.me ifconfig.me ident.me v4.ident.me checkip.amazonaws.com checkip.dyndns.org test-ipv6.com ip-api.com ipify.org icanhazip.com ip-score.com doileak.com bash.ws f.vision amiunique.org deviceinfo.me coveryourtracks.eff.org showmyip.com ip8.com webrtc.org; do
            check_domains+=("\"domain:$dom\"")
        done
        local check_domains_joined; check_domains_joined=$(IFS=,; echo "${check_domains[*]}")
        routing_rules_list+=("{
        \"type\": \"field\",
        \"domain\": [
          $check_domains_joined
        ],
        \"outboundTag\": \"WARP\"
      }")
    fi

    local routing_rules_str; routing_rules_str=$(IFS=,; echo "${routing_rules_list[*]}")
    
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
    if [[ "$reality_enabled" == "true" ]]; then
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
    },
    {
      "tag": "vless-grpc",
      "port": 8443,
      "protocol": "vless",
      "settings": {
        "clients": ['"$vless_grpc_clients_str"'],
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
        "network": "grpc",
        "security": "tls",
        "tlsSettings": {
          "certificates": [{
            "certificateFile": "'"$SSL_DIR"'/fullchain.cer",
            "keyFile": "'"$SSL_DIR"'/private.key"
          }],
          "alpn": [
            "h2"
          ],
          "minVersion": "1.2"
        },
        "grpcSettings": {
          "serviceName": "vless-grpc",
          "multiMode": true
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
    },
    {
      "tag": "vless-grpc",
      "port": 8443,
      "protocol": "vless",
      "settings": {
        "clients": ['"$vless_grpc_clients_str"'],
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
        "network": "grpc",
        "security": "tls",
        "tlsSettings": {
          "certificates": [{
            "certificateFile": "'"$SSL_DIR"'/fullchain.cer",
            "keyFile": "'"$SSL_DIR"'/private.key"
          }],
          "alpn": [
            "h2"
          ],
          "minVersion": "1.2"
        },
        "grpcSettings": {
          "serviceName": "vless-grpc",
          "multiMode": true
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
  "dns": {
    "servers": [
      "1.1.1.2",
      "9.9.9.9",
      "8.8.8.8",
      "1.0.0.2",
      "8.8.4.4",
      "208.67.222.222",
      "localhost"
    ],
    "disableCache": false,
    "queryStrategy": "UseIPv4"
  },
  "policy": {
    "levels": {
      "0": {
        "handshake": 4,
        "connIdle": 300,
        "uplinkOnly": 2,
        "downlinkOnly": 5,
        "bufferSize": 4
      }
    },
    "system": {
      "statsInboundUplink": false,
      "statsInboundDownlink": false,
      "statsOutboundUplink": false,
      "statsOutboundDownlink": false
    }
  },
  "inbounds": $inbounds_str,
  "outbounds": $outbounds_str,
  "routing": {
    "domainStrategy": "IPIfNonMatch",
    "rules": [
      $routing_rules_str
    ]
  }
}
EOF

    systemctl restart xray
    log_info "Restarted Xray service"
}

# === Генерация конфигурации Hysteria 2 ===
generate_hysteria_config() {
    echo "🧩 Генерация конфигурации Hysteria 2..."
    mkdir -p /etc/hysteria
    
    local DOMAIN; DOMAIN=$(get_installed_var "DOMAIN")
    [[ -z "$DOMAIN" ]] && DOMAIN="${DOMAIN:-}"
    
    local config_yaml="/etc/hysteria/config.yaml"
    
    # Собираем userpass для Hysteria 2 (UUID используется и как имя пользователя, и как пароль)
    local userpass=()
    if [[ -d "$CLIENT_CONFIG_DIR" ]] && [[ "$(find "$CLIENT_CONFIG_DIR" -maxdepth 1 -name '*.json' 2>/dev/null | wc -l)" -gt 0 ]]; then
        while IFS= read -r -d '' filepath; do
            local uuid; uuid=$(python3 -c "import json, sys; print(json.load(open(sys.argv[1])).get('id', ''))" "$filepath" 2>/dev/null)
            if [[ -n "$uuid" ]] && [[ "$uuid" != "null" ]]; then
                userpass+=("    \"$uuid\": \"$uuid\"")
            fi
        done < <(find "$CLIENT_CONFIG_DIR" -maxdepth 1 -name '*.json' -print0 | sort -z)
    else
        # Первоначальная генерация (когда json файлов на диске еще нет, но UUIDs заполнен)
        for ((i=1; i<=NUM_DEVICES; i++)); do
            local uuid="${UUIDs[$i]}"
            if [[ -n "$uuid" ]]; then
                userpass+=("    \"$uuid\": \"$uuid\"")
            fi
        done
    fi
    
    if [[ ${#userpass[@]} -eq 0 ]]; then
        userpass+=("    \"default\": \"default\"")
    fi
    
    local userpass_str; userpass_str=$(IFS=$'\n'; echo "${userpass[*]}")
    
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
    local iptables_path; iptables_path=$(command -v iptables 2>/dev/null || echo "/sbin/iptables")
    local ip6tables_path; ip6tables_path=$(command -v ip6tables 2>/dev/null || echo "/sbin/ip6tables")

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
    
    local DOMAIN; DOMAIN=$(get_installed_var "DOMAIN")
    local FINGERPRINT; FINGERPRINT=$(get_installed_var "FINGERPRINT")
    if [[ -z "$FINGERPRINT" ]]; then FINGERPRINT="random"; fi

    if [[ -d "$CLIENT_CONFIG_DIR" ]] && [[ "$(find "$CLIENT_CONFIG_DIR" -maxdepth 1 -name '*.json' 2>/dev/null | wc -l)" -gt 0 ]]; then
        # Обновляем существующие конфиги (идемпотентность)
        for filepath in "$CLIENT_CONFIG_DIR"/*.json; do
            [[ -e "$filepath" ]] || continue
            
            local uuid; uuid=$(python3 -c "import json, sys; print(json.load(open(sys.argv[1])).get('id', ''))" "$filepath" 2>/dev/null)
            local name; name=$(python3 -c "import json, sys; print(json.load(open(sys.argv[1])).get('remarks', ''))" "$filepath" 2>/dev/null)
            
            if [[ -z "$uuid" ]] || [[ "$uuid" == "null" ]]; then continue; fi
            if [[ -z "$name" ]] || [[ "$name" == "null" ]]; then
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
        for ((i=1; i<=NUM_DEVICES; i++)); do
            local name="${DEVICE_NAMES[$i]}"
            local uuid="${UUIDs[$i]}"
            
            [[ -z "$uuid" ]] && uuid=$(cat /proc/sys/kernel/random/uuid)
            [[ -z "$name" ]] && name="Device_$i"

            local filename="client_$i"
            local safe_filename; safe_filename=$(echo "$name" | tr -cd '[:alnum:]_.-' | tr '[:upper:]' '[:lower:]')
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
PORT = 10080
CONFIG_DIR = "/etc/xray/client_configs"
INSTALLED_FILE = "/etc/xray/.installed"

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

def get_installed_vars():
    vars = {
        "domain": "",
        "emoji": "",
        "fp": "random",
        "reality_enabled": "false",
        "reality_sni": "max.ru",
        "reality_pbk": "",
        "reality_sid": "",
        "routing_enabled": "true",
        "providerid": ""
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
                        elif key in ("provider_id", "providerid"): vars["providerid"] = val
    except Exception:
        pass
    if not vars["fp"]:
        vars["fp"] = "random"
    return vars

def dict_to_yaml(data, indent=0):
    lines = []
    spacer = " " * indent
    if isinstance(data, dict):
        for k, v in data.items():
            if v is None:
                lines.append(f"{spacer}{k}: null")
            elif isinstance(v, (dict, list)):
                lines.append(f"{spacer}{k}:")
                lines.append(dict_to_yaml(v, indent + 2))
            elif isinstance(v, bool):
                lines.append(f"{spacer}{k}: {str(v).lower()}")
            elif isinstance(v, (int, float)):
                lines.append(f"{spacer}{k}: {v}")
            else:
                escaped = str(v).replace('"', '\\"')
                lines.append(f"{spacer}{k}: \"{escaped}\"")
    elif isinstance(data, list):
        for item in data:
            if isinstance(item, (dict, list)):
                sub = dict_to_yaml(item, 0)
                sub_lines = sub.split("\n")
                if sub_lines:
                    sub_lines[0] = f"{spacer}- {sub_lines[0]}"
                    for i in range(1, len(sub_lines)):
                        sub_lines[i] = f"{spacer}  {sub_lines[i]}"
                    lines.append("\n".join(sub_lines))
            else:
                if isinstance(item, bool):
                    lines.append(f"{spacer}- {str(item).lower()}")
                elif isinstance(item, (int, float)):
                    lines.append(f"{spacer}- {item}")
                else:
                    escaped = str(item).replace('"', '\\"')
                    lines.append(f"{spacer}- \"{escaped}\"")
    return "\n".join(lines)

def vless_url_to_sing_box_outbound(url: str):
    if not url.startswith("vless://"):
        return None
    try:
        parsed = urllib.parse.urlparse(url)
        netloc = parsed.netloc
        if "@" in netloc:
            uuid, host_port = netloc.split("@", 1)
        else:
            return None
            
        if ":" in host_port:
            host, port_str = host_port.split(":", 1)
            port = int(port_str)
        else:
            host = host_port
            port = 443
            
        params = urllib.parse.parse_qs(parsed.query)
        
        def get_param(name: str):
            val = params.get(name) or params.get(name + "[]")
            return val[0] if val else None

        flow = get_param("flow")
        security = get_param("security")
        sni = get_param("sni")
        fp = get_param("fp") or "chrome"
        pbk = get_param("pbk")
        sid = get_param("sid")
        transport_type = get_param("type")
        path = get_param("path")
        service_name = get_param("serviceName") or get_param("service_name")
        
        tag = urllib.parse.unquote(parsed.fragment) if parsed.fragment else host
        
        outbound = {
            "type": "vless",
            "tag": tag,
            "server": host,
            "server_port": port,
            "uuid": uuid,
            "packet_encoding": "xudp"
        }
        
        if flow:
            outbound["flow"] = flow
            
        if security == "reality":
            outbound["tls"] = {
                "enabled": True,
                "server_name": sni or host,
                "utls": {
                    "enabled": True,
                    "fingerprint": fp
                },
                "reality": {
                    "enabled": True,
                    "public_key": pbk or "",
                    "short_id": sid or ""
                }
            }
        elif security == "tls":
            alpn_list = ["h2"] if transport_type == "grpc" else ["http/1.1"]
            outbound["tls"] = {
                "enabled": True,
                "server_name": sni or host,
                "alpn": alpn_list,
                "utls": {
                    "enabled": True,
                    "fingerprint": fp
                }
            }
            
        if transport_type == "ws":
            outbound["transport"] = {
                "type": "ws",
                "path": path or "/",
            }
        elif transport_type == "grpc":
            outbound["transport"] = {
                "type": "grpc",
                "service_name": service_name or "grpc"
            }
        elif transport_type == "httpupgrade":
            outbound["transport"] = {
                "type": "httpupgrade",
                "path": path or "/",
                "host": sni or host
            }
            
        return outbound
    except Exception:
        return None

def hysteria2_url_to_sing_box_outbound(url: str):
    if not url.startswith("hysteria2://"):
        return None
    try:
        parsed = urllib.parse.urlparse(url)
        netloc = parsed.netloc
        if "@" in netloc:
            auth, host_port = netloc.split("@", 1)
            if ":" in auth:
                password = auth.split(":", 1)[0]
            else:
                password = auth
        else:
            return None
            
        if ":" in host_port:
            host, port_str = host_port.split(":", 1)
            port = int(port_str)
        else:
            host = host_port
            port = 443
            
        params = urllib.parse.parse_qs(parsed.query)
        
        def get_param(name: str):
            val = params.get(name) or params.get(name + "[]")
            return val[0] if val else None

        sni = get_param("sni")
        hop = get_param("hop") or get_param("mport") or get_param("ports")
        tag = urllib.parse.unquote(parsed.fragment) if parsed.fragment else host
        
        outbound = {
            "type": "hysteria2",
            "tag": tag,
            "server": host,
            "server_port": port,
            "password": password,
            "tls": {
                "enabled": True,
                "server_name": sni or host,
                "insecure": False
            }
        }
        if hop:
            outbound["server_ports"] = [hop.replace("-", ":")]
            outbound["hop_interval"] = "30s"
        return outbound
    except Exception:
        return None

def vless_url_to_xray_outbound(url: str, index: int):
    if not url.startswith("vless://"):
        return None
    try:
        parsed = urllib.parse.urlparse(url)
        netloc = parsed.netloc
        if "@" in netloc:
            uuid, host_port = netloc.split("@", 1)
        else:
            return None
            
        if ":" in host_port:
            host, port_str = host_port.split(":", 1)
            port = int(port_str)
        else:
            host = host_port
            port = 443
            
        params = urllib.parse.parse_qs(parsed.query)
        
        def get_param(name: str):
            val = params.get(name) or params.get(name + "[]")
            return val[0] if val else None

        flow = get_param("flow")
        security = get_param("security")
        sni = get_param("sni")
        fp = get_param("fp") or "chrome"
        pbk = get_param("pbk")
        sid = get_param("sid")
        transport_type = get_param("type")
        path = get_param("path")
        service_name = get_param("serviceName") or get_param("service_name")
        
        tag = f"proxy-{index}"
        
        outbound = {
            "protocol": "vless",
            "tag": tag,
            "settings": {
                "vnext": [
                    {
                        "address": host,
                        "port": port,
                        "users": [
                            {
                                "id": uuid,
                                "encryption": "none"
                            }
                        ]
                    }
                ]
            },
            "streamSettings": {
                "network": transport_type or "tcp",
                "security": security or "none"
            }
        }
        
        if flow:
            outbound["settings"]["vnext"][0]["users"][0]["flow"] = flow
            
        if security == "reality":
            outbound["streamSettings"]["realitySettings"] = {
                "publicKey": pbk or "",
                "fingerprint": fp,
                "serverName": sni or host,
                "shortId": sid or "",
                "spiderX": "/"
            }
        elif security == "tls":
            outbound["streamSettings"]["tlsSettings"] = {
                "serverName": sni or host,
                "fingerprint": fp
            }
            
        if transport_type == "ws":
            outbound["streamSettings"]["wsSettings"] = {
                "path": path or "/",
                "headers": {
                    "Host": sni or host
                }
            }
        elif transport_type == "grpc":
            outbound["streamSettings"]["grpcSettings"] = {
                "serviceName": service_name or "grpc",
                "multiMode": True
            }
        elif transport_type == "httpupgrade":
            outbound["streamSettings"]["httpupgradeSettings"] = {
                "path": path or "/",
                "host": sni or host
            }
            
        return outbound
    except Exception:
        return None

def vless_url_to_mihomo_proxy(url: str):
    if not url.startswith("vless://"):
        return None
    try:
        parsed = urllib.parse.urlparse(url)
        netloc = parsed.netloc
        if "@" in netloc:
            uuid, host_port = netloc.split("@", 1)
        else:
            return None
            
        if ":" in host_port:
            host, port_str = host_port.split(":", 1)
            port = int(port_str)
        else:
            host = host_port
            port = 443
            
        params = urllib.parse.parse_qs(parsed.query)
        
        def get_param(name: str):
            val = params.get(name) or params.get(name + "[]")
            return val[0] if val else None

        flow = get_param("flow")
        security = get_param("security")
        sni = get_param("sni")
        fp = get_param("fp") or "chrome"
        pbk = get_param("pbk")
        sid = get_param("sid")
        transport_type = get_param("type")
        path = get_param("path")
        service_name = get_param("serviceName") or get_param("service_name")
        
        tag = urllib.parse.unquote(parsed.fragment) if parsed.fragment else host
        
        proxy = {
            "name": tag,
            "type": "vless",
            "server": host,
            "port": port,
            "uuid": uuid,
            "udp": True,
            "tls": True if security in ("tls", "reality") else False,
            "network": transport_type or "tcp"
        }
        
        if flow:
            proxy["flow"] = flow
            
        if security == "reality":
            proxy["reality-opts"] = {
                "public-key": pbk or "",
                "short-id": sid or ""
            }
            proxy["client-fingerprint"] = fp
            if sni:
                proxy["servername"] = sni
        elif security == "tls":
            proxy["client-fingerprint"] = fp
            if sni:
                proxy["servername"] = sni
            if transport_type == "grpc":
                proxy["alpn"] = ["h2"]
            else:
                proxy["alpn"] = ["http/1.1"]
                
        if transport_type == "ws":
            proxy["ws-opts"] = {
                "path": path or "/",
                "headers": {
                    "Host": sni or host
                }
            }
        elif transport_type == "grpc":
            proxy["grpc-opts"] = {
                "grpc-service-name": service_name or "grpc"
            }
        elif transport_type == "httpupgrade":
            proxy["httpupgrade-opts"] = {
                "path": path or "/",
                "headers": {
                    "Host": sni or host
                }
            }
            
        return proxy
    except Exception:
        return None

def hysteria2_url_to_mihomo_proxy(url: str):
    if not url.startswith("hysteria2://"):
        return None
    try:
        parsed = urllib.parse.urlparse(url)
        netloc = parsed.netloc
        if "@" in netloc:
            auth, host_port = netloc.split("@", 1)
            if ":" in auth:
                password = auth.split(":", 1)[0]
            else:
                password = auth
        else:
            return None
            
        if ":" in host_port:
            host, port_str = host_port.split(":", 1)
            port = int(port_str)
        else:
            host = host_port
            port = 443
            
        params = urllib.parse.parse_qs(parsed.query)
        
        def get_param(name: str):
            val = params.get(name) or params.get(name + "[]")
            return val[0] if val else None

        sni = get_param("sni")
        hop = get_param("hop") or get_param("mport") or get_param("ports")
        tag = urllib.parse.unquote(parsed.fragment) if parsed.fragment else host
        
        proxy = {
            "name": tag,
            "type": "hysteria2",
            "server": host,
            "port": port,
            "password": password,
            "auth-str": password,
            "sni": sni or host,
            "skip-cert-verify": False,
            "alpn": ["h3"]
        }
        if hop:
            proxy["ports"] = hop
            proxy["hop-interval"] = "30s"
        return proxy
    except Exception:
        return None

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
            self.send_header("X-Robots-Tag", "noindex, nofollow, noarchive, nosnippet, noimageindex")
            self.end_headers()
            self.wfile.write(DECOY_HTML.encode("utf-8"))
            return
        
        ivars = get_installed_vars()
        domain = ivars["domain"]
        emoji = ivars["emoji"]
        fp = ivars["fp"]
        providerid = ivars.get("providerid", "")
        if not domain:
            domain = self.headers.get('Host', '').split(':')[0]

        if emoji:
            remark_vision = f"{emoji}🌐 VLESS-TCP"
            remark_hy2 = f"{emoji}⚡ Hysteria2"
            remark_grpc = f"{emoji}↔️ VLESS-gRPC"
            remark_reality = f"{emoji}🪞 VLESS-Reality ({ivars['reality_sni']})"
        else:
            remark_vision = "🌐 VLESS-TCP"
            remark_hy2 = "⚡ Hysteria2"
            remark_grpc = "↔️ VLESS-gRPC"
            remark_reality = f"🪞 VLESS-Reality ({ivars['reality_sni']})"

        encoded_remark_vision = urllib.parse.quote(remark_vision)
        encoded_remark_hy2 = urllib.parse.quote(remark_hy2)
        encoded_remark_grpc = urllib.parse.quote(remark_grpc)
        encoded_remark_reality = urllib.parse.quote(remark_reality)
        
        vless_vision = f"vless://{uuid_param}@{domain}:443?encryption=none&flow=xtls-rprx-vision&security=tls&type=tcp&fp={fp}&alpn=http%2F1.1#{encoded_remark_vision}"
        hy2_link = f"hysteria2://{uuid_param}:{uuid_param}@{domain}:20443?sni={domain}&hop=20000-50000&mport=20000-50000#{encoded_remark_hy2}"
        vless_grpc = f"vless://{uuid_param}@{domain}:8443?encryption=none&security=tls&type=grpc&serviceName=vless-grpc&service_name=vless-grpc&mode=multi&fp={fp}&alpn=h2&sni={domain}#{encoded_remark_grpc}"
        
        urls = [vless_vision, hy2_link, vless_grpc]
        if ivars["reality_enabled"] == "true":
            vless_reality = f"vless://{uuid_param}@{domain}:443?flow=xtls-rprx-vision&security=reality&sni={ivars['reality_sni']}&pbk={ivars['reality_pbk']}&sid={ivars['reality_sid']}&fp={fp}&type=tcp#{encoded_remark_reality}"
            urls.append(vless_reality)
            
        sub_content_links = "\n".join(urls) + "\n"
            
        client_display = f"❯ {client_name}"
        b64_client_display = "base64:" + base64.b64encode(client_display.encode('utf-8')).decode('utf-8')
        
        announce_text = f"Профиль: {client_name} • Локации: VLESS TCP (443), Hysteria2 (20443), VLESS gRPC (8443) • Коридор: https://mvrvntn.github.io/koridor/ • Нет сети? ➔ Обновите ↻"
        b64_announce = "base64:" + base64.b64encode(announce_text.encode('utf-8')).decode('utf-8')
        
        support_url = "https://t.me/mavrtunbot"

        query_params = urllib.parse.parse_qs(parsed_url.query)
        format_param = query_params.get("format", [""])[0].lower()

        user_agent = self.headers.get("User-Agent", "").lower()
        client_param = query_params.get("client", [""])[0].lower()
        if client_param in ("happ", "incy"):
            user_agent += f" {client_param}"

        if not format_param:
            if "sing-box" in user_agent or "singbox" in user_agent or "sfa" in user_agent or "sfi" in user_agent:
                format_param = "singbox"
            elif any(c in user_agent for c in ("clash", "mihomo", "meta", "flclash", "stash")):
                format_param = "clash"
            elif "xray" in user_agent or "v2ray" in user_agent:
                format_param = "xray"

        resp_headers = {
            "Cache-Control": "no-store",
            "X-Robots-Tag": "noindex, nofollow, noarchive, nosnippet, noimageindex",
            "profile-title": b64_client_display,
            "profile-update-interval": "1",
            "support-url": support_url,
            "profile-web-page-url": "https://mvrvntn.github.io/koridor/",
            "announce": b64_announce,
            "subscription-auto-update-enable": "1",
            "subscription-ping-onopen-enabled": "1",
            "subscription-autoconnect": "1",
            "subscription-autoconnect-type": "lastused",
            "subscription-userinfo": "0",
            "sort-order": "ping",
            "hide-url": "1",
            "noises-enable": "0",
            "no-limit-enabled": "1",
            "fragmentation-enable": "0",
            "per-app-proxy-enable": "0",
            "server-address-resolve-enable": "1"
        }
        if providerid:
            resp_headers["providerid"] = providerid

        if "incy" in user_agent:
            resp_headers.update({
                "banner-bg-color": "#F4F4F5",
                "banner-button-color": "#1A1A1A"
            })

        routing_enabled = ivars.get("routing_enabled", "true") != "false"
        if routing_enabled:
            if "happ" in user_agent:
                resp_headers["autorouting"] = "happ://autorouting/onadd/https://cdn.jsdelivr.net/gh/hydraponique/roscomvpn-routing@main/HAPP/JSONSUB.JSON"
            else:
                resp_headers["autorouting"] = "incy://autorouting/onadd/https://cdn.jsdelivr.net/gh/hydraponique/roscomvpn-routing@main/INCY/JSONSUB.JSON"

        if format_param == "singbox" or format_param == "sing-box":
            outbounds_list = []
            outbound_tags = []
            for u in urls:
                if u.startswith("vless://"):
                    ob = vless_url_to_sing_box_outbound(u)
                    if ob:
                        outbounds_list.append(ob)
                        outbound_tags.append(ob["tag"])
                elif u.startswith("hysteria2://"):
                    ob = hysteria2_url_to_sing_box_outbound(u)
                    if ob:
                        outbounds_list.append(ob)
                        outbound_tags.append(ob["tag"])

            singbox_config = {
                "dns": {
                    "rules": [
                        {
                            "server": "remote",
                            "query_type": ["A", "AAAA"]
                        },
                        {
                            "server": "local",
                            "outbound": "any"
                        }
                    ],
                    "fakeip": {
                        "enabled": True,
                        "inet4_range": "198.18.0.0/15",
                        "inet6_range": "fc00::/18"
                    },
                    "servers": [
                        {
                            "tag": "cf-dns",
                            "address": "https://1.1.1.1/dns-query"
                        },
                        {
                            "tag": "local",
                            "detour": "direct",
                            "address": "https://77.88.8.8/dns-query",
                            "strategy": "ipv4_only",
                            "address_strategy": "prefer_ipv4"
                        },
                        {
                            "tag": "remote",
                            "address": "fakeip"
                        }
                    ],
                    "independent_cache": True
                },
                "log": {
                    "level": "warning",
                    "disabled": False,
                    "timestamp": True
                },
                "route": {
                    "rules": [
                        {
                            "action": "sniff"
                        },
                        {
                            "mode": "or",
                            "type": "logical",
                            "rules": [
                                {
                                    "protocol": "dns"
                                },
                                {
                                    "port": 53
                                }
                            ],
                            "action": "hijack-dns"
                        },
                        {
                            "outbound": "direct",
                            "ip_is_private": True
                        },
                        {
                            "port": [25, 135, 137, 138, 139, 445, 465, 587],
                            "outbound": "block"
                        },
                        {
                            "outbound": "block",
                            "rule_set": ["oisd-big"]
                        },
                        {
                            "port": [443],
                            "network": ["udp"],
                            "outbound": "block"
                        },
                        {
                            "domain_suffix": [
                                "lava.ru",
                                "lava.top",
                                "lava.link",
                                "lava.money"
                            ],
                            "outbound": "→ Remnawave"
                        },
                        {
                            "outbound": "direct",
                            "rule_set": ["ru-bundle"]
                        },
                        {
                            "outbound": "→ Remnawave",
                            "rule_set": [
                                "discord-voice-ip-list",
                                "geosite-tiktok",
                                "geosite-whatsapp",
                                "geosite-telegram",
                                "geoip-telegram",
                                "viber_aws_ip"
                            ]
                        }
                    ],
                    "rule_set": [
                        {
                            "tag": "oisd-big",
                            "url": "https://github.com/burjuyz/RuRulesets/raw/main/ruleset-domain-oisd_big.srs",
                            "type": "remote",
                            "format": "binary"
                        },
                        {
                            "tag": "ru-bundle",
                            "url": "https://github.com/legiz-ru/sb-rule-sets/raw/main/ru-bundle.srs",
                            "type": "remote",
                            "format": "binary"
                        },
                        {
                            "tag": "discord-voice-ip-list",
                            "url": "https://github.com/legiz-ru/sb-rule-sets/raw/main/discord-voice-ip-list.srs",
                            "type": "remote",
                            "format": "binary"
                        },
                        {
                            "tag": "geosite-tiktok",
                            "url": "https://github.com/MetaCubeX/meta-rules-dat/raw/sing/geo/geosite/tiktok.srs",
                            "type": "remote",
                            "format": "binary"
                        },
                        {
                            "tag": "geosite-whatsapp",
                            "url": "https://github.com/MetaCubeX/meta-rules-dat/raw/sing/geo/geosite/whatsapp.srs",
                            "type": "remote",
                            "format": "binary"
                        },
                        {
                            "tag": "geosite-telegram",
                            "url": "https://github.com/MetaCubeX/meta-rules-dat/raw/sing/geo/geosite/telegram.srs",
                            "type": "remote",
                            "format": "binary"
                        },
                        {
                            "tag": "geoip-telegram",
                            "url": "https://github.com/MetaCubeX/meta-rules-dat/raw/sing/geo/geoip/telegram.srs",
                            "type": "remote",
                            "format": "binary"
                        },
                        {
                            "tag": "viber_aws_ip",
                            "url": "https://github.com/legiz-ru/sb-rule-sets/raw/main/viber_aws_ip.srs",
                            "type": "remote",
                            "format": "binary"
                        }
                    ],
                    "override_android_vpn": True,
                    "auto_detect_interface": True
                },
                "inbounds": [
                    {
                        "mtu": 9000,
                        "tag": "tun-in",
                        "type": "tun",
                        "sniff": True,
                        "stack": "mixed",
                        "platform": {
                            "http_proxy": {
                                "server": "127.0.0.1",
                                "enabled": True,
                                "server_port": 2412
                            }
                        },
                        "auto_route": True,
                        "strict_route": True,
                        "inet4_address": "172.19.0.1/30",
                        "inet6_address": "fdfe:dcba:9876::1/126",
                        "interface_name": "tun125",
                        "endpoint_independent_nat": True
                    },
                    {
                        "tag": "mixed-in",
                        "type": "mixed",
                        "sniff": True,
                        "users": [],
                        "listen": "127.0.0.1",
                        "listen_port": 2412,
                        "set_system_proxy": False
                    }
                ],
                "outbounds": [
                    {
                        "tag": "→ Remnawave",
                        "type": "selector",
                        "outbounds": outbound_tags,
                        "interrupt_exist_connections": True
                    },
                    *outbounds_list,
                    {
                        "tag": "direct",
                        "type": "direct"
                    },
                    {
                        "tag": "block",
                        "type": "block"
                    }
                ],
                "experimental": {
                    "clash_api": {
                        "external_ui": "yacd",
                        "default_mode": "rule",
                        "external_controller": "127.0.0.1:9090",
                        "external_ui_download_url": "https://github.com/MetaCubeX/Yacd-meta/archive/gh-pages.zip",
                        "external_ui_download_detour": "direct"
                    },
                    "cache_file": {
                        "path": "remnawave.db",
                        "enabled": True,
                        "cache_id": "remnawave",
                        "store_fakeip": True
                    }
                }
            }
            body = json.dumps(singbox_config, indent=2, ensure_ascii=False)
            self.send_response(200)
            self.send_header("Content-Type", "application/json; charset=utf-8")
            for k, v in resp_headers.items():
                self.send_header(k, v)
            self.end_headers()
            self.wfile.write(body.encode("utf-8"))
            return

        elif format_param == "xray":
            outbounds_list = []
            for i, u in enumerate(urls, 1):
                if u.startswith("vless://"):
                    ob = vless_url_to_xray_outbound(u, i)
                    if ob:
                        outbounds_list.append(ob)
            
            xray_config = {
                "dns": {
                    "hosts": {
                        "lkfl2.nalog.ru": "213.24.64.175",
                        "lknpd.nalog.ru": "213.24.64.181",
                        "domain:googleapis.cn": "googleapis.com",
                        "geosite:category-ads": "127.0.0.1"
                    },
                    "servers": [
                        "https://8.8.8.8/dns-query",
                        "https://1.1.1.1/dns-query",
                        {
                            "address": "https://8.8.8.8/dns-query",
                            "domains": [
                                "domain:lava.ru",
                                "domain:lava.top",
                                "domain:lava.link",
                                "domain:lava.money",
                                "geosite:google-play",
                                "geosite:github",
                                "geosite:twitch-ads",
                                "geosite:youtube",
                                "geosite:telegram"
                            ]
                        },
                        {
                            "address": "https://77.88.8.8/dns-query",
                            "domains": [
                                "geosite:private",
                                "geosite:category-ru",
                                "geosite:whitelist",
                                "geosite:microsoft",
                                "geosite:apple",
                                "geosite:epicgames",
                                "geosite:riot",
                                "geosite:escapefromtarkov",
                                "geosite:steam",
                                "geosite:origin",
                                "geosite:twitch",
                                "geosite:pinterest",
                                "geosite:faceit"
                            ]
                        }
                    ],
                    "queryStrategy": "UseIPv4"
                },
                "log": {
                    "loglevel": "warning"
                },
                "stats": {},
                "policy": {
                    "levels": {
                        "8": {
                            "connIdle": 300,
                            "handshake": 4,
                            "uplinkOnly": 1,
                            "downlinkOnly": 1
                        }
                    },
                    "system": {
                        "statsOutboundUplink": True,
                        "statsOutboundDownlink": True
                    }
                },
                "routing": {
                    "domainStrategy": "IPIfNonMatch",
                    "rules": [
                        {
                            "port": 53,
                            "type": "field",
                            "outboundTag": "dns-out"
                        },
                        {
                            "port": "25,135,137,138,139,445,465,587",
                            "type": "field",
                            "network": "tcp,udp",
                            "outboundTag": "block"
                        },
                        {
                            "port": 443,
                            "type": "field",
                            "network": "udp",
                            "outboundTag": "block"
                        },
                        {
                            "type": "field",
                            "domain": [
                                "geosite:win-spy",
                                "geosite:torrent",
                                "geosite:category-ads"
                            ],
                            "outboundTag": "block"
                        },
                        {
                            "ip": ["77.88.8.8"],
                            "type": "field",
                            "outboundTag": "direct"
                        },
                        {
                            "ip": ["8.8.8.8", "1.1.1.1"],
                            "type": "field",
                            "balancerTag": "Super_Balancer"
                        },
                        {
                            "type": "field",
                            "domain": [
                                "domain:lava.ru",
                                "domain:lava.top",
                                "domain:lava.link",
                                "domain:lava.money",
                                "geosite:google-play",
                                "geosite:github",
                                "geosite:twitch-ads",
                                "geosite:youtube",
                                "geosite:telegram"
                            ],
                            "balancerTag": "Super_Balancer"
                        },
                        {
                            "type": "field",
                            "domain": [
                                "geosite:private",
                                "geosite:category-ru",
                                "geosite:whitelist",
                                "geosite:microsoft",
                                "geosite:apple",
                                "geosite:epicgames",
                                "geosite:riot",
                                "geosite:escapefromtarkov",
                                "geosite:steam",
                                "geosite:origin",
                                "geosite:twitch",
                                "geosite:pinterest",
                                "geosite:faceit"
                            ],
                            "outboundTag": "direct"
                        },
                        {
                            "ip": [
                                "geoip:private",
                                "geoip:direct"
                            ],
                            "type": "field",
                            "outboundTag": "direct"
                        },
                        {
                            "type": "field",
                            "network": "tcp,udp",
                            "balancerTag": "Super_Balancer"
                        }
                    ],
                    "balancers": [
                        {
                            "tag": "Super_Balancer",
                            "selector": ["proxy"],
                            "strategy": {
                                "type": "leastPing"
                            },
                            "fallbackTag": "direct"
                        }
                    ],
                    "domainStrategy": "IPIfNonMatch"
                },
                "inbounds": [
                    {
                        "tag": "socks",
                        "port": 10808,
                        "listen": "127.0.0.1",
                        "protocol": "socks",
                        "settings": {
                            "udp": True,
                            "auth": "noauth",
                            "userLevel": 8
                        },
                        "sniffing": {
                            "enabled": True,
                            "routeOnly": True,
                            "destOverride": ["http", "quic", "tls"]
                        }
                    },
                    {
                        "tag": "http",
                        "port": 10809,
                        "listen": "127.0.0.1",
                        "protocol": "http",
                        "settings": {
                            "userLevel": 8,
                            "allowTransparent": False
                        },
                        "sniffing": {
                            "enabled": True,
                            "routeOnly": True,
                            "destOverride": ["http", "quic", "tls"]
                        }
                    }
                ],
                "outbounds": [
                    *outbounds_list,
                    {
                        "tag": "direct",
                        "protocol": "freedom"
                    },
                    {
                        "tag": "block",
                        "protocol": "blackhole"
                    },
                    {
                        "tag": "dns-out",
                        "protocol": "dns"
                    }
                ]
            }
            body = json.dumps(xray_config, indent=2, ensure_ascii=False)
            self.send_response(200)
            self.send_header("Content-Type", "application/json; charset=utf-8")
            for k, v in resp_headers.items():
                self.send_header(k, v)
            self.end_headers()
            self.wfile.write(body.encode("utf-8"))
            return

        elif format_param in ("clash", "mihomo"):
            proxies_list = []
            proxy_names = []
            seen_names = {}
            for u in urls:
                if u.startswith("vless://"):
                    pr = vless_url_to_mihomo_proxy(u)
                    if pr:
                        original_name = pr["name"]
                        name = original_name
                        counter = seen_names.get(original_name, 0)
                        if counter > 0:
                            name = f"{original_name} [{counter}]"
                        seen_names[original_name] = counter + 1
                        pr["name"] = name
                        proxies_list.append(pr)
                        proxy_names.append(name)
                elif u.startswith("hysteria2://"):
                    pr = hysteria2_url_to_mihomo_proxy(u)
                    if pr:
                        original_name = pr["name"]
                        name = original_name
                        counter = seen_names.get(original_name, 0)
                        if counter > 0:
                            name = f"{original_name} [{counter}]"
                        seen_names[original_name] = counter + 1
                        pr["name"] = name
                        proxies_list.append(pr)
                        proxy_names.append(name)
                        
            if not proxy_names:
                proxy_names = ["DIRECT"]

            clash_config = {
                "mixed-port": 7890,
                "allow-lan": False,
                "bind-address": "*",
                "mode": "rule",
                "log-level": "warning",
                "ipv6": False,
                "external-controller": "127.0.0.1:9090",
                "geox-url": {
                    "geoip": "https://testingcf.jsdelivr.net/gh/MetaCubeX/meta-rules-dat@release/geoip.dat",
                    "geosite": "https://testingcf.jsdelivr.net/gh/MetaCubeX/meta-rules-dat@release/geosite.dat",
                    "mmdb": "https://testingcf.jsdelivr.net/gh/MetaCubeX/meta-rules-dat@release/country.mmdb"
                },
                "dns": {
                    "enable": True,
                    "ipv6": False,
                    "enhanced-mode": "fake-ip",
                    "fake-ip-range": "198.18.0.1/16",
                    "default-nameserver": [
                        "77.88.8.8",
                        "1.1.1.1"
                    ],
                    "proxy-server-nameserver": [
                        "77.88.8.8",
                        "1.1.1.1"
                    ],
                    "nameserver": [
                        "77.88.8.8"
                    ],
                    "fallback": [
                        "8.8.8.8",
                        "1.1.1.1"
                    ]
                },
                "tun": {
                    "enable": True,
                    "stack": "system",
                    "auto-route": True,
                    "auto-detect-interface": True
                },
                "proxy-groups": [
                    {
                        "name": "🛡️ VPN",
                        "icon": "https://cdn.jsdelivr.net/gh/Koolson/Qure@master/IconSet/Color/Hijacking.png",
                        "type": "select",
                        "proxies": ["⚡️ Авто"] + proxy_names
                    },
                    {
                        "name": "📺 Youtube",
                        "icon": "https://cdn.jsdelivr.net/gh/Koolson/Qure@master/IconSet/Color/YouTube.png",
                        "type": "select",
                        "proxies": ["🛡️ VPN", "⚡️ Авто", "DIRECT"] + proxy_names
                    },
                    {
                        "name": "💬 Discord",
                        "icon": "https://cdn.jsdelivr.net/gh/Koolson/Qure@master/IconSet/Color/Discord.png",
                        "type": "select",
                        "proxies": ["🛡️ VPN", "⚡️ Авто", "DIRECT"] + proxy_names
                    },
                    {
                        "name": "🎮 Игры",
                        "icon": "https://cdn.jsdelivr.net/gh/Koolson/Qure@master/IconSet/Color/Game.png",
                        "type": "select",
                        "proxies": ["🛡️ VPN", "⚡️ Авто", "DIRECT"] + proxy_names
                    },
                    {
                        "name": "⚡️ Авто",
                        "icon": "https://cdn.jsdelivr.net/gh/Koolson/Qure@master/IconSet/Color/Speed.png",
                        "type": "url-test",
                        "proxies": list(proxy_names),
                        "url": "http://cp.cloudflare.com/generate_204",
                        "interval": 300,
                        "tolerance": 50
                    }
                ],
                "rule-providers": {
                    "microsoft": {
                        "type": "http",
                        "behavior": "domain",
                        "url": "https://raw.githubusercontent.com/burjuyz/RuRulesets/main/ruleset-domain-microsoft.yaml",
                        "path": "./rulesets/microsoft.yaml",
                        "interval": 86400
                    },
                    "torrent": {
                        "type": "http",
                        "behavior": "domain",
                        "url": "https://raw.githubusercontent.com/burjuyz/RuRulesets/main/ruleset-domain-torrent.yaml",
                        "path": "./rulesets/torrent.yaml",
                        "interval": 86400
                    },
                    "steam": {
                        "type": "http",
                        "behavior": "domain",
                        "url": "https://raw.githubusercontent.com/burjuyz/RuRulesets/main/ruleset-domain-steam.yaml",
                        "path": "./rulesets/steam.yaml",
                        "interval": 86400
                    },
                    "discord": {
                        "type": "http",
                        "behavior": "domain",
                        "url": "https://raw.githubusercontent.com/burjuyz/RuRulesets/main/ruleset-domain-discord.yaml",
                        "path": "./rulesets/discord.yaml",
                        "interval": 86400
                    },
                    "category-ru": {
                        "type": "http",
                        "behavior": "domain",
                        "url": "https://raw.githubusercontent.com/burjuyz/RuRulesets/main/ruleset-domain-category-ru.yaml",
                        "path": "./rulesets/category-ru.yaml",
                        "interval": 86400
                    },
                    "private-domains": {
                        "type": "http",
                        "behavior": "domain",
                        "url": "https://raw.githubusercontent.com/burjuyz/RuRulesets/main/ruleset-domain-private.yaml",
                        "path": "./rulesets/private.yaml",
                        "interval": 86400
                    }
                },
                "proxies": proxies_list,
                "rules": [
                    "DST-PORT,25,REJECT",
                    "DST-PORT,135,REJECT",
                    "DST-PORT,137,REJECT",
                    "DST-PORT,138,REJECT",
                    "DST-PORT,139,REJECT",
                    "DST-PORT,445,REJECT",
                    "DST-PORT,465,REJECT",
                    "DST-PORT,587,REJECT",
                    "AND,((NETWORK,udp),(PORT,443)),REJECT",
                    "RULE-SET,private-domains,DIRECT",
                    "RULE-SET,category-ru,DIRECT",
                    "RULE-SET,microsoft,DIRECT",
                    "RULE-SET,steam,🎮 Игры",
                    "RULE-SET,discord,💬 Discord",
                    "PROCESS-NAME,Discord.exe,💬 Discord",
                    "PROCESS-NAME,DiscordCanary.exe,💬 Discord",
                    "PROCESS-NAME,DiscordPTB.exe,💬 Discord",
                    "DOMAIN-KEYWORD,discord,💬 Discord",
                    "DOMAIN-SUFFIX,youtube.com,📺 Youtube",
                    "DOMAIN-SUFFIX,googlevideo.com,📺 Youtube",
                    "DOMAIN-SUFFIX,ytimg.com,📺 Youtube",
                    "DOMAIN-SUFFIX,youtube-nocookie.com,📺 Youtube",
                    "DOMAIN-SUFFIX,youtu.be,📺 Youtube",
                    "DOMAIN-SUFFIX,lava.ru,🛡️ VPN",
                    "DOMAIN-SUFFIX,lava.top,🛡️ VPN",
                    "DOMAIN-SUFFIX,lava.link,🛡️ VPN",
                    "DOMAIN-SUFFIX,lava.money,🛡️ VPN",
                    "GEOSITE,google-play,🛡️ VPN",
                    "RULE-SET,torrent,DIRECT",
                    "GEOIP,private,DIRECT",
                    "MATCH,🛡️ VPN"
                ]
            }
            body = dict_to_yaml(clash_config)
            self.send_response(200)
            self.send_header("Content-Type", "application/yaml; charset=utf-8")
            for k, v in resp_headers.items():
                self.send_header(k, v)
            self.end_headers()
            self.wfile.write(body.encode("utf-8"))
            return

        # Default raw link list formatted base64
        if "v2ray" in user_agent or "clash" in user_agent:
            sub_content = sub_content_links
        else:
            sub_metadata = (
                f"#profile-title: {b64_client_display}\n"
                f"#profile-update-interval: 1\n"
                f"#support-url: {support_url}\n"
                f"#profile-web-page-url: https://mvrvntn.github.io/koridor/\n"
                f"#announce: {b64_announce}\n"
                f"#subscription-userinfo: 0\n"
                f"#sort-order: ping\n"
                f"#fragmentation-enable: 1\n"
                f"#fragmentation-packets: tlshello\n"
                f"#fragmentation-length: 10-30\n"
                f"#fragmentation-interval: 10-20\n"
                f"#hide-url: 1\n"
                f"#noises-enable: 0\n"
                f"#no-limit-enabled: 1\n"
                f"#per-app-proxy-enable: 0\n"
            )
            if providerid:
                sub_metadata = f"#providerid {providerid}\n" + sub_metadata
            if "incy" in user_agent:
                sub_metadata += (
                    "#server-address-resolve-enable: 1\n"
                    "#server-address-resolve-dns-domain: https://common.dot.dns.yandex.net/dns-query\n"
                    "#server-address-resolve-dns-ip: 77.88.8.8\n"
                    "#banner-bg-color: #F4F4F5\n"
                    "#banner-button-color: #1A1A1A\n"
                )
            sub_content = sub_metadata + sub_content_links
            
        b64_content = base64.b64encode(sub_content.encode("utf-8")).decode("utf-8")
        self.send_response(200)
        self.send_header("Content-Type", "text/plain; charset=utf-8")
        for k, v in resp_headers.items():
            self.send_header(k, v)
        self.end_headers()
        self.wfile.write(b64_content.encode("utf-8"))

if __name__ == "__main__":
    handler = SubHandler
    socketserver.TCPServer.allow_reuse_address = True
    with socketserver.TCPServer(("127.0.0.1", PORT), handler) as httpd:
        httpd.serve_forever()
EOF

    # Создаём systemd service
    local py_path; py_path=$(command -v python3 || echo "/usr/bin/python3")
    cat > /etc/systemd/system/xray-sub.service <<EOF
[Unit]
Description=Xray Subscription Service
After=network.target

[Service]
Type=simple
User=nobody
Group=nogroup
ExecStart=$py_path $SUB_SERVER_SCRIPT
Restart=always

[Install]
WantedBy=multi-user.target
EOF

    systemctl daemon-reload
    systemctl enable xray-sub >/dev/null 2>&1
    systemctl restart xray-sub
    log_info "Restarted Xray Subscription service"
}

# === Установка утилиты генерации ссылок ===
install_generate_script() {
    cat > "$GENERATE_SCRIPT" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

# Цвета для красивого вывода
BOLD='\033[1m'
NC='\033[0m'
CYAN='\033[0;36m'
PURPLE='\033[0;35m'
YELLOW='\033[0;33m'
GREEN='\033[0;32m'
RED='\033[0;31m'

  CONFIG_DIR="/etc/xray/client_configs"
  DOMAIN=$(awk -F= '/^DOMAIN=/{print $2}' /etc/xray/.installed | tr -d '[:space:]')
  EMOJI=$(awk -F= '/^EMOJI=/{print $2}' /etc/xray/.installed | tr -d '[:space:]')
  FLOW="xtls-rprx-vision"
  FINGERPRINT=$(awk -F= '/^FINGERPRINT=/{print $2}' /etc/xray/.installed | tr -d '[:space:]')
  if [[ -z "$FINGERPRINT" ]]; then FINGERPRINT="random"; fi
  PORT=443

  REALITY_ENABLED=$(awk -F= '/^REALITY_ENABLED=/{print $2}' /etc/xray/.installed | tr -d '[:space:]')
  REALITY_SNI=$(awk -F= '/^REALITY_SNI=/{print $2}' /etc/xray/.installed | tr -d '[:space:]')
  REALITY_PBK=$(awk -F= '/^REALITY_PUBLIC_KEY=/{print $2}' /etc/xray/.installed | tr -d '[:space:]')
  REALITY_SID=$(awk -F= '/^REALITY_SHORT_ID=/{print $2}' /etc/xray/.installed | tr -d '[:space:]')

mapfile -t -d '' config_files < <(find "$CONFIG_DIR" -maxdepth 1 -name '*.json' -print0 | sort -z)

if [[ ${#config_files[@]} -eq 0 ]]; then
  echo -e "${RED}❌ Конфиги не найдены!${NC}"
  exit 1
fi

echo -e "\n${BOLD}${CYAN}📱  ДОСТУПНЫЕ УСТРОЙСТВА${NC}"
echo -e "${CYAN}──────────────────────────────────────────────────────────${NC}"
for i in "${!config_files[@]}"; do
  remarks=$(python3 -c "import json, sys; print(json.load(open(sys.argv[1])).get('remarks', ''))" "${config_files[$i]}" 2>/dev/null)
  if [[ -z "$remarks" ]] || [[ "$remarks" = "null" ]]; then
    remarks="${config_files[$i]##*/}"
    remarks="${remarks%.json}"
  fi
  echo -e " ${BOLD}${YELLOW}$((i+1)).${NC} $remarks"
done
echo -e "${CYAN}──────────────────────────────────────────────────────────${NC}"

read -r -p "Выберите устройство (1-${#config_files[@]}): " choice
if ! [[ "$choice" =~ ^[0-9]+$ ]] || [[ "$choice" -lt 1 ]] || [[ "$choice" -gt ${#config_files[@]} ]]; then
  echo -e "${RED}❌ Неверный выбор!${NC}"
  exit 1
fi

selected="${config_files[$((choice-1))]}"
UUID=$(python3 -c "import json, sys; print(json.load(open(sys.argv[1])).get('id', ''))" "$selected" 2>/dev/null)
remarks=$(python3 -c "import json, sys; print(json.load(open(sys.argv[1])).get('remarks', ''))" "$selected" 2>/dev/null)
if [[ -z "$remarks" ]] || [[ "$remarks" = "null" ]]; then
  remarks="${selected##*/}"
  remarks="${remarks%.json}"
fi

# Генерация названий с новыми эмодзи-символами и скобками
if [[ -n "$EMOJI" ]]; then
  remark_vision="${EMOJI}🌐 VLESS-TCP"
  remark_hy2="${EMOJI}⚡ Hysteria2"
  remark_grpc="${EMOJI}↔️ VLESS-gRPC"
  remark_reality="${EMOJI}🪞 VLESS-Reality (${REALITY_SNI})"
else
  remark_vision="🌐 VLESS-TCP"
  remark_hy2="⚡ Hysteria2"
  remark_grpc="↔️ VLESS-gRPC"
  remark_reality="🪞 VLESS-Reality (${REALITY_SNI})"
fi

urlencode() {
  python3 -c "import urllib.parse, sys; print(urllib.parse.quote(sys.argv[1]), end='')" "$1" 2>/dev/null || echo -n "$1"
}

encoded_remark_vision=$(urlencode "$remark_vision")
encoded_remark_hy2=$(urlencode "$remark_hy2")
encoded_remark_grpc=$(urlencode "$remark_grpc")
encoded_remark_reality=$(urlencode "$remark_reality")

# Ссылки для подключения
VLESS_VISION="vless://${UUID}@${DOMAIN}:${PORT}?encryption=none&flow=${FLOW}&security=tls&type=tcp&fp=${FINGERPRINT}&alpn=http%2F1.1#${encoded_remark_vision}"
HY2_LINK="hysteria2://${UUID}:${UUID}@${DOMAIN}:20443?sni=${DOMAIN}&hop=20000-50000&mport=20000-50000#${encoded_remark_hy2}"
VLESS_GRPC="vless://${UUID}@${DOMAIN}:8443?encryption=none&security=tls&type=grpc&serviceName=vless-grpc&service_name=vless-grpc&mode=multi&fp=${FINGERPRINT}&alpn=h2&sni=${DOMAIN}#${encoded_remark_grpc}"
SUBSCRIPTION_URL="https://${DOMAIN}/sub/${UUID}"

if [[ "$REALITY_ENABLED" = "true" ]]; then
  VLESS_REALITY="vless://${UUID}@${DOMAIN}:${PORT}?flow=${FLOW}&security=reality&sni=${REALITY_SNI}&pbk=${REALITY_PBK}&sid=${REALITY_SID}&fp=${FINGERPRINT}&type=tcp#${encoded_remark_reality}"
fi

echo -e "\n${BOLD}${PURPLE}🔗  ССЫЛКИ ДЛЯ ПОДКЛЮЧЕНИЯ${NC}"
echo -e "${PURPLE}──────────────────────────────────────────────────────────${NC}"
echo -e " ${BOLD}${YELLOW}1. VLESS TCP Vision (Для смартфонов и ПК, порт 443):${NC}"
echo -e "    ${GREEN}$VLESS_VISION${NC}"
echo -e " ${BOLD}${YELLOW}2. Hysteria2 (UDP, быстрый обход, порт 20443/hopping):${NC}"
echo -e "    ${GREEN}$HY2_LINK${NC}"
echo -e " ${BOLD}${YELLOW}3. VLESS gRPC TLS (Резервный протокол, порт 8443):${NC}"
echo -e "    ${GREEN}$VLESS_GRPC${NC}"
if [[ "$REALITY_ENABLED" = "true" ]]; then
echo -e " ${BOLD}${YELLOW}4. VLESS Reality (Маскировка ${REALITY_SNI}):${NC}"
echo -e "    ${GREEN}$VLESS_REALITY${NC}"
fi

echo -e "\n ${BOLD}${YELLOW}Ссылка подписки (импорт в клиент):${NC}"
echo -e "    ${CYAN}$SUBSCRIPTION_URL${NC}"
echo -e "${PURPLE}──────────────────────────────────────────────────────────${NC}"

echo -e "\n${BOLD}${CYAN}🔳  ГЕНЕРАЦИЯ QR-КОДА${NC}"
echo -e "${CYAN}──────────────────────────────────────────────────────────${NC}"
echo -e " Выберите, для чего отобразить QR-код:"
echo -e " ${BOLD}${YELLOW}1.${NC} VLESS TCP Vision (порт 443)"
echo -e " ${BOLD}${YELLOW}2.${NC} Hysteria2 (порт 20443/hopping)"
echo -e " ${BOLD}${YELLOW}3.${NC} VLESS gRPC TLS (порт 8443)"
if [[ "$REALITY_ENABLED" = "true" ]]; then
echo -e " ${BOLD}${YELLOW}4.${NC} VLESS Reality"
echo -e " ${BOLD}${YELLOW}5.${NC} Ссылка подписки"
else
echo -e " ${BOLD}${YELLOW}4.${NC} Ссылка подписки"
fi
echo -e "${CYAN}──────────────────────────────────────────────────────────${NC}"
read -r -p "Ваш выбор: " qr_choice
if [[ "$REALITY_ENABLED" = "true" ]]; then
  case "$qr_choice" in
    1) qrencode -t UTF8 "$VLESS_VISION" ;;
    2) qrencode -t UTF8 "$HY2_LINK" ;;
    3) qrencode -t UTF8 "$VLESS_GRPC" ;;
    4) qrencode -t UTF8 "$VLESS_REALITY" ;;
    5) qrencode -t UTF8 "$SUBSCRIPTION_URL" ;;
    *) echo -e "${RED}Выход без вывода QR-кода${NC}" ;;
  esac
else
  case "$qr_choice" in
    1) qrencode -t UTF8 "$VLESS_VISION" ;;
    2) qrencode -t UTF8 "$HY2_LINK" ;;
    3) qrencode -t UTF8 "$VLESS_GRPC" ;;
    4) qrencode -t UTF8 "$SUBSCRIPTION_URL" ;;
    *) echo -e "${RED}Выход без вывода QR-кода${NC}" ;;
  esac
fi
EOF

    chmod +x "$GENERATE_SCRIPT"
}

# === Проверка предыдущей установки (до запроса данных) ===
main() {
    case "${1:-}" in
        -h|--help)
            usage
            ;;
        -v|--version)
            echo "$SCRIPT_NAME version 1.0.0"
            exit 0
            ;;
        --optimize)
            optimize_vps
            ;;
        --renew-cert)
            renew_ssl_certificate --force
            exit 0
            ;;
        --update-core|--update-geoblocks|--headless|"")
            # Корректные режимы работы, продолжаем выполнение
            ;;
        -*)
            echo "❌ Неизвестная опция: $1" >&2
            echo "Используйте $SCRIPT_NAME --help для справки." >&2
            exit 1
            ;;
    esac

    if [[ -f "$MARKER_FILE" ]]; then
        show_connections() {
            echo -e "\n--- Активные подключения к Xray ---"
            local conns; conns=$(ss -tnp | grep -E ':(443|8443)\s' | grep -v '127.0.0.1')
            if [[ -z "$conns" ]]; then
                echo "Нет активных подключений на порты 443 / 8443."
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
            read -r -p "Выбор (1-4): " lchoice
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
            local port_443_process; port_443_process=$(ss -tlnp 'sport = :443' 2>/dev/null | grep -v 'Local Address' | awk '{print $NF}')
            local port_8443_process; port_8443_process=$(ss -tlnp 'sport = :8443' 2>/dev/null | grep -v 'Local Address' | awk '{print $NF}')
            local port_443_udp_process; port_443_udp_process=$(ss -ulnp 'sport = :443' 2>/dev/null | grep -v 'Local Address' | awk '{print $NF}')
            local port_80_process; port_80_process=$(ss -tlnp 'sport = :80' 2>/dev/null | grep -v 'Local Address' | awk '{print $NF}')
            
            if [[ -n "$port_443_process" ]]; then
                echo -e " 🟢 Порт 443 (TCP) успешно занят процессом: ${GREEN}$port_443_process${NC}"
                if [[ "$port_443_process" =~ "openvpn" ]]; then
                    echo -e "  ${RED}⚠️ ВНИМАНИЕ! Порт 443 занят процессом OpenVPN. Это приведет к неработоспособности Xray!${NC}"
                fi
            else
                echo -e " 🔴 ${RED}Порт 443 (TCP) Свободен или Xray не запущен!${NC}"
            fi

            if [[ -n "$port_8443_process" ]]; then
                echo -e " 🟢 Порт 8443 (TCP - gRPC) успешно занят процессом: ${GREEN}$port_8443_process${NC}"
            else
                echo -e " 🔴 ${RED}Порт 8443 (TCP - gRPC) Свободен или Xray не запущен!${NC}"
            fi

            if [[ -n "$port_443_udp_process" ]]; then
                echo -e " 🟢 Порт 443 (UDP) успешно занят процессом: ${GREEN}$port_443_udp_process${NC}"
            else
                echo -e " 🔴 ${RED}Порт 443 (UDP) Свободен или Hysteria 2 не запущена!${NC}"
            fi
            
            if [[ -n "$port_80_process" ]]; then
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
            local domain; domain=$(get_installed_var "DOMAIN")
            if [[ -n "$domain" ]]; then
                echo -e " Текущий домен сервера: ${CYAN}$domain${NC}"
                local resolved_ip; resolved_ip=$(getent hosts "$domain" | awk '{print $1}' | head -n 1)
                if [[ -n "$resolved_ip" ]]; then
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
            if [[ "$(get_installed_var "WARP_INSTALLED")" == "true" ]]; then
                if ip link show warp >/dev/null 2>&1; then
                    echo -e " Интерфейс warp: 🟢 ${GREEN}UP (Поднят)${NC}"
                    echo -e " Выполняем тест пинга и маршрутизации через интерфейс warp..."
                    local warp_test; warp_test=$(curl --interface warp -s --connect-timeout 4 https://www.cloudflare.com/cdn-cgi/trace | grep -E "(ip=|warp=)")
                    if [[ -n "$warp_test" ]]; then
                        echo -e " 🟢 ${GREEN}Сеть WARP успешно отвечает:${NC}"
                        echo "   ${warp_test//$'\n'/$'\n'   }"
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
                local curl_opts=()
                if [[ -n "$iface" ]]; then
                    curl_opts=(--interface "$iface")
                fi

                # Netflix
                local nf_code; nf_code=$(curl "${curl_opts[@]}" -s -o /dev/null -w "%{http_code}" --connect-timeout 4 https://www.netflix.com/title/80018499)
                local nf_res="${RED}🔴 Заблокирован${NC}"
                if [[ "$nf_code" == "200" ]]; then
                    nf_res="${GREEN}🟢 Доступен (Оригиналы + Каталог)${NC}"
                elif [[ "$nf_code" == "301" ]] || [[ "$nf_code" == "302" ]]; then
                    nf_res="${YELLOW}🟡 Доступны только собственные релизы${NC}"
                fi

                # ChatGPT
                local gpt_code; gpt_code=$(curl "${curl_opts[@]}" -s -o /dev/null -w "%{http_code}" --connect-timeout 4 https://chatgpt.com)
                local gpt_res="${RED}🔴 Заблокирован${NC}"
                if [[ "$gpt_code" == "200" ]] || [[ "$gpt_code" == "302" ]]; then
                    gpt_res="${GREEN}🟢 Доступен${NC}"
                fi

                # YouTube Region
                local yt_region; yt_region=$(curl "${curl_opts[@]}" -s --connect-timeout 4 https://www.youtube.com/premium 2>/dev/null | awk -F'"' '/countryCode":/ { for(i=1;i<=NF;i++) if($i=="countryCode") print $(i+2) }')
                local yt_res="${RED}🔴 Не удалось определить регион${NC}"
                if [[ -n "$yt_region" ]]; then
                    yt_res="${GREEN}🟢 Доступен (Регион: $yt_region)${NC}"
                fi

                echo -e "   👉 ${CYAN}$label:${NC}"
                echo -e "      - Netflix: $nf_res"
                echo -e "      - ChatGPT: $gpt_res"
                echo -e "      - YouTube: $yt_res"
            }
            check_media_unlock "Основной IP сервера" ""
            if [[ "$(get_installed_var "WARP_INSTALLED")" == "true" ]] && ip link show warp >/dev/null 2>&1; then
                check_media_unlock "Через интерфейс WARP" "warp"
            fi

            # 6. Проверка сертификатов SSL
            echo -e "\n${BOLD}[6] Проверка SSL-сертификатов Let's Encrypt:${NC}"
            if [[ -f "$SSL_DIR/fullchain.cer" ]] && [[ -f "$SSL_DIR/private.key" ]]; then
                echo -e " Файлы SSL: 🟢 ${GREEN}Присутствуют в директории $SSL_DIR${NC}"
                local end_date; end_date=$(openssl x509 -enddate -noout -in "$SSL_DIR/fullchain.cer" 2>/dev/null | cut -d= -f2)
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
            local ipt_path; ipt_path=$(command -v iptables 2>/dev/null || echo "/sbin/iptables")
            if $ipt_path -t nat -S 2>/dev/null | grep -q "20000:50000"; then
                echo -e " Port Hopping (IPv4 NAT): 🟢 ${GREEN}АКТИВЕН (Перенаправление 20000-50000 -> 443)${NC}"
            else
                echo -e " Port Hopping (IPv4 NAT): 🔴 ${RED}НЕАКТИВЕН${NC}"
            fi
            
            local ipt6_path; ipt6_path=$(command -v ip6tables 2>/dev/null || echo "/sbin/ip6tables")
            if $ipt6_path -t nat -S &>/dev/null; then
                if $ipt6_path -t nat -S 2>/dev/null | grep -q "20000:50000"; then
                    echo -e " Port Hopping (IPv6 NAT): 🟢 ${GREEN}АКТИВЕН (Перенаправление 20000-50000 -> 443)${NC}"
                else
                    echo -e " Port Hopping (IPv6 NAT): 🔴 ${RED}НЕАКТИВЕН${NC}"
                fi
            fi

            # 8. Использование системных ресурсов
            echo -e "\n${BOLD}[8] Использование ресурсов процессами Xray и Hysteria 2:${NC}"
            local xray_pid; xray_pid=$(systemctl show --property=MainPID --value xray)
            local hysteria_pid; hysteria_pid=$(systemctl show --property=MainPID --value hysteria-server)
            
            if [[ -n "$xray_pid" ]] && [[ "$xray_pid" -ne 0 ]] && ps -p "$xray_pid" >/dev/null; then
                local xray_mem; xray_mem=$(ps -o rss= -p "$xray_pid" | awk '{print int($1/1024)}')
                local xray_cpu; xray_cpu=$(ps -o %cpu= -p "$xray_pid")
                echo -e " Xray (PID $xray_pid):   CPU: ${GREEN}${xray_cpu}%${NC} | Memory: ${GREEN}${xray_mem} MB${NC}"
            else
                echo -e " Xray: 🔴 Процесс не запущен"
            fi
            
            if [[ -n "$hysteria_pid" ]] && [[ "$hysteria_pid" -ne 0 ]] && ps -p "$hysteria_pid" >/dev/null; then
                local hysteria_mem; hysteria_mem=$(ps -o rss= -p "$hysteria_pid" | awk '{print int($1/1024)}')
                local hysteria_cpu; hysteria_cpu=$(ps -o %cpu= -p "$hysteria_pid")
                echo -e " Hysteria 2 (PID $hysteria_pid): CPU: ${GREEN}${hysteria_cpu}%${NC} | Memory: ${GREEN}${hysteria_mem} MB${NC}"
            else
                echo -e " Hysteria 2: 🔴 Процесс не запущен"
            fi

            echo -e "\n${BOLD}Диагностика завершена. Нажмите Enter, чтобы вернуться назад...${NC}"
            read -r
        }


        add_client() {
            echo -e "\n--- Добавление нового клиента ---"
            read -r -p "Введите имя нового устройства (например: client_new): " new_name
            new_name=$(echo "$new_name" | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//')
            if [[ -z "$new_name" ]]; then
                echo "❌ Имя не может быть пустым"
                return
            fi

            local safe_filename; safe_filename=$(echo "$new_name" | tr -cd '[:alnum:]_.-' | tr '[:upper:]' '[:lower:]')
            if [[ -z "$safe_filename" ]]; then
                safe_filename="client_new"
            fi

            if [[ -f "$CLIENT_CONFIG_DIR/${safe_filename}.json" ]]; then
                echo "❌ Клиент с таким именем уже существует!"
                return
            fi

            local new_uuid; new_uuid=$(xray uuid)
            DOMAIN=$(get_installed_var "DOMAIN")
            local FINGERPRINT; FINGERPRINT=$(get_installed_var "FINGERPRINT")
            if [[ -z "$FINGERPRINT" ]]; then FINGERPRINT="random"; fi

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
            local current_num; current_num=$(find "$CLIENT_CONFIG_DIR" -maxdepth 1 -name '*.json' | wc -l)
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
            if [[ -z "$num" ]]; then
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
            if [[ -z "$num" ]]; then
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
            
            mapfile -t -d '' config_files < <(find "$CLIENT_CONFIG_DIR" -maxdepth 1 -name '*.json' -print0 | sort -z)
            if [[ ${#config_files[@]} -eq 0 ]]; then
                ui_item_color "" "❌ Нет доступных клиентов для удаления" "" "${RED}"
                ui_footer "${RED}"
                return
            fi

            for i in "${!config_files[@]}"; do
                remarks=$(python3 -c "import json, sys; print(json.load(open(sys.argv[1])).get('remarks', ''))" "${config_files[$i]}" 2>/dev/null)
                if [[ -z "$remarks" ]]; then
                    remarks="${config_files[$i]##*/}"
                    remarks="${remarks%.json}"
                fi
                ui_item_color "$((i+1))" "$remarks" "${YELLOW}" "${RED}"
            done
            ui_item_color "0" "↩️ Отмена и возврат назад" "${CYAN}" "${RED}"
            ui_footer "${RED}"

            read -r -p " Выберите клиента (1-${#config_files[@]}, или 0 для выхода): " choice
            if [[ "$choice" == "0" ]] || [[ -z "$choice" ]]; then
                return
            fi

            if ! [[ "$choice" =~ ^[0-9]+$ ]] || [[ "$choice" -lt 1 ]] || [[ "$choice" -gt ${#config_files[@]} ]]; then
                echo -e " ${RED}❌ Неверный выбор!${NC}"
                return
            fi

            selected="${config_files[$((choice-1))]}"
            remarks=$(python3 -c "import json, sys; print(json.load(open(sys.argv[1])).get('remarks', ''))" "$selected" 2>/dev/null)
            if [[ -z "$remarks" ]]; then
                remarks="${selected##*/}"
                remarks="${remarks%.json}"
            fi

            read -r -p " Вы действительно хотите удалить '$remarks'? [y/N]: " confirm
            if [[ "$confirm" =~ ^[Yy]$ ]]; then
                rm -f "$selected"
                # Обновляем конфиг сервера и перезапускаем xray и hysteria
                generate_server_config
                generate_hysteria_config

                # Обновляем маркер
                local current_num; current_num=$(find "$CLIENT_CONFIG_DIR" -maxdepth 1 -name '*.json' | wc -l)
                update_marker_val "NUM_DEVICES" "$current_num"

                echo -e " ${GREEN}✅ Клиент '$remarks' успешно удален из системы!${NC}"
                sleep 1
            else
                echo " Отменено."
            fi
        }

        show_status_dashboard() {
            local domain; domain=$(get_installed_var "DOMAIN")
            local clients_count; clients_count=$(find "$CLIENT_CONFIG_DIR" -maxdepth 1 -name '*.json' 2>/dev/null | wc -l)
            
            # Статусы системных служб
            local xray_ver=""
            if [[ -f "/usr/local/bin/xray" ]]; then
                xray_ver=$(/usr/local/bin/xray version 2>/dev/null | head -n 1 | awk '{print $2}')
            elif command -v xray >/dev/null 2>&1; then
                xray_ver=$(xray version 2>/dev/null | head -n 1 | awk '{print $2}')
            fi

            local xray_status="${RED}OFF${NC}"
            if [[ -n "$xray_ver" ]]; then
                systemctl is-active xray >/dev/null 2>&1 && xray_status="${GREEN}ACTIVE${NC} (v$xray_ver)" || xray_status="${RED}OFF${NC} (v$xray_ver)"
            else
                systemctl is-active xray >/dev/null 2>&1 && xray_status="${GREEN}ACTIVE${NC}" || xray_status="${RED}OFF${NC}"
            fi
            
            local sub_status="${RED}OFF${NC}"
            systemctl is-active xray-sub >/dev/null 2>&1 && sub_status="${GREEN}ACTIVE${NC}"
            
            local hy2_status="${RED}OFF${NC}"
            systemctl is-active hysteria-server >/dev/null 2>&1 && hy2_status="${GREEN}ACTIVE${NC}"
            
            local warp_installed; warp_installed=$(get_installed_var "WARP_INSTALLED")
            local warp_enabled; warp_enabled=$(get_installed_var "WARP_ENABLED")
            local warp_mode; warp_mode=$(get_installed_var "WARP_MODE")
            [[ -z "$warp_mode" ]] && warp_mode="smart"
            
            local warp_status="${RED}NOT INSTALLED${NC}"
            if [[ "$warp_installed" == "true" ]]; then
                if [[ "$warp_enabled" == "true" ]]; then
                    if [[ "$warp_mode" == "full" ]]; then
                        warp_status="${GREEN}ON (FULL)${NC}"
                    else
                        warp_status="${GREEN}ON (SMART)${NC}"
                    fi
                else
                    warp_status="${YELLOW}DISABLED${NC}"
                fi
            fi

            local opera_installed; opera_installed=$(get_installed_var "OPERA_INSTALLED")
            local opera_enabled; opera_enabled=$(get_installed_var "OPERA_ENABLED")
            local opera_status="${RED}NOT INSTALLED${NC}"
            if [[ "$opera_installed" == "true" ]]; then
                if [[ "$opera_enabled" == "true" ]]; then
                    opera_status="${GREEN}ON${NC}"
                else
                    opera_status="${YELLOW}DISABLED${NC}"
                fi
            fi

            local ssl_badge="${RED}ОТСУТСТВУЕТ${NC}"
            if [[ -f "$SSL_DIR/fullchain.cer" ]]; then
                local cert_end; cert_end=$(openssl x509 -enddate -noout -in "$SSL_DIR/fullchain.cer" 2>/dev/null | cut -d= -f2)
                local end_epoch; end_epoch=$(date -d "$cert_end" +%s 2>/dev/null || echo 0)
                local now_epoch; now_epoch=$(date +%s)
                if [[ -z "$cert_end" || "$end_epoch" -eq 0 ]]; then
                    ssl_badge="${YELLOW}Ошибка даты${NC}"
                else
                    local days_left=$(( (end_epoch - now_epoch) / 86400 ))
                    if (( days_left < 0 )); then
                        ssl_badge="${RED}ИСТЕК!${NC}"
                    elif (( days_left < 15 )); then
                        ssl_badge="${YELLOW}Истекает ($days_left дн.)${NC}"
                    else
                        ssl_badge="${GREEN}OK ($days_left дн.)${NC}"
                    fi
                fi
            fi

            ui_header "🖥️  СТАТУС СЕРВЕРА"
            ui_status "🌐" "Сервер" "${GREEN}$domain${NC} | SSL: [$ssl_badge]"
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
            read -r -p " Выберите отпечаток (1-10): " fp_choice
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

        ssl_and_domain_menu() {
            local current_domain; current_domain=$(get_installed_var "DOMAIN")
            local ssl_status="${RED}ОТСУТСТВУЕТ${NC}"
            local end_date="неизвестно"
            local days_left=0
            if [[ -f "$SSL_DIR/fullchain.cer" ]]; then
                end_date=$(openssl x509 -enddate -noout -in "$SSL_DIR/fullchain.cer" 2>/dev/null | cut -d= -f2)
                local end_epoch; end_epoch=$(date -d "$end_date" +%s 2>/dev/null || echo 0)
                local now_epoch; now_epoch=$(date +%s)
                days_left=$(( (end_epoch - now_epoch) / 86400 ))
                if (( days_left < 0 )); then
                    ssl_status="${RED}ИСТЕК (${days_left#-} дн. назад)!${NC}"
                elif (( days_left < 15 )); then
                    ssl_status="${YELLOW}ИСТЕКАЕТ СКОРО ($days_left дн. осталось)${NC}"
                else
                    ssl_status="${GREEN}АКТИВЕН ($days_left дн. осталось)${NC}"
                fi
            fi

            ui_header "🔐  УПРАВЛЕНИЕ SSL-СЕРТИФИКАТОМ И ДОМЕНОМ"
            ui_item "" "🌐 Текущий домен: ${GREEN}$current_domain${NC}"
            ui_item "" "📜 Статус сертификата: $ssl_status"
            ui_item "" "📅 Срок действия до: ${YELLOW}$end_date${NC}"
            ui_divider
            ui_item "1" "🔄 Принудительно обновить SSL-сертификат прямо сейчас"
            ui_item "2" "🧪 Проверить автопродление (Dry-run тест)"
            ui_item "3" "🌐 Сменить основной домен (с перевыпуском SSL)"
            ui_item "0" "↩️ Вернуться в главное меню" "${CYAN}"
            ui_footer
            
            read -r -p " Выберите действие (0-3): " dchoice
            case $dchoice in
                0) main_menu ;;
                1)
                    renew_ssl_certificate --force
                    echo -e "\nНажмите Enter для возврата в меню..."
                    read -r
                    ssl_and_domain_menu
                    ;;
                2)
                    test_ssl_renewal
                    ssl_and_domain_menu
                    ;;
                3)
                    echo -e "\n${BOLD}--- Смена основного домена ---${NC}"
                    echo -e "Для смены домена потребуется перевыпустить SSL сертификат."
                    echo -e "Убедитесь, что новый домен направлен A-записью на IP вашего сервера."
                    read -r -p "Введите новый домен (например, vless.mydomain.com): " new_domain
                    new_domain=$(echo "$new_domain" | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//' -e 's|^https\?://||' -e 's|/.*$||' -e 's|:.*$||')
                    if [[ -z "$new_domain" ]]; then
                        echo -e "${RED}❌ Домен не может быть пустым.${NC}"
                        sleep 1
                        ssl_and_domain_menu
                        return
                    fi
                    if [[ "$new_domain" == "$current_domain" ]]; then
                        echo -e "${YELLOW}Этот домен уже является основным.${NC}"
                        sleep 1
                        ssl_and_domain_menu
                        return
                    fi
                    
                    # Проверим резолв нового домена
                    local DOMAIN="$new_domain"
                    check_domain
                    
                    # Временно остановим xray, чтобы освободить 80 порт для certbot
                    echo "🛑 Останавливаем службы для перевыпуска SSL..."
                    systemctl stop xray 2>/dev/null || true
                    
                    local EMAIL; EMAIL=$(get_installed_var "EMAIL")
                    echo "🔐 Запуск Certbot для получения нового сертификата..."
                    if certbot certonly --standalone -d "$new_domain" --email "$EMAIL" --agree-tos --non-interactive --key-type ecdsa; then
                        log_info "Requested SSL certificate for $new_domain"
                        echo "✅ SSL-сертификат получен успешно!"
                        
                        # Копируем сертификаты
                        mkdir -p "$SSL_DIR"
                        cp -f "/etc/letsencrypt/live/$new_domain/fullchain.pem" "$SSL_DIR/fullchain.cer"
                        cp -f "/etc/letsencrypt/live/$new_domain/privkey.pem" "$SSL_DIR/private.key"
                        
                        chown -R nobody:nogroup "$SSL_DIR"
                        chmod 755 "$SSL_DIR"
                        chmod 644 "$SSL_DIR/fullchain.cer"
                        chmod 600 "$SSL_DIR/private.key"
                        
                        # Удаляем старый сертификат из certbot, чтобы не засорять автопродление
                        if [[ -n "$current_domain" && "$current_domain" != "$new_domain" ]]; then
                            certbot delete --cert-name "$current_domain" --non-interactive 2>/dev/null || true
                        fi

                        setup_cert_renew_hook
                        
                        # Обновляем маркер
                        update_marker_val "DOMAIN" "$new_domain"
                        
                        # Обновляем конфигурации
                        DOMAIN="$new_domain"
                        NUM_DEVICES=$(get_installed_var "NUM_DEVICES")
                        generate_server_config
                        generate_hysteria_config
                        setup_subscription_server
                        generate_client_configs
                        install_generate_script
                        systemctl restart hysteria-server 2>/dev/null || true
                        
                        echo -e "${GREEN}✅ Основной домен успешно изменен на $new_domain!${NC}"
                        sleep 2
                    else
                        echo -e "${RED}❌ Не удалось перевыпустить SSL-сертификат для $new_domain.${NC}"
                        echo "Возвращаем запуск Xray с прежним доменом..."
                        systemctl start xray 2>/dev/null || true
                        sleep 2
                    fi
                    ssl_and_domain_menu
                    ;;
                *)
                    echo -e "${RED}❌ Неверный выбор!${NC}"
                    sleep 1
                    ssl_and_domain_menu
                    ;;
            esac
        }

        reality_management_menu() {
            local reality_enabled; reality_enabled=$(get_installed_var "REALITY_ENABLED")
            local reality_sni; reality_sni=$(get_installed_var "REALITY_SNI")
            [[ -z "$reality_sni" ]] && reality_sni="max.ru"
            local reality_dest; reality_dest=$(get_installed_var "REALITY_DEST")
            [[ -z "$reality_dest" ]] && reality_dest="max.ru:443"

            ui_header "🛡️  МАСКИРОВКА ТРАФИКА (VLESS-REALITY)"
            local status_text="${RED}Выключена${NC}"
            [[ "$reality_enabled" == "true" ]] && status_text="${GREEN}Активна${NC}"
            ui_item "" "Текущий статус: $status_text"
            ui_item "" "Маскировочный SNI: ${CYAN}$reality_sni${NC}"
            ui_item "" "Адрес назначения (DEST): ${CYAN}$reality_dest${NC}"
            ui_divider
            if [[ "$reality_enabled" == "true" ]]; then
                ui_item "1" "📴 Отключить маскировку Reality (возврат к прямому VLESS-TLS)"
            else
                ui_item "1" "🛡️ Включить маскировку Reality (маскироваться под $reality_sni)"
            fi
            ui_item "2" "⚙️ Изменить маскировочный сайт (SNI и DEST)"
            ui_item "0" "↩️ Вернуться в главное меню" "${CYAN}"
            ui_footer

            read -r -p " Выберите действие (0-2): " rchoice
            case $rchoice in
                0) main_menu ;;
                1)
                    if [[ "$reality_enabled" == "true" ]]; then
                        echo "📴 Отключение маскировки Reality..."
                        update_marker_val "REALITY_ENABLED" "false"
                    else
                        echo "🛡️ Включение маскировки Reality..."
                        update_marker_val "REALITY_ENABLED" "true"
                        # Инициализируем дефолты если пусты
                        if [[ -z "$(get_installed_var "REALITY_SNI")" ]]; then
                            update_marker_val "REALITY_SNI" "max.ru"
                        fi
                        if [[ -z "$(get_installed_var "REALITY_DEST")" ]]; then
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
                    read -r -p " SNI (по умолчанию max.ru): " new_sni
                    new_sni=$(echo "$new_sni" | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//' -e 's/\/$//')
                    [[ -z "$new_sni" ]] && new_sni="max.ru"

                    echo "Введите адрес назначения (по умолчанию $new_sni:443):"
                    read -r -p " DEST (по умолчанию $new_sni:443): " new_dest
                    new_dest=$(echo "$new_dest" | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//' -e 's/\/$//')
                    [[ -z "$new_dest" ]] && new_dest="$new_sni:443"

                    update_marker_val "REALITY_SNI" "$new_sni"
                    update_marker_val "REALITY_DEST" "$new_dest"

                    echo -e "${GREEN}✅ Настройки изменены на SNI: $new_sni | DEST: $new_dest${NC}"
                    
                    # Если Reality уже включен, пересоберем
                    if [[ "$(get_installed_var "REALITY_ENABLED")" == "true" ]]; then
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

        manage_provider_id() {
            ui_header "🔑 УПРАВЛЕНИЕ PROVIDER ID"
            local current_pid; current_pid=$(get_installed_var "PROVIDER_ID")
            if [[ -z "$current_pid" ]]; then
                echo -e " Текущий статус: ${RED}Не установлен${NC}"
            else
                echo -e " Текущий статус: ${GREEN}${current_pid}${NC}"
            fi
            ui_divider
            ui_item "1" "✏️ Указать / Изменить Provider ID"
            ui_item "2" "🗑️ Удалить Provider ID"
            ui_item "0" "⬅️ Вернуться в главное меню"
            ui_footer
            read -r -p " Выберите действие (0-2): " pid_choice
            case $pid_choice in
                1)
                    read -r -p " Введите ваш Provider ID с happ-proxy.com: " new_pid
                    if [[ -n "$new_pid" ]]; then
                        update_marker_val "PROVIDER_ID" "$new_pid"
                        echo -e "${GREEN}✅ Provider ID успешно сохранен!${NC}"
                        systemctl restart xray-sub >/dev/null 2>&1
                        log_info "Restarted Xray Subscription service"
                    else
                        echo -e "${RED}❌ Пустое значение!${NC}"
                    fi
                    sleep 1.5
                    manage_provider_id
                    ;;
                2)
                    update_marker_val "PROVIDER_ID" ""
                    echo -e "${GREEN}✅ Provider ID удален!${NC}"
                    systemctl restart xray-sub >/dev/null 2>&1
                    sleep 1.5
                    manage_provider_id
                    ;;
                0)
                    main_menu
                    ;;
                *)
                    echo -e "${RED}❌ Неверный выбор!${NC}"
                    sleep 1
                    manage_provider_id
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
            ui_item "6" "📊 Мониторинг active-соединений (порты 443 / 8443)"
            ui_item "7" "🛠️ Запустить полную диагностику системы (Troubleshooting)"
            ui_divider
            ui_item "8" "🔧 Оптимизация VPS (Xanmod ядро, BBR, RPS, Sysctl, ZRAM)"
            ui_item "9" "🔄 Обновить скрипт с GitHub и применить новые фиксы"
            ui_item "10" "🌐 Изменить отпечаток TLS (Fingerprint)"
            ui_item "11" "🔐 Управление SSL-сертификатом и доменом"
            ui_item "12" "🔑 Управление Provider ID (happ-proxy.com)"
            ui_divider
            ui_item_color "13" "${RED}🗑️ Полностью удалить всю установку Xray с сервера${NC}" "${RED}" "${CYAN}"
            ui_item "14" "🚪 Выйти из терминала" "${CYAN}"
            ui_footer
            read -r -p " Выберите действие (1-14): " choice
            case $choice in
                1) "$GENERATE_SCRIPT" ; main_menu ;;
                2) add_client ; main_menu ;;
                3) remove_client ; main_menu ;;
                4) bypass_menu ;;
                5) show_logs ; main_menu ;;
                6) show_connections ; main_menu ;;
                7) run_diagnostics ; main_menu ;;
                8) optimize_vps ;;
                9) 
                    echo -e "\n${BOLD}${GREEN}🔄 Загрузка последней версии скрипта...${NC}"
                    cd /root || exit
                    curl -fsSL --connect-timeout 10 -o install_xray.sh -L "https://raw.githubusercontent.com/mvrvntn/xray-vless-install/main/install_xray.sh?v=$RANDOM" && chmod +x install_xray.sh
                    echo -e "${GREEN}✅ Скрипт обновлен! Применяем обновления ядра и конфигурации...${NC}"
                    /root/install_xray.sh --update-core
                    exit 0
                    ;;
                10) change_fingerprint ; main_menu ;;
                11) ssl_and_domain_menu ;;
                12) manage_provider_id ;;
                13) 
                    echo -e "\n${BOLD}${RED}⚠️ ВНИМАНИЕ! Это действие удалит Xray, все конфигурации, WARP и Opera Proxy!${NC}"
                    read -r -p "Вы уверены? (y/n): " uconf
                    if [[ "$uconf" =~ ^[Yy]$ ]]; then
                        uninstall_all
                    else
                        main_menu
                    fi
                    ;;
                14) exit 0 ;;
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
            local script_path; script_path=$(realpath "$0")
            if crontab -l 2>/dev/null | grep -q 'update-geoblocks'; then
                echo "📴 Отключение автообновления геоблокировок..."
                (crontab -l 2>/dev/null | grep -v 'update-geoblocks') | crontab -
                echo -e "${GREEN}✅ Автообновление отключено${NC}"
            else
                echo "🔄 Включение автообновления геоблокировок..."
                (crontab -l 2>/dev/null | grep -v 'update-geoblocks'; echo "30 3 * * * bash \"$script_path\" --update-geoblocks >/dev/null 2>&1") | crontab -
                echo -e "${GREEN}✅ Автообновление включено (ежедневно в 03:30)${NC}"
            fi
            sleep 1.5
        }

        bypass_menu() {
            local warp_installed; warp_installed=$(get_installed_var "WARP_INSTALLED")
            local warp_enabled; warp_enabled=$(get_installed_var "WARP_ENABLED")
            local warp_mode; warp_mode=$(get_installed_var "WARP_MODE")
            [[ -z "$warp_mode" ]] && warp_mode="smart"

            local opera_installed; opera_installed=$(get_installed_var "OPERA_INSTALLED")
            local opera_enabled; opera_enabled=$(get_installed_var "OPERA_ENABLED")

            ui_header "🌀  УПРАВЛЕНИЕ ОБХОДАМИ БЛОКИРОВОК" "${PURPLE}"
            
            # Секция Cloudflare WARP
            ui_item_color "" "${BOLD}[ Cloudflare WARP ]${NC}" "" "${PURPLE}"
            if [[ "$warp_installed" != "true" ]]; then
                ui_item_color "" "Статус: ${RED}Не установлен${NC}" "" "${PURPLE}"
                ui_item_color "1" "📥 Установить и активировать Cloudflare WARP" "${YELLOW}" "${PURPLE}"
            else
                local warp_status="${RED}Выключен${NC}"
                [[ "$warp_enabled" == "true" ]] && warp_status="${GREEN}Активен${NC}"
                local mode_text="${CYAN}Smart-обход${NC}"
                [[ "$warp_mode" == "full" ]] && mode_text="${PURPLE}Full-обход (весь трафик)${NC}"
                ui_item_color "" "Статус: $warp_status | Режим: $mode_text" "" "${PURPLE}"
                if [[ "$warp_enabled" == "true" ]]; then
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
            
            if [[ "$opera_installed" != "true" ]]; then
                ui_item_color "" "Статус: ${RED}Не установлен${NC}" "" "${PURPLE}"
                ui_item_color "7" "📥 Установить и активировать Opera Proxy" "${YELLOW}" "${PURPLE}"
            else
                local opera_status="${RED}Выключен${NC}"
                [[ "$opera_enabled" == "true" ]] && opera_status="${GREEN}Активен${NC}"
                ui_item_color "" "Статус: $opera_status" "" "${PURPLE}"
                if [[ "$opera_enabled" == "true" ]]; then
                    ui_item_color "7" "📴 Отключить Opera Proxy" "${YELLOW}" "${PURPLE}"
                else
                    ui_item_color "7" "🌀 Включить Opera Proxy" "${YELLOW}" "${PURPLE}"
                fi
                ui_item_color "8" "📝 Редактировать список доменов Opera Proxy" "${YELLOW}" "${PURPLE}"
                ui_item_color "9" "${RED}🗑️ Удалить Opera Proxy${NC}" "${RED}" "${PURPLE}"
            fi
            
            ui_divider "${PURPLE}"
            ui_item_color "" "${BOLD}[ Настройки подписки ]${NC}" "" "${PURPLE}"
            local routing_enabled; routing_enabled=$(get_installed_var "ROUTING_ENABLED")
            [[ -z "$routing_enabled" ]] && routing_enabled="true"
            local routing_status="${RED}Отключена${NC}"
            [[ "$routing_enabled" == "true" ]] && routing_status="${GREEN}Включена${NC}"
            ui_item_color "" "Передача маршрутов (Routing): $routing_status" "" "${PURPLE}"
            if [[ "$routing_enabled" == "true" ]]; then
                ui_item_color "10" "📴 Отключить передачу маршрутов в клиенты" "${YELLOW}" "${PURPLE}"
            else
                ui_item_color "10" "🌀 Включить передачу маршрутов в клиенты" "${YELLOW}" "${PURPLE}"
            fi
            
            ui_divider "${PURPLE}"
            ui_item_color "0" "↩️ Назад в главное меню" "${CYAN}" "${PURPLE}"
            ui_footer "${PURPLE}"
            
            read -r -p " Выберите действие (0-10): " bchoice
            case $bchoice in
                0)
                    main_menu
                    ;;
                1)
                    if [[ "$warp_installed" != "true" ]]; then
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
                    if [[ "$warp_installed" == "true" ]]; then
                        echo -e "\n${BOLD}Выберите новый режим исходящего трафика:${NC}"
                        echo -e " ${BOLD}${YELLOW}1.${NC} Smart-обход"
                        echo -e " ${BOLD}${YELLOW}2.${NC} Full-обход"
                        read -r -p "Режим (1-2): " mchoice
                        if [[ "$mchoice" == "1" ]]; then
                            update_marker_val "WARP_MODE" "smart"
                            echo -e "${GREEN}✅ Режим изменен на Smart-обход${NC}"
                        elif [[ "$mchoice" == "2" ]]; then
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
                    if [[ "$warp_installed" == "true" ]]; then
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
                    if [[ "$warp_installed" == "true" ]]; then
                        toggle_warp_auto_update
                    else
                        echo -e "${RED}❌ Установите WARP сначала!${NC}"
                    fi
                    bypass_menu
                    ;;
                5)
                    if [[ "$warp_installed" == "true" ]]; then
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
                    if [[ "$warp_installed" == "true" ]]; then
                        uninstall_warp
                    else
                        echo -e "${RED}❌ Установите WARP сначала!${NC}"
                    fi
                    bypass_menu
                    ;;
                7)
                    if [[ "$opera_installed" != "true" ]]; then
                        install_opera_proxy
                    else
                        toggle_opera_proxy
                    fi
                    sleep 1.5
                    bypass_menu
                    ;;
                8)
                    if [[ "$opera_installed" == "true" ]]; then
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
                    if [[ "$opera_installed" == "true" ]]; then
                        uninstall_opera_proxy
                    else
                        echo -e "${RED}❌ Установите Opera Proxy сначала!${NC}"
                    fi
                    sleep 1.5
                    bypass_menu
                    ;;
                10)
                    local current_status; current_status=$(get_installed_var "ROUTING_ENABLED")
                    if [[ "$current_status" == "false" ]]; then
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

            [[ -n "${XRAY_CONFIG_DIR:-}" ]] && rm -rf -- "$XRAY_CONFIG_DIR"
            [[ -n "${CLIENT_CONFIG_DIR:-}" ]] && rm -rf -- "$CLIENT_CONFIG_DIR"
            [[ -n "${SSL_DIR:-}" ]] && rm -rf -- "$SSL_DIR"
            [[ -n "${GENERATE_SCRIPT:-}" ]] && rm -f -- "$GENERATE_SCRIPT"
            rm -f /var/log/xray/{access.log,error.log}
            if crontab -l &>/dev/null; then
                crontab -l | grep -v "certbot renew" | crontab -
            fi
            rm -f /usr/local/bin/xray-cert-renew.sh
            rm -f /etc/letsencrypt/renewal-hooks/deploy/xray-cert-renew.sh
            systemctl stop hysteria-server >/dev/null 2>&1
            systemctl disable hysteria-server >/dev/null 2>&1
            rm -f /etc/systemd/system/hysteria-server.service
            rm -rf -- /etc/hysteria
            rm -f /usr/local/bin/hysteria
            systemctl daemon-reload >/dev/null 2>&1

            ufw delete allow 443/tcp > /dev/null
            ufw delete allow 8443/tcp > /dev/null
            ufw delete allow 443/udp > /dev/null
            ufw delete allow 80/tcp > /dev/null
            rm -f "$MARKER_FILE"
            echo "✅ Удалено"
        }

        echo "⚠️ Xray уже установлен"
        
        # Самодиагностика и исправление пустых/отсутствующих UUID
        repaired=false
        if [[ -d "$CLIENT_CONFIG_DIR" ]] && [[ "$(find "$CLIENT_CONFIG_DIR" -name '*.json' 2>/dev/null | wc -l)" -gt 0 ]]; then
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

            if [[ -n "$repair_output" ]]; then
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

        if [[ "$repaired" = true ]]; then
            echo "🔄 Пересборка конфигурации сервера после исправления..."
            DOMAIN=$(get_installed_var "DOMAIN")
            NUM_DEVICES=$(get_installed_var "NUM_DEVICES")
            generate_server_config
            generate_hysteria_config
            install_generate_script
            echo "✅ Восстановление успешно завершено!"
        fi

        if [[ "$1" != "--update-core" ]] && [[ "$1" != "--update-geoblocks" ]]; then
            main_menu
            exit 0
        fi
    fi

    # === Логгирование ===
    mkdir -p /var/log/xray
    exec > >(tee -a "$INSTALL_LOG") 2>&1

    # === Обработка флага автоматического обновления геоблокировок ===
    if [[ "$1" == "--update-geoblocks" ]]; then
        update_geoblock_list
        DOMAIN=$(get_installed_var "DOMAIN")
        NUM_DEVICES=$(get_installed_var "NUM_DEVICES")
        if [[ -n "$DOMAIN" ]] && [[ -n "$NUM_DEVICES" ]]; then
            generate_server_config
            echo "✅ Конфигурация Xray перегенерирована."
        fi
        exit 0
    fi

    # === Обработка флага обновления ядра (update) ===
    if [[ "$1" == "--update-core" ]]; then
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
        setup_cert_renew_hook
        if [[ -f "$SSL_DIR/fullchain.cer" ]]; then
            if ! openssl x509 -checkend 86400 -noout -in "$SSL_DIR/fullchain.cer" 2>/dev/null; then
                echo "⚠️ Обнаружен истекший или заканчивающийся SSL-сертификат, обновляем..."
                renew_ssl_certificate --force || true
            fi
        fi
        echo "✅ Сервер успешно обновлен до последней версии! Можете вызвать xry для проверки."
        exit 0
    fi

    # === Обработка флага headless ===
    if [[ "$1" == "--headless" ]]; then
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
        for ((i=1; i<=NUM_DEVICES; i++)); do
            if [[ -n "$1" ]]; then
                DEVICE_NAMES[i]="$1"
                shift
            else
                DEVICE_NAMES[i]="client_$i"
            fi
        done
    else
        echo -e "\n${BOLD}${CYAN}🚀  УСТАНОВКА XRAY VLESS СЕРВЕРА${NC}"
        echo -e "${CYAN}──────────────────────────────────────────────────────────${NC}"
        echo -e " Добро пожаловать! Давайте настроим ваш новый VPN-сервер."
        echo -e "${CYAN}──────────────────────────────────────────────────────────${NC}"
        
        if [[ ! -f "$MARKER_FILE" ]]; then
            echo -e "\n ${BOLD}${YELLOW}ОПТИМИЗАЦИЯ VPS${NC}"
            read -r -p " Выполнить оптимизацию VPS (Sysctl, BBR, RPS, ZRAM, лимиты сети)? [y/N]: " opt_choice
            if [[ "$opt_choice" =~ ^[Yy]$ ]]; then
                optimize_vps
            fi
            echo -e "${CYAN}──────────────────────────────────────────────────────────${NC}"
        fi
        
        # 1. Ввод домена с валидацией
        while true; do
            echo -e " ${BOLD}${YELLOW}Шаг 1 из 4:${NC} Укажите ваш домен"
            read -r -p " 🌐 Введите домен (например, sub.domain.com): " DOMAIN
            DOMAIN=$(echo "$DOMAIN" | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//' -e 's|^https\?://||' -e 's|/.*$||' -e 's|:.*$||')
            if [[ -n "$DOMAIN" ]]; then
                break
            fi
            echo -e " ${RED}❌ Домен не может быть пустым. Пожалуйста, укажите валидный домен.${NC}"
        done
        
        # 2. Ввод Email с валидацией
        while true; do
            echo -e "\n ${BOLD}${YELLOW}Шаг 2 из 4:${NC} Укажите Email для SSL-сертификата Let's Encrypt"
            read -r -p " 📧 Email: " EMAIL
            EMAIL=$(echo "$EMAIL" | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//')
            if [[ "$EMAIL" =~ ^[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}$ ]]; then
                break
            fi
            echo -e " ${RED}❌ Некорректный формат Email. Попробуйте еще раз (например: myemail@mail.com).${NC}"
        done
        
        # 3. Ввод количества устройств с валидацией
        while true; do
            echo -e "\n ${BOLD}${YELLOW}Шаг 3 из 4:${NC} Сколько клиентских устройств добавить?"
            read -r -p " 📱 Количество устройств: " NUM_DEVICES
            if [[ "$NUM_DEVICES" =~ ^[1-9][0-9]*$ ]]; then
                break
            fi
            echo -e " ${RED}❌ Пожалуйста, введите положительное целое число.${NC}"
        done
        
        echo -e "\n ${BOLD}${YELLOW}Шаг 4 из 4:${NC} Задайте имена для ваших устройств"
        DEVICE_NAMES=()
        for ((i=1; i<=NUM_DEVICES; i++)); do
            read -r -p " 👤 Имя для устройства $i (по умолчанию client_$i): " dev_name
            dev_name=$(echo "$dev_name" | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//')
            if [[ -z "$dev_name" ]]; then
                DEVICE_NAMES[i]="client_$i"
            else
                DEVICE_NAMES[i]="$dev_name"
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

}

main "$@"
