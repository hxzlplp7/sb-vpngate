#!/usr/bin/env bash
# -*- coding: utf-8 -*-

# ==============================================================================
# sb-vpngate 一键配置及管理脚本 (纯 Bash 豪华版，无 Python 依赖)
# 支持 sing-box 代理入站，及 VPN Gate/直连策略路由出站分流
# ==============================================================================

# 颜色定义
RED='\033[31;1m'
GREEN='\033[32;1m'
YELLOW='\033[33;1m'
BLUE='\033[34;1m'
CYAN='\033[36;1m'
PLAIN='\033[0m'

# 工作目录与配置文件路径
SB_DIR="/etc/sing-box"
ENV_FILE="${SB_DIR}/sb-vpngate.env"
TEMPLATE_FILE="${SB_DIR}/sb-config.json.template"
CONFIG_FILE="${SB_DIR}/config.json"
OPENVPN_DIR="/etc/openvpn"
VPNGATE_OVPN="${OPENVPN_DIR}/vpngate.ovpn"

# 输出辅助函数
info() { echo -e "${GREEN}[提示] $1${PLAIN}"; }
warn() { echo -e "${YELLOW}[警告] $1${PLAIN}"; }
err() { echo -e "${RED}[错误] $1${PLAIN}"; exit 1; }
cyan() { echo -e "${CYAN}$1${PLAIN}"; }

# 检查 root 权限
[[ $EUID -ne 0 ]] && err "请使用 root 权限运行此脚本！(例如: sudo bash $0)"

# 加载保存的环境变量
if [[ -f "$ENV_FILE" ]]; then
    source "$ENV_FILE"
fi

# 检查系统类型
detect_os() {
    if [[ -f /etc/redhat-release ]]; then
        release="centos"
    elif grep -q -E -i "debian" /etc/os-release; then
        release="debian"
    elif grep -q -E -i "ubuntu" /etc/os-release; then
        release="ubuntu"
    else
        err "当前脚本仅支持 Debian, Ubuntu 或 CentOS 系统。"
    fi
}

# 检查架构
detect_arch() {
    case $(uname -m) in
        x86_64) cpu="amd64" ;;
        aarch64) cpu="arm64" ;;
        armv7l) cpu="armv7" ;;
        *) err "目前脚本不支持 $(uname -m) CPU 架构。" ;;
    esac
}

# 动态生成挂载脚本文件，确保即使独立运行也能成功初始化
write_routing_scripts() {
    # 自动创建并修复 /dev/net/tun 设备节点
    if [[ ! -c /dev/net/tun ]]; then
        # 清除可能被错误创建的同名目录
        rm -rf /dev/net/tun 2>/dev/null
        mkdir -p /dev/net
        mknod /dev/net/tun c 10 200 2>/dev/null
        chmod 600 /dev/net/tun 2>/dev/null
    fi
    modprobe tun >/dev/null 2>&1

    # 写入 vpngate-up.sh
    cat << 'EOF' | tr -d '\r' > "${OPENVPN_DIR}/vpngate-up.sh"
#!/bin/bash
dev=$1
local_ip=$4
echo "[vpngate-up] 接口已启动: ${dev}, 本地分配 IP: ${local_ip}"
ip route flush table 1000 2>/dev/null
ip route add default dev "${dev}" table 1000
if ! ip rule show | grep -q "fwmark 0x3e8"; then
    ip rule add fwmark 1000 table 1000
    echo "[vpngate-up] 策略路由规则 fwmark 1000 -> table 1000 添加成功"
fi
iptables -t nat -D POSTROUTING -o "${dev}" -j MASQUERADE 2>/dev/null
iptables -t nat -A POSTROUTING -o "${dev}" -j MASQUERADE
echo "[vpngate-up] NAT MASQUERADE 规则添加成功"
exit 0
EOF
    chmod +x "${OPENVPN_DIR}/vpngate-up.sh"

    # 写入 vpngate-down.sh
    cat << 'EOF' | tr -d '\r' > "${OPENVPN_DIR}/vpngate-down.sh"
#!/bin/bash
dev=$1
echo "[vpngate-down] 接口已关闭: ${dev}，开始清理网络规则..."
iptables -t nat -D POSTROUTING -o "${dev}" -j MASQUERADE 2>/dev/null
while ip rule show | grep -q "fwmark 0x3e8"; do
    ip rule del fwmark 1000 table 1000 2>/dev/null
done
ip route flush table 1000 2>/dev/null
echo "[vpngate-down] 规则清理完毕！"
exit 0
EOF
    chmod +x "${OPENVPN_DIR}/vpngate-down.sh"

    # 写入 vpngate.auth 默认账号密码文件 (vpn / vpn)
    cat << 'EOF' | tr -d '\r' > "${OPENVPN_DIR}/vpngate.auth"
vpn
vpn
EOF
    chmod 600 "${OPENVPN_DIR}/vpngate.auth"
}

# 写入配置文件模板
write_config_template() {
    cat << 'EOF' | tr -d '\r' > "$TEMPLATE_FILE"
{
  "log": {
    "disabled": false,
    "level": "info",
    "timestamp": true
  },
  "inbounds": [
    {
      "type": "vless",
      "tag": "vless-in",
      "listen": "::",
      "listen_port": PORT_VL_RE,
      "users": [
        {
          "uuid": "UUID_VAL",
          "flow": "xtls-rprx-vision"
        }
      ],
      "tls": {
        "enabled": true,
        "server_name": "YM_VL_RE_VAL",
        "reality": {
          "enabled": true,
          "handshake": {
            "server": "YM_VL_RE_VAL",
            "server_port": 443
          },
          "private_key": "PRIVATE_KEY_VAL",
          "short_id": [
            "SHORT_ID_VAL"
          ]
        }
      }
    },
    {
      "type": "vmess",
      "tag": "vmess-in",
      "listen": "::",
      "listen_port": PORT_VM_WS,
      "users": [
        {
          "uuid": "UUID_VAL",
          "alterId": 0
        }
      ],
      "transport": {
        "type": "ws",
        "path": "PATH_VM_WS_VAL",
        "max_early_data": 2048,
        "early_data_header_name": "Sec-WebSocket-Protocol"
      }
    }
  ],
  "outbounds": [
    {
      "type": "direct",
      "tag": "direct"
    },
    {
      "type": "direct",
      "tag": "vpngate-out",
      "routing_mark": 1000
    },
    {
      "type": "block",
      "tag": "block"
    }
  ],
  "route": {
    "rule_set": [
      RULE_SET_PLACEHOLDER
    ],
    "rules": [
      {
        "protocol": [
          "quic",
          "stun"
        ],
        "outbound": "block"
      },
      {
        "ip_cidr": [
          "224.0.0.0/3",
          "ff00::/8",
          "10.0.0.0/8",
          "172.16.0.0/12",
          "192.168.0.0/16",
          "127.0.0.0/8",
          "100.64.0.0/10",
          "::1/128",
          "fc00::/7",
          "fe80::/10"
        ],
        "outbound": "direct"
      },
      ROUTE_RULES_PLACEHOLDER,
      {
        "outbound": "DEFAULT_OUTBOUND_VAL",
        "network": [
          "udp",
          "tcp"
        ]
      }
    ],
    "final": "direct",
    "auto_detect_interface": true
  }
}
EOF
}

