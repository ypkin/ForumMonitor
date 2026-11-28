import json
import time
import requests
import cloudscraper
from bs4 import BeautifulSoup
from datetime import datetime, timedelta, timezone
from send import NotificationSender
import os
import sys
import re
import random
import fcntl
import psutil
import google.generativeai as genai
from pymongo import MongoClient, errors
from concurrent.futures import ThreadPoolExecutor, as_completed

# 颜色定义
GREEN = '\033[0;32m'
YELLOW = '\033[0;33m'
RED = '\033[0;31m'
CYAN = '\033[0;36m'
BLUE = '\033[0;34m'
NC = '\033[0m'
GRAY = '\033[0;90m'
WHITE = '\033[1;37m'
MAGENTA = '\033[0;35m'

SHANGHAI = timezone(timedelta(hours=8))

def log(msg, color=NC, icon=""):
    timestamp = datetime.now(SHANGHAI).strftime("%H:%M:%S")
    prefix = f"{icon} " if icon else ""
    try:
        print(f"{GRAY}[{timestamp}]{NC} {color}{prefix}{msg}{NC}")
        sys.stdout.flush()
    except: pass

# --- AI 裁决层提示词 (v2.0): 只做准入判断, 输出 JSON, 不参与推送排版 ---
VERDICT_THREAD_PROMPT = """你是一个 VPS 优惠帖的准入裁决员。你只做一件事：判断这篇帖子值不值得推送给用户抢购。

判定规则（硬条件）：
- push=true：商家发布的真实销售帖，且包含至少一个具体套餐（配置或价格），或明确的抽奖赠送活动。
- push=false：求购帖、提问帖、讨论帖、测评帖、纯公告（无套餐）、已结束的活动说明、与 VPS 销售无关的内容。

示例：
输入："RackNerd 2GB KVM $15.88/yr, order link inside" 输出：{"push": true}
输入："Which provider has the best network to Asia?" 输出：{"push": false}
输入："We will perform maintenance this weekend" 输出：{"push": false}
输入："Giveaway: 5 free VPS for 1 year, comment to enter" 输出：{"push": true}

只输出一个 JSON：{"push": true} 或 {"push": false}。不要输出任何其他文字。"""

VERDICT_COMMENT_PROMPT = """你是一个 VPS 优惠评论的准入裁决员。你只做一件事：判断这条评论是否带来了新的抢购机会。

判定规则（硬条件）：
- push=true：评论带来新促销、补货、降价或抽奖，且至少包含以下一项具体要素：价格、订购链接、优惠码、明确的补货数量或套餐。
- push=false：顶帖(bump)、感谢、提问、晒单、订单号、闲聊；只有 "restocked"、"back in stock" 等字样但没有任何具体要素的，也不推。
- push=false：主消息是标题主推套餐已售罄，只是顺带推荐其他套餐有货——即使带订购链接或优惠码也不推（那不是补货，其他套餐原帖里本来就能买）。只有售罄套餐本身补货、或原帖没有的新优惠码/新降价，才算新机会。
- push=false：纯宣传口号刷屏——只有商家广告语加一个通用链接（主页/分类页），没有任何具体要素（价格、优惠码、补货数量、具体套餐）的，不推。这类是普通用户为抽奖复制粘贴的刷屏，通用链接不算新的下单入口。

示例：
输入："Restocked 50x 2GB plan in HK, $10/yr: https://example.com/order" 输出：{"push": true}
输入："Restocked!" 输出：{"push": false}
输入："Just ordered, order #12345, please double bandwidth" 输出：{"push": false}
输入："Use code BF50 for 50% off all plans until Friday" 输出：{"push": true}
输入："Any plan for restock?" 输出：{"push": false}
输入："Yes all of our $7/yr Linux plans are sold out. However, we have Ryzen/i9 availability: https://example.com/order?promocode=BF2GB" 输出：{"push": false}
输入："The $7/yr plan is back in stock, 30 more available: https://example.com/order?promocode=BF1GB" 输出：{"push": true}
输入："💥🔥 KABOOM! ExampleHost’s BLACKFRIDAY EVENT IS NEXT LEVEL — Grab yours now: https://www.example.com/dedicated-servers 🔥💥" 输出：{"push": false}

只输出一个 JSON：{"push": true} 或 {"push": false}。不要输出任何其他文字。"""

