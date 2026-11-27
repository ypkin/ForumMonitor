#!/usr/bin/env bash
# ForumMonitor (Docker 版) 管理菜单 —— 功能与原脚本版 fm 菜单一一对应（22 项）
# 用法: ./menu.sh                 交互菜单（输数字或命令名均可）
#       ./menu.sh <命令名>        直接执行，如 ./menu.sh test-push
# 依赖: docker compose + 宿主机 python3（改配置用）
set -u
cd "$(dirname "$0")"
PROJECT_DIR="$(pwd)"
CONFIG="data/config.json"

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[0;33m'; BLUE='\033[0;34m'
CYAN='\033[0;36m'; GRAY='\033[0;90m'; NC='\033[0m'

if docker compose version >/dev/null 2>&1; then DC="docker compose";
elif command -v docker-compose >/dev/null 2>&1; then DC="docker-compose";
else echo -e "${RED}未找到 docker compose，请先安装 Docker${NC}"; exit 1; fi

msg_ok()   { echo -e "${GREEN}✅ $1${NC}"; }
msg_err()  { echo -e "${RED}❌ $1${NC}"; }
msg_warn() { echo -e "${YELLOW}⚠️  $1${NC}"; }
msg_info() { echo -e "${CYAN}ℹ️  $1${NC}"; }
pause()    { read -n 1 -s -r -p "..." ; echo; }

# ---------------- 配置读写（宿主机 python3） ----------------
pyget() { # pyget key [default]
    python3 - "$1" "${2:-}" <<'PY'
import json, sys
key, default = sys.argv[1], sys.argv[2]
try:
    c = json.load(open('data/config.json'))['config']
    v = c.get(key, default)
    if isinstance(v, bool): print('true' if v else 'false')
    elif isinstance(v, list): print('\n'.join(str(x) for x in v))
    else: print(v)
except Exception:
    print(default)
PY
}

pyset() { # pyset key value（bool/int/list 按 key 名自动转换；list 用 +值 追加、-序号 删除）
    python3 - "$1" "$2" <<'PY'
import json, sys
key, val = sys.argv[1], sys.argv[2]
BOOL_KEYS = {'enable_telegram', 'enable_pushplus'}
INT_KEYS = {'frequency', 'max_workers'}
LIST_KEYS = {'vip_threads', 'monitored_usernames', 'monitored_roles'}
path = 'data/config.json'
d = json.load(open(path)); c = d['config']
if key in BOOL_KEYS: c[key] = val.lower() in ('true', '1', 'yes', 'y')
elif key in INT_KEYS: c[key] = int(val)
elif key in LIST_KEYS:
    cur = c.get(key, [])
    if val.startswith('+'): cur.append(val[1:])
    elif val.startswith('-'):
        i = int(val[1:]) - 1
        if 0 <= i < len(cur): cur.pop(i)
    c[key] = cur
else: c[key] = val
json.dump(d, open(path, 'w'), ensure_ascii=False, indent=2)
PY
}

pyset_file() { # pyset_file key filepath（多行文本，如提示词）
    python3 - "$1" "$2" <<'PY'
import json, sys
key, fp = sys.argv[1], sys.argv[2]
path = 'data/config.json'
d = json.load(open(path))
d['config'][key] = open(fp, encoding='utf-8').read().strip()
json.dump(d, open(path, 'w'), ensure_ascii=False, indent=2)
PY
}

mask() { local v="$1" n=${#1}; if [ "$n" -eq 0 ]; then echo "(未填)"; elif [ "$n" -le 8 ]; then echo "****"; else echo "${v:0:4}****${v: -4}"; fi; }
# 注意：docker compose 子命令会吞掉标准输入，所有不靠 stdin 喂脚本的调用都必须 </dev/null，
# 否则会把用户在菜单里输入的选项吃掉（run_test_push/run_view_history 用 heredoc 喂脚本的除外）
app_id() { $DC ps -q app </dev/null 2>/dev/null; }
app_running() { [ -n "$(app_id)" ]; }

run_restart() {
    if app_running; then $DC restart app </dev/null >/dev/null 2>&1 && msg_ok "已重启" || msg_err "重启失败";
    else msg_info "服务未运行，下次启动时生效"; fi
}

push_count() {
    app_running || { echo "-"; return; }
    timeout 6 $DC exec -T app python -c "import pymongo,os; print(pymongo.MongoClient(os.getenv('MONGO_HOST','mongodb://mongo:27017/'))['forum_monitor']['push_logs'].count_documents({}))" </dev/null 2>/dev/null || echo "-"
}

restart_count() {
    local id; id=$(app_id)
    [ -n "$id" ] && docker inspect -f '{{.RestartCount}}' "$id" </dev/null 2>/dev/null || echo "-"
}

# ---------------- 基础管理 ----------------
run_install() {
    if [ ! -f "$CONFIG" ]; then
        cp data/config.example.json "$CONFIG"
        msg_warn "已生成 $CONFIG，请先用菜单 9/10 填好 Token 与 AI 密钥"
    fi
    msg_info "构建并启动（安装/重置）..."
    $DC up -d --build </dev/null && msg_ok "安装/重置完成"
    $DC ps </dev/null
}

run_uninstall() {
    msg_warn "卸载将停止并删除容器与数据卷（MongoDB 去重/推送历史会清空）！"
    read -p "确认卸载? (y/n): " c; [ "$c" = "y" ] || { msg_info "已取消"; return; }
    # 顺带清保活
    crontab -l 2>/dev/null | grep -v "fm-keepalive" | crontab - 2>/dev/null || true
    read -p "连镜像和配置文件 data/config.json 一起删? (y/n): " c2
    if [ "$c2" = "y" ]; then
        $DC down -v --rmi local </dev/null
        rm -f "$CONFIG"
        msg_ok "彻底卸载完成（容器/数据卷/镜像/配置已删）"
    else
        $DC down -v </dev/null
        msg_ok "卸载完成（配置保留在 $CONFIG）"
    fi
}

run_update() {
    if [ -d .git ]; then git pull --ff-only || { msg_err "git pull 失败"; return; }; fi
    $DC up -d --build </dev/null && msg_ok "更新完成（已拉最新代码并重建）"
}

# ---------------- 服务控制 ----------------
run_start() { $DC up -d </dev/null && msg_ok "已启动"; }
run_stop()  { $DC down </dev/null && msg_ok "已停止"; }
run_restart2() { app_running && $DC restart app </dev/null && msg_ok "已重启" || msg_err "服务未运行"; }

run_status() {
    $DC ps </dev/null </dev/null
    if [ -f data/heartbeat.txt ]; then
        local hb; hb=$(tr -cd '0-9' < data/heartbeat.txt)
        [ -n "$hb" ] && echo -e "--- 心跳: ${GREEN}$(( $(date +%s) - hb )) 秒前${NC} | 容器自动重启: $(restart_count) 次 | 已推送通知: $(push_count)"
    fi
}

run_logs() {
    msg_info "正在加载实时日志..."
    echo -e "${YELLOW}👉 按 '0' 返回主菜单 | 按 'Ctrl+C' 退出脚本${NC}"
    echo -e "${GRAY}--------------------------------------------------${NC}"
    # setsid 让日志进程自成进程组：docker compose logs 被 kill 后 wait 会永久挂起，
    # 必须整组 TERM→KILL 才能可靠收尾（否则按 0 返回时卡死在 wait 上）
    setsid $DC logs -f --tail 50 app </dev/null &
    local LOG_PID=$!
    cleanup_logs() {
        [ -n "${LOG_PID:-}" ] || return 0
        kill -TERM -"$LOG_PID" >/dev/null 2>&1 || true
        local i; for i in 1 2 3 4 5 6 7 8 9 10; do kill -0 "$LOG_PID" 2>/dev/null || break; sleep 0.2; done
        kill -KILL -"$LOG_PID" >/dev/null 2>&1 || true
        wait "$LOG_PID" 2>/dev/null || true
        LOG_PID=""
    }
    trap 'trap - SIGINT EXIT; cleanup_logs; echo; msg_ok "已退出脚本"; exit 0' SIGINT
    trap cleanup_logs EXIT
    while true; do
        read -n 1 -s -r key || break
        if [ "$key" = "0" ]; then break; fi
    done
    cleanup_logs
    trap - SIGINT EXIT
    echo -e "\n${GREEN}[OK] 返回主菜单...${NC}"
    sleep 0.5
}

# ---------------- 配置管理 ----------------
run_edit_config() {
    echo "--- 修改基础配置 (直接回车保留) ---"
    echo "Pushplus Token 当前: $(mask "$(pyget pushplus_token)")"
    read -p "Pushplus Token: " v;     [ -n "$v" ] && pyset pushplus_token "$v"
    echo "Telegram Bot Token 当前: $(mask "$(pyget telegram_bot_token)")"
    read -p "Telegram Bot Token: " v; [ -n "$v" ] && pyset telegram_bot_token "$v"
    echo "Telegram Chat ID 当前: $(pyget telegram_chat_id)"
    read -p "Telegram Chat ID: " v;   [ -n "$v" ] && pyset telegram_chat_id "$v"
    msg_ok "配置已更新，重启中..."
    run_restart
}

run_ai_switch() {
    local prov; prov=$(pyget ai_provider gemini)
    echo -e "\n${CYAN}--- AI 引擎切换 ---${NC}"
    echo -e "当前: ${GREEN}${prov^^}${NC}"
    echo "  1. Google Gemini"
    echo "  2. Cloudflare Workers AI"
    echo "  0. 返回"
    read -p "选择: " sel
    case "$sel" in
        1)
            echo "Gemini API Key 当前: $(mask "$(pyget gemini_api_key)")"
            read -p "API Key (回车保留): " v; [ -n "$v" ] && pyset gemini_api_key "$v"
            echo "Model 当前: $(pyget model)"
            read -p "Model (回车保留): " v; [ -n "$v" ] && pyset model "$v"
            echo "裁决模型 verdict_model 当前: $(pyget verdict_model '(空=跟随 Model)')"
            read -p "verdict_model (回车保留, none 清空): " v
            if [ "$v" = "none" ]; then pyset verdict_model ""; elif [ -n "$v" ]; then pyset verdict_model "$v"; fi
            echo "过滤模型 filter_model 当前: $(pyget filter_model '(空=跟随 Model)')"
            read -p "filter_model (回车保留, none 清空): " v
            if [ "$v" = "none" ]; then pyset filter_model ""; elif [ -n "$v" ]; then pyset filter_model "$v"; fi
            pyset ai_provider gemini
            msg_ok "已切换至 Gemini，重启中..."; run_restart ;;
        2)
            echo "Account ID 当前: $(pyget cf_account_id)"
            read -p "Account ID (回车保留): " v; [ -n "$v" ] && pyset cf_account_id "$v"
            echo "API Token 当前: $(mask "$(pyget cf_api_token)")"
            read -p "API Token (回车保留): " v; [ -n "$v" ] && pyset cf_api_token "$v"
            echo "Model 当前: $(pyget cf_model)"
            read -p "Model (回车保留): " v; [ -n "$v" ] && pyset cf_model "$v"
            pyset ai_provider workers
            msg_ok "已切换至 Workers AI，重启中..."; run_restart ;;
        *) return ;;
    esac
}

run_edit_frequency() {
    local cur; cur=$(pyget frequency 30)
    echo "当前: $cur 秒"
    read -p "新间隔 (秒): " v
    if ! [[ "$v" =~ ^[0-9]+$ ]]; then msg_err "无效数字"; return 1; fi
    pyset frequency "$v"; run_restart
}

run_edit_threads() {
    local cur; cur=$(pyget max_workers 5)
    echo "当前: $cur"
    read -p "新线程数 (1-100): " v
    if ! [[ "$v" =~ ^[0-9]+$ ]] || [ "$v" -lt 1 ] || [ "$v" -gt 100 ]; then msg_err "无效数字"; return 1; fi
    pyset max_workers "$v"; run_restart
}

run_setup_keepalive() {
    local LINE="*/5 * * * * cd $PROJECT_DIR && docker compose up -d >/dev/null 2>&1 # fm-keepalive"
    if crontab -l 2>/dev/null | grep -q "fm-keepalive"; then
        echo -e "保活状态: ${GREEN}已开启${NC}（每 5 分钟检查，容器不在就自动拉起；另有 compose restart 策略兜底）"
        read -p "关闭保活? (y/n): " c
        if [ "$c" = "y" ]; then
            crontab -l 2>/dev/null | grep -v "fm-keepalive" | crontab -
            msg_ok "保活已关闭"
        fi
    else
        echo -e "保活状态: ${RED}未开启${NC}"
        read -p "开启保活? (y/n): " c
        if [ "$c" = "y" ]; then
            (crontab -l 2>/dev/null | grep -v "fm-keepalive"; echo "$LINE") | crontab -
            msg_ok "已添加（每 5 分钟）"
        fi
    fi
}

run_toggle_push() {
    while true; do
        local tg pp; tg=$(pyget enable_telegram); pp=$(pyget enable_pushplus)
        echo -e "${CYAN}--- 推送通道开关 ---${NC}"
        echo "  1. Telegram : $( [ "$tg" = "true" ] && echo -e "${GREEN}ON${NC}" || echo -e "${RED}OFF${NC}" )"
        echo "  2. PushPlus : $( [ "$pp" = "true" ] && echo -e "${GREEN}ON${NC}" || echo -e "${RED}OFF${NC}" )"
        echo "  0. 返回"
        read -p "输入编号切换: " sel || break
        case "$sel" in
            1) [ "$tg" = "true" ] && pyset enable_telegram false || pyset enable_telegram true ;;
            2) [ "$pp" = "true" ] && pyset enable_pushplus false || pyset enable_pushplus true ;;
            0) break ;;
            *) ;;
        esac
    done
    msg_ok "开关已保存"; run_restart
}