# 安装必要依赖
install_dependencies() {
    info "开始安装基础系统依赖..."
    detect_os
    
    if [[ "$release" == "debian" || "$release" == "ubuntu" ]]; then
        apt-get update -y
        apt-get install -y curl openvpn python3 iptables jq tar wget openssl
    elif [[ "$release" == "centos" ]]; then
        yum install -y epel-release
        yum makecache
        yum install -y curl openvpn python3 iptables jq tar wget openssl
    fi
    
    # 确保文件夹存在
    mkdir -p "$SB_DIR"
    mkdir -p "$OPENVPN_DIR"
    
    # 写入挂载脚本与模板
    write_routing_scripts
    write_config_template
    
    info "依赖软件和核心辅助脚本安装完成。"
}

# 获取最新 sing-box 版本
get_latest_sing_box_version() {
    local version=""
    version=$(curl -s https://api.github.com/repos/SagerNet/sing-box/releases/latest | grep -oP '"tag_name":\s*"v\K[0-9.]+' | head -n 1)
    if [[ -z "$version" ]]; then
        version=$(curl -Ls -o /dev/null -w %{url_effective} https://github.com/SagerNet/sing-box/releases/latest | grep -oP 'tag/v\K[0-9.]+' | head -n 1)
    fi
    if [[ -z "$version" ]]; then
        version="1.11.2"  # 兜底默认版本
    fi
    echo "$version"
}

# 安装或升级 sing-box
install_sing_box() {
    detect_arch
    local version=$(get_latest_sing_box_version)
    info "正从 GitHub 下载 sing-box v${version} (${cpu})..."
    
    local filename="sing-box-${version}-linux-${cpu}"
    local download_url="https://github.com/SagerNet/sing-box/releases/download/v${version}/${filename}.tar.gz"
    
    wget -qO /tmp/sing-box.tar.gz "$download_url"
    if [[ $? -ne 0 ]]; then
        err "下载 sing-box 核心失败，请检查网络是否能顺畅访问 GitHub。"
    fi
    
    tar -zxf /tmp/sing-box.tar.gz -C /tmp/
    mv "/tmp/${filename}/sing-box" "/usr/local/bin/sing-box"
    chmod +x "/usr/local/bin/sing-box"
    rm -rf /tmp/sing-box* "/tmp/${filename}"
    
    info "sing-box 内核已成功安装至 /usr/local/bin/sing-box"
    /usr/local/bin/sing-box version
    
    # 写入 systemd 配置文件
    cat <<EOF | tr -d '\r' > /etc/systemd/system/sing-box.service
[Unit]
Description=sing-box service
After=network.target nss-lookup.target

[Service]
User=root
WorkingDirectory=/root
CapabilityBoundingSet=CAP_NET_ADMIN CAP_NET_BIND_SERVICE CAP_NET_RAW
AmbientCapabilities=CAP_NET_ADMIN CAP_NET_BIND_SERVICE CAP_NET_RAW
ExecStart=/usr/local/bin/sing-box run -c /etc/sing-box/config.json
ExecReload=/bin/kill -HUP \$MAINPID
Restart=on-failure
RestartSec=10
LimitNOFILE=infinity

[Install]
WantedBy=multi-user.target
EOF

    systemctl daemon-reload
    systemctl enable sing-box >/dev/null 2>&1
    info "sing-box systemd 服务已注册并启用。"
}

# 随机生成未占用的端口
get_random_port() {
    local port
    while true; do
        port=$(shuf -i 10000-65535 -n 1)
        if ! ss -tuln | grep -q -w "$port"; then
            echo "$port"
            break
        fi
    done
}

# 配置入站环境参数
configure_inbounds() {
    # 核心前置校验：如果还没有执行过选项 1 安装 sing-box 内核，则拦截配置
    if [[ ! -x "/usr/local/bin/sing-box" ]]; then
        warn "检测到 sing-box 内核尚未安装！请先选择【选项 1】安装依赖和内核后再进行配置。"
        return 1
    fi

    info "开始配置 sing-box 入站 parameters..."
    
    read -p "设置 VLESS-Reality 监听端口 [默认随机]: " input_port_vl
    if [[ -z "$input_port_vl" ]]; then
        if [[ -n "$PORT_VL_RE" ]]; then port_vl_re="$PORT_VL_RE"; else port_vl_re=$(get_random_port); fi
    else
        port_vl_re="$input_port_vl"
    fi
    
    read -p "设置 VMess-WS 监听端口 [默认随机]: " input_port_vm
    if [[ -z "$input_port_vm" ]]; then
        if [[ -n "$PORT_VM_WS" ]]; then port_vm_ws="$PORT_VM_WS"; else port_vm_ws=$(get_random_port); fi
    else
        port_vm_ws="$input_port_vm"
    fi
    
    read -p "设置 VLESS-Reality 伪装 SNI 域名 [默认: apple.com]: " input_sni
    if [[ -z "$input_sni" ]]; then
        if [[ -n "$YM_VL_RE" ]]; then ym_vl_re="$YM_VL_RE"; else ym_vl_re="apple.com"; fi
    else
        ym_vl_re="$input_sni"
    fi
    
    # 生成 UUID
    if [[ -n "$UUID" ]]; then
        uuid_val="$UUID"
    else
        uuid_val=$(/usr/local/bin/sing-box generate uuid 2>/dev/null || cat /proc/sys/kernel/random/uuid)
    fi
    
    # 生成 Reality 密钥对
    if [[ -n "$PRIVATE_KEY" && -n "$PUBLIC_KEY" ]]; then
        priv_key="$PRIVATE_KEY"
        pub_key="$PUBLIC_KEY"
    else
        local keypair=$(/usr/local/bin/sing-box generate reality-keypair 2>/dev/null)
        priv_key=$(echo "$keypair" | grep -i "PrivateKey" | awk '{print $2}')
        pub_key=$(echo "$keypair" | grep -i "PublicKey" | awk '{print $2}')
    fi
    
    # 生成 ShortID
    if [[ -n "$SHORT_ID" ]]; then
        short_id_val="$SHORT_ID"
    else
        short_id_val=$(openssl rand -hex 8)
    fi
    
    # 设置 VMess 路径
    if [[ -n "$PATH_VM_WS" ]]; then
        path_vm_ws_val="$PATH_VM_WS"
    else
        path_vm_ws_val="/${uuid_val}-vm"
    fi
    
    # 保存环境参数到持久化文件
    cat <<EOF | tr -d '\r' > "$ENV_FILE"
PORT_VL_RE=${port_vl_re}
PORT_VM_WS=${port_vm_ws}
UUID="${uuid_val}"
YM_VL_RE="${ym_vl_re}"
PRIVATE_KEY="${priv_key}"
PUBLIC_KEY="${pub_key}"
SHORT_ID="${short_id_val}"
PATH_VM_WS="${path_vm_ws_val}"
ROUTING_MODE=${ROUTING_MODE:-1}
EOF

    # 更新全局配置变量
    PORT_VL_RE=${port_vl_re}
    PORT_VM_WS=${port_vm_ws}
    UUID="${uuid_val}"
    YM_VL_RE="${ym_vl_re}"
    PRIVATE_KEY="${priv_key}"
    PUBLIC_KEY="${pub_key}"
    SHORT_ID="${short_id_val}"
    PATH_VM_WS="${path_vm_ws_val}"
    
    info "入站配置参数已成功生成并保存。"
}

# 纯 Bash 生成并校验 config.json
generate_config_json() {
    # 每次生成配置前强制刷新模板文件，确保其版本与当前运行脚本百分百同步
    write_config_template
    
    # 复制模板到临时配置文件
    cp "$TEMPLATE_FILE" "$CONFIG_FILE"
    
    # 确定默认出站和分流路由规则
    local default_outbound
    local rules_json
    local rule_sets_json
    if [[ "${ROUTING_MODE:-1}" -eq 1 ]]; then
        # 全局代理模式：中国流量直连，其余出站走 VPN Gate
        default_outbound="vpngate-out"
        rule_sets_json='{"tag": "geosite-cn", "type": "remote", "format": "binary", "url": "https://raw.githubusercontent.com/SagerNet/sing-geosite/rule-set/geosite-cn.srs", "download_detour": "direct"}, {"tag": "geoip-cn", "type": "remote", "format": "binary", "url": "https://raw.githubusercontent.com/SagerNet/sing-geoip/rule-set/geoip-cn.srs", "download_detour": "direct"}'
        rules_json='{"rule_set": "geosite-cn", "outbound": "direct"}, {"rule_set": "geoip-cn", "outbound": "direct"}'
    else
        # 规则分流模式：默认直连，境外常用服务走 VPN Gate
        default_outbound="direct"
        rule_sets_json='{"tag": "geosite-geolocation-!cn", "type": "remote", "format": "binary", "url": "https://raw.githubusercontent.com/SagerNet/sing-geosite/rule-set/geosite-geolocation-!cn.srs", "download_detour": "direct"}, {"tag": "geoip-telegram", "type": "remote", "format": "binary", "url": "https://raw.githubusercontent.com/SagerNet/sing-geoip/rule-set/geoip-telegram.srs", "download_detour": "direct"}'
        rules_json='{"rule_set": "geosite-geolocation-!cn", "outbound": "vpngate-out"}, {"rule_set": "geoip-telegram", "outbound": "vpngate-out"}'
    fi
    
    # 使用自定义定界符 '#' 执行 sed 替换，保证 Base64 中的 '/' 字符不引发 sed 语法报错
    sed -i "s#PORT_VL_RE#${PORT_VL_RE}#g" "$CONFIG_FILE"
    sed -i "s#PORT_VM_WS#${PORT_VM_WS}#g" "$CONFIG_FILE"
    sed -i "s#UUID_VAL#${UUID}#g" "$CONFIG_FILE"
    sed -i "s#YM_VL_RE_VAL#${YM_VL_RE}#g" "$CONFIG_FILE"
    sed -i "s#PRIVATE_KEY_VAL#${PRIVATE_KEY}#g" "$CONFIG_FILE"
    sed -i "s#SHORT_ID_VAL#${SHORT_ID}#g" "$CONFIG_FILE"
    sed -i "s#PATH_VM_WS_VAL#${PATH_VM_WS}#g" "$CONFIG_FILE"
    sed -i "s#DEFAULT_OUTBOUND_VAL#${default_outbound}#g" "$CONFIG_FILE"
    sed -i "s#RULE_SET_PLACEHOLDER#${rule_sets_json}#g" "$CONFIG_FILE"
    sed -i "s#ROUTE_RULES_PLACEHOLDER#${rules_json}#g" "$CONFIG_FILE"
    
    # 使用 jq 校验 JSON 格式
    if jq . "$CONFIG_FILE" >/dev/null 2>&1; then
        info "config.json 已成功生成且通过语法合法性校验。"
    else
        err "生成的 config.json 存在语法错误，请检查配置文件模板！"
    fi
}

# 测试单个 VPN 节点的连通性 (TCP/Ping 结合)
test_node_connectivity() {
    local b64="$1"
    local ip="$2"
    
    # 解码
    local ovpn=$(echo -n "$b64" | base64 -d 2>/dev/null)
    [[ -z "$ovpn" ]] && ovpn=$(echo -n "$b64" | openssl base64 -d 2>/dev/null)
    
    if [[ -z "$ovpn" ]]; then
        echo -e "${RED}解码失败${PLAIN}"
        return 1
    fi
    
    # 提取 remote 行及协议
    local remote_line=$(echo "$ovpn" | grep -E '^remote[[:space:]]' | head -n 1)
    local proto=$(echo "$ovpn" | grep -E '^proto[[:space:]]' | head -n 1 | awk '{print $2}' | tr '[:upper:]' '[:lower:]')
    local port=$(echo "$remote_line" | awk '{print $3}')
    
    [[ -z "$port" ]] && port="443"
    
    # 优先测试 TCP 端口连通性 (使用 Bash 内置 Socket 提升速度与准确度)
    if [[ "$remote_line" == *tcp* || "$proto" == *tcp* ]]; then
        if timeout 1.2 bash -c "</dev/tcp/${ip}/${port}" >/dev/null 2>&1; then
            echo -e "${GREEN}可用 (TCP)${PLAIN}"
            return 0
        fi
    fi
    
    # 备用使用 Ping 测试
    if ping -c 1 -W 1 "$ip" >/dev/null 2>&1; then
        echo -e "${GREEN}可用 (Ping)${PLAIN}"
        return 0
    fi
    
    echo -e "${RED}不可用${PLAIN}"
    return 1
}

# 纯 Bash 交互式更新并连接 VPN Gate 节点
connect_vpngate() {
    write_routing_scripts
    info "正在拉取 VPN Gate 可用节点列表..."
    
    # 抓取 CSV 节点原始数据并清洗，去掉开头的注释行与尾部的星号行
    curl -sL --connect-timeout 12 "https://www.vpngate.net/api/iphone/" | grep -v '^#' | grep -v '^\*' | grep -v '^$' > /tmp/vg_raw.csv
    if [[ ! -s /tmp/vg_raw.csv ]]; then
        # 备用地址
        curl -sL --connect-timeout 12 "http://mirror.vpngate.net/api/iphone/" | grep -v '^#' | grep -v '^\*' | grep -v '^$' > /tmp/vg_raw.csv
    fi
    
    if [[ ! -s /tmp/vg_raw.csv ]]; then
        warn "拉取 VPN Gate 列表失败，请检查 VPS 的网络能否访问外网。"
        return
    fi
    
    # 提取当前可用国家的简称及各自的节点数量，按节点数降序排列
    local countries_summary
    countries_summary=$(awk -F',' '{print $7}' /tmp/vg_raw.csv | sort | uniq -c | sort -rn | awk '{printf "%s(%s) ", $2, $1}' | sed 's/ $//')

    # 提供国家/地区过滤筛选
    local country_filter
    if [[ "$1" == "auto" ]]; then
        country_filter="${SAVED_COUNTRY_FILTER}"
        info "[后台自愈] 检测到自动重连请求，使用历史国家过滤器: [${country_filter:-所有国家}]"
    else
        echo -e "当前可用国家及节点数统计: \033[36m${countries_summary}\033[0m"
        read -p "过滤指定国家节点 (例如: JP, US, KR，直接回车显示所有评分最高节点): " country_filter
        country_filter=$(echo "$country_filter" | tr '[:lower:]' '[:upper:]')
        
        # 持久化保存用户的国家过滤器选择到 env 环境变量文件中
        sed -i '/SAVED_COUNTRY_FILTER=/d' "$ENV_FILE" 2>/dev/null
        echo "SAVED_COUNTRY_FILTER=\"${country_filter}\"" >> "$ENV_FILE"
    fi
    
    # 纯 Bash / awk 提取核心属性，并按评分 (Score) 进行倒序排序
    if [[ -n "$country_filter" ]]; then
        awk -F',' -v country="$country_filter" '$7 == country {print $2 "|" $3 "|" $4 "|" $5 "|" $7 "|" $NF}' /tmp/vg_raw.csv | sort -t'|' -k2,2rn > /tmp/vg_sorted.txt
    else
        awk -F',' '{print $2 "|" $3 "|" $4 "|" $5 "|" $7 "|" $NF}' /tmp/vg_raw.csv | sort -t'|' -k2,2rn > /tmp/vg_sorted.txt
    fi
    
    if [[ ! -s /tmp/vg_sorted.txt ]]; then
        warn "未找到匹配国家 [$country_filter] 的节点，展示所有节点列表。"
        awk -F',' '{print $2 "|" $3 "|" $4 "|" $5 "|" $7 "|" $NF}' /tmp/vg_raw.csv | sort -t'|' -k2,2rn > /tmp/vg_sorted.txt
    fi
    
    # 截取前 15 个节点展示
    head -n 15 /tmp/vg_sorted.txt > /tmp/vg_top15.txt
    
    local i=1
    declare -A node_ip
    declare -A node_country
    declare -A node_b64
    declare -A node_score
    declare -A node_ping
    declare -A node_speed
    
    # 解析并缓存原始节点细节
    while IFS='|' read -r ip score ping speed country b64; do
        node_ip[$i]="$ip"
        node_score[$i]="$score"
        node_ping[$i]="$ping"
        node_speed[$i]="$speed"
        node_country[$i]="$country"
        node_b64[$i]="$b64"
        i=$((i+1))
    done < /tmp/vg_top15.txt
    local total_nodes=$((i-1))
    
    if [[ "$total_nodes" -eq 0 ]]; then
        warn "无可用的 VPN 节点。"
        return
    fi
    
    # 多进程并行执行连通性网络测试，提升显示响应速度
    info "正在对前 ${total_nodes} 个节点进行并发连通性测试 (网络握手/Ping)..."
    declare -A test_pids
    for j in $(seq 1 $total_nodes); do
        (
            local res
            res=$(test_node_connectivity "${node_b64[$j]}" "${node_ip[$j]}")
            echo "$res" > "/tmp/vg_res_${j}.txt"
        ) &
        test_pids[$j]=$!
    done
    
    # 等待所有后台网络检测子任务运行完毕
    for j in $(seq 1 $total_nodes); do
        wait ${test_pids[$j]} 2>/dev/null
    done
    
    # 打印排版漂亮的表格
    echo -e "\n------------------------------------------------------------------------------------------------"
    printf "%-5s | %-10s | %-15s | %-10s | %-12s | %-10s | %-12s\n" "序号" "国家" "IP 地址" "延迟Ping" "最大带宽" "系统评分" "连接状态"
    echo "------------------------------------------------------------------------------------------------"
    
    declare -A node_status
    for j in $(seq 1 $total_nodes); do
        local ip="${node_ip[$j]}"
        local score="${node_score[$j]}"
        local ping="${node_ping[$j]}"
        local speed="${node_speed[$j]}"
        local country="${node_country[$j]}"
        
        # 格式化宽带速率显示
        local speed_val="Unknown"
        if [[ "$speed" -gt 0 ]]; then
            local mbps=$(awk -v s="$speed" 'BEGIN {printf "%.1f", s/1000000}')
            speed_val="${mbps} Mbps"
        fi
        
        local ping_val="${ping} ms"
        if [[ "$ping" -le 0 ]]; then ping_val="Unknown"; fi
        
        # 读取后台进程测速结果
        local status_val=$(cat "/tmp/vg_res_${j}.txt" 2>/dev/null)
        [[ -z "$status_val" ]] && status_val="${RED}不可用${PLAIN}"
        node_status[$j]="$status_val"
        
        # 清理临时结果文件
        rm -f "/tmp/vg_res_${j}.txt"
        
        printf "\033[36m%-5s\033[0m | %-10s | %-15s | %-10s | %-12s | %-10s | %b\n" "$j" "$country" "$ip" "$ping_val" "$speed_val" "$score" "$status_val"
    done
    echo "------------------------------------------------------------------------------------------------"
    # 自动轮询连接逻辑
    local success=0
    local available_indices=()
    local unavailable_indices=()
    
    for j in $(seq 1 $total_nodes); do
        if [[ "${node_status[$j]}" == *"可用"* ]]; then
            available_indices+=($j)
        else
            unavailable_indices+=($j)
        fi
    done
    
    # 优先轮询可用节点，其次是不可用节点
    local try_indices=("${available_indices[@]}" "${unavailable_indices[@]}")
    local total_try=${#try_indices[@]}
    info "已整理候选队列：优先尝试 ${#available_indices[@]} 个可用节点，其次尝试 ${#unavailable_indices[@]} 个备用节点。"
    
    local try_count=0
    for idx in "${try_indices[@]}"; do
        try_count=$((try_count+1))
        local selected_ip="${node_ip[$idx]}"
        local selected_country="${node_country[$idx]}"
        local selected_b64="${node_b64[$idx]}"
        local selected_score="${node_score[$idx]}"
        local selected_ping="${node_ping[$idx]}"
        
        info "[自动连接] ($try_count/$total_try) 正在尝试节点: IP=${selected_ip} | 国家=${selected_country} | 评分=${selected_score} | 延迟=${selected_ping}ms"
        
        # 1. 安全地停止现有的 openvpn 客户端并清理路由表/网卡
        systemctl stop openvpn-vpngate 2>/dev/null
        if [[ -x "${OPENVPN_DIR}/vpngate-down.sh" ]]; then
            "${OPENVPN_DIR}/vpngate-down.sh" tun-vpngate >/dev/null 2>&1
        fi
        sleep 1.5 # 给系统释放网卡充足时间

        # 2. 解码 OVPN 配置文件
        echo -n "$selected_b64" | base64 -d > /tmp/vg_decoded.ovpn 2>/dev/null
        if [[ ! -s /tmp/vg_decoded.ovpn ]]; then
            echo -n "$selected_b64" | openssl base64 -d > /tmp/vg_decoded.ovpn 2>/dev/null
        fi
        
        if [[ ! -s /tmp/vg_decoded.ovpn ]]; then
            warn "[自动连接] 节点 Base64 配置文件解码失败，跳过该节点。"
            continue
        fi
        
        # 3. 动态配置写入
        grep -v -i -E '^[[:space:]]*(dev|redirect-gateway|route-gateway|route[[:space:]]+[0-9]|dhcp-option|auth-user-pass)' /tmp/vg_decoded.ovpn | tr -d '\r' > "$VPNGATE_OVPN"
        
        cat <<EOF | tr -d '\r' >> "$VPNGATE_OVPN"

# 以下由 sb-vpngate 脚本自动注入，用于配置认证与策略路由分流
auth-user-pass /etc/openvpn/vpngate.auth
dev tun-vpngate
route-nopull
pull-filter ignore "dhcp-option"
pull-filter ignore "redirect-gateway"
data-ciphers AES-256-GCM:AES-128-GCM:CHACHA20-POLY1305:AES-256-CBC:AES-128-CBC
script-security 2
up /etc/openvpn/vpngate-up.sh
down /etc/openvpn/vpngate-down.sh
EOF

        # 4. 重新生成并启动服务
        local openvpn_path=$(which openvpn)
        [[ -z "$openvpn_path" ]] && openvpn_path="/usr/sbin/openvpn"
        
        cat <<EOF | tr -d '\r' > /etc/systemd/system/openvpn-vpngate.service
[Unit]
Description=VPN Gate OpenVPN Client Connection
After=network.target

[Service]
Type=simple
ExecStart=${openvpn_path} --config ${VPNGATE_OVPN}
Restart=on-failure
RestartSec=5

[Install]
WantedBy=multi-user.target
EOF

        systemctl daemon-reload
        systemctl restart openvpn-vpngate
        
        # 5. 双指标状态监控，最长等待 15 秒
        local connected=0
        local check_timeout=15
        for s in $(seq 1 $check_timeout); do
            # 如果 OpenVPN 服务已经不活跃，说明启动崩溃（例如凭证被拒或底层隧道协商失败）
            if ! systemctl is-active --quiet openvpn-vpngate; then
                warn "  -> OpenVPN 客户端进程异常退出/连接被拒绝。"
                break
            fi
            
            # 检测 tun-vpngate 网卡并确认分配了 IP
            if ip addr show dev tun-vpngate 2>/dev/null | grep -q "inet"; then
                # 进一步验证 table 1000 路由表中已经自动下发了默认网关
                if ip route show table 1000 2>/dev/null | grep -q "default dev"; then
                    connected=1
                    break
                fi
            fi
            
            # 打印等待进度
            echo -ne "  -> 建立隧道中，等待分配 IP... (${s}/${check_timeout}s)\r"
            sleep 1
        done
        echo "" # 清理换行

        if [[ "$connected" -eq 1 ]]; then
            success=1
            local assigned_ip=$(ip addr show dev tun-vpngate 2>/dev/null | grep "inet" | awk '{print $2}' | cut -d'/' -f1)
            info "🎉 节点连接成功！分配的内网 IP: ${assigned_ip}"
            
            # 校验外网 IP
            local vpn_ip=$(curl -s4m5 --interface tun-vpngate icanhazip.com 2>/dev/null)
            if [[ -n "$vpn_ip" ]]; then
                info "VPN Gate 实际外网出口 IP: ${vpn_ip}"
            fi
            break
        else
            warn "[自动连接] 节点 ${selected_ip} 连接超时或建立隧道失败，正清理环境并切换至下一个节点..."
            systemctl stop openvpn-vpngate 2>/dev/null
            if [[ -x "${OPENVPN_DIR}/vpngate-down.sh" ]]; then
                "${OPENVPN_DIR}/vpngate-down.sh" tun-vpngate >/dev/null 2>&1
            fi
        fi
    done

    if [[ "$success" -ne 1 ]]; then
        err "已尝试完候选队列中的所有节点，均未能成功建立连接。请稍后运行脚本重试，或尝试更换其他过滤国家！"
    fi
}

# 设置分流路由模式
configure_routing_mode() {
    echo -e "\n~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~"
    cyan "请选择出站分流路由模式："
    echo "1. 【全局代理模式】 (默认除 CN 中国大陆流量直连，其余所有出站全部走 VPN Gate)"
    echo "2. 【规则分流模式】 (默认直连，仅境外主流服务如 Google/Netflix/Telegram 走 VPN Gate)"
    read -p "请输入模式【1-2】[当前:${ROUTING_MODE:-1}]: " choice_mode
    
    case "$choice_mode" in
        1) ROUTING_MODE=1 ;;
        2) ROUTING_MODE=2 ;;
        *) warn "输入错误或保持默认，未修改路由模式。" ;;
    esac
    
    # 写入环境变量并重新生成配置
    sed -i "s/ROUTING_MODE=.*/ROUTING_MODE=${ROUTING_MODE}/" "$ENV_FILE" 2>/dev/null || echo "ROUTING_MODE=${ROUTING_MODE}" >> "$ENV_FILE"
    
    if [[ -n "$UUID" ]]; then
        generate_config_json
        systemctl restart sing-box
        info "sing-box 路由配置已更新并重启应用。"
    fi
}

