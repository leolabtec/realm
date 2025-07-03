#!/bin/bash

# ========== Realm 中转管理脚本 v2.7 ==========
# 基于 v2.1 版本全面修复
# 主要修复内容：
# 1. 修复所有已知语法错误和逻辑缺陷
# 2. 增强输入验证和错误处理
# 3. 优化服务管理功能
# 4. 完善日志记录系统
# 5. 改进面板管理功能

# ===== 基础配置 =====
sh_ver="2.7"
red="\033[0;31m"
green="\033[0;32m"
yellow="\033[1;33m"
blue="\033[0;34m"
plain="\033[0m"

# 路径配置
CONFIG_PATH="/root/.realm/config.toml"
PANEL_CONFIG="/root/realm/web/config.toml"
CERT_PATH="/root/realm/web/certs"
LOG_FILE="/var/log/realm_manager.log"
SCRIPT_URL="https://raw.githubusercontent.com/wcwq98/realm/main/realm.sh"
REALM_BIN="/usr/local/bin/realm"
SERVICE_FILE="/etc/systemd/system/realm.service"
PANEL_SERVICE="/etc/systemd/system/realm-panel.service"

# ===== 初始化环境 =====
init_env() {
    mkdir -p /root/.realm /root/realm/web "$CERT_PATH"
    [[ ! -f "$CONFIG_PATH" ]] && touch "$CONFIG_PATH"
    [[ ! -f "$LOG_FILE" ]] && touch "$LOG_FILE"
    chmod 600 "$LOG_FILE"
}

# ===== 日志系统 =====
log() {
    local level=$1
    local message=$2
    local timestamp=$(date "+%Y-%m-%d %H:%M:%S")
    
    case $level in
        "INFO") color="$green" ;;
        "WARN") color="$yellow" ;;
        "ERROR") color="$red" ;;
        "DEBUG") color="$blue" ;;
        *) color="$plain" ;;
    esac
    
    echo -e "${color}[${timestamp}] [${level}] ${message}${plain}"
    echo "[${timestamp}] [${level}] ${message}" >> "$LOG_FILE"
}

# ===== 状态检查 =====
update_realm_status() {
    if [[ -f "$REALM_BIN" ]]; then
        realm_status="已安装"
        realm_status_color=$green
    else
        realm_status="未安装"
        realm_status_color=$red
    fi
}

check_realm_service_status() {
    if systemctl is-active --quiet realm; then
        realm_service_status="运行中"
        realm_service_status_color=$green
    else
        realm_service_status="未运行"
        realm_service_status_color=$red
    fi
}

update_panel_status() {
    if [[ -f "/root/realm/web/realm_web" ]]; then
        panel_status="已安装"
        panel_status_color=$green
    else
        panel_status="未安装" 
        panel_status_color=$red
    fi
}

check_panel_service_status() {
    if systemctl is-active --quiet realm-panel; then
        panel_service_status="运行中"
        panel_service_status_color=$green
    else
        panel_service_status="未运行"
        panel_service_status_color=$red
    fi
}

