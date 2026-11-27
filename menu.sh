#!/usr/bin/env bash
# ForumMonitor (Docker 版) 管理菜单
# 用法: ./menu.sh            交互菜单
#       ./menu.sh status|start|stop|restart|logs|update   直接执行
# 依赖: docker compose + 宿主机 python3（仅用于改配置）
set -u
cd "$(dirname "$0")"

CONFIG="data/config.json"
GREEN='\033[0;32m'; RED='\033[0;31m'; CYAN='\033[0;36m'; GRAY='\033[0;90m'; NC='\033[0m'

if docker compose version >/dev/null 2>&1; then DC="docker compose";
elif command -v docker-compose >/dev/null 2>&1; then DC="docker-compose";
else echo -e "${RED}未找到 docker compose，请先安装 Docker${NC}"; exit 1; fi

msg_ok()   { echo -e "${GREEN}✅ $1${NC}"; }
msg_err()  { echo -e "${RED}❌ $1${NC}"; }
msg_info() { echo -e "${CYAN}ℹ️  $1${NC}"; }
pause()    { read -n 1 -s -r -p "按任意键返回菜单..." ; echo; }

check_config() {
    if [ ! -f "$CONFIG" ]; then
        msg_err "找不到 $CONFIG，请先 cp data/config.example.json data/config.json 并填写"
        exit 1
    fi
}

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

pyset() { # pyset key value  （按 key 名自动处理 bool/int/list 类型）
    python3 - "$1" "$2" <<'PY'
import json, sys
key, val = sys.argv[1], sys.argv[2]
BOOL_KEYS = {'enable_telegram', 'enable_pushplus'}
INT_KEYS = {'frequency', 'max_workers'}
LIST_KEYS = {'vip_threads', 'monitored_usernames', 'monitored_roles'}
path = 'data/config.json'
d = json.load(open(path))
c = d['config']
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

app_running() { [ -n "$($DC ps -q app 2>/dev/null)" ]; }

restart_if_running() {
    if app_running; then
        msg_info "正在重启 app 使配置生效..."
        $DC restart app >/dev/null 2>&1 && msg_ok "已重启" || msg_err "重启失败，请手动 $DC restart app"
    else
        msg_info "服务未运行，下次启动时生效"
    fi
}

mask() { # 密钥打码显示
    local v="$1"; local n=${#v}
    if [ "$n" -eq 0 ]; then echo "(未填)"; elif [ "$n" -le 8 ]; then echo "****"; else echo "${v:0:4}****${v: -4}"; fi
}

show_status() {
    echo -e "${CYAN}--- 运行状态 ---${NC}"
    $DC ps 2>/dev/null
    local prov model
    prov=$(pyget ai_provider gemini); model=$(pyget model '')
    echo -e "AI 引擎: ${GREEN}$prov${NC}  模型: $model  裁决: $(pyget verdict_model '(跟随)')  频率: $(pyget frequency 30)s"
    echo -e "${GRAY}最近日志:${NC}"
    $DC logs --tail 5 app 2>/dev/null | sed 's/^/  /'
}

do_test_push() {
    if ! app_running; then msg_err "app 未运行，请先启动服务"; return; fi
    msg_info "正在发送测试推送（按已开启的通道）..."
    $DC exec -T app python - <<'PY'
from send import NotificationSender
s = NotificationSender()
ok = s.send_html_message("ForumMonitor 测试推送", "这是一条测试消息，收到说明推送通道正常。")
print("RESULT:", "OK" if ok else "FAILED")
PY
}

do_test_ai() {
    if ! app_running; then msg_err "app 未运行，请先启动服务"; return; fi
    msg_info "正在测试 AI 引擎..."
    $DC exec -T app python - <<'PY'
import json, time
cfg = json.load(open('data/config.json'))['config']
t = time.time()
try:
    if cfg.get('ai_provider') == 'workers':
        import requests
        r = requests.post(
            f"https://api.cloudflare.com/client/v4/accounts/{cfg['cf_account_id']}/ai/run/{cfg['cf_model']}",
            headers={"Authorization": f"Bearer {cfg['cf_api_token']}"},
            json={"messages": [{"role": "user", "content": "Reply with OK only"}]}, timeout=60)
        print("HTTP", r.status_code, str(r.json())[:160])
    else:
        import google.generativeai as genai
        genai.configure(api_key=cfg['gemini_api_key'])
        m = genai.GenerativeModel(cfg.get('model', 'gemini-3.5-flash-lite'))
        print("REPLY:", m.generate_content('Reply with OK only').text.strip()[:100])
    print("elapsed: %.1fs" % (time.time() - t))
except Exception as e:
    print("AI ERROR:", e)
PY
}

edit_telegram() {
    echo "当前 Bot Token: $(mask "$(pyget telegram_bot_token)")"
    echo "当前 Chat ID : $(pyget telegram_chat_id)"
    echo "当前开关    : enable_telegram = $(pyget enable_telegram)"
    read -p "新 Bot Token (回车保留): " v; [ -n "$v" ] && pyset telegram_bot_token "$v"
    read -p "新 Chat ID (回车保留): " v;  [ -n "$v" ] && pyset telegram_chat_id "$v"
    read -p "开启 Telegram 推送? (true/false, 回车保留): " v; [ -n "$v" ] && pyset enable_telegram "$v"
    msg_ok "Telegram 配置已保存"; restart_if_running
}

edit_pushplus() {
    echo "当前 Token: $(mask "$(pyget pushplus_token)")"
    echo "当前开关  : enable_pushplus = $(pyget enable_pushplus)"
    read -p "新 PushPlus Token (回车保留): " v; [ -n "$v" ] && pyset pushplus_token "$v"
    read -p "开启 PushPlus 推送? (true/false, 回车保留): " v; [ -n "$v" ] && pyset enable_pushplus "$v"
    msg_ok "PushPlus 配置已保存"; restart_if_running
}

edit_ai() {
    local prov; prov=$(pyget ai_provider gemini)
    echo "当前引擎: $prov"
    echo "  1. Google Gemini"
    echo "  2. Cloudflare Workers AI"
    echo "  0. 不切换，只改当前引擎参数"
    read -p "选择: " sel
    case "$sel" in
        1) pyset ai_provider gemini; prov=gemini ;;
        2) pyset ai_provider workers; prov=workers ;;
    esac
    if [ "$prov" = "gemini" ]; then
        echo "当前 Gemini Key: $(mask "$(pyget gemini_api_key)")"
        read -p "新 Gemini API Key (回车保留): " v; [ -n "$v" ] && pyset gemini_api_key "$v"
        echo "当前 model(摘要/过滤): $(pyget model)"
        read -p "新 model (回车保留): " v; [ -n "$v" ] && pyset model "$v"
        echo "当前 verdict_model(裁决): $(pyget verdict_model '(空=跟随 model)')"
        read -p "新 verdict_model (回车保留, 输 none 清空): " v
        if [ "$v" = "none" ]; then pyset verdict_model ""; elif [ -n "$v" ]; then pyset verdict_model "$v"; fi
        echo "当前 filter_model(过滤): $(pyget filter_model '(空=跟随 model)')"
        read -p "新 filter_model (回车保留, 输 none 清空): " v
        if [ "$v" = "none" ]; then pyset filter_model ""; elif [ -n "$v" ]; then pyset filter_model "$v"; fi
    else
        echo "当前 CF Account ID: $(pyget cf_account_id)"
        read -p "新 Account ID (回车保留): " v; [ -n "$v" ] && pyset cf_account_id "$v"
        echo "当前 CF Token: $(mask "$(pyget cf_api_token)")"
        read -p "新 API Token (回车保留): " v; [ -n "$v" ] && pyset cf_api_token "$v"
        echo "当前 cf_model: $(pyget cf_model)"
        read -p "新 cf_model (回车保留): " v; [ -n "$v" ] && pyset cf_model "$v"
    fi
    msg_ok "AI 配置已保存"; restart_if_running
}