# 启动服务
start_services() {
    info "正在启动所有服务..."
    if [[ ! -f "$CONFIG_FILE" ]]; then
        err "未找到 sing-box 配置文件 config.json，请先执行选项 2 配置入站。"
    fi
    
    systemctl restart sing-box
    info "sing-box 服务已启动/重启。"
    
    if [[ -f "$VPNGATE_OVPN" ]]; then
        systemctl restart openvpn-vpngate
        info "openvpn-vpngate 客户端已启动/重启。"
    else
        warn "未检测到已下载的 VPN Gate 节点配置，请执行选项 3 关联并启动 VPN Gate。"
    fi
}

# 停止服务
stop_services() {
    info "正在停止相关服务..."
    systemctl stop sing-box 2>/dev/null
    systemctl stop openvpn-vpngate 2>/dev/null
    
    # 额外通过 vpngate-down.sh 清理策略路由和网卡规则，以防遗留
    if [[ -x "${OPENVPN_DIR}/vpngate-down.sh" ]]; then
        "${OPENVPN_DIR}/vpngate-down.sh" tun-vpngate 2>/dev/null
    fi
    
    info "所有相关服务均已停止，策略路由规则已重置。"
}

# 获取 VPS 外部公网 IP
get_public_ip() {
    local ip=""
    ip=$(curl -s4m5 icanhazip.com || curl -s4m5 api.ipify.org)
    if [[ -z "$ip" ]]; then
        ip="你的VPS公网IP"
    fi
    echo "$ip"
}

