# ForumMonitor

LowEndTalk 优惠帖 24 小时监控：新帖 RSS + 指定帖子评论双通道盯梢，AI 负责过滤、裁决和摘要，真正的抢购机会（补货 / 新优惠码 / 新下单链接 / 抽奖）第一时间推送到 Telegram / PushPlus。Docker 一键部署。

## 功能

- **新帖监控**：轮询 LET 的 RSS，新促销帖经 AI 摘要后推送（商家、套餐、价格、下单链接、优惠码一帖说清）
- **VIP 评论专线**：指定帖子（如黑五大帖）每轮必扫评论，商家/楼主的补货、放码以「插播/回复」形式即时推送
- **AI 三层把关**：硬过滤（晒单、订单号、水贴先毙）→ AI 过滤 → AI 裁决（JSON 准入判断，裁决失败自动放行，宁可多推不漏闪购）
- **双引擎可切换**：Google Gemini 或 Cloudflare Workers AI，改配置即换
- **模型分流**：摘要、过滤、裁决可各用一个模型（`model` / `filter_model` / `verdict_model`），免费额度按模型分别计算，等于变相翻倍
- **MongoDB 去重**：帖子、评论、推送记录全量落库，重启不重复推送
- 评论只扫每个帖子**最后 2 页** + 近 24 小时，角色只认商家 / 楼主 / 主持人等

## 快速开始（Docker）

```bash
git clone <本仓库地址>
cd forum-monitor-docker

# 1. 准备配置
cp data/config.example.json data/config.json
# 编辑 data/config.json，至少填好 Telegram 和一个 AI 引擎的 key（见下表）

# 2. 启动（自带 MongoDB，不需要另装）
docker compose up -d --build

# 3. 看日志
docker compose logs -f app
```

停止：`docker compose down`（数据在 named volume 里，不会丢）。

## 管理菜单

仓库自带宿主机管理脚本（需要宿主机有 python3），常用操作不用记命令：

```bash
./menu.sh
```

菜单包含：运行状态 / 启停 / 重启 / 实时日志、Telegram 与 PushPlus 设置、AI 引擎切换与模型设置、轮询频率、VIP 专线帖子增删、测试推送、测试 AI、更新（拉代码+重建）。在菜单里改完配置会自动重启 app 生效。

也可以直接带参数执行：`./menu.sh status|start|stop|restart|logs|update`。

## 配置说明（data/config.json）

| 键 | 说明 | 获取方式 |
|---|---|---|
| `telegram_bot_token` | Telegram 机器人 Token | 找 @BotFather 发 /newbot |
| `telegram_chat_id` | 接收推送的会话 ID | 先给机器人发一句话，再问 @userinfobot |
| `enable_telegram` / `enable_pushplus` | 两个推送通道的开关 | |
| `pushplus_token` | PushPlus Token（推微信） | pushplus.plus 登录后首页 |
| `ai_provider` | AI 引擎：`gemini` 或 `workers` | |
| `gemini_api_key` | Gemini API Key | aistudio.google.com/apikey |
| `model` | 摘要用模型 | 推荐 `gemini-3.5-flash-lite` |
| `verdict_model` | 裁决用模型（空 = 跟随 `model`） | 推荐 `gemini-3.1-flash-lite`，与摘要分开计额度 |
| `filter_model` | 过滤用模型（空 = 跟随 `model`） | |
| `cf_account_id` / `cf_api_token` / `cf_model` | Workers AI 引擎参数（provider=workers 时用） | CF 控制台 Workers & Pages 页有 Account ID；Token 在 My Profile → API Tokens 创建（权限 Account → Workers AI → Edit） |
| `frequency` | 轮询间隔秒数 | 默认 30 |
| `vip_threads` | 评论专线帖子链接数组 | 如 `["https://lowendtalk.com/discussion/xxxx"]` |
| `monitored_roles` / `monitored_usernames` | 评论监控认的角色 / 指定用户名 | 一般用默认 |
| `thread_prompt` / `filter_prompt` | 摘要 / 过滤提示词 | 已内置调好的默认值，一般不用改 |

**免费额度提示**：Gemini 免费层按「项目 × 模型」分别计，两个 Flash-Lite 模型各 500 次/天；摘要与裁决分用两个 Lite 模型即可各吃一份额度。非 Lite 的 Flash 模型免费层只有 20 次/天，不要用。

## 不用 Docker 的跑法

需要 Python 3.11 + 一个 MongoDB：

```bash
pip install -r requirements.txt
cp data/config.example.json data/config.json   # 填好 key
MONGO_HOST="mongodb://localhost:27017/" python core.py
```

## 目录结构

```
core.py                 主程序（抓取 / AI / 推送调度）
send.py                 推送模块（Telegram + PushPlus）
menu.sh                 宿主机管理菜单（启停 / 改配置 / 测试推送与 AI）
data/config.example.json  配置模板（真实配置 data/config.json 不入库）
Dockerfile / docker-compose.yml
```

## 注意

- `data/config.json` 含各平台密钥，**不要**提交到公开仓库（.gitignore 已排除）
- 推送内容来自论坛公开帖子，AI 摘要偶有误差，下单前请点原文核对