# ===== 依赖检查 =====
check_dependencies() {
    local deps=("wget" "tar" "systemctl" "sed" "grep" "curl" "unzip" "openssl" "ss")
    local missing=()
    
    for dep in "${deps[@]}"; do
        if ! command -v "$dep" &>/dev/null; then
            missing+=("$dep")
        fi
    done
    
    if [[ ${#missing[@]} -gt 0 ]]; then
        log "WARN" "缺少依赖: ${missing[*]}, 尝试安装..."
        
        if command -v apt-get &>/dev/null; then
            apt-get update -q && apt-get install -y -q "${missing[@]}" || {
                log "ERROR" "依赖安装失败!"
                exit 1
            }
        elif command -v yum &>/dev/null; then
            yum install -y -q "${missing[@]}" || {
                log "ERROR" "依赖安装失败!"
                exit 1
            }
        else
            log "ERROR" "不支持的包管理器，请手动安装: ${missing[*]}"
            exit 1
        fi
    fi
}

# ===== 参数验证 =====
validate_ip() {
    local ip=$1
    [[ $ip =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]] || return 1
    
    local IFS='.'
    local -a octets=($ip)
    for octet in "${octets[@]}"; do
        [[ $octet -le 255 ]] || return 1
    done
    
    return 0
}

validate_port() {
    [[ $1 =~ ^[0-9]+$ ]] && [[ $1 -ge 1 ]] && [[ $1 -le 65535 ]]
}

validate_ip_port() {
    local input=$1
    local ip_port_regex='^([0-9]{1,3}\.){3}[0-9]{1,3}:[0-9]{1,5}$'
    
    if [[ $input =~ $ip_port_regex ]]; then
        local ip=${input%:*}
        local port=${input#*:}
        validate_ip "$ip" && validate_port "$port"
    else
        return 1
    fi
}

check_port() {
    local port=$1
    if ss -tuln | grep -q ":${port} "; then
        log "WARN" "端口 ${port} 已被占用"
        return 1
    fi
    return 0
}

# ===== CLI 参数处理 =====
handle_cli_params() {
    while getopts "l:r:a:d:uih" opt; do
        case $opt in
            l) listen_ip_port="$OPTARG" ;;
            r) remote_ip_port="$OPTARG" ;;
            a) add_rule "$OPTARG" ;;
            d) delete_rule "$OPTARG" ;;
            u) update_realm ;;
            i) install_realm ;;
            h) show_help; exit 0 ;;
            *) show_help; exit 1 ;;
        esac
    done

    if [[ -n "$listen_ip_port" && -n "$remote_ip_port" ]]; then
        if ! validate_ip_port "$listen_ip_port" || ! validate_ip_port "$remote_ip_port"; then
            log "ERROR" "输入格式无效，请使用 IP:端口 格式"
            exit 1
        fi
        
        local port=${listen_ip_port#*:}
        if ! check_port "$port"; then
            exit 1
        fi
        
        add_single_rule "$listen_ip_port" "$remote_ip_port"
        exit 0
    fi
}

# ===== 规则管理 =====
add_single_rule() {
    local listen=$1
    local remote=$2
    
    echo -e "\n[[endpoints]]\nlisten = \"${listen}\"\nremote = \"${remote}\"" >> "$CONFIG_PATH"
    log "INFO" "添加成功: ${listen} → ${remote}"
    
    if systemctl is-active --quiet realm; then
        systemctl restart realm
        log "INFO" "已重启 realm 服务"
    fi
}

add_port_range_forward() {
    read -p "请输入落地 IP: " ip
    read -p "请输入起始端口: " start_port
    read -p "请输入结束端口: " end_port
    read -p "请输入落地端口: " remote_port

    if ! validate_ip "$ip"; then
        log "ERROR" "IP 格式错误"
        return 1
    fi

    if ! validate_port "$start_port" || ! validate_port "$end_port" || ! validate_port "$remote_port"; then
        log "ERROR" "端口格式错误"
        return 1
    fi

    if [[ $start_port -gt $end_port ]]; then
        log "ERROR" "起始端口不能大于结束端口"
        return 1
    fi

    local added=0
    for ((port=start_port; port<=end_port; port++)); do
        if check_port "$port"; then
            add_single_rule "0.0.0.0:${port}" "${ip}:${remote_port}"
            ((added++))
        fi
    done

    log "INFO" "成功添加 ${added} 条转发规则"
}