# 查看运行状态与客户端链接
view_status_and_links() {
    local vps_ip=$(get_public_ip)
    
    echo -e "\n======================= 系统运行状态 ======================="
    # 检测 sing-box
    if systemctl is-active --quiet sing-box; then
        echo -e "sing-box 运行状态: ${GREEN}运行中 (Active)${PLAIN}"
    else
        echo -e "sing-box 运行状态: ${RED}已停止 (Inactive)${PLAIN}"
        echo -e "${RED}--- sing-box 最近的错误日志 ---${PLAIN}"
        journalctl -u sing-box --no-pager -n 15
        echo -e "${RED}-------------------------------${PLAIN}"
    fi
    
    # 检测 OpenVPN
    if systemctl is-active --quiet openvpn-vpngate; then
        echo -e "VPN Gate 运行状态: ${GREEN}服务已拉起 (Active)${PLAIN}"
        # 显示 VPN 节点出口 IP 归属地与 ISP 信息
        if ip route show table 1000 2>/dev/null | grep -q "default dev"; then
            local ip_info=$(curl -s4m5 --interface tun-vpngate ip-api.com/json/ 2>/dev/null)
            if [[ -n "$ip_info" ]]; then
                local vpn_ip=$(echo "$ip_info" | jq -r '.query' 2>/dev/null)
                local country=$(echo "$ip_info" | jq -r '.country' 2>/dev/null)
                local isp=$(echo "$ip_info" | jq -r '.isp' 2>/dev/null)
                if [[ -n "$vpn_ip" && "$vpn_ip" != "null" ]]; then
                    echo -e "VPN 节点实际出口 IP: ${CYAN}${vpn_ip}${PLAIN} (${country} - ${isp})"
                else
                    echo -e "VPN 节点实际出口 IP: ${YELLOW}隧道已建立，但无法获取详细归属信息${PLAIN}"
                fi
            else
                # 备用回退到 icanhazip
                local vpn_ip=$(curl -s4m5 --interface tun-vpngate icanhazip.com 2>/dev/null)
                if [[ -n "$vpn_ip" ]]; then
                    echo -e "VPN 节点实际出口 IP: ${CYAN}${vpn_ip}${PLAIN}"
                else
                    echo -e "VPN 节点实际出口 IP: ${YELLOW}已建立隧道，正在配置并等待分配 IP...${PLAIN}"
                fi
            fi
        else
            echo -e "VPN 隧道状态: ${YELLOW}已拉起进程，但隧道尚未握手连接成功 (策略路由表 1000 仍为空)${PLAIN}"
            echo -e "${YELLOW}[提示] 这可能是因为选定的 VPN Gate 节点暂时无法连接。若超过 30 秒仍未成功，请执行【选项 8】查看 OpenVPN 日志，或执行【选项 3】切换其他高评分节点。${PLAIN}"
        fi
    else
        echo -e "VPN Gate 运行状态: ${RED}未连接 (Inactive)${PLAIN}"
        echo -e "${RED}--- openvpn-vpngate 最近的错误日志 ---${PLAIN}"
        local ovpn_logs=$(journalctl -u openvpn-vpngate --no-pager -n 15)
        echo "$ovpn_logs"
        echo -e "${RED}--------------------------------------${PLAIN}"
        if echo "$ovpn_logs" | grep -q "Cannot open TUN/TAP dev"; then
            echo -e "${YELLOW}[排障指引] 检测到系统缺失 TUN/TAP 设备文件或无访问权限！"
            echo -e "1. 脚本已尝试在连接时自动检测并运行 mknod 创建该设备。"
            echo -e "2. 若此报错依然存在，说明您的 VPS 运行在 OpenVZ 或 LXC 虚拟化架构上，且母机未授予 TUN 网卡权限。"
            echo -e "   请登录您的 VPS 服务商控制面板（如 SolusVM、Proxmox、Virtualizor），在网卡设置中开启 'TUN/TAP' 支持，然后重启 VPS 即可解决。${PLAIN}"
        fi
    fi
    
    # 检测自愈重连守护服务状态
    local keepalive_status="${RED}已关闭 (Inactive)${PLAIN}"
    if systemctl is-active --quiet vpngate-keepalive 2>/dev/null; then
        keepalive_status="${GREEN}运行中 (Active)${PLAIN}"
    fi
    echo -e "断线自愈重连守护: ${keepalive_status}"
    
    # 显示当前的策略模式
    if [[ "$ROUTING_MODE" -eq 2 ]]; then
        echo -e "分流出站路由模式: ${CYAN}规则分流模式 (境外常用走 VPN，其余直连)${PLAIN}"
    else
        echo -e "分流出站路由模式: ${CYAN}全局代理模式 (除中国流量直连，其余全部走 VPN)${PLAIN}"
    fi
    
    if [[ -z "$UUID" ]]; then
        warn "尚未生成任何节点入站配置，请先执行选项 2 进行配置生成。"
        return
    fi
    
    echo -e "\n======================= 协议入站端口 ======================="
    echo -e "VLESS-Reality 端口: ${CYAN}${PORT_VL_RE}${PLAIN}"
    echo -e "VMess-WS 端口:      ${CYAN}${PORT_VM_WS}${PLAIN}"
    echo -e "通用 UUID 密码:     ${CYAN}${UUID}${PLAIN}"
    
    echo -e "\n======================= 客户端连接节点 (直连导入) ======================="
    
    # VLESS Reality 链接
    local vless_link="vless://${UUID}@${vps_ip}:${PORT_VL_RE}?security=reality&sni=${YM_VL_RE}&fp=chrome&pbk=${PUBLIC_KEY}&sid=${SHORT_ID}&flow=xtls-rprx-vision#sb-vpngate_VLESS"
    echo -e "\033[35;1mVLESS-Reality 链接:\033[0m"
    echo "$vless_link"
    
    # VMess WS 链接 (Base64)
    local vmess_json="{\"v\":\"2\",\"ps\":\"sb-vpngate_VMess-WS\",\"add\":\"${vps_ip}\",\"port\":${PORT_VM_WS},\"id\":\"${UUID}\",\"aid\":\"0\",\"scy\":\"auto\",\"net\":\"ws\",\"type\":\"none\",\"host\":\"${vps_ip}\",\"path\":\"${PATH_VM_WS}\",\"tls\":\"none\"}"
    local vmess_b64=$(echo -n "$vmess_json" | base64 -w 0)
    local vmess_link="vmess://${vmess_b64}"
    echo -e "\n\033[35;1mVMess-WS 链接:\033[0m"
    echo "$vmess_link"
    
    echo -e "\n============================================================\n"
}

