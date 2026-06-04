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
    "https://raw.githubusercontent.com/PuddinCat/BestClash/refs/heads/main/proxies.yaml",
    "https://raw.githubusercontent.com/free-nodes/v2rayfree/main/v202606032",
    "https://fn09.sp0502.xyz/nodes/14a5a27704e4475ce7bf687a2103b638",
    "https://fn09.sp0502.xyz/nodes/bacc647434001f1375a7af64aa7b42c5",
    "https://fn09.sp0502.xyz/nodes/248ccebb9915c02fd0f42be0b1c1cd95",
    "https://fn09.sp0502.xyz/nodes/8b8098a888c0950f13743f60a849cd06",
    "https://fn09.sp0502.xyz/nodes/35ac9a6e5aac32e12b26abe4dcb2de19",
    "https://fn09.sp0502.xyz/nodes/2e76faa24d0e485caa2446d13986d974",
    "https://fn09.sp0502.xyz/nodes/fd29cc4df1f30ecfe44f6419bb75d40b",
    "https://fn09.sp0502.xyz/nodes/42b986f932bd17d0fc5a38c21ece65e3",
    "https://fn09.sp0502.xyz/nodes/1d43a9f4f7a9e582cdfd692891b24b5b",
    "https://fn09.sp0502.xyz/nodes/5155fd7b525491778e791bf12124aa38",
    "https://fn09.sp0502.xyz/nodes/565f573024cc7bd950197902461bbd4c",
    "https://fn09.sp0502.xyz/nodes/d7c8d91cfdc698b4f5ce12de5b420d2c",
    "https://5kKWmk.tosslk.xyz/9c6c45fbcdf09b1f7e0a1bdd8c02e4eb",
    "https://raw.githubusercontent.com/shaoyouvip/free/refs/heads/main/all.yaml",
    "https://raw.githubusercontent.com/shaoyouvip/free/refs/heads/main/base64.txt",
    "https://proxy.v2gh.com/https://raw.githubusercontent.com/Pawdroid/Free-servers/main/sub",
    "https://mirror.v2gh.com/https://raw.githubusercontent.com/Pawdroid/Free-servers/main/sub",
    "https://raw.githubusercontent.com/caijh/FreeProxiesScraper/master/Eternity",
    "https://raw.githubusercontent.com/caijh/FreeProxiesScraper/master/Eternity.yaml",
    "https://2REeRj.tosslk.xyz/bb6ee19c4b761ed9fddd9ef67d3049dd",
    "https://raw.githubusercontent.com/hello-world-1989/cn-news/main/end-gfw-together",
    "https://raw.githubusercontent.com/hello-world-1989/cn-news/refs/heads/main/clash.yaml",
    "https://raw.githubusercontent.com/ssrsub/ssr/master/v2ray",
    "https://raw.githubusercontent.com/ssrsub/ssr/master/clash.yaml",
    "https://raw.githubusercontent.com/shaoyouvip/free/refs/heads/main/mihomo.yaml",
    "https://dlconf.clashapps.cc/yaml/9ebbe501-eb58-c360-95cc-dae9cea09453.yaml",
    "https://sub.pmsub.me/clash.yaml",
    "https://sub.sharecentre.online/sub",
    "https://sub.5112233.xyz/auto"
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
    except Exception as e:
        return None, url

def parse_vmess(link):
    try:
        b64_str = link[8:].split('#')[0]
        decoded = decode_base64_safely(b64_str)
        if not decoded:
            return None
        data = json.loads(decoded)
        
        # 兼容部分订阅里端口写成字符串的情况
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
            # 兼容 ss://base64_string 结构
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