_edit_prompt_text() { # key 显示名
    local key="$1" name="$2" tmp; tmp=$(mktemp /tmp/fm-prompt.XXXXXX.txt)
    pyget "$key" > "$tmp"
    echo -e "${CYAN}--- 编辑: $name ---${NC}"
    echo -e "${GRAY}将打开编辑器（默认 vi，保存退出后生效）；当前内容已写入临时文件${NC}"
    read -p "按回车打开编辑器..." _
    ${EDITOR:-vi} "$tmp" < /dev/tty
    if [ -s "$tmp" ]; then
        pyset_file "$key" "$tmp"
        msg_ok "$name 已更新，重启中..."; run_restart
    else
        msg_warn "内容为空，未修改。"
    fi
    rm -f "$tmp"
}

_reset_prompts() {
    echo -e "\n${RED}⚠️ 警告: 将重置两个提示词为默认值（取自 data/config.example.json）！${NC}"
    read -p "确认重置? (y/n): " c; [ "$c" = "y" ] || return
    python3 - <<'PY'
import json
ex = json.load(open('data/config.example.json'))['config']
path = 'data/config.json'
d = json.load(open(path))
for k in ('thread_prompt', 'filter_prompt'):
    if k in ex: d['config'][k] = ex[k]
json.dump(d, open(path, 'w'), ensure_ascii=False, indent=2)
print('prompts reset')
PY
    msg_ok "提示词已重置，重启中..."; run_restart
}