# 查看运行日志
view_logs() {
    echo -e "\n~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~"
    cyan "           请选择要查看的日志类型："
    echo " 1. 查看 sing-box 运行日志 (最后 50 行)"
    echo " 2. 实时滚动追踪 (tail -f) sing-box 日志"
    echo " 3. 查看 openvpn-vpngate 运行日志 (最后 50 行)"
    echo " 4. 实时滚动追踪 (tail -f) openvpn-vpngate 日志"
    echo " 0. 返回主菜单"
    echo "~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~"
    local log_choice
    read -p "请输入选项【0-4】: " log_choice
    
    case "$log_choice" in
        1)
            info "正在拉取 sing-box 运行日志 (最后 50 行)..."
            journalctl -u sing-box --no-pager -n 50
            ;;
        2)
            info "开始实时追踪 sing-box 日志 (按 Ctrl+C 退出)..."
            journalctl -u sing-box -f
            ;;
        3)
            info "正在拉取 openvpn-vpngate 运行日志 (最后 50 行)..."
            journalctl -u openvpn-vpngate --no-pager -n 50
            ;;
        4)
            info "开始实时追踪 openvpn-vpngate 日志 (按 Ctrl+C 退出)..."
            journalctl -u openvpn-vpngate -f
            ;;
        0|*)
            info "返回主菜单。"
            return
            ;;
    esac
}