edit_frequency() {
    echo "当前轮询间隔: $(pyget frequency 30) 秒"
    read -p "新间隔秒数 (回车保留): " v; [ -n "$v" ] && pyset frequency "$v"
    msg_ok "频率已保存"; restart_if_running
}

edit_vip() {
    while true; do
        echo -e "${CYAN}--- VIP 评论专线 ---${NC}"
        local list; list=$(pyget vip_threads)
        if [ -z "$list" ]; then echo "  (空)"; else echo "$list" | nl -ba | sed 's/^/  /'; fi
        echo "  a. 添加帖子链接"
        echo "  d. 按编号删除"
        echo "  0. 返回"
        read -p "选择: " act
        case "$act" in
            a) read -p "粘贴帖子链接: " url; [ -n "$url" ] && pyset vip_threads "+$url" && msg_ok "已添加" ;;
            d) read -p "要删除的编号: " n; [ -n "$n" ] && pyset vip_threads "-$n" && msg_ok "已删除" ;;
            0) break ;;
        esac
    done
    restart_if_running
}

do_update() {
    if [ -d .git ]; then git pull --ff-only || { msg_err "git pull 失败"; return; }; fi
    $DC up -d --build && msg_ok "已更新并重建"
}

do_logs() { $DC logs -f --tail 100 app; }

# --- 非交互子命令 ---
case "${1:-}" in
    status)  check_config; show_status; exit 0 ;;
    start)   $DC up -d; exit 0 ;;
    stop)    $DC down; exit 0 ;;
    restart) $DC restart app; exit 0 ;;
    logs)    do_logs; exit 0 ;;
    update)  do_update; exit 0 ;;
esac

check_config
command -v python3 >/dev/null 2>&1 || { msg_err "需要宿主机 python3 才能改配置（看状态/启停不受影响）"; }

while true; do
    echo -e "\n${CYAN}================ ForumMonitor 管理菜单 (Docker) ================${NC}"
    if app_running; then echo -e " 服务状态: ${GREEN}运行中${NC}   引擎: $(pyget ai_provider gemini)"; else echo -e " 服务状态: ${RED}未运行${NC}"; fi
    echo -e "${GRAY}----------------------------------------------------------------${NC}"
    echo "  1. 运行状态        2. 启动服务        3. 停止服务"
    echo "  4. 重启服务        5. 查看日志（实时）"
    echo "  6. Telegram 设置   7. PushPlus 设置"
    echo "  8. AI 引擎设置     9. 轮询频率"
    echo " 10. VIP 专线管理"
    echo " 11. 测试推送       12. 测试 AI"
    echo " 13. 更新（拉代码+重建）"
    echo "  0. 退出"
    read -p "请选择: " opt
    case "$opt" in
        1) show_status; pause ;;
        2) $DC up -d && msg_ok "已启动"; pause ;;
        3) $DC down && msg_ok "已停止"; pause ;;
        4) $DC restart app && msg_ok "已重启"; pause ;;
        5) do_logs ;;
        6) edit_telegram; pause ;;
        7) edit_pushplus; pause ;;
        8) edit_ai; pause ;;
        9) edit_frequency; pause ;;
        10) edit_vip; pause ;;
        11) do_test_push; pause ;;
        12) do_test_ai; pause ;;
        13) do_update; pause ;;
        0) exit 0 ;;
        *) ;;
    esac
done