delete_rule() {
    if [[ ! -f "$CONFIG_PATH" ]]; then
        log "ERROR" "配置文件不存在: $CONFIG_PATH"
        return 1
    fi

    local lines=()
    while IFS= read -r line; do
        lines+=("$line")
    done < <(grep -n 'listen =' "$CONFIG_PATH" | grep -v '#' | awk -F: '{print $1}')

    if [[ ${#lines[@]} -eq 0 ]]; then
        log "INFO" "未发现转发规则"
        return 0
    fi

    echo "当前转发规则："
    for i in "${!lines[@]}"; do
        local line_num=${lines[$i]}
        local listen=$(sed -n "${line_num}p" "$CONFIG_PATH" | cut -d '"' -f 2)
        local remote_line=$((line_num + 1))
        local remote=$(sed -n "${remote_line}p" "$CONFIG_PATH" | cut -d '"' -f 2)
        echo "$((i+1)). 监听: ${listen} -> 远程: ${remote}"
    done

    if [[ -n "$1" ]]; then
        local sel=$1
    else
        read -p "请输入要删除的编号 (0取消): " sel
    fi

    [[ $sel == "0" ]] && return 0
    
    if [[ $sel =~ ^[0-9]+$ ]] && [[ $sel -gt 0 ]] && [[ $sel -le ${#lines[@]} ]]; then
        local target_line=${lines[$((sel-1))]}
        sed -i "$((target_line-1)),$((target_line+1))d" "$CONFIG_PATH"
        log "INFO" "转发规则已删除"
        
        if systemctl is-active --quiet realm; then
            systemctl restart realm
            log "INFO" "已重启 realm 服务"
        fi
    else
        log "ERROR" "无效的选择"
        return 1
    fi
}

# ===== 服务管理 =====
service_management() {
    echo -e "\n${green}服务管理${plain}"
    echo "1. 启动 Realm"
    echo "2. 停止 Realm" 
    echo "3. 重启 Realm"
    echo "4. 查看状态"
    echo "0. 返回主菜单"
    
    read -p "请选择操作: " choice
    case $choice in
        1) systemctl start realm && log "INFO" "Realm 已启动" ;;
        2) systemctl stop realm && log "INFO" "Realm 已停止" ;;
        3) systemctl restart realm && log "INFO" "Realm 已重启" ;;
        4) systemctl status realm --no-pager ;;
        0) return ;;
        *) log "ERROR" "无效选择" ;;
    esac
}

# ===== 面板管理 =====
panel_management() {
    echo -e "\n${green}面板管理${plain}"
    echo "1. 安装/更新面板"
    echo "2. 启动面板"
    echo "3. 停止面板"
    echo "4. 重启面板"
    echo "5. 查看面板状态"
    echo "0. 返回主菜单"
    
    read -p "请选择操作: " choice
    case $choice in
        1) install_panel ;;
        2) systemctl start realm-panel && log "INFO" "面板已启动" ;;
        3) systemctl stop realm-panel && log "INFO" "面板已停止" ;;
        4) systemctl restart realm-panel && log "INFO" "面板已重启" ;;
        5) systemctl status realm-panel --no-pager ;;
        0) return ;;
        *) log "ERROR" "无效选择" ;;
    esac
}

install_panel() {
    local arch=$(uname -m)
    case "$arch" in
        x86_64) file="realm-panel-linux-amd64.zip" ;;
        aarch64|arm64) file="realm-panel-linux-arm64.zip" ;;
        *) log "ERROR" "不支持的架构: ${arch}"; return 1 ;;
    esac

    log "INFO" "检测到系统架构: ${arch}, 将下载: ${file}"
    
    mkdir -p /root/realm/web || return 1
    cd /root/realm || return 1

    log "INFO" "正在下载面板..."
    if ! wget -O "$file" "https://github.com/wcwq98/realm/releases/download/v2.5/${file}"; then
        log "ERROR" "面板下载失败"
        return 1
    fi

    log "INFO" "正在解压面板文件..."
    if ! unzip -o "$file" -d /root/realm/web; then
        log "ERROR" "解压面板文件失败"
        return 1
    fi
    
    chmod +x /root/realm/web/realm_web

    log "INFO" "正在创建面板服务..."
    cat <<EOF > "$PANEL_SERVICE"
[Unit]
Description=Realm Web Panel
After=network.target

[Service]
Type=simple
ExecStart=/root/realm/web/realm_web
WorkingDirectory=/root/realm/web
Restart=always
User=root