# 彻底卸载脚本与服务
uninstall_all() {
    echo -e "\n~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~"
    warn "您确认要卸载本脚本的所有组件吗？这将删除所有配置、停止并删除服务！"
    read -p "请输入 [y/N] 进行确认: " confirm
    if [[ "$confirm" != "y" && "$confirm" != "Y" ]]; then
        info "已取消卸载。"
        return
    fi
    
    stop_services
    
    # 停止并删除重连守护进程
    systemctl stop vpngate-keepalive >/dev/null 2>&1
    systemctl disable vpngate-keepalive >/dev/null 2>&1
    rm -f /etc/systemd/system/vpngate-keepalive.service
    rm -f /usr/local/bin/vpngate-keepalive.sh
    
    # 删除 systemd 服务
    systemctl disable sing-box >/dev/null 2>&1
    systemctl disable openvpn-vpngate >/dev/null 2>&1
    rm -f /etc/systemd/system/sing-box.service
    rm -f /etc/systemd/system/openvpn-vpngate.service
    systemctl daemon-reload
    
    # 删除二进制核心与配置目录
    rm -f /usr/local/bin/sing-box
    rm -rf "$SB_DIR"
    
    # 清理 OpenVPN 配置
    rm -f "$VPNGATE_OVPN"
    rm -f "${OPENVPN_DIR}/vpngate-up.sh" "${OPENVPN_DIR}/vpngate-down.sh"
    
    info "卸载完成！所有组件、配置及服务均已清理完毕。"
    exit 0
}