run_prompt_menu() {
    while true; do
        echo -e "${BLUE}================================================================${NC}"
        echo -e " ${CYAN}AI 提示词管理 (Prompt Settings)${NC}"
        echo -e "${BLUE}================================================================${NC}"
        echo -e "  1. 修改: 帖子摘要提示词 (Thread Summary Prompt)"
        echo -e "     ${GRAY}* 用于生成新帖子的总结内容${NC}"
        echo -e "  2. 修改: 回复过滤提示词 (Comment Filter Prompt)"
        echo -e "     ${GRAY}* 用于分析回帖，提取补货或优惠信息${NC}"
        echo -e "${GRAY}----------------------------------------------------------------${NC}"
        echo -e "  3. 重置: 恢复默认提示词 (Reset to Default)"
        echo -e "  0. 返回上级菜单"
        read -p "请选择: " o || return
        case "$o" in
            1) _edit_prompt_text "thread_prompt" "帖子摘要提示词"; pause ;;
            2) _edit_prompt_text "filter_prompt" "回复过滤提示词"; pause ;;
            3) _reset_prompts; pause ;;
            0) return ;;
            *) ;;
        esac
    done
}

# ---------------- 监控规则 ----------------
edit_list() { # key 显示名
    local key="$1" name="$2"
    while true; do
        echo -e "${CYAN}--- $name ---${NC}"
        local list; list=$(pyget "$key")
        if [ -z "$list" ]; then echo "  (空)"; else echo "$list" | nl -ba | sed 's/^/  /'; fi
        echo "  a. 添加"
        echo "  d. 按编号删除"
        echo "  0. 返回"
        read -p "选择: " act || break
        case "$act" in
            a) read -p "输入要添加的内容: " v; [ -n "$v" ] && pyset "$key" "+$v" && msg_ok "已添加" ;;
            d) read -p "要删除的编号: " n; [ -n "$n" ] && pyset "$key" "-$n" && msg_ok "已删除" ;;
            0) break ;;
        esac
    done
    run_restart
}
run_vip()   { edit_list vip_threads "VIP 专线（帖子链接）"; }
run_roles() { edit_list monitored_roles "监控角色"; }
run_users() { edit_list monitored_usernames "指定用户"; }