def convert_clash_to_singbox(data):
    try:
        t = data.get("type", "").lower()
        server = data.get("server")
        port = data.get("port")
        if not server or not port:
            return None
            
        port = int(port)
        outbound = {
            "type": t,
            "server": server,
            "server_port": port
        }
        
        if t == "vmess":
            outbound["uuid"] = data.get("uuid")
            outbound["security"] = data.get("cipher", "auto")
            outbound["alter_id"] = int(data.get("alterId", 0))
            
            net = str(data.get("network", "")).lower()
            ws_opts = data.get("ws-opts", {})
            if net == "ws":
                outbound["transport"] = {
                    "type": "ws",
                    "path": ws_opts.get("path", "/"),
                    "headers": {}
                }
                ws_host = ws_opts.get("headers", {}).get("Host") or data.get("servername")
                if ws_host:
                    outbound["transport"]["headers"]["Host"] = ws_host
                    
            if str(data.get("tls", "")).lower() == "true" or port == 443:
                outbound["tls"] = {
                    "enabled": True,
                    "server_name": data.get("servername") or server
                }
                
        elif t == "vless":
            outbound["uuid"] = data.get("uuid")
            outbound["flow"] = data.get("flow", "")
            
            tls = str(data.get("tls", "")).lower() == "true"
            reality = str(data.get("reality", "")).lower() == "true"
            if tls or reality:
                outbound["tls"] = {
                    "enabled": True,
                    "server_name": data.get("servername") or server
                }
                if reality:
                    outbound["tls"]["reality"] = {
                        "enabled": True,
                        "public_key": data.get("public-key"),
                        "short_id": data.get("short-id")
                    }
                    
            net = str(data.get("network", "")).lower()
            if net == "ws":
                ws_opts = data.get("ws-opts", {})
                outbound["transport"] = {
                    "type": "ws",
                    "path": ws_opts.get("path", "/"),
                    "headers": {}
                }
                ws_host = ws_opts.get("headers", {}).get("Host")
                if ws_host:
                    outbound["transport"]["headers"]["Host"] = ws_host
            elif net == "grpc":
                grpc_opts = data.get("grpc-opts", {})
                outbound["transport"] = {
                    "type": "grpc",
                    "service_name": grpc_opts.get("grpc-service-name", "")
                }
                
        elif t == "shadowsocks":
            outbound["type"] = "shadowsocks"
            outbound["method"] = data.get("cipher")
            outbound["password"] = data.get("password")
            
        elif t == "trojan":
            outbound["password"] = data.get("password")
            outbound["tls"] = {
                "enabled": True,
                "server_name": data.get("sni") or data.get("servername") or server
            }
        else:
            return None
            
        return outbound
    except Exception:
        return None

def parse_clash_yaml(content):
    nodes = []
    lines = content.splitlines()
    in_proxies = False
    current_node = None
    sub_key = None
    sub_dict = {}

    for line in lines:
        stripped = line.strip()
        if not stripped or stripped.startswith("#"):
            continue
            
        if not in_proxies:
            if stripped.startswith("proxies:"):
                in_proxies = True
            continue
            
        leading_spaces = len(line) - len(line.lstrip(' '))
        if leading_spaces == 0 and not stripped.startswith("proxies:"):
            in_proxies = False
            if current_node:
                nodes.append(current_node)
                current_node = None
            continue
            
        if stripped.startswith("-"):
            if current_node:
                nodes.append(current_node)
            current_node = {}
            sub_key = None
            sub_dict = {}
            item_line = stripped[1:].strip()
            if ":" in item_line:
                k, v = item_line.split(":", 1)
                k = k.strip().strip("'\"")
                v = v.strip().strip("'\"")
                current_node[k] = v
            continue
            
        if current_node is not None:
            if stripped.endswith(":"):
                sub_key = stripped[:-1].strip().strip("'\"")
                sub_dict = {}
                current_node[sub_key] = sub_dict
                continue
                
            if ":" in stripped:
                k, v = stripped.split(":", 1)
                k = k.strip().strip("'\"")
                v = v.strip().strip("'\"")
                if sub_key and leading_spaces > 4:
                    sub_dict[k] = v
                else:
                    sub_key = None
                    current_node[k] = v

    if current_node:
        nodes.append(current_node)
        
    sb_nodes = []
    for c in nodes:
        sb_node = convert_clash_to_singbox(c)
        if sb_node:
            sb_nodes.append(sb_node)
    return sb_nodes

def parse_mixed_subscription(content):
    # 尝试 Base64 订阅
    decoded = decode_base64_safely(content)
    if decoded:
        return parse_v2ray_urls(decoded)
        
    # 如果解码失败，尝试直接作为 v2ray URLs 文本解析
    nodes = parse_v2ray_urls(content)
    if nodes:
        return nodes
        
    # 否则作为 Clash YAML 结构解析
    return parse_clash_yaml(content)

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
                        # 翻译部分常用国家以符合国人阅读习惯
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
    print("[Parser] 开始拉取所有免费节点源，共计 31 个订阅地址...", flush=True)
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
                
    # 节点去重 (根据 server, port, type, uuid/password 组合去重)
    unique_nodes = []
    seen_keys = set()
    for n in all_nodes:
        # 创建唯一指纹
        fp = f"{n.get('type')}_{n.get('server')}_{n.get('server_port')}_{n.get('uuid') or n.get('password')}"
        if fp not in seen_keys:
            seen_keys.add(fp)
            unique_nodes.append(n)
            
    print(f"[Parser] 获取到去重节点共计: {len(unique_nodes)} 个，开始批量查询地理归属 (IP-API Batch)...", flush=True)
    
    # 批量解析 IP 归属国
    final_nodes = resolve_ips_country(unique_nodes)
    
    # 写入缓存文件
    cache_path = "/etc/sing-box/nodes_cache.json"
    with open(cache_path, "w", encoding="utf-8") as f:
        json.dump(final_nodes, f, ensure_ascii=False, indent=2)
        
    print(f"[Parser] 数据缓存写入成功: {cache_path}，当前归属有效的节点共计: {len(final_nodes)} 个。", flush=True)

if __name__ == "__main__":
    main()