# 开启/关闭断线自动重连守护进程
toggle_keepalive() {
    if systemctl is-active --quiet vpngate-keepalive 2>/dev/null; then
        info "正在关闭节点断线重连守护服务..."
        systemctl stop vpngate-keepalive 2>/dev/null
        systemctl disable vpngate-keepalive 2>/dev/null
        rm -f /etc/systemd/system/vpngate-keepalive.service
        rm -f /usr/local/bin/vpngate-keepalive.sh
        systemctl daemon-reload
        info "已成功关闭并注销守护服务。"
    else
        info "正在配置并开启节点断线重连守护服务..."
        local script_abs_path=$(realpath "$0")
        
        # 写入监控脚本
        cat <<EOF | tr -d '\r' > /usr/local/bin/vpngate-keepalive.sh
#!/bin/bash
# VPN Gate 断线自愈监控守护脚本
ENV_FILE="/etc/sing-box/sb-vpngate.env"

info() { echo -e "\033[32m[Keepalive] \$1\033[0m"; }
warn() { echo -e "\033[33m[Keepalive] \$1\033[0m"; }

# 引入配置
[[ -f "\$ENV_FILE" ]] && source "\$ENV_FILE"

SCRIPT_PATH="${script_abs_path}"

info "断线自愈监控已启动。检测周期: 60 秒。"

while true; do
    # 只有当用户主动拉起了 VPN 服务，我们才进行掉线监控
    if systemctl is-active --quiet openvpn-vpngate; then
        local test_ok=0
        # 优先使用 curl 通过指定接口测试，其次使用 ping
        if curl -s4m4 --interface tun-vpngate icanhazip.com >/dev/null 2>&1; then
            test_ok=1
        elif ping -I tun-vpngate -c 1 -W 3 8.8.8.8 >/dev/null 2>&1; then
            test_ok=1
        fi
        
        if [[ "\$test_ok" -eq 0 ]]; then
            warn "⚠️ 检测到当前 VPN 通道断开或网络不可达！开始执行自动故障漂移自愈..."
            bash "\${SCRIPT_PATH}" auto-connect
        fi
    fi
    sleep 60
done
EOF
        chmod +x /usr/local/bin/vpngate-keepalive.sh

        # 写入 systemd 服务
        cat <<EOF | tr -d '\r' > /etc/systemd/system/vpngate-keepalive.service
[Unit]
Description=VPN Gate Keepalive Monitor Daemon
After=network.target openvpn-vpngate.service

[Service]
Type=simple
ExecStart=/bin/bash /usr/local/bin/vpngate-keepalive.sh
Restart=always
RestartSec=5

[Install]
WantedBy=multi-user.target
EOF

        systemctl daemon-reload
        systemctl enable vpngate-keepalive >/dev/null 2>&1
        systemctl start vpngate-keepalive
        info "🎉 守护服务已成功开启并启动！"
    fi
}