class ForumMonitor:
    def __init__(self, config_path='data/config.json'):
        # --- SELF-HEALING SINGLETON ---
        self.lock_file = open('/tmp/forum_monitor.lock', 'w')
        try:
            fcntl.lockf(self.lock_file, fcntl.LOCK_EX | fcntl.LOCK_NB)
        except IOError:
            log("⚡ Duplicate instance detected! Killing zombies...", YELLOW)
            self.kill_other_instances()
            time.sleep(2)
            try:
                fcntl.lockf(self.lock_file, fcntl.LOCK_EX | fcntl.LOCK_NB)
                log("✅ Zombies killed. Taking over.", GREEN)
            except:
                log("❌ Failed to acquire lock. Exiting.", RED)
                sys.exit(1)
        # ------------------------------

        self.config_path = config_path
        self.mongo_host = os.getenv("MONGO_HOST", 'mongodb://localhost:27017/')
        self.load_config()

        self.mongo_client = MongoClient(self.mongo_host) 
        self.db = self.mongo_client['forum_monitor']
        self.threads_collection = self.db['threads']
        self.comments_collection = self.db['comments']
        self.push_logs = self.db['push_logs']
        
        self.processed_urls_this_cycle = set()
        
        self.scraper = cloudscraper.create_scraper(
            browser={'browser': 'chrome', 'platform': 'windows', 'desktop': True}
        )
        self.scraper.headers.update({
            'Accept': 'text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8',
            'Accept-Language': 'en-US,en;q=0.9',
            'Referer': 'https://lowendtalk.com/',
        })

        self.ai_provider = self.config.get('ai_provider', 'gemini')
        self.thread_prompt = self.config.get('thread_prompt', '')
        self.filter_prompt = self.config.get('filter_prompt', '')

        if self.ai_provider == 'gemini':
            try:
                api_key = self.config.get('gemini_api_key')
                model_name = self.config.get('model', 'gemini-2.0-flash-lite')
                if api_key:
                    genai.configure(api_key=api_key)
                    filter_model_name = self.config.get('filter_model') or model_name
                    verdict_model_name = self.config.get('verdict_model') or model_name
                    self.model_summary = genai.GenerativeModel(model_name, system_instruction=self.thread_prompt)
                    self.model_filter = genai.GenerativeModel(filter_model_name, system_instruction=self.filter_prompt)
                    self.model_verdict_thread = genai.GenerativeModel(verdict_model_name, system_instruction=VERDICT_THREAD_PROMPT)
                    self.model_verdict_comment = genai.GenerativeModel(verdict_model_name, system_instruction=VERDICT_COMMENT_PROMPT)
                    log(f"AI Engine: Gemini ({model_name})", GREEN, "🧠")
            except Exception as e: log(f"Gemini Init Error: {e}", RED)
        elif self.ai_provider == 'workers':
            self.cf_account = self.config.get('cf_account_id')
            self.cf_token = self.config.get('cf_api_token')
            self.cf_model = self.config.get('cf_model', '@cf/meta/llama-3.1-8b-instruct')
            if self.cf_account and self.cf_token:
                log(f"AI Engine: Workers AI ({self.cf_model})", GREEN, "🧠")
            else:
                log("AI Engine: Workers AI Config Missing!", RED)

        try:
            self.threads_collection.create_index('link', unique=True)
            self.comments_collection.create_index('comment_id', unique=True)
            self.push_logs.create_index('created_at')
        except: pass

    def kill_other_instances(self):
        current_pid = os.getpid()
        for proc in psutil.process_iter(['pid', 'name', 'cmdline']):
            try:
                if proc.info['pid'] == current_pid: continue
                cmdline = proc.info.get('cmdline', [])
                if cmdline and 'core.py' in ' '.join(cmdline):
                    log(f"   -> Killing zombie PID: {proc.info['pid']}", GRAY)
                    proc.kill()
            except: pass

    def load_config(self):
        try:
            if not os.path.exists(self.config_path):
                # No example.json copy, just use empty
                self.config = {}
            with open(self.config_path, 'r') as f:
                self.config = json.load(f)['config']
                self.notifier = NotificationSender(self.config_path)
        except: self.config = {}

    def update_heartbeat(self):
        try:
            with open('data/heartbeat.txt', 'w') as f:
                f.write(str(int(time.time())))
        except: pass

    def log_push_history(self, p_type, title, url):
        try:
            self.push_logs.insert_one({
                'type': p_type, 'title': title, 'url': url,
                'created_at': datetime.now(SHANGHAI)
            })
        except: pass

    def generate_ai_content(self, system_prompt, user_content, gemini_model_instance=None, json_mode=False):
        retries = 5
        delay = 10
        for i in range(retries):
            try:
                time.sleep(1) 
                if self.ai_provider == 'gemini':
                    if gemini_model_instance:
                        gen_cfg = {"temperature": 0}
                        if json_mode: gen_cfg["response_mime_type"] = "application/json"
                        response = gemini_model_instance.generate_content(user_content, generation_config=gen_cfg)
                        return response.text
                    else: return "Gemini Not Initialized"
                elif self.ai_provider == 'workers':
                    url = f"https://api.cloudflare.com/client/v4/accounts/{self.cf_account}/ai/run/{self.cf_model}"
                    headers = {"Authorization": f"Bearer {self.cf_token}"}
                    payload = {"messages": [{"role": "system", "content": system_prompt}, {"role": "user", "content": user_content}], "temperature": 0, "max_tokens": 1024}
                    resp = requests.post(url, headers=headers, json=payload, timeout=300)
                    if resp.status_code == 200:
                        res = resp.json().get("result", {}).get("response", "FALSE")
                        if isinstance(res, (dict, list)): res = json.dumps(res, ensure_ascii=False)
                        return res
                    else: raise Exception(f"CF API Error: {resp.status_code} {resp.text}")
            except Exception as e:
                if "429" in str(e) or "quota" in str(e).lower():
                    log(f"⚠️ AI Rate Limit (429). Retrying... ({i+1}/{retries})", YELLOW)
                    time.sleep(delay); delay = int(delay * 1.5)
                else:
                    log(f"❌ AI Error: {e}", RED); return "FALSE"
        return "FALSE"

    def get_summarize_from_ai(self, description):
        try: 
            gemini_obj = self.model_summary if self.ai_provider == 'gemini' else None
            return self.generate_ai_content(self.thread_prompt, description, gemini_obj).strip()
        except: return "AI Error"

    def get_filter_from_ai(self, description):
        try:
            gemini_obj = self.model_filter if self.ai_provider == 'gemini' else None
            text = self.generate_ai_content(self.filter_prompt, description, gemini_obj).strip()
            return text
        except: return "FALSE"

    def ai_verdict(self, kind, text):
        # AI 裁决层: 返回 True=推, False=不推, None=裁决失败
        # None 时上层放行 (fail-open): 宁可多推一条, 绝不漏掉闪购
        try:
            text = (text or "")[:3000]
            if not text.strip(): return False
            if self.ai_provider == 'gemini':
                model = getattr(self, 'model_verdict_thread', None) if kind == 'thread' else getattr(self, 'model_verdict_comment', None)
                if not model: return None
                raw = self.generate_ai_content("", text, model, json_mode=True)
            elif self.ai_provider == 'workers':
                prompt = VERDICT_THREAD_PROMPT if kind == 'thread' else VERDICT_COMMENT_PROMPT
                raw = self.generate_ai_content(prompt, text, None, json_mode=True)
            else:
                return None
            if not raw: return None
            m = re.search(r'\{.*\}', raw, re.S)
            if not m: return None
            data = json.loads(m.group(0))
            if isinstance(data, dict) and 'push' in data:
                return bool(data['push'])
            return None
        except Exception as e:
            log(f"Verdict Error: {e}", RED)
            return None

    def markdown_to_html(self, text):
        text = re.sub(r'\s*\|\s*不详', '', text)
        text = re.sub(r'不详\s*\|\s*', '', text)
        text = text.replace("```html", "").replace("```", "")
        text = re.sub(r'\*\*(.*?)\*\*', r'<b>\1</b>', text)
        text = re.sub(r'`([^`\n]+)`', r'<code>\1</code>', text)
        text = re.sub(r'</?(span|div|p|font|h[1-6])[^>]*>', '', text, flags=re.IGNORECASE)
        text = text.replace('&', '&amp;')
        text = text.replace('<', '&lt;')
        text = text.replace('>', '&gt;')
        text = text.replace('&lt;b&gt;', '<b>').replace('&lt;/b&gt;', '</b>')
        text = text.replace('&lt;code&gt;', '<code>').replace('&lt;/code&gt;', '</code>')
        text = text.replace('&lt;a href="', '<a href="').replace('"&gt;', '">').replace('&lt;/a&gt;', '</a>')
        text = text.replace('\n', '<br>')
        return text.strip()

    def handle_thread(self, thread_data, extracted_links):
        try:
            self.threads_collection.insert_one(thread_data)
            now_sh = datetime.now(SHANGHAI)
            pub_date_sh = thread_data['pub_date'].astimezone(SHANGHAI)

            if (now_sh - pub_date_sh).total_seconds() <= 86400:
                verdict = self.ai_verdict('thread', thread_data.get('description', ''))
                if verdict is False:
                    log(f"   🚫 [Verdict] 新帖未通过裁决, 不推送: {thread_data['title'][:30]}", GRAY)
                    return True
                log(f"AI 正在摘要: {thread_data['title'][:20]}...", YELLOW, "🤖")
                raw_summary = self.get_summarize_from_ai(thread_data['description'])
                if not raw_summary or raw_summary.strip().upper() in ("FALSE", "AI ERROR"):
                    log(f"   ⚠️ AI 摘要失败, 本轮不推, 删记录下轮重试: {thread_data['title'][:30]}", YELLOW)
                    try: self.threads_collection.delete_one({'_id': thread_data['_id']})
                    except: pass
                    return True
                html_summary = self.markdown_to_html(raw_summary)
                html_summary = html_summary.replace("[ORDER_LINK_HERE]", "")

                time_str = pub_date_sh.strftime('%Y-%m-%d %H:%M')
                safe_title = thread_data['title'].replace('<', '&lt;').replace('>', '&gt;')
                safe_creator = thread_data['creator'].replace('<', '&lt;').replace('>', '&gt;')
                model_n = self.config.get('model') if self.ai_provider == 'gemini' else self.config.get('cf_model')

                msg_content = (
                    f"<b>🟢 [新帖] {safe_title}</b>\n"
                    f"👤 {safe_creator} | 🕒 {time_str} | 🤖 {model_n}\n"
                    f"{'-'*20}\n"
                    f"{html_summary}\n" 
                    f"{'-'*20}\n"
                    f"原文链接: {thread_data['link']}"
                )
                msg_content = msg_content.replace('\n', '<br>')
                
                if self.notifier.send_html_message(f"🟢 [新帖] {safe_title}", msg_content):
                    self.log_push_history("thread", thread_data['title'], thread_data['link'])

            return True 
        except errors.DuplicateKeyError: return False
        except: return False

    def handle_comment(self, comment_data, thread_data, created_at_sh):
        try:
            self.comments_collection.insert_one(comment_data)
            log(f"   ✅ [新回复] {comment_data['author']} (活跃中...)", GREEN)
            
            if not comment_data['message'].strip(): return

            # --- [HARD FILTER] 强力过滤系统 (v76/v77) ---
            msg_lower = comment_data['message'].lower()

            # 1. 拦截翻倍/晒单
            if ("order" in msg_lower or "invoice" in msg_lower) and ("double" in msg_lower or "bandwidth" in msg_lower):
                log(f"      🚫 [Filter] 拦截翻倍/晒单", GRAY); return
            
            # 2. 拦截纯订单号
            if len(msg_lower) < 60 and (("order" in msg_lower and "#" in msg_lower) or "invoice" in msg_lower):
                log(f"      🚫 [Filter] 拦截纯订单号", GRAY); return

            # 3. 拦截无意义短回复
            junk_words = ["pm sent", "check pm", "sent you a pm", "replied", "ticket opened", "check ticket", "thanks", "thx", "good luck", "nice offer", "upvoted", "support", "ticket #", "dm sent"]
            if len(msg_lower) < 50 and any(k in msg_lower for k in junk_words):
                 log(f"      🚫 [Filter] 拦截水贴/工单回复", GRAY); return
            
            # 4. 极短纯文本拦截
            if len(msg_lower) < 10 and not any(c.isdigit() for c in msg_lower):
                 log(f"      🚫 [Filter] 拦截极短回复", GRAY); return
            # ---------------------------------------------

            verdict = self.ai_verdict('comment', comment_data['message'])
            if verdict is False:
                log(f"      🚫 [Verdict] 评论未通过裁决", GRAY); return

            ai_resp = self.get_filter_from_ai(comment_data['message'])
            upper_resp = ai_resp.upper()
            if "FALSE" in upper_resp or "无法分析" in ai_resp or "CANNOT" in upper_resp:
                log(f"      🚫 [Filter] AI 判定无新机会", GRAY)

            if "FALSE" not in upper_resp and "无法分析" not in ai_resp and "CANNOT" not in upper_resp:
                log(f"      🚀 关键词匹配! 推送中...", GREEN)
                ai_resp_html = self.markdown_to_html(ai_resp)
                
                tp = thread_data.get('creator', 'Unknown').replace('<', '&lt;').replace('>', '&gt;')
                ra = comment_data['author'].replace('<', '&lt;').replace('>', '&gt;')
                tt = thread_data.get('title', 'Unknown').replace('<', '&lt;').replace('>', '&gt;')
                model_n = self.config.get('model') if self.ai_provider == 'gemini' else self.config.get('cf_model')
                time_str = created_at_sh.strftime('%Y-%m-%d %H:%M')
                
                is_op = (comment_data['author'] == thread_data['creator'])
                type_label = "回复" if is_op else "插播"
                type_icon = "🔵" if is_op else "🔴"
                
                push_title = f"{type_icon} [{type_label}] [{tp}] {tt}"
                
                msg_content = (
                    f"<b>{push_title}</b>\n"
                    f"👤 {ra} | 🕒 {time_str} | 🤖 {model_n}\n"
                    f"{'-'*20}\n"
                    f"{ai_resp_html}\n"
                    f"{'-'*20}\n"
                    f"原文链接: {comment_data['url']}"
                )
                msg_content = msg_content.replace('\n', '<br>')
                
                if self.notifier.send_html_message(push_title, msg_content):
                    self.log_push_history("reply", f"{push_title}", comment_data['url'])
                    
        except errors.DuplicateKeyError: pass 
        except: pass

    def parse_let_comment(self, html_content, thread_data):
        soup = BeautifulSoup(html_content, 'html.parser')
        comments = soup.find_all('li', class_='ItemComment')
        now_sh = datetime.now(SHANGHAI)
        enabled_roles = self.config.get('monitored_roles', ["creator", "provider", "top_host", "host_rep", "admin"])
        target_usernames = self.config.get('monitored_usernames', [])
        found_recent = False

        for comment in comments:
            try:
                date_str = comment.find('time')['datetime']
                created_at_aware = datetime.strptime(date_str, "%Y-%m-%dT%H:%M:%S%z")
                created_at_sh = created_at_aware.astimezone(SHANGHAI)
                if (now_sh - created_at_sh).total_seconds() > 86400: continue 
                found_recent = True
                
                author_tag = comment.find('a', class_='Username')
                if not author_tag: continue
                author_name = author_tag.text
                
                role_hits = []
                is_target_user = (author_name in target_usernames)
                if author_name == thread_data['creator']: role_hits.append('creator')
                class_str = " ".join(comment.get('class', [])).lower()
                if 'role_patronprovider' in class_str or 'role_provider' in class_str: role_hits.append('provider')
                if 'role_tophost' in class_str: role_hits.append('top_host')
                if 'role_hostrep' in class_str: role_hits.append('host_rep')
                if 'role_administrator' in class_str or author_name.lower() == 'administrator': role_hits.append('admin')
                if not role_hits: role_hits.append('other')
                
                if not (any(r in enabled_roles for r in role_hits) or is_target_user): continue

                comment_id = comment['id'].replace('Comment_', '')
                msg_div = comment.find('div', class_='Message')
                if msg_div:
                    for quote in msg_div.find_all('blockquote'): quote.decompose()
                    
                    for a in msg_div.find_all('a', href=True):
                        url = a['href']
                        if "lowendtalk.com" not in url:
                             a.replace_with(f" {a.get_text(strip=True)} (Link: {url}) ")
                    
                    message = msg_div.get_text(separator=' ', strip=True)
                else: message = ""
                
                if not message or len(message) < 2: continue

                permalink_url = f"https://lowendtalk.com/discussion/comment/{comment_id}/#Comment_{comment_id}"
                c_data = {'comment_id': comment_id, 'thread_link': thread_data['link'], 'author': author_name, 'message': message, 'created_at': created_at_aware, 'url': permalink_url}
                self.handle_comment(c_data, thread_data, created_at_sh)
            except: pass
        return found_recent

    def get_max_page_from_soup(self, soup):
        try:
            pager = soup.find('div', class_='Pager')
            if not pager: return 1
            pages = [int(a.get_text(strip=True)) for a in pager.find_all('a') if a.get_text(strip=True).isdigit()]
            return max(pages) if pages else 1
        except: return 1

    def fetch_comments(self, thread_data, silent=False):
        self.processed_urls_this_cycle.add(thread_data['link'])
        if thread_data['creator'] == 'Unknown':
             stored = self.threads_collection.find_one({'link': thread_data['link']})
             if stored: thread_data['creator'] = stored.get('creator', 'Unknown')

        try:
            time.sleep(1 if silent else 0.2)
            resp = self.scraper.get(thread_data['link'], timeout=15)
            shield_status = "OK" if resp.status_code == 200 else f"FAIL({resp.status_code})"
            
            if resp.status_code != 200: 
                log(f"   ❌ [Shield:{shield_status}] {thread_data['link']}", RED)
                return False
                
            soup = BeautifulSoup(resp.text, 'html.parser')
            max_page = self.get_max_page_from_soup(soup)
            target_limit = max(1, max_page - 1)
            for page in range(max_page, target_limit - 1, -1):
                p_start = time.time()
                if page == 1 and max_page == 1: content = resp.text
                else:
                    time.sleep(0.2)
                    p_resp = self.scraper.get(f"{thread_data['link']}/p{page}", timeout=15)
                    if p_resp.status_code != 200: continue
                    content = p_resp.text
                has_recent = self.parse_let_comment(content, thread_data)
                if not silent: 
                    author = thread_data.get('creator', 'Unknown')
                    title = thread_data.get('title', 'Unknown')
                    log(f"   📄 [Shield:{shield_status}] {WHITE}@{author}{NC} {CYAN}{title[:30]}...{NC} | P{page}/{max_page} | {time.time()-p_start:.2f}s", GRAY)
                if not has_recent: break
            return True
        except: return False

    def process_rss_item(self, item_str):
        try:
            item_soup = BeautifulSoup(item_str, 'xml')
            title = item_soup.find('title').get_text()
            link = item_soup.find('link').get_text()
            creator = "Unknown"
            c_tag = item_soup.find('dc:creator') or item_soup.find('creator') or item_soup.find('author')
            if c_tag: creator = c_tag.get_text(strip=True)
            pub_date = datetime.strptime(item_soup.find('pubDate').get_text(), "%a, %d %b %Y %H:%M:%S %z")
            
            raw_html = item_soup.find('description').get_text() or ""
            desc_soup = BeautifulSoup(raw_html, 'html.parser')
            
            for a in desc_soup.find_all('a', href=True):
                url = a['href']
                text = a.get_text(strip=True)
                if 'lowendtalk.com' in url:
                    continue
                if any(k in text.lower() for k in ['order', 'buy', 'purchase', 'cart', 'here']) or any(k in url.lower() for k in ['cart', 'aff', 'billing', 'whmcs']):
                    a.replace_with(f" {text} (下单链接: {url}) ")
                else:
                    a.replace_with(f" {text} (Link: {url}) ")
            
            desc_text = desc_soup.get_text(separator=" ", strip=True)

            t_data = {'cate': 'let', 'title': title, 'link': link, 'description': desc_text, 'pub_date': pub_date, 'created_at': datetime.utcnow(), 'creator': creator, 'last_page': 1}
            self.processed_urls_this_cycle.add(link)
            age = (datetime.now(timezone.utc) - pub_date).total_seconds()

            if self.threads_collection.find_one({'link': link}):
                is_processed = self.fetch_comments(t_data, silent=(age > 86400))
                return "SILENT" if (age > 86400 and is_processed) else "ACTIVE"
            else:
                if age <= 86400: self.handle_thread(t_data, []); return "NEW_PUSH"
                else: self.threads_collection.insert_one(t_data); self.fetch_comments(t_data, silent=True); return "OLD_SAVED"
        except: return "ERROR"

    def check_rss(self):
        try:
            start_t = time.time()
            max_w = self.config.get('max_workers', 3) 
            resp = self.scraper.get("https://lowendtalk.com/categories/offers/feed.rss", timeout=30)
            if resp.status_code == 200:
                soup = BeautifulSoup(resp.text, 'xml')
                items = soup.find_all('item')
                log(f"RSS 扫描 | 目标: {len(items)} | 线程: {max_w} | 连通: ✅ (200)", BLUE, "📡")
                stats = {"SILENT": 0, "ACTIVE": 0, "NEW_PUSH": 0, "ERROR": 0, "OLD_SAVED": 0}
                with ThreadPoolExecutor(max_workers=max_w) as executor:
                    futures = [executor.submit(self.process_rss_item, str(i)) for i in items]
                    for f in as_completed(futures):
                        res = f.result()
                        if res in stats: stats[res] += 1
                log(f"RSS 完成 | 耗时: {time.time()-start_t:.2f}s | 新:{stats['NEW_PUSH']} 活:{stats['ACTIVE']} 静:{stats['SILENT']}", GREEN)
            else:
                log(f"RSS 扫描 | 连通: ❌ ({resp.status_code})", RED, "📡")
        except Exception as e: log(f"RSS Error: {e}", RED, "❌")

    def check_vip_threads(self):
        vip_urls = self.config.get('vip_threads', [])
        if not vip_urls: return
        log(f"VIP 专线扫描 ({len(vip_urls)})...", MAGENTA, "👑")
        for url in vip_urls:
            try:
                resp = self.scraper.get(url, timeout=30)
                if resp.status_code != 200: continue
                soup = BeautifulSoup(resp.text, 'html.parser')
                title = soup.select_one('.PageTitle h1').get_text(strip=True)
                creator = soup.select_one('.Author .Username').get_text(strip=True) if soup.select_one('.Author .Username') else "Unknown"
                t_data = {'link': url, 'title': title, 'creator': creator, 'pub_date': datetime.now(timezone.utc)}
                self.threads_collection.update_one({'link': url}, {'$setOnInsert': t_data}, upsert=True)
                self.fetch_comments(t_data, silent=False)
            except: pass

    def check_category_list(self):
        target_urls = ["https://lowendtalk.com/categories/offers", "https://lowendtalk.com/categories/announcements"]
        log(f"列表页扫描 ({len(target_urls)})...", MAGENTA, "🔎")
        start_t = time.time()
        for url in target_urls:
            obj_name = url.split('/')[-1]
            try:
                resp = self.scraper.get(url, timeout=30)
                
                shield_state = "✅ 访问正常" if resp.status_code == 200 else f"❌ 访问失败 ({resp.status_code})"
                if resp.status_code != 200:
                    log(f"   -> [{obj_name}] {shield_state}", RED)
                    continue
                
                soup = BeautifulSoup(resp.text, 'html.parser')
                candidates = []
                for d in soup.select('.ItemDiscussion') + soup.select('tr.ItemDiscussion'):
                    try:
                        a = d.select_one('.DiscussionName a') or d.find('h3', class_='DiscussionName').find('a')
                        if not a: continue
                        link = a['href']
                        if not link.startswith('http'): link = "https://lowendtalk.com" + link
                        if link in self.processed_urls_this_cycle: continue
                        
                        dt = d.select_one('.LastCommentDate time') or d.select_one('.DateUpdated time')
                        if dt and dt.has_attr('datetime'):
                            last_active = datetime.strptime(dt['datetime'], "%Y-%m-%dT%H:%M:%S%z")
                            if (datetime.now(timezone.utc) - last_active).total_seconds() < 172800:
                                creator = d.select_one('.FirstUser').get_text(strip=True) if d.select_one('.FirstUser') else "Unknown"
                                candidates.append({'link': link, 'title': a.get_text(strip=True), 'creator': creator})
                    except: continue
                
                result_msg = f"发现 {len(candidates)} 新候选项" if candidates else "无新候选项 (RSS已覆盖)"
                color = YELLOW if candidates else GRAY
                log(f"   -> [{obj_name}] {shield_state} | 结果: {result_msg}", color)

                for t in candidates: self.fetch_comments(t, silent=False)
            except Exception as e:
                log(f"   -> [{obj_name}] 错误: {e}", RED)
        log(f"列表页完成 | 耗时: {time.time()-start_t:.2f}s", MAGENTA)

    def next_sleep(self):
        """本轮休眠秒数：先按 frequency_min~frequency_max 随机得到最短间隔
        （菜单 11 可调；范围未设置时回退到旧版固定 frequency），再把唤醒
        时刻向上取整到整分钟 :00——保证每轮轮询都在某一分钟的 0 秒开始，
        而 VIP 专线是每轮第一项，等于 VIP 轮询卡在 :00 出发。
        min>max 自动对调，下限最低 1 秒；算出的休眠不足 2 秒时顺延一分钟，
        避免与上一轮挤进同一分钟重复扫。
        """
        cfg = self.config
        base = int(cfg.get('frequency', 300))
        lo = cfg.get('frequency_min')
        hi = cfg.get('frequency_max')
        if lo is None and hi is None:
            interval = base
        else:
            lo = int(lo) if lo is not None else base
            hi = int(hi) if hi is not None else base
            if lo > hi:
                lo, hi = hi, lo
            lo = max(1, lo)
            hi = max(lo, hi)
            interval = random.randint(lo, hi)
        now = time.time()
        wake = (int(now + interval) // 60 + 1) * 60
        sleep_s = wake - now
        if sleep_s < 2:
            sleep_s += 60
        return sleep_s

    def start_monitoring(self):
        log("=== 监控服务启动 (v2.0) ===", GREEN, "🚀")
        wait0 = 60 - (time.time() % 60)
        if wait0 > 1:
            log(f"⏱️ 对齐整分钟: {wait0:.0f}s 后开始首轮轮询...", YELLOW)
            time.sleep(wait0)
        while True:
            t0 = time.time()
            self.processed_urls_this_cycle.clear()
            print(f"{GRAY}--------------------------------------------------{NC}")
            self.check_vip_threads()
            self.check_rss()
            self.check_category_list()
            self.update_heartbeat()
            sleep_s = self.next_sleep()
            log(f"⏱️ 耗时: {time.time()-t0:.2f}s | 休眠 {sleep_s:.0f}s...", YELLOW)
            time.sleep(sleep_s)

if __name__ == "__main__":
    sys.stdout.reconfigure(line_buffering=True)
    ForumMonitor().start_monitoring()
