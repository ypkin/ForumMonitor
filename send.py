import json
import requests
import os
import re
import html
from requests.adapters import HTTPAdapter
from urllib3.util.retry import Retry
from datetime import datetime

GREEN = '\033[0;32m'
RED = '\033[0;31m'
YELLOW = '\033[0;33m'
NC = '\033[0m'
GRAY = '\033[0;90m'

def log(msg, color=NC, icon=""):
    timestamp = datetime.now().strftime("%H:%M:%S")
    prefix = f"{icon} " if icon else ""
    print(f"{GRAY}[{timestamp}]{NC} {color}{prefix}{msg}{NC}")

class NotificationSender:
    def __init__(self, config_path='data/config.json'):
        self.config_path = config_path
        base_dir = os.path.dirname(os.path.abspath(config_path))
        self.stats_path = os.path.join(base_dir, 'stats.json')
        self.pushplus_token = ""
        self.tg_bot_token = ""
        self.tg_chat_id = ""
        self.enable_pushplus = True
        self.enable_telegram = True
        
        self.session = requests.Session()
        self.session.headers.update({'User-Agent': 'curl/7.74.0'})
        adapter = HTTPAdapter(max_retries=Retry(total=3, backoff_factor=1))
        self.session.mount("https://", adapter)
        self.load_config()

    def load_config(self):
        try:
            with open(self.config_path, 'r') as f:
                cfg = json.load(f)['config']
                self.pushplus_token = cfg.get('pushplus_token', '')
                self.tg_bot_token = cfg.get('telegram_bot_token', '')
                self.tg_chat_id = cfg.get('telegram_chat_id', '')
                self.enable_pushplus = cfg.get('enable_pushplus', True)
                self.enable_telegram = cfg.get('enable_telegram', True)
        except: pass

    def record_success(self):
        try:
            stats = {}
            if os.path.exists(self.stats_path):
                with open(self.stats_path, 'r') as f: stats = json.load(f)
            stats['push_count'] = stats.get('push_count', 0) + 1
            with open(self.stats_path, 'w') as f: json.dump(stats, f)
        except Exception as e: log(f"Stats Error: {e}", RED, "❌")

    def send_message(self, message):
        return self.send_html_message("ForumMonitor Notification", message)

    def send_telegram(self, title, html_content):
        if not self.enable_telegram: return False
        if not self.tg_bot_token or not self.tg_chat_id: return False
        try:
            # 1. Clean up HTML for Telegram
            msg = html_content 
            msg = msg.replace("<br>", "\n").replace("<br/>", "\n")
            msg = re.sub(r'<div.*?>', '', msg).replace('</div>', '\n')
            msg = re.sub(r'<span.*?>', '', msg).replace('</span>', ' ')
            while "\n\n\n" in msg: msg = msg.replace("\n\n\n", "\n\n")
            
            messages = []
            # Updated Max Length to Telegram API limit (4096)
            MAX_LEN = 4095
            if len(msg) > MAX_LEN:
                while len(msg) > 0:
                    if len(msg) <= MAX_LEN: messages.append(msg); break
                    split_idx = msg.rfind('\n', 0, MAX_LEN)
                    if split_idx == -1: split_idx = MAX_LEN
                    messages.append(msg[:split_idx])
                    msg = msg[split_idx:]
            else: messages.append(msg)

            all_success = True
            for i, part in enumerate(messages):
                url = f"https://api.telegram.org/bot{self.tg_bot_token}/sendMessage"
                
                # Try sending as HTML first
                payload = {'chat_id': self.tg_chat_id, 'text': part, 'parse_mode': 'HTML', 'disable_web_page_preview': True}
                resp = self.session.post(url, json=payload, timeout=15)
                
                if resp.status_code == 200: 
                    log(f"Telegram Success: {title[:25]}...", GREEN, "✈️")
                else:
                    # --- Failover: Try sending as Plain Text if HTML fails ---
                    if resp.status_code == 400:
                        log(f"⚠️ TG HTML Error ({resp.status_code}). Retrying as Plain Text...", YELLOW)
                        # Strip all tags and UNESCAPE HTML entities (e.g. &lt; -> <)
                        clean_text = re.sub(r'<[^>]+>', '', part)
                        clean_text = html.unescape(clean_text)
                        
                        payload_retry = {'chat_id': self.tg_chat_id, 'text': clean_text, 'disable_web_page_preview': True}
                        retry_resp = self.session.post(url, json=payload_retry, timeout=15)
                        
                        if retry_resp.status_code == 200:
                             log(f"Telegram Text Retry Success: {title[:25]}...", GREEN, "✈️")
                             continue
                        else:
                             log(f"Retry Failed: {retry_resp.text}", RED)
                    # -------------------------------------------------------
                    
                    log(f"Telegram Failed ({resp.status_code}): {resp.text}", RED, "❌"); all_success = False
            return all_success
        except Exception as e: log(f"Telegram Error: {e}", RED, "❌"); return False

    def send_html_message(self, title, html_content):
        success_count = 0
        
        # Pushplus
        if self.enable_pushplus and self.pushplus_token and self.pushplus_token != "YOUR_PUSHPLUS_TOKEN_HERE":
            try:
                pp_title = title[:90] + "..." if len(title) > 95 else title
                payload = {"token": self.pushplus_token, "title": pp_title, "content": html_content, "template": "html"}
                resp = self.session.post("https://www.pushplus.plus/send", json=payload, timeout=15)
                if resp.status_code == 200 and resp.json().get('code') == 200:
                    log(f"Pushplus Success: {title[:25]}...", GREEN, "📨"); success_count += 1
                else: 
                    reason = resp.text
                    level = RED
                    if "用户账号使用受限" in reason: level = YELLOW
                    log(f"Pushplus Failed ({resp.status_code}): {reason}", level, "❌")
            except Exception as e: log(f"Pushplus Error: {e}", RED, "❌")

        # Telegram
        if self.send_telegram(title, html_content): success_count += 1
        
        if success_count > 0: self.record_success(); return True
        return False