# 主循环控制菜单
main_menu() {
    if [[ -f "$ENV_FILE" ]]; then
        source "$ENV_FILE"
    fi
    
    local keepalive_status="${RED}已关闭${PLAIN}"
    if systemctl is-active --quiet vpngate-keepalive 2>/dev/null; then
        keepalive_status="${GREEN}已开启${PLAIN}"
    fi
    
    echo -e "\n~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~"
    cyan "           sing-box 入站 / VPN Gate 策略分流出站 一键脚本 (纯 Bash 版)"
    echo " 1. 安装/更新 Sing-box & OpenVPN 依赖"
    echo " 2. 配置并生成 Sing-box 入站配置 (VLESS-Reality / VMess-WS)"
    echo " 3. 选择并连接 VPN Gate 节点 (交互式更新)"
    echo " 4. 修改策略出站分流模式 (全局/规则分流)"
    echo " 5. 启动服务 (sing-box & openvpn-vpngate)"
    echo " 6. 停止服务"
    echo " 7. 查看当前运行状态与配置连接信息"
    echo " 8. 查看运行日志 (sing-box & openvpn)"
    echo " 9. 彻底卸载本脚本服务"
    echo -e " 10. 开启/关闭 节点掉线自动重连守护服务 (当前: ${keepalive_status})"
    echo " 0. 退出脚本"
    echo "~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~"
    read -p "请输入数字选择选项【0-10】: " menu_choice
    
    case "$menu_choice" in
        1)
            install_dependencies
            install_sing_box
            ;;
        2)
            configure_inbounds
            generate_config_json
            ;;
        3)
            connect_vpngate
            ;;
        4)
            configure_routing_mode
            ;;
        5)
            start_services
            ;;
        6)
            stop_services
            ;;
        7)
            view_status_and_links
            ;;
        8)
            view_logs
            ;;
        9)
            uninstall_all
            ;;
        10)
            toggle_keepalive
            ;;
        0)
            cyan "感谢使用本脚本，退出。"
            exit 0
            ;;
        *)
            warn "无效的输入选项，请输入数字 0 至 10。"
            ;;
    esac
}

# 脚本入口
main() {
    detect_os
    
    # 后台自愈非交互式执行通道
    if [[ "$1" == "auto-connect" ]]; then
        if [[ -f "$ENV_FILE" ]]; then
            source "$ENV_FILE"
        fi
        info "收到断线自愈触发，开始执行自动重新连接..."
        connect_vpngate "auto"
        exit 0
    fi

    # 打印 ASCII 艺术字
    echo -e "${CYAN}"
    echo "   ____  ____    _   _ ____  _   _  ____    _  _____ _____ "
    echo "  / ___|| __ )  | | | |  _ \| \ | |/ ___|  / \|_   _| ____|"
    echo "  \___ \|  _ \  | | | | |_) |  \| | |  _  / _ \ | | |  _|  "
    echo "   ___) | |_) | | |_| |  __/| |\  | |_| |/ ___ \| | | |___ "
    echo "  |____/|____/   \___/|_|   |_| \_|\____/_/   \_\_| |_____|"
    echo -e "${PLAIN}"
    
    while true; do
        main_menu
    done
}

main "$@"