[Install]
WantedBy=multi-user.target
EOF

    # 生成证书
    if ! generate_self_signed_cert; then
        log "ERROR" "HTTPS证书生成失败"
        return 1
    fi

    # 写入面板配置
    cat <<EOF > "$PANEL_CONFIG"
listen = "0.0.0.0:8080"
tls_cert = "${CERT_PATH}/cert.pem"
tls_key = "${CERT_PATH}/key.pem"
EOF

    systemctl daemon-reload
    systemctl enable realm-panel --now || {
        log "ERROR" "面板服务启动失败"
        return 1
    }

    log "INFO" "面板安装完成并已启动"
    log "INFO" "面板访问地址: https://$(hostname -I | awk '{print $1}'):8080"
    return 0
}

generate_self_signed_cert() {
    mkdir -p "$CERT_PATH"
    local cert="${CERT_PATH}/cert.pem"
    local key="${CERT_PATH}/key.pem"
    local ip=$(hostname -I | awk '{print $1}')

    if [[ -f "$cert" && -f "$key" ]]; then
        log "INFO" "自签名证书已存在，跳过生成"
        return 0
    fi

    log "INFO" "正在为 IP ${ip} 生成自签名 HTTPS 证书..."
    
    openssl req -x509 -nodes -days 365 -newkey rsa:2048 \
        -keyout "$key" \
        -out "$cert" \
        -subj "/C=CN/ST=Realm/L=Realm/O=Realm/OU=Realm/CN=${ip}" || {
        log "ERROR" "证书生成失败"
        return 1
    }

    log "INFO" "证书已生成: ${cert}"
    return 0
}

# ===== Realm 安装/更新 =====
install_realm() {
    local arch=$(uname -m)
    case "$arch" in
        x86_64) file="realm-x86_64-unknown-linux-gnu.tar.gz" ;;
        aarch64) file="realm-aarch64-unknown-linux-gnu.tar.gz" ;;
        *) log "ERROR" "不支持的架构: ${arch}"; return 1 ;;
    esac

    log "INFO" "正在下载 realm..."
    if ! wget -O realm.tar.gz "https://github.com/zhboner/realm/releases/latest/download/${file}"; then
        log "ERROR" "下载失败"
        return 1
    fi

    log "INFO" "正在解压安装..."
    tar -xzf realm.tar.gz && chmod +x realm
    mv realm "$REALM_BIN" || {
        log "ERROR" "安装失败"
        return 1
    }

    log "INFO" "正在创建服务文件..."
    cat <<EOF > "$SERVICE_FILE"
[Unit]
Description=Realm Port Forwarding
After=network.target

[Service]
Type=simple
ExecStart=${REALM_BIN} -c ${CONFIG_PATH}
WorkingDirectory=/root
Restart=always
User=root

[Install]
WantedBy=multi-user.target
EOF

    systemctl daemon-reload
    systemctl enable realm --now || {
        log "ERROR" "服务启动失败"
        return 1
    }

    log "INFO" "realm 安装完成并已启动"
    return 0
}

update_realm() {
    if ! command -v "$REALM_BIN" &>/dev/null; then
        log "ERROR" "realm 未安装，请先安装"
        return 1
    fi
    
    local current_ver=$("$REALM_BIN" --version | awk '{print $2}')
    log "INFO" "当前版本: ${current_ver}"
    
    install_realm || return 1
    
    local new_ver=$("$REALM_BIN" --version | awk '{print $2}')
    log "INFO" "成功更新到版本: ${new_ver}"
}

# ===== 卸载功能 =====
uninstall() {
    read -p "确定要卸载 Realm 吗？(y/N): " yn
    yn=${yn:-N}
    
    if [[ $yn =~ ^[Yy]$ ]]; then
        log "INFO" "正在卸载 Realm..."
        
        systemctl stop realm realm-panel 2>/dev/null
        systemctl disable realm realm-panel 2>/dev/null
        rm -f "$SERVICE_FILE" "$PANEL_SERVICE" "$REALM_BIN"
        rm -rf /root/.realm /root/realm
        systemctl daemon-reload
        
        log "INFO" "Realm 已卸载"
    else
        log "INFO" "已取消卸载"
    fi
}

