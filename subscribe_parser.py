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

def parse_mixed_subscription(content):
    # 尝试 Base64 订阅
    decoded = decode_base64_safely(content)
    if decoded:
        return parse_v2ray_urls(decoded)
        
    # 如果解码失败，尝试直接作为 v2ray URLs 文本解析
    return parse_v2ray_urls(content)

def parse_v2ray_urls(content):
    nodes = []
    links = re.findall(r'(vmess://[a-zA-Z0-9+/=\-_]+|vless://[^\s]+|ss://[^\s]+|trojan://[^\s]+)', content)
    for link in links:
        node = parse_single_link(link)
        if node:
            nodes.append(node)
    return nodes

def query_ip_risk(ip, timeout=5):
    url = f"http://ip234.in/fraud_check?ip={ip}"
    try:
        req = urllib.request.Request(
            url, 
            headers={'User-Agent': 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36'}
        )
        with urllib.request.urlopen(req, timeout=timeout) as response:
            res_data = json.loads(response.read().decode('utf-8'))
            if res_data and res_data.get('code') == 0:
                data = res_data.get('data', {})
                risk_str = data.get("risk", "未知")
                if risk_str.endswith("风险"):
                    risk_str = risk_str[:-2]
                return ip, {
                    "risk": risk_str,
                    "risk_score": data.get("score", "-")
                }
    except Exception:
        pass
    return ip, {"risk": "未知", "risk_score": "-"}

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
            
    # 并发查询 IP 风险值
    risk_results = {}
    with ThreadPoolExecutor(max_workers=10) as executor:
        futures = {executor.submit(query_ip_risk, ip): ip for ip in ips_to_query}
        for future in futures:
            ip, risk_info = future.result()
            risk_results[ip] = risk_info
            
    valid_nodes = []
    for ip, node_list in ip_to_nodes.items():
        res = results.get(ip, {"country": "Unknown", "country_code": "XX", "isp": "Unknown"})
        risk_res = risk_results.get(ip, {"risk": "未知", "risk_score": "-"})
        for node in node_list:
            node["country"] = res["country"]
            node["country_code"] = res["country_code"]
            node["isp"] = res["isp"]
            node["risk"] = risk_res["risk"]
            node["risk_score"] = risk_res["risk_score"]
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
