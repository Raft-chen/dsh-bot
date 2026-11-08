# 排查手册

配合根目录 [README](../README.md) 使用。这里是可以照着做的检查步骤。

---

## 0. 先确认现象属于哪一类

| 现象 | 大概率原因 | 跳到 |
|---|---|---|
| 飞书发消息完全没反应 | 进程没跑 / 事件订阅没配好 | [§2](#2-飞书里完全没反应) |
| 飞书回"执行过程：出错" | 源码补丁丢了 | [§1](#1-任务全部失败最优先查这个) |
| bot 起不来 / 报缺包 | profile 依赖没装好 | [§3](#3-profile-依赖问题) |
| 模型调用失败 / 401 | API Key 或模型名 | [§4](#4-模型与凭据) |

---

## 1. 任务全部失败（最优先查这个）

### 第一步：看任务账本

```
<bot状态目录>/profiles/<profile>/jobs.json
```

Windows 默认是 `C:\Users\<你>\.dsh-lark\profiles\default\jobs.json`。

关注每个记录的 `state` 和 `checkpoint.stage`：

| 观察 | 含义 |
|---|---|
| `state: "failed"`, `stage: "finalizing"` | **agent 运行时启动失败** → 极可能补丁丢了，跳第二步 |
| `state: "completed"` | 正常 |
| 压根没有新记录 | 消息没到 bot，跳 [§2](#2-飞书里完全没反应) |

### 第二步：跑补丁脚本

```powershell
powershell -ExecutionPolicy Bypass -File ..\reapply-patches.ps1
```

然后重启 bot。

### 第三步：还是不行 → 直接跑 agent 运行时

**这是最有效的一步。** bot 会把 agent 运行时的 stderr 静默掉，必须绕开它：

```powershell
# 按你的实际路径改
$env:DSH_HOME = "D:\dsh"
$env:DEEPSEEK_API_KEY = "sk-..."          # 用你自己的 key
$bin = "$env:DSH_HOME\profiles\node_modules\@deepseek-ai\dsh\lib\bin.js"

node $bin --profile headless "reply with exactly OK"
```

| 输出 | 结论 |
|---|---|
| `OK` | agent 运行时正常，问题在 bot 层 |
| `user patch-layer watching requires the Cordis HMR service` | 补丁 1 没生效 |
| 报模型 / 401 错误 | 跳 [§4](#4-模型与凭据) |
| 报缺包 | 跳 [§3](#3-profile-依赖问题) |

> **常见误判**：不加任务参数跑 `dsh --profile headless` 会输出
> `a task is required` 然后正常退出 —— 这**不代表运行时没问题**。
> 一定要带上任务参数，让代码真正走到 HMR 那一步。

---

## 2. 飞书里完全没反应

### 检查 bot 进程

```powershell
# Windows：看有没有 bot 与它 spawn 的 agent 运行时
Get-CimInstance Win32_Process -Filter "Name='node.exe'" |
  Where-Object { $_.CommandLine -match "dsh-lark" } |
  Select-Object ProcessId, CommandLine
```

应该看到**两个**进程：bot 主进程（`--profile dsh-lark`）和 agent 运行时（`--profile dsh-lark-sdk`）。

> **注意别开两个 bot**。两个实例会抢同一条飞书 WebSocket 长连接，
> 消息可能被投给任意一个。同一时间只保留一个 bot 进程。

### 检查网络连接

```powershell
# bot 进程 PID 换成实际的
Get-NetTCPConnection -OwningProcess <PID> -State Established |
  Select-Object RemoteAddress, RemotePort
```

有到 443 的连接说明连上了飞书；一个都没有说明没连上。

### 检查飞书后台配置

<https://open.feishu.cn/app> → 选你的应用：

| 项 | 应该是什么 |
|---|---|
| 事件与回调 → **订阅方式** | **使用长连接接收事件/回调** |
| 事件订阅 | 已添加 `im.message.receive_v1`（接收消息） |
| 权限管理 | `im:message` 和 `im:message:send_as_bot` 已开通 |

**订阅方式选错是最常见的原因。** 如果配成了 HTTP 回调，飞书会尝试往公网地址推事件，
本机收不到 —— 而 bot 日志里一片安静。

如果 bot 日志里出现这段（中文可能因终端编码显示为乱码）：

```
[ws] receive events or callbacks through persistent connection only available
     in self-build & Feishu app, Configured in: Developer Console
       -> Events and Callbacks -> Mode of event/callback subscription
       -> Receive events/callbacks through persistent connection
```

就是在提示你去后台把订阅方式改成**长连接**。

### 检查事件是否真的进来了

bot 的 guardian 心跳文件里有 `lastInboundAt` 时间戳：

```
<bot状态目录>/profiles/<profile>/guardian/heartbeat.json
```

这个时间戳更新了 → 消息确实到达了 bot。

---

## 3. profile 依赖问题

### 三个必备条件

每个 profile 目录下都要满足：

**① bundles 必须同时出现在 dependencies 里**

```json
{
  "dependencies": {
    "@deepseek-ai/dsh-base": "0.1.0-rc.8"     // ← 必须显式列出
  },
  "dsh": { "profile": { "bundles": ["@deepseek-ai/dsh-base"] } }
}
```

只写 `bundles` 是不够的，pnpm 不会据此安装。

**② hmr 必须是 1.0.17**

`^1.0.16` 会解析到 1.0.19，而 1.0.18 起删了 `registerConfig()`。

**③ `pnpm-workspace.yaml` 用 CRLF**

LF 行尾会让 `overrides:` 被解析进注释，静默失效。

### 检查方法

```powershell
# 包是否存在且版本正确
$dir = "D:\dsh\profiles\dsh-lark\node_modules\@deepseek-ai"
foreach ($p in @("dsh-base","cordis-plugin-hmr","cordis-plugin-timer","cordis")) {
  $pj = "$dir\$p\package.json"
  $v = if (Test-Path $pj) { (Get-Content $pj -Raw | Select-String '"version"\s*:\s*"([^"]+)"').Matches[0].Groups[1].Value } else { "缺失" }
  "{0,-24} {1}" -f $p, $v
}
```

期望：`dsh-base 0.1.0-rc.8`、`cordis-plugin-hmr 1.0.17`。

### 重装

```powershell
$dir = "D:\dsh\profiles\dsh-lark"     # 分别对 dsh-lark 和 dsh-lark-sdk 做
Set-Location $dir
$env:CI = "true"                       # 允许无 TTY 下重建 modules 目录
Remove-Item node_modules -Recurse -Force
Remove-Item pnpm-lock.yaml -Force
pnpm install --prefer-offline
```

> `CI=true` 很关键。不加会报
> `ERR_PNPM_ABORTED_REMOVE_MODULES_DIR_NO_TTY` 然后中止。

---

## 4. 模型与凭据

### 核对模型 id

**不要相信插件里写的模型名**，直接问 API：

```powershell
$key = "sk-..."
Invoke-WebRequest "https://api.deepseek.com/models" `
  -Headers @{ Authorization = "Bearer $key" } -UseBasicParsing |
  Select-Object -Expand Content
```

用返回的 `id` 字段，而不是插件内置的。

### 快速验证 key 是否可用

```powershell
$body = @{
  model = "deepseek-flash"
  messages = @(@{ role = "user"; content = "say OK" })
  max_tokens = 200          # 别设太小，这模型有 reasoning token 消耗
} | ConvertTo-Json -Depth 5

Invoke-WebRequest "https://api.deepseek.com/chat/completions" -Method Post `
  -Headers @{ Authorization = "Bearer $key"; "Content-Type" = "application/json" } `
  -Body $body -UseBasicParsing | Select-Object -Expand Content
```

> **`max_tokens` 别设太小**：`deepseek-flash` 会消耗 reasoning token，
> 设成 10 可能返回空内容，让你误判成 key 或模型有问题。至少给 200。

### 凭据格式的两个时代

DSH 的凭据文件 `.credentials.yaml` 在 rc.8 与 0.2.x 之间**格式不兼容**：

| 版本 | 格式 | 认证方式 |
|---|---|---|
| `0.1.0-rc.8` | `引用名: "字符串值"`，引用名须匹配 `^[A-Za-z_][A-Za-z0-9_]*$` | API Key（环境变量名） |
| `0.2.x` | `引用名: { kind, payload: {...} }` 嵌套 | OAuth 账号令牌 |

**结论**：桌面版（0.2.x）的登录凭据**不能**直接给 rc.8 运行时用。
rc.8 走 API Key，设 `DEEPSEEK_API_KEY` 环境变量即可。

如果你把 0.2.x 格式的凭据文件复制给了 rc.8，会看到：

```
credentials-local: the value for "version" in ... must be a string
credentials-local: credential ref "..." must match /^[A-Za-z_][A-Za-z0-9_]*$/
```

删掉那份文件，改用 API Key。

---

## 5. 日志都在哪

| 内容 | 位置 |
|---|---|
| bot 结构化日志（stderr） | 启动脚本重定向的文件，如 `D:\dsh\bot-full.log` |
| 任务账本 | `<bot状态目录>/profiles/<p>/jobs.json` |
| 会话记录 | `<bot状态目录>/profiles/<p>/sessions.json` |
| guardian 心跳 | `<bot状态目录>/profiles/<p>/guardian/heartbeat.json` |
| DSH 启动失败诊断 | `$DSH_HOME/logs/startup-*.log` |
| pnpm 操作日志 | `<profile>/.plugin-manager/logs/operation-*/pnpm.log` |

**警告**：bot 的结构化日志**经常什么都没有**。因为关键错误在
`dsh-app-boot` 里被 `suppressShutdownError()` 吞掉了，
或者发生在被 pipe 的 agent 子进程里。
**遇到这种情况不要死磕日志，直接跑 §1 第三步。**

---

## 6. 启动脚本的两个 Windows 陷阱

### `.bat` 必须 ASCII + CRLF

cmd.exe 用**本地 ANSI 码页**读取 `.bat`。UTF-8（尤其带 BOM）的中文会被截断，
换行错位，导致注释被当成命令执行，报出一堆莫名其妙的
`'xxx' 不是内部或外部命令`。

**要么全 ASCII**，要么确认文件是 **ANSI/GBK + CRLF**。

### `.ps1` 含中文需要 UTF-8 BOM

Windows PowerShell 5.1 靠 BOM 识别 UTF-8。没有 BOM 的中文会乱码，
甚至让解析器报 `The string is missing the terminator`。

用这个转换：

```powershell
$f = "D:\dsh\reapply-patches.ps1"
$c = [System.IO.File]::ReadAllText($f, [System.Text.Encoding]::UTF8)
[System.IO.File]::WriteAllText($f, $c, (New-Object System.Text.UTF8Encoding($true)))
```