# ---------------- 功能测试 ----------------
# 注意：容器内不能直接实例化 ForumMonitor —— 它的单例逻辑会杀掉正在跑的主进程。
# 下面用 __new__ 绕过 __init__ 的锁/杀进程，只装配 AI 与推送所需属性，行为与原版一致。
HELPER_PREAMBLE='
import sys, json, os
sys.path.append("/app")
from core import ForumMonitor
m = ForumMonitor.__new__(ForumMonitor)
m.config_path = "data/config.json"
m.load_config()
m.ai_provider = m.config.get("ai_provider", "gemini")
m.thread_prompt = m.config.get("thread_prompt", "")
m.filter_prompt = m.config.get("filter_prompt", "")
if m.ai_provider == "gemini":
    import google.generativeai as genai
    key = m.config.get("gemini_api_key")
    if key:
        genai.configure(api_key=key)
        mn = m.config.get("model", "gemini-2.0-flash-lite")
        m.model_summary = genai.GenerativeModel(mn, system_instruction=m.thread_prompt)
        m.model_filter = genai.GenerativeModel(m.config.get("filter_model") or mn, system_instruction=m.filter_prompt)
elif m.ai_provider == "workers":
    m.cf_account = m.config.get("cf_account_id")
    m.cf_token = m.config.get("cf_api_token")
    m.cf_model = m.config.get("cf_model", "@cf/meta/llama-3.1-8b-instruct")
