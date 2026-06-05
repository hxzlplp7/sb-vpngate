#!/usr/bin/env bash
# -*- coding: utf-8 -*-

# ==============================================================================
# sb-vpngate 一键配置及管理脚本
# 支持 sing-box 代理入站，及 免费代理节点/直连 链式出站分流
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
    if [[ -f /etc/os-release ]]; then
        . /etc/os-release
        release=$ID
    fi
    if [[ "$release" != "debian" && "$release" != "ubuntu" && "$release" != "centos" && "$release" != "rhel" && "$release" != "rocky" && "$release" != "almalinux" ]]; then
        # 兼容处理
        if grep -q -E -i "debian|ubuntu" /etc/os-release 2>/dev/null; then
            release="debian"
        elif grep -q -E -i "centos|rhel|rocky" /etc/os-release 2>/dev/null; then
            release="centos"
        else
            err "当前脚本仅支持 Debian, Ubuntu 或 CentOS/RHEL 系列系统。"
        fi
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

# 写入订阅解析脚本 subscribe_parser.py
write_subscribe_parser() {
    mkdir -p "${SB_DIR}"
    cat << 'EOF' | tr -d '\r' > "${SB_DIR}/subscribe_parser.py"
#!/usr/bin/env python3
# -*- coding: utf-8 -*-

import base64
import json
import re
import socket
import urllib.request
import urllib.parse
from concurrent.futures import ThreadPoolExecutor

SUBSCRIPTION_URLS = [
    "https://raw.githubusercontent.com/free-nodes/v2rayfree/main/v202606032",
    "https://raw.githubusercontent.com/shaoyouvip/free/refs/heads/main/base64.txt",
    "https://proxy.v2gh.com/https://raw.githubusercontent.com/Pawdroid/Free-servers/main/sub",
    "https://raw.githubusercontent.com/caijh/FreeProxiesScraper/master/Eternity",
    "https://raw.githubusercontent.com/hello-world-1989/cn-news/main/end-gfw-together",
    "https://raw.githubusercontent.com/ssrsub/ssr/master/v2ray"
]

def decode_base64_safely(data):
    if not data:
        return None
    if isinstance(data, bytes):
        try:
            data = data.decode('utf-8', errors='ignore')
        except Exception:
            return None
    data = data.strip().replace('\r', '').replace('\n', '').replace(' ', '')
    padding = len(data) % 4
    if padding:
        data += '=' * (4 - padding)
    try:
        return base64.b64decode(data).decode('utf-8', errors='ignore')
    except Exception:
        return None

def fetch_url(url, timeout=8):
    try:
        req = urllib.request.Request(
            url, 
            headers={'User-Agent': 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36'}
        )
        with urllib.request.urlopen(req, timeout=timeout) as response:
            return response.read(), url
    except Exception:
        return None, url

def parse_vmess(link):
    try:
        b64_str = link[8:].split('#')[0]
        decoded = decode_base64_safely(b64_str)
        if not decoded:
            return None
        data = json.loads(decoded)
        
        port = data.get("port", 443)
        try:
            port = int(port)
        except ValueError:
            port = 443
            
        outbound = {
            "type": "vmess",
            "server": data.get("add"),
            "server_port": port,
            "uuid": data.get("id"),
            "security": "auto",
            "alter_id": int(data.get("aid", 0))
        }
        
        net = str(data.get("net", "")).lower()
        if net == "ws":
            outbound["transport"] = {
                "type": "ws",
                "path": data.get("path", "/"),
                "headers": {}
            }
            host = data.get("host")
            if host:
                outbound["transport"]["headers"]["Host"] = host
        elif net == "grpc":
            outbound["transport"] = {
                "type": "grpc",
                "service_name": data.get("path", "")
            }
            
        tls = str(data.get("tls", "")).lower()
        if tls == "tls":
            outbound["tls"] = {
                "enabled": True,
                "server_name": data.get("sni") or data.get("host") or data.get("add")
            }
        return outbound
    except Exception:
        return None

def parse_vless_or_trojan(link):
    try:
        parsed = urllib.parse.urlparse(link)
        proto = parsed.scheme
        uuid_or_pass = parsed.username or parsed.netloc.split('@')[0]
        
        host_port = parsed.netloc.split('@')[-1]
        if ":" in host_port:
            host, port_str = host_port.split(':', 1)
            port = int(port_str.split('/')[0])
        else:
            host = host_port
            port = 443
            
        if not host or not port:
            return None
            
        query = urllib.parse.parse_qs(parsed.query)
        
        outbound = {
            "type": proto,
            "server": host,
            "server_port": port
        }
        
        if proto == "vless":
            outbound["uuid"] = uuid_or_pass
            flow = query.get("flow", [""])[0]
            if flow:
                outbound["flow"] = flow
        else:
            outbound["password"] = uuid_or_pass
            
        security = query.get("security", [""])[0].lower()
        tls_enabled = security in ("tls", "reality") or "security=" in parsed.query
        
        if tls_enabled:
            outbound["tls"] = {
                "enabled": True,
                "server_name": query.get("sni", [""])[0] or host
            }
            if security == "reality":
                outbound["tls"]["reality"] = {
                    "enabled": True,
                    "public_key": query.get("pbk", [""])[0],
                    "short_id": query.get("sid", [""])[0]
                }
                
        network = query.get("type", [""])[0].lower()
        if network == "ws":
            outbound["transport"] = {
                "type": "ws",
                "path": query.get("path", ["/"])[0],
                "headers": {}
            }
            ws_host = query.get("host", [""])[0]
            if ws_host:
                outbound["transport"]["headers"]["Host"] = ws_host
        elif network == "grpc":
            outbound["transport"] = {
                "type": "grpc",
                "service_name": query.get("serviceName", [""])[0]
            }
        return outbound
    except Exception:
        return None

def parse_shadowsocks(link):
    try:
        parsed = urllib.parse.urlparse(link)
        host = parsed.hostname
        port = parsed.port
        userinfo = parsed.username
        
        if not host or not port:
            raw_b64 = link[5:].split('#')[0]
            decoded = decode_base64_safely(raw_b64)
            if decoded:
                return parse_shadowsocks("ss://" + decoded)
            return None
            
        method_pwd = decode_base64_safely(userinfo)
        if not method_pwd:
            method_pwd = userinfo
            
        if ":" not in method_pwd:
            return None
        method, password = method_pwd.split(":", 1)
        
        outbound = {
            "type": "shadowsocks",
            "server": host,
            "server_port": int(port),
            "method": method,
            "password": password
        }
        return outbound
    except Exception:
        return None

def parse_single_link(link):
    link = link.strip()
    if link.startswith("vmess://"):
        return parse_vmess(link)
    elif link.startswith("vless://") or link.startswith("trojan://"):
        return parse_vless_or_trojan(link)
    elif link.startswith("ss://"):
        return parse_shadowsocks(link)
    return None

def parse_mixed_subscription(content):
    decoded = decode_base64_safely(content)
    if decoded:
        return parse_v2ray_urls(decoded)
        
    return parse_v2ray_urls(content)

def parse_v2ray_urls(content):
    nodes = []
    links = re.findall(r'(vmess://[a-zA-Z0-9+/=\-_]+|vless://[^\s]+|ss://[^\s]+|trojan://[^\s]+)', content)
    for link in links:
        node = parse_single_link(link)
        if node:
            nodes.append(node)
    return nodes

def resolve_ips_country(nodes):
    ip_to_nodes = {}
    ips_to_query = []
    
    for node in nodes:
        server = node.get("server")
        if not server:
            continue
        ip = server
        if not re.match(r'^\d{1,3}\.\d{1,3}\.\d{1,3}\.\d{1,3}$', server):
            try:
                ip = socket.gethostbyname(server)
            except Exception:
                continue
                
        node["server_ip"] = ip
        if ip not in ip_to_nodes:
            ip_to_nodes[ip] = []
            ips_to_query.append(ip)
        ip_to_nodes[ip].append(node)
        
    batch_size = 100
    results = {}
    
    for i in range(0, len(ips_to_query), batch_size):
        chunk = ips_to_query[i:i+batch_size]
        payload = [{"query": ip} for ip in chunk]
        
        try:
            req = urllib.request.Request(
                "http://ip-api.com/batch",
                data=json.dumps(payload).encode("utf-8"),
                headers={"Content-Type": "application/json"}
            )
            with urllib.request.urlopen(req, timeout=10) as resp:
                batch_res = json.loads(resp.read().decode("utf-8"))
                for item in batch_res:
                    query_ip = item.get("query")
                    if query_ip:
                        raw_c = item.get("country", "Unknown")
                        c_code = item.get("countryCode", "XX")
                        results[query_ip] = {
                            "country": raw_c,
                            "country_code": c_code,
                            "isp": item.get("isp", "Unknown")
                        }
        except Exception:
            pass
            
    valid_nodes = []
    for ip, node_list in ip_to_nodes.items():
        res = results.get(ip, {"country": "Unknown", "country_code": "XX", "isp": "Unknown"})
        for node in node_list:
            node["country"] = res["country"]
            node["country_code"] = res["country_code"]
            node["isp"] = res["isp"]
            valid_nodes.append(node)
            
    return valid_nodes

def main():
    print("[Parser] 开始拉取所有免费节点源，共计 6 个订阅地址...", flush=True)
    all_nodes = []
    
    with ThreadPoolExecutor(max_workers=10) as executor:
        futures = {executor.submit(fetch_url, url): url for url in SUBSCRIPTION_URLS}
        for future in futures:
            res, url = future.result()
            if res:
                try:
                    content = res.decode('utf-8', errors='ignore')
                    nodes = parse_mixed_subscription(content)
                    all_nodes.extend(nodes)
                    print(f"  -> 成功拉取并解析: {url.split('/')[-1]} | 获取节点: {len(nodes)} 个", flush=True)
                except Exception as e:
                    print(f"  -> 解析失败: {url.split('/')[-1]} | 错误: {e}", flush=True)
            else:
                print(f"  -> 网络超时或加载失败: {url.split('/')[-1]}", flush=True)
                
    unique_nodes = []
    seen_keys = set()
    for n in all_nodes:
        fp = f"{n.get('type')}_{n.get('server')}_{n.get('server_port')}_{n.get('uuid') or n.get('password')}"
        if fp not in seen_keys:
            seen_keys.add(fp)
            unique_nodes.append(n)
            
    print(f"[Parser] 获取到去重节点共计: {len(unique_nodes)} 个，开始批量查询地理归属 (IP-API Batch)...", flush=True)
    
    final_nodes = resolve_ips_country(unique_nodes)
    
    cache_path = "/etc/sing-box/nodes_cache.json"
    with open(cache_path, "w", encoding="utf-8") as f:
        json.dump(final_nodes, f, ensure_ascii=False, indent=2)
        
    print(f"[Parser] 数据缓存写入成功: {cache_path}，当前归属有效的节点共计: {len(final_nodes)} 个。", flush=True)

if __name__ == "__main__":
    main()
EOF
    chmod +x "${SB_DIR}/subscribe_parser.py"
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
      "type": "anytls",
      "tag": "anytls-in",
      "listen": "::",
      "listen_port": PORT_ANYTLS,
      "users": [
        {
          "password": "PASSWORD_VAL"
        }
      ],
      "tls": {
        "enabled": true,
        "server_name": "YM_VL_RE_VAL",
        "certificate_path": "CERT_PATH_VAL",
        "key_path": "KEY_PATH_VAL"
      }
    },
    {
      "type": "hysteria2",
      "tag": "hy2-in",
      "listen": "::",
      "listen_port": PORT_HY2,
      "users": [
        {
          "password": "PASSWORD_VAL"
        }
      ],
      "tls": {
        "enabled": true,
        "alpn": [
          "h3"
        ],
        "certificate_path": "CERT_PATH_VAL",
        "key_path": "KEY_PATH_VAL"
      }
    },
    {
      "type": "tuic",
      "tag": "tuic-in",
      "listen": "::",
      "listen_port": PORT_TUIC,
      "users": [
        {
          "uuid": "UUID_VAL",
          "password": "PASSWORD_VAL"
        }
      ],
      "congestion_control": "bbr",
      "tls": {
        "enabled": true,
        "alpn": [
          "h3"
        ],
        "certificate_path": "CERT_PATH_VAL",
        "key_path": "KEY_PATH_VAL"
      }
    },
    {
      "type": "http",
      "tag": "local-in",
      "listen": "127.0.0.1",
      "listen_port": 10080
    }
  ],
  "outbounds": [
    {
      "type": "direct",
      "tag": "direct"
    },
    {
      "type": "direct",
      "tag": "proxy-out"
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
        "inbound": [
          "local-in"
        ],
        "outbound": "proxy-out"
      },
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
        apt-get install -y curl python3 jq tar wget openssl
    elif [[ "$release" == "centos" || "$release" == "rhel" || "$release" == "rocky" || "$release" == "almalinux" ]]; then
        yum install -y epel-release
        yum makecache
        yum install -y curl python3 jq tar wget openssl
    fi
    
    # 确保文件夹存在
    mkdir -p "$SB_DIR"
    
    # 写入挂载脚本与模板
    write_subscribe_parser
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
        version="1.11.2"
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

configure_inbounds() {
    if [[ ! -x "/usr/local/bin/sing-box" ]]; then
        warn "检测到 sing-box 内核未安装！请先选择 1 安装内核后再进行配置。"
        return 1
    fi

    info "开始配置 VPS 代理入站规则..."

    read -p "请输入 VLESS-Reality 端口 [默认: 随机]: " input_port_vl
    if [[ -z "$input_port_vl" ]]; then
        if [[ -n "$PORT_VL_RE" ]]; then port_vl_re="$PORT_VL_RE"; else port_vl_re=$(get_random_port); fi
    else
        port_vl_re="$input_port_vl"
    fi

    read -p "请输入 AnyTLS 端口 [默认: 随机]: " input_port_anytls
    if [[ -z "$input_port_anytls" ]]; then
        if [[ -n "$PORT_ANYTLS" ]]; then port_anytls="$PORT_ANYTLS"; else port_anytls=$(get_random_port); fi
    else
        port_anytls="$input_port_anytls"
    fi

    read -p "请输入 Hysteria 2 端口 [默认: 随机]: " input_port_hy2
    if [[ -z "$input_port_hy2" ]]; then
        if [[ -n "$PORT_HY2" ]]; then port_hy2="$PORT_HY2"; else port_hy2=$(get_random_port); fi
    else
        port_hy2="$input_port_hy2"
    fi

    read -p "请输入 TUIC v5 端口 [默认: 随机]: " input_port_tuic
    if [[ -z "$input_port_tuic" ]]; then
        if [[ -n "$PORT_TUIC" ]]; then port_tuic="$PORT_TUIC"; else port_tuic=$(get_random_port); fi
    else
        port_tuic="$input_port_tuic"
    fi

    read -p "请输入 Reality/AnyTLS 伪装 SNI [默认: apple.com]: " input_sni
    if [[ -z "$input_sni" ]]; then
        if [[ -n "$YM_VL_RE" ]]; then ym_vl_re="$YM_VL_RE"; else ym_vl_re="apple.com"; fi
    else
        ym_vl_re="$input_sni"
    fi

    if [[ -n "$UUID" ]]; then
        uuid_val="$UUID"
    else
        uuid_val=$(/usr/local/bin/sing-box generate uuid 2>/dev/null || cat /proc/sys/kernel/random/uuid)
    fi

    if [[ -n "$PASSWORD" ]]; then
        password_val="$PASSWORD"
    else
        password_val=$(openssl rand -base64 12 | tr -d '/+=')
    fi

    if [[ -n "$PRIVATE_KEY" && -n "$PUBLIC_KEY" ]]; then
        priv_key="$PRIVATE_KEY"
        pub_key="$PUBLIC_KEY"
    else
        local keypair=$(/usr/local/bin/sing-box generate reality-keypair 2>/dev/null)
        priv_key=$(echo "$keypair" | grep -i "PrivateKey" | awk '{print $2}')
        pub_key=$(echo "$keypair" | grep -i "PublicKey" | awk '{print $2}')
    fi

    if [[ -n "$SHORT_ID" ]]; then
        short_id_val="$SHORT_ID"
    else
        short_id_val=$(openssl rand -hex 8)
    fi
    
    # 保存环境参数到持久化文件
    cat <<EOF | tr -d '\r' > "$ENV_FILE"
PORT_VL_RE=${port_vl_re}
PORT_ANYTLS=${port_anytls}
PORT_HY2=${port_hy2}
PORT_TUIC=${port_tuic}
UUID="${uuid_val}"
PASSWORD="${password_val}"
YM_VL_RE="${ym_vl_re}"
PRIVATE_KEY="${priv_key}"
PUBLIC_KEY="${pub_key}"
SHORT_ID="${short_id_val}"
ROUTING_MODE=${ROUTING_MODE:-1}
SAVED_COUNTRY_FILTER="${SAVED_COUNTRY_FILTER}"
EOF

    PORT_VL_RE=${port_vl_re}
    PORT_ANYTLS=${port_anytls}
    PORT_HY2=${port_hy2}
    PORT_TUIC=${port_tuic}
    UUID="${uuid_val}"
    PASSWORD="${password_val}"
    YM_VL_RE="${ym_vl_re}"
    PRIVATE_KEY="${priv_key}"
    PUBLIC_KEY="${pub_key}"
    SHORT_ID="${short_id_val}"
    
    info "入站配置参数已成功生成并保存。"
}

# 纯 Bash 生成并校验 config.json
generate_config_json() {
write_config_template

# 自动检查入站关键环境变量，如果为空则静默生成默认配置，防止 sed 替换空值导致 JSON 语法损坏
if [[ -z "${PORT_VL_RE}" || -z "${PORT_ANYTLS}" || -z "${PORT_HY2}" || -z "${PORT_TUIC}" || -z "${UUID}" || -z "${PASSWORD}" ]]; then
    local port_vl_re
    local port_anytls
    local port_hy2
    local port_tuic
    local ym_vl_re
    local uuid_val
    local password_val
    local priv_key
    local pub_key
    local short_id_val

    if [[ -n "$PORT_VL_RE" ]]; then port_vl_re="$PORT_VL_RE"; else port_vl_re=$(get_random_port); fi
    if [[ -n "$PORT_ANYTLS" ]]; then port_anytls="$PORT_ANYTLS"; else port_anytls=$(get_random_port); fi
    if [[ -n "$PORT_HY2" ]]; then port_hy2="$PORT_HY2"; else port_hy2=$(get_random_port); fi
    if [[ -n "$PORT_TUIC" ]]; then port_tuic="$PORT_TUIC"; else port_tuic=$(get_random_port); fi
    if [[ -n "$YM_VL_RE" ]]; then ym_vl_re="$YM_VL_RE"; else ym_vl_re="apple.com"; fi
    if [[ -n "$UUID" ]]; then uuid_val="$UUID"; else uuid_val=$(/usr/local/bin/sing-box generate uuid 2>/dev/null || cat /proc/sys/kernel/random/uuid); fi
    if [[ -n "$PASSWORD" ]]; then password_val="$PASSWORD"; else password_val=$(openssl rand -base64 12 | tr -d '/+='); fi
    
    if [[ -n "$PRIVATE_KEY" && -n "$PUBLIC_KEY" ]]; then
        priv_key="$PRIVATE_KEY"
        pub_key="$PUBLIC_KEY"
    else
        local keypair=$(/usr/local/bin/sing-box generate reality-keypair 2>/dev/null)
        priv_key=$(echo "$keypair" | grep -i "PrivateKey" | awk '{print $2}')
        pub_key=$(echo "$keypair" | grep -i "PublicKey" | awk '{print $2}')
    fi
    
    if [[ -n "$SHORT_ID" ]]; then short_id_val="$SHORT_ID"; else short_id_val=$(openssl rand -hex 8); fi

    cat <<EOF | tr -d '\r' > "$ENV_FILE"
PORT_VL_RE=${port_vl_re}
PORT_ANYTLS=${port_anytls}
PORT_HY2=${port_hy2}
PORT_TUIC=${port_tuic}
UUID="${uuid_val}"
PASSWORD="${password_val}"
YM_VL_RE="${ym_vl_re}"
PRIVATE_KEY="${priv_key}"
PUBLIC_KEY="${pub_key}"
SHORT_ID="${short_id_val}"
ROUTING_MODE=\${ROUTING_MODE:-1}
SAVED_COUNTRY_FILTER="\${SAVED_COUNTRY_FILTER}"
EOF

    PORT_VL_RE=${port_vl_re}
    PORT_ANYTLS=${port_anytls}
    PORT_HY2=${port_hy2}
    PORT_TUIC=${port_tuic}
    UUID="${uuid_val}"
    PASSWORD="${password_val}"
    YM_VL_RE="${ym_vl_re}"
    PRIVATE_KEY="${priv_key}"
    PUBLIC_KEY="${pub_key}"
    SHORT_ID="${short_id_val}"
fi

# 自动生成 10 年自签证书供 anytls / hysteria2 / tuic 共用
if [[ ! -f "${SB_DIR}/self_signed.crt" || ! -f "${SB_DIR}/self_signed.key" ]]; then
    mkdir -p "${SB_DIR}"
    openssl req -x509 -nodes -newkey rsa:2048 \
      -keyout "${SB_DIR}/self_signed.key" \
      -out "${SB_DIR}/self_signed.crt" \
      -subj "/CN=sb-inbound-self-signed" -days 3650 >/dev/null 2>&1
fi

cp "$TEMPLATE_FILE" "$CONFIG_FILE"

local default_outbound
local rules_json
local rule_sets_json
if [[ "${ROUTING_MODE:-1}" -eq 1 ]]; then
    default_outbound="proxy-out"
    rule_sets_json='{"tag": "geosite-cn", "type": "remote", "format": "binary", "url": "https://raw.githubusercontent.com/SagerNet/sing-geosite/rule-set/geosite-cn.srs", "download_detour": "direct"}, {"tag": "geoip-cn", "type": "remote", "format": "binary", "url": "https://raw.githubusercontent.com/SagerNet/sing-geoip/rule-set/geoip-cn.srs", "download_detour": "direct"}'
    rules_json='{"rule_set": "geosite-cn", "outbound": "direct"}, {"rule_set": "geoip-cn", "outbound": "direct"}'
else
    default_outbound="direct"
    rule_sets_json='{"tag": "geosite-geolocation-!cn", "type": "remote", "format": "binary", "url": "https://raw.githubusercontent.com/SagerNet/sing-geosite/rule-set/geosite-geolocation-!cn.srs", "download_detour": "direct"}, {"tag": "geoip-telegram", "type": "remote", "format": "binary", "url": "https://raw.githubusercontent.com/SagerNet/sing-geoip/rule-set/geoip-telegram.srs", "download_detour": "direct"}'
    rules_json='{"rule_set": "geosite-geolocation-!cn", "outbound": "proxy-out"}, {"rule_set": "geoip-telegram", "outbound": "proxy-out"}'
fi

local selected_node_json
if [[ -f "${SB_DIR}/selected_node.json" ]]; then
    selected_node_json=$(cat "${SB_DIR}/selected_node.json")
    if ! echo "${selected_node_json}" | jq . >/dev/null 2>&1; then
        selected_node_json='{"type": "direct", "tag": "proxy-out"}'
    fi
else
    selected_node_json='{"type": "direct", "tag": "proxy-out"}'
fi

sed -i "s#PORT_VL_RE#${PORT_VL_RE}#g" "$CONFIG_FILE"
sed -i "s#PORT_ANYTLS#${PORT_ANYTLS}#g" "$CONFIG_FILE"
sed -i "s#PORT_HY2#${PORT_HY2}#g" "$CONFIG_FILE"
sed -i "s#PORT_TUIC#${PORT_TUIC}#g" "$CONFIG_FILE"
sed -i "s#UUID_VAL#${UUID}#g" "$CONFIG_FILE"
sed -i "s#PASSWORD_VAL#${PASSWORD}#g" "$CONFIG_FILE"
sed -i "s#YM_VL_RE_VAL#${YM_VL_RE}#g" "$CONFIG_FILE"
sed -i "s#PRIVATE_KEY_VAL#${PRIVATE_KEY}#g" "$CONFIG_FILE"
sed -i "s#SHORT_ID_VAL#${SHORT_ID}#g" "$CONFIG_FILE"
sed -i "s#CERT_PATH_VAL#${SB_DIR}/self_signed.crt#g" "$CONFIG_FILE"
sed -i "s#KEY_PATH_VAL#${SB_DIR}/self_signed.key#g" "$CONFIG_FILE"
sed -i "s#DEFAULT_OUTBOUND_VAL#${default_outbound}#g" "$CONFIG_FILE"
sed -i "s#RULE_SET_PLACEHOLDER#${rule_sets_json}#g" "$CONFIG_FILE"
sed -i "s#ROUTE_RULES_PLACEHOLDER#${rules_json}#g" "$CONFIG_FILE"

# 使用 jq 进行类型安全、不依赖 sed 字符转义的 JSON 出站节点替换
jq --argjson new_outbound "${selected_node_json}" \
   '(.outbounds[] | select(.tag == "proxy-out")) = ($new_outbound + {"tag": "proxy-out"})' \
   "$CONFIG_FILE" > "${CONFIG_FILE}.tmp" && mv "${CONFIG_FILE}.tmp" "$CONFIG_FILE"

if jq . "$CONFIG_FILE" >/dev/null 2>&1; then
    info "config.json 已成功生成且通过语法合法性校验。"
else
    err "生成的 config.json 存在语法错误，请检查配置文件模板！"
fi
}

# 测试单个 TCP 节点的连通性并返回 RTT 延迟 (ms)
test_node_rtt() {
    local ip="$1"
    local port="$2"
    local start_time=$(date +%s%N)
    # 使用 Bash 自带 socket 测试 TCP 握手
    if timeout 1.5 bash -c "</dev/tcp/${ip}/${port}" >/dev/null 2>&1; then
        local end_time=$(date +%s%N)
        local rtt=$(( (end_time - start_time) / 1000000 ))
        echo "$rtt"
    else
        echo "9999"
    fi
}

# 更新并连接免费节点
connect_vpngate() {
    write_subscribe_parser
    local cache_file="${SB_DIR}/nodes_cache.json"
    local update_sub="n"
    
    if [[ "$1" == "auto" ]]; then
        update_sub="n"
    else
        if [[ -f "$cache_file" ]]; then
            read -p "是否更新免费订阅源节点？(y/N, 默认使用本地缓存): " update_sub
            update_sub=$(echo "$update_sub" | tr '[:upper:]' '[:lower:]')
        else
            update_sub="y"
        fi
    fi
    
    if [[ "$update_sub" == "y" ]]; then
        info "正在从所有订阅源拉取最新节点并解析 IP 归属 (这可能需要 10-20 秒，请稍后)..."
        python3 "${SB_DIR}/subscribe_parser.py"
    fi
    
    if [[ ! -f "$cache_file" ]]; then
        err "未能生成节点缓存，请检查订阅源网络连通状况！"
    fi
    
    # 统计可用国家的简称及各自的节点数量
    local countries_summary
    countries_summary=$(jq -r '.[] | .country_code' "$cache_file" 2>/dev/null | sort | uniq -c | sort -rn | awk '{printf "%s(%s) ", $2, $1}' | sed 's/ $//')

    local country_filter
    if [[ "$1" == "auto" ]]; then
        country_filter="${SAVED_COUNTRY_FILTER}"
        info "[后台自愈] 检测到自动重连请求，使用历史国家过滤器: [${country_filter:-所有国家}]"
    else
        echo -e "当前可用国家及节点数统计: \033[36m${countries_summary}\033[0m"
        read -p "过滤指定国家节点 (例如: JP, US, KR，直接回车显示所有评分最高节点): " country_filter
        country_filter=$(echo "$country_filter" | tr '[:lower:]' '[:upper:]')
        
        sed -i '/SAVED_COUNTRY_FILTER=/d' "$ENV_FILE" 2>/dev/null
        echo "SAVED_COUNTRY_FILTER=\"${country_filter}\"" >> "$ENV_FILE"
    fi
    
    # 筛选出符合条件的节点并取前 25 个
    local nodes_json
    if [[ -n "$country_filter" ]]; then
        nodes_json=$(jq -c "[.[] | select(.country_code == \"${country_filter}\")] | .[0:25]" "$cache_file")
    else
        nodes_json=$(jq -c ".[0:25]" "$cache_file")
    fi
    
    local total_nodes=$(echo "$nodes_json" | jq '. | length')
    if [[ "$total_nodes" -eq 0 ]]; then
        warn "未找到匹配国家 [${country_filter}] 的节点。"
        return
    fi
    
    declare -A node_server
    declare -A node_port
    declare -A node_proto
    declare -A node_country
    declare -A node_isp
    declare -A node_json_str
    
    # 展开解析
    for j in $(seq 1 $total_nodes); do
        local idx=$((j-1))
        local item=$(echo "$nodes_json" | jq -c ".[${idx}]")
        node_server[$j]=$(echo "$item" | jq -r '.server')
        node_port[$j]=$(echo "$item" | jq -r '.server_port')
        node_proto[$j]=$(echo "$item" | jq -r '.type')
        node_country[$j]=$(echo "$item" | jq -r '.country')
        node_isp[$j]=$(echo "$item" | jq -r '.isp')
        # 将 tag 强制覆盖为 proxy-out，并移除 ip-api 探测产生的冗余属性以符合 sing-box json 约束
        node_json_str[$j]=$(echo "$item" | jq -c '. + {tag: "proxy-out"} | del(.country, .country_code, .isp, .server_ip, .fetched_at)')
    done
    
    # 多线程进行延迟测速
    info "正在对前 ${total_nodes} 个节点进行并发连通性测试 (TCP 延迟)..."
    declare -A test_pids
    for j in $(seq 1 $total_nodes); do
        (
            local rtt
            rtt=$(test_node_rtt "${node_server[$j]}" "${node_port[$j]}")
            echo "$rtt" > "/tmp/node_rtt_${j}.txt"
        ) &
        test_pids[$j]=$!
    done
    
    for j in $(seq 1 $total_nodes); do
        wait ${test_pids[$j]} 2>/dev/null
    done
    
# 打印表格（仅包含可用且已排序的节点）
declare -A node_rtt
local available_indices=()

for j in $(seq 1 $total_nodes); do
    local rtt=$(cat "/tmp/node_rtt_${j}.txt" 2>/dev/null)
    rm -f "/tmp/node_rtt_${j}.txt"
    [[ -z "$rtt" ]] && rtt="9999"
    node_rtt[$j]="$rtt"
    if [[ "$rtt" -lt 9999 ]]; then
        available_indices+=($j)
    fi
done

local sorted_available_indices=()
if [[ "${#available_indices[@]}" -gt 0 ]]; then
    sorted_available_indices=($(
        for idx in "${available_indices[@]}"; do
            echo "$idx ${node_rtt[$idx]}"
        done | sort -k2,2n | awk '{print $1}'
    ))
fi

echo -e "\n------------------------------------------------------------------------------------------------"
printf "%-5s | %-10s | %-12s | %-12s | %-8s | %-20s | %-12s\n" "序号" "协议" "延迟" "国家" "端口" "服务器地址" "网络提供商"
echo "------------------------------------------------------------------------------------------------"

local show_idx=1
for idx in "${sorted_available_indices[@]}"; do
    local rtt_show="${node_rtt[$idx]} ms"
    printf "\033[36m%-5s\033[0m | %-10s | %-12b | %-12s | %-8s | %-20s | %-12s\n" "$show_idx" "${node_proto[$idx]}" "$rtt_show" "${node_country[$idx]}" "${node_port[$idx]}" "${node_server[$idx]:0:18}..." "${node_isp[$idx]}"
    show_idx=$((show_idx+1))
done
echo "------------------------------------------------------------------------------------------------"

local try_indices=("${sorted_available_indices[@]}")
local total_try=${#try_indices[@]}
if [[ "$total_try" -eq 0 ]]; then
    warn "没有可用节点！"
    return 1
fi
info "已整理候选队列：按延迟排序仅尝试这 ${total_try} 个可用节点（已过滤掉不可用节点）。"

local success=0
    local try_count=0
    for idx in "${try_indices[@]}"; do
        try_count=$((try_count+1))
        local server_ip="${node_server[$idx]}"
        local server_port="${node_port[$idx]}"
        local proto="${node_proto[$idx]}"
        local country="${node_country[$idx]}"
        local rtt="${node_rtt[$idx]}"
        local node_json="${node_json_str[$idx]}"
        
        info "[自动连接] ($try_count/$total_try) 正在尝试节点: 协议=${proto} | 服务器=${server_ip}:${server_port} | 国家=${country} | 延迟=${rtt}ms"
        
        # 1. 缓存当前选择的 outbound json
        echo "$node_json" > "${SB_DIR}/selected_node.json"
        
        # 2. 重新拼接生成 config.json
        generate_config_json
        
        # 3. 重启 sing-box 服务
        systemctl restart sing-box
        sleep 2
        
        # 4. 连通性测试，最长等待 10 秒
        local connected=0
        local check_timeout=10
        for s in $(seq 1 $check_timeout); do
            if ! systemctl is-active --quiet sing-box; then
                warn "  -> sing-box 进程异常退出！"
                break
            fi
            
            # 探测是否能够通过代理访问外网（严格进行合法 IP 正则匹配）
            local probe_ip
            probe_ip=$(curl -s4m4 -x http://127.0.0.1:10080 icanhazip.com 2>/dev/null | tr -d '\r\n ')
            if [[ "$probe_ip" =~ ^[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}$ ]]; then
                connected=1
                break
            fi
            
            echo -ne "  -> 代理出站测试中... (${s}/${check_timeout}s)\r"
            sleep 1
        done
        echo ""
        
        if [[ "$connected" -eq 1 ]]; then
            success=1
            info "🎉 节点连接成功！"
            local ip_info=$(curl -s4m5 -x http://127.0.0.1:10080 ip-api.com/json/ 2>/dev/null)
            if [[ -n "$ip_info" ]]; then
                local vpn_ip=$(echo "$ip_info" | jq -r '.query' 2>/dev/null)
                local vpn_country=$(echo "$ip_info" | jq -r '.country' 2>/dev/null)
                local vpn_isp=$(echo "$ip_info" | jq -r '.isp' 2>/dev/null)
                info "实际外网出站 IP: ${CYAN}${vpn_ip}${PLAIN} (${vpn_country} - ${vpn_isp})"
            fi
            break
        else
            warn "[自动连接] 节点 ${server_ip} 代理出站测试失败，正清理并尝试下一个..."
        fi
    done
    
    if [[ "$success" -ne 1 ]]; then
        # 回退至直连
        rm -f "${SB_DIR}/selected_node.json"
        generate_config_json
        systemctl restart sing-box
        err "已尝试完候选队列中的所有节点，均未能成功连接。已重置为默认直连出站。"
    fi
}

# 设置分流路由模式
configure_routing_mode() {
    echo -e "\n~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~"
    cyan "请选择出站分流路由模式："
    echo "1. 【全局代理模式】 (默认除 CN 中国大陆流量直连，其余所有出站全部走代理出口)"
    echo "2. 【规则分流模式】 (默认直连，仅境外主流服务如 Google/Netflix/Telegram 走代理出口)"
    read -p "请输入模式【1-2】[当前:${ROUTING_MODE:-1}]: " choice_mode
    
    case "$choice_mode" in
        1) ROUTING_MODE=1 ;;
        2) ROUTING_MODE=2 ;;
        *) warn "输入错误或保持默认，未修改路由模式。" ;;
    esac
    
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
}

# 停止服务
stop_services() {
    info "正在停止相关服务..."
    systemctl stop sing-box 2>/dev/null
    info "所有相关服务均已停止。"
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

    echo -e "
======================= 运行状态 ======================="
    if systemctl is-active --quiet sing-box; then
        echo -e "sing-box 运行状态: ${GREEN}运行中 (Active)${PLAIN}"

        # 查看当前选中的代理出口节点
        if [[ -f "${SB_DIR}/selected_node.json" ]]; then
            local proto=$(jq -r '.type' "${SB_DIR}/selected_node.json" 2>/dev/null)
            local server=$(jq -r '.server' "${SB_DIR}/selected_node.json" 2>/dev/null)
            local port=$(jq -r '.server_port' "${SB_DIR}/selected_node.json" 2>/dev/null)
            echo -e "代理出站节点:     ${CYAN}${proto}://${server}:${port}${PLAIN}"

            # 严格使用合法 IP 正则匹配测试代理出站连通性
            local ip_info=$(curl -s4m5 -x http://127.0.0.1:10080 ip-api.com/json/ 2>/dev/null)
            if [[ -n "$ip_info" ]]; then
                local vpn_ip=$(echo "$ip_info" | jq -r '.query' 2>/dev/null)
                local country=$(echo "$ip_info" | jq -r '.country' 2>/dev/null)
                local isp=$(echo "$ip_info" | jq -r '.isp' 2>/dev/null)
                if [[ -n "$vpn_ip" && "$vpn_ip" != "null" ]]; then
                    echo -e "代理实际出口 IP:   ${CYAN}${vpn_ip}${PLAIN} (${country} - ${isp})"
                else
                    echo -e "代理实际出口 IP:   ${YELLOW}通道正常但未能获取出口归属${PLAIN}"
                fi
            else
                echo -e "代理实际出口 IP:   ${RED}代理通道似乎断开，无法连通外网${PLAIN}"
            fi
        else
            echo -e "代理实际出口 IP:   ${YELLOW}直连模式 (Direct)${PLAIN}"
        fi
    else
        echo -e "sing-box 运行状态: ${RED}未启动 (Inactive)${PLAIN}"
        echo -e "${RED}--- sing-box 最近的错误日志 ---${PLAIN}"
        journalctl -u sing-box --no-pager -n 15
        echo -e "${RED}-------------------------------${PLAIN}"
    fi

    # 监测断线自愈守护进程状态
    local keepalive_status="${RED}未启动 (Inactive)${PLAIN}"
    if systemctl is-active --quiet vpngate-keepalive 2>/dev/null; then
        keepalive_status="${GREEN}运行中 (Active)${PLAIN}"
    fi
    echo -e "断线自愈重连守护:  ${keepalive_status}"

    # 检测当前出站策略模式
    if [[ "$ROUTING_MODE" -eq 2 ]]; then
        echo -e "分流出站路由模式:  ${CYAN}全局代理模式 (所有流量强制走境外代理出站)${PLAIN}"
    else
        echo -e "分流出站路由模式:  ${CYAN}规则分流模式 (除中国流量直连，其余全部走代理)${PLAIN}"
    fi

    if [[ -z "$UUID" || -z "$PASSWORD" ]]; then
        warn "尚未配置 VPS 代理入站参数，请先执行选项 2 进行配置。"
        return
    fi

    echo -e "
======================= 端口与密钥 ======================="
    echo -e "VLESS-Reality 端口: ${CYAN}${PORT_VL_RE}${PLAIN}"
    echo -e "AnyTLS 端口:        ${CYAN}${PORT_ANYTLS}${PLAIN}"
    echo -e "Hysteria 2 端口:    ${CYAN}${PORT_HY2}${PLAIN}"
    echo -e "TUIC v5 端口:       ${CYAN}${PORT_TUIC}${PLAIN}"
    echo -e "入站 UUID 密钥:     ${CYAN}${UUID}${PLAIN}"
    echo -e "AnyTLS/TUIC 密码:   ${CYAN}${PASSWORD}${PLAIN}"

    echo -e "
======================= 客户端连接 (分享链接) ======================="

    # VLESS Reality 节点
    local vless_link="vless://${UUID}@${vps_ip}:${PORT_VL_RE}?encryption=none&flow=xtls-rprx-vision&security=reality&sni=${YM_VL_RE}&fp=chrome&pbk=${PUBLIC_KEY}&sid=${SHORT_ID}#VLESS_Reality"
    echo -e "[35;1m1. VLESS-Reality 链接:[0m"
    echo "$vless_link"

    # AnyTLS 节点
    local anytls_link="anytls://${PASSWORD}@${vps_ip}:${PORT_ANYTLS}?security=tls&sni=${YM_VL_RE}&allowInsecure=1#AnyTLS"
    echo -e "
[35;1m2. AnyTLS 节点链接:[0m"
    echo "$anytls_link"

    # Hysteria 2 节点
    local hy2_link="hysteria2://${PASSWORD}@${vps_ip}:${PORT_HY2}?insecure=1&sni=${YM_VL_RE}&alpn=h3#Hysteria2"
    echo -e "
[35;1m3. Hysteria 2 链接:[0m"
    echo "$hy2_link"

    # TUIC v5 节点
    local tuic_link="tuic://${UUID}:${PASSWORD}@${vps_ip}:${PORT_TUIC}?congestion_control=bbr&alpn=h3&allow_insecure=1#TUIC5"
    echo -e "
[35;1m4. TUIC v5 链接:[0m"
    echo "$tuic_link"

    echo -e "
============================================================
"
}

# 查看运行日志
view_logs() {
    echo -e "\n~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~"
    cyan "           请选择要查看的日志类型："
    echo " 1. 查看 sing-box 运行日志 (最后 50 行)"
    echo " 2. 实时滚动追踪 (tail -f) sing-box 日志"
    echo " 0. 返回主菜单"
    echo "~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~"
    local log_choice
    read -p "请输入选项【0-2】: " log_choice
    
    case "$log_choice" in
        1)
            info "正在拉取 sing-box 运行日志 (最后 50 行)..."
            journalctl -u sing-box --no-pager -n 50
            ;;
        2)
            info "开始实时追踪 sing-box 日志 (按 Ctrl+C 退出)..."
            journalctl -u sing-box -f
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
    rm -f /etc/systemd/system/sing-box.service
    systemctl daemon-reload
    
    # 删除二进制核心与配置目录
    rm -f /usr/local/bin/sing-box
    rm -rf "$SB_DIR"
    
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
# 免费节点掉线自愈监控守护脚本
ENV_FILE="/etc/sing-box/sb-vpngate.env"

info() { echo -e "\033[32m[Keepalive] \$1\033[0m"; }
warn() { echo -e "\033[33m[Keepalive] \$1\033[0m"; }

# 引入配置
[[ -f "\$ENV_FILE" ]] && source "\$ENV_FILE"

SCRIPT_PATH="${script_abs_path}"

info "断线自愈监控已启动。检测周期: 60 秒。"

while true; do
    if systemctl is-active --quiet sing-box; then
        # 只有在存在选定节点时才进行自愈探测，以防初始未配置而死循环
        if [[ -f "/etc/sing-box/selected_node.json" ]]; then
            local test_ok=0
            # 检测 sing-box http 代理端口（严格进行合法 IP 正则匹配）
            local probe_ip
            probe_ip=\$(curl -s4m4 -x http://127.0.0.1:10080 icanhazip.com 2>/dev/null | tr -d '\\r\\n ')
            if [[ "\$probe_ip" =~ ^[0-9]{1,3}\\.[0-9]{1,3}\\.[0-9]{1,3}\\.[0-9]{1,3}\$ ]]; then
                test_ok=1
            fi
            
            if [[ "\$test_ok" -eq 0 ]]; then
                warn "⚠️ 检测到代理出站通道断开或网络不可达！开始执行自动故障漂移自愈..."
                bash "\${SCRIPT_PATH}" auto-connect
            fi
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
After=network.target sing-box.service

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
    cyan "           sing-box 入站 / 免费节点链式策略分流出站 一键脚本 (纯 Bash 版) "
    echo " 1. 安装/更新 Sing-box 依赖及主内核 "
    echo " 2. 配置并生成 Sing-box 入站配置 (VLESS-Reality / VMess-WS) "
    echo " 3. 更新并连接免费节点 (从 6 个订阅源自动抓取/测速/过滤) "
    echo " 4. 修改策略出站分流模式 (全局/规则分流) "
    echo " 5. 启动服务 (sing-box) "
    echo " 6. 停止服务 "
    echo " 7. 查看当前运行状态与配置连接信息 "
    echo " 8. 查看运行日志 "
    echo " 9. 彻底卸载本脚本服务 "
    echo -e " 10. 开启/关闭 节点掉线自动重连守护服务 (当前: ${keepalive_status}) "
    echo " 0. 退出脚本 "
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