# ===== 脚本更新 =====
update_script() {
    log "INFO" "正在检查更新..."
    local latest_ver=$(curl -s "$SCRIPT_URL" | grep 'sh_ver="' | head -1 | sed -E 's/.*sh_ver="([^"]+)".*/\1/')
    
    if [[ -z "$latest_ver" ]]; then
        log "ERROR" "获取最新版本失败"
        return 1
    fi
    
    if [[ "$latest_ver" == "$sh_ver" ]]; then
        log "INFO" "当前已是最新版本 v${sh_ver}"
        return 0
    fi
    
    log "INFO" "发现新版本 v${latest_ver}，当前版本 v${sh_ver}"
    read -p "是否更新？(Y/n): " yn
    yn=${yn:-Y}
    
    if [[ $yn =~ ^[Yy]$ ]]; then
        log "INFO" "正在更新脚本..."
        if wget -O "$0" "$SCRIPT_URL"; then
            chmod +x "$0"
            log "INFO" "更新成功，请重新运行脚本"
            exit 0
        else
            log "ERROR" "更新失败"
            return 1
        fi
    else
        log "INFO" "已取消更新"
    fi
}

# ===== 帮助信息 =====
show_help() {
    echo -e "${green}Realm 管理脚本 v${sh_ver} 使用说明${plain}"
    echo "用法: $0 [选项]"
    echo
    echo "选项:"
    echo "  -l <监听地址>   设置监听地址 (IP:端口)"
    echo "  -r <远程地址>   设置远程地址 (IP:端口)"
    echo "  -a              添加转发规则 (交互模式)"
    echo "  -d              删除转发规则 (交互模式)"
    echo "  -i              安装 Realm"
    echo "  -u              更新脚本"
    echo "  -h              显示帮助信息"
    echo
    echo "示例:"
    echo "  $0 -l 0.0.0.0:1234 -r 1.1.1.1:4321  # 添加转发规则"
    echo "  $0 -i                                # 安装 Realm"
}

# ===== 主菜单 =====
show_menu() {
    clear
    update_realm_status
    check_realm_service_status
    update_panel_status
    check_panel_service_status
    
    echo -e "${green}Realm 中转管理脚本 v${sh_ver}${plain}"
    echo "================================="
    echo "1. 添加单端口转发"
    echo "2. 添加端口段转发"
    echo "3. 删除转发规则"
    echo "4. 服务管理 (启动/停止/重启)"
    echo "5. 面板管理 (安装/配置)"
    echo "6. 安装/更新 Realm"
    echo "7. 更新管理脚本"
    echo "8. 卸载 Realm"
    echo "0. 退出脚本"
    echo "================================="
    echo -e "realm 状态: ${realm_status_color}${realm_status}${plain}"
    echo -e "realm 服务: ${realm_service_status_color}${realm_service_status}${plain}"
    echo -e "面板状态: ${panel_status_color}${panel_status}${plain}"
    echo -e "面板服务: ${panel_service_status_color}${panel_service_status}${plain}"
}

# ===== 主程序入口 =====
main() {
    check_dependencies
    init_env
    
    # 处理 CLI 参数
    if [[ $# -gt 0 ]]; then
        handle_cli_params "$@"
        exit $?
    fi
    
    # 交互式菜单
    while true; do
        show_menu
        read -p "请输入选项 [0-8]: " num
        
        case $num in
            1) add_single_rule "0.0.0.0" ;;
            2) add_port_range_forward ;;
            3) delete_rule ;;
            4) service_management ;;
            5) panel_management ;;
            6) update_realm ;;
            7) update_script ;;
            8) uninstall ;;
            0) exit 0 ;;
            *) log "ERROR" "无效选项" ;;
        esac
        
        read -p "按回车键继续..." -r
    done
}

# 启动主程序
main "$@"