'

run_test_ai() {
    app_running || { msg_err "服务未运行，请先启动"; return; }
    msg_info "正在测试 AI..."
    local RES
    RES=$($DC exec -T app python -c "$HELPER_PREAMBLE
print(m.get_filter_from_ai('Test message.'))" </dev/null 2>&1)
    echo "API Response: $RES"
    if [[ "$RES" == *"FALSE"* ]] || [[ -n "$RES" ]]; then msg_ok "AI 响应成功"; else msg_err "AI 响应为空/失败"; fi
}

run_test_push() {
    app_running || { msg_err "服务未运行，请先启动"; return; }
    msg_info "正在发送全真模拟通知..."
    $DC exec -T app python - <<'PY'
import sys
sys.path.append('/app')
from send import NotificationSender
from datetime import datetime

s = NotificationSender('data/config.json')
time_str = datetime.now().strftime('%Y-%m-%d %H:%M')

title = '🟢 [TEST] 模拟 VPS 优惠通知'
content = (
    f'<b>🔵 [回复] [TestUser] 帖子标题测试</b>\n'
    f'👤 TestUser | 🕒 {time_str} | 🤖 Mock-Model-v1\n'
    f'{"-"*20}\n'
    f'[促销] ExampleHost\n'
    f'配置：AMD Ryzen 7 5700G（8核16线程） 64GB内存 1TB三星NVMe\n'
    f'价格：$49.95/月 $44.95（限时优惠）\n'
    f'链接：https://billing.example.com/index.php?rp=/store/bare-metal/ryzen-7\n'
    f'链接：https://example.com/second-link\n'
    f'优惠码：CYBR7-2025\n'
    f'总结：ExampleHost推出Cyber Week限时促销...\n\n'
    f'原文链接: https://lowendtalk.com/test'
)
content_html = content.replace('\n', '<br>')
s.send_html_message(title, content_html)
print('test push sent')
PY
}

run_view_history() {
    app_running || { msg_err "服务未运行，请先启动"; return; }
    $DC exec -T app python - <<'PY'
import pymongo, os
from datetime import datetime
try:
    client = pymongo.MongoClient(os.getenv('MONGO_HOST', 'mongodb://mongo:27017/'))
    logs = list(client['forum_monitor']['push_logs'].find().sort('created_at', -1).limit(20))
    print('-'*85 + f'\n| {"Time":<19} | {"Type":<8} | {"Title":<50} |\n' + '-'*85)
    for l in logs:
        ts = l.get('created_at', datetime.now()).strftime('%Y-%m-%d %H:%M:%S')
        t = l.get('title', 'No Title')[:45]
        print(f'| {ts:<19} | {l.get("type", "UNK"):<8} | {t:<50} |')
    print('-'*85)
except Exception as e:
    print('history error:', e)
PY
}

run_repush_active() {
    app_running || { msg_err "服务未运行，请先启动"; return; }
    msg_info "正在重推 (Single-Thread)..."
    $DC exec -T app python -c "$HELPER_PREAMBLE
import time, os
from datetime import timezone
from pymongo import MongoClient
from core import SHANGHAI
m.mongo_client = MongoClient(os.getenv('MONGO_HOST', 'mongodb://mongo:27017/'))
m.db = m.mongo_client['forum_monitor']
try:
    cursor = m.db['threads'].find().sort('pub_date', -1).limit(5)
    print('Scanning...')
    for t in cursor:
        print(f' -> Repushing: {t.get(\"title\")[:30]}')
        raw_summary = m.get_summarize_from_ai(t.get('description', ''))
        if not raw_summary or raw_summary.strip().upper() in ('FALSE', 'AI ERROR'):
            print(' -> Skip (AI summary failed)')
            continue
        html_summary = m.markdown_to_html(raw_summary)
        pub_date = t['pub_date']
        if pub_date.tzinfo is None: pub_date = pub_date.replace(tzinfo=timezone.utc)
        time_str = pub_date.astimezone(SHANGHAI).strftime('%Y-%m-%d %H:%M')
        safe_title = t['title'].replace('<', '&lt;').replace('>', '&gt;')
        safe_creator = t.get('creator', 'Unknown').replace('<', '&lt;').replace('>', '&gt;')
        model_n = m.config.get('model') if m.ai_provider == 'gemini' else m.config.get('cf_model')
        msg_content = (
            f'<b>🟡 [Repush] {safe_title}</b>\n'
            f'👤 {safe_creator} | 🕒 {time_str} | 🤖 {model_n}\n'
            f'{\"-\"*20}\n'
            f'{html_summary}\n'
            f'{\"-\"*20}\n'
            f'原文链接: {t[\"link\"]}'
        )
        m.notifier.send_html_message(f'🟡 [Repush] {safe_title}', msg_content)
        time.sleep(2)
except Exception as e: print(f'Error: {e}')
" </dev/null
}

# ---------------- 主菜单 ----------------
print_header() {
    local running prov model freq tg pp pc rc mshow
    if app_running; then running="${GREEN}运行中 (Running)${NC}"; else running="${RED}未运行 (Stopped)${NC}"; fi
    prov=$(pyget ai_provider gemini); prov=${prov^^}
    if [ "$(pyget ai_provider gemini)" = "workers" ]; then model=$(pyget cf_model); else model=$(pyget model); fi
    if [ ${#model} -gt 18 ]; then mshow="${model:0:18}.."; else mshow="$model"; fi
    freq=$(pyget frequency 30)
    tg=$(pyget enable_telegram); pp=$(pyget enable_pushplus)
    pc=$(push_count); rc=$(restart_count)
    echo -e "${BLUE}================================================================${NC}"
    echo -e " ${CYAN}ForumMonitor (Docker 版)${NC}"
    echo -e "${BLUE}================================================================${NC}"
    printf " %-16s %b | %-16s %b\n" "运行状态:" "$running" "已推送通知:" "${GREEN}$pc${NC}"
    printf " %-16s %-20s | %-16s %s\n" "AI 引擎:" "$prov" "轮询间隔:" "${freq}s"
    printf " %-16s %-20s | %-16s %b\n" "当前模型:" "$mshow" "自动重启:" "${RED}$rc 次${NC}"
    echo -e "${GRAY}----------------------------------------------------------------${NC}"
    printf " %-16s %b | %-16s %b\n" "Pushplus:" "$([ "$pp" = "true" ] && echo "${GREEN}ON${NC}" || echo "${RED}OFF${NC}")" "Telegram:" "$([ "$tg" = "true" ] && echo "${GREEN}ON${NC}" || echo "${RED}OFF${NC}")"
    echo -e "${BLUE}================================================================${NC}"
    echo -e " ${GREEN}选项菜单${NC}"
    echo -e "${GRAY}----------------------------------------------------------------${NC}"
    echo -e " ${CYAN}[基础管理]${NC}"
    printf "  %-4s %-14s %s\n" "1." "install" "安装/重置"
    printf "  %-4s %-14s %s\n" "2." "uninstall" "彻底卸载"
    printf "  %-4s %-14s %s\n" "3." "update" "更新代码(补丁)"
    echo -e " ${CYAN}[服务控制]${NC}"
    printf "  %-4s %-14s %s\n" "4." "start" "启动"
    printf "  %-4s %-14s %s\n" "5." "stop" "停止"
    printf "  %-4s %-14s %s\n" "6." "restart" "重启"
    printf "  %-4s %-14s %s\n" "7." "status" "状态"
    printf "  %-4s %-14s %s\n" "8." "logs" "日志"
    echo -e " ${CYAN}[配置管理]${NC}"
    printf "  %-4s %-14s %s\n" "9." "edit" "修改Token/ID"
    printf "  %-4s %-14s %s\n" "10." "ai-switch" "切换AI引擎"
    printf "  %-4s %-14s %s\n" "11." "frequency" "调整频率"
    printf "  %-4s %-14s %s\n" "12." "threads" "修改线程数"
    printf "  %-4s %-14s %s\n" "13." "keepalive" "开启保活"
    printf "  %-4s %-14s %b%s%b\n" "14." "toggle-push" "$GREEN" "推送通道开关" "$NC"
    printf "  %-4s %-14s %s\n" "15." "prompt" "AI提示词设置"
    echo -e " ${CYAN}[监控规则]${NC}"
    printf "  %-4s %-14s %s\n" "16." "vip" "VIP专线"
    printf "  %-4s %-14s %s\n" "17." "roles" "监控角色"
    printf "  %-4s %-14s %s\n" "18." "users" "指定用户"
    echo -e " ${CYAN}[功能测试]${NC}"
    printf "  %-4s %-14s %s\n" "19." "test-ai" "测试 AI"
    printf "  %-4s %-14s %s\n" "20." "test-push" "测试推送"
    printf "  %-4s %-14s %s\n" "21." "history" "推送历史"
    printf "  %-4s %-14s %s\n" "22." "repush" "手动重推"
    echo -e "${GRAY}----------------------------------------------------------------${NC}"
    printf "  %-4s %-14s %s\n" "q." "quit" "退出"
}

dispatch() {
    case "$1" in
        install|1) run_install ;;
        uninstall|2) run_uninstall ;;
        update|3) run_update ;;
        start|4) run_start ;;
        stop|5) run_stop ;;
        restart|6) run_restart2 ;;
        status|7) run_status ;;
        logs|8) run_logs ;;
        edit|9) run_edit_config ;;
        ai-switch|10) run_ai_switch ;;
        frequency|11) run_edit_frequency ;;
        threads|12) run_edit_threads ;;
        keepalive|13) run_setup_keepalive ;;
        toggle-push|14) run_toggle_push ;;
        prompt|15) run_prompt_menu ;;
        vip|16) run_vip ;;
        roles|17) run_roles ;;
        users|18) run_users ;;
        test-ai|19) run_test_ai ;;
        test-push|20) run_test_push ;;
        history|21) run_view_history ;;
        repush|22) run_repush_active ;;
        q|quit|0) exit 0 ;;
        *) msg_err "无效选项: $1"; return 1 ;;
    esac
}

# 非交互子命令
if [ $# -ge 1 ]; then
    case "$1" in
        monitor) # 兼容原版保活调用习惯：容器不在就拉起
            $DC up -d </dev/null >/dev/null 2>&1; exit 0 ;;
        *) dispatch "$1"; exit $? ;;
    esac
fi

[ -f "$CONFIG" ] || msg_warn "未找到 $CONFIG：先选 1 (install) 生成，或 cp data/config.example.json data/config.json"
command -v python3 >/dev/null 2>&1 || msg_err "需要宿主机 python3 才能读写配置"

while true; do
    print_header
    read -p "请输入选项: " opt || exit 0
    case "$opt" in
        q|quit) exit 0 ;;
        logs|8) dispatch logs ;;
        prompt|15) dispatch prompt ;;
        toggle-push|14) dispatch toggle-push ;;
        vip|16) dispatch vip ;;
        roles|17) dispatch roles ;;
        users|18) dispatch users ;;
        *) dispatch "$opt"; pause ;;
    esac
done
