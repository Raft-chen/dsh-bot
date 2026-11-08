# dsh-bot

> 把 [dsh-lark-bot](https://github.com/PlutoKeating/dsh-lark-bot) 跑起来的过程中，踩到的坑、定位过程和最终修复。
>
> 目标环境：Windows + DSH 桌面版（`0.2.0-rc.2`）+ dsh-lark-bot（`0.19.16`）+ 独立 DSH 运行时（`0.1.0-rc.8`）

> **📚 相关记录**：[`BKM/`](BKM/) 目录里另有两份 DSH 实践记录 ——
> **手机远程控制家里的 DSH**（阿里云反代 + SSH 隧道）和
> **把 HuggingFace 上的模型跑在本地**（Ollama 调优 + GGUF MTP 头修复）。
> 如果本文的飞书 bot 部分不是你遇到的问题，可以先看那边。

---

## 这份文档解决什么问题

按官方 README 一步步装，你会遇到的是一个**任务全部失败、但日志里什么都没有**的黑箱。`doctor` 全部显示 `ok`，飞书能收到消息，bot 也在跑 —— 但每条消息都回"执行出错"。

根因是 **`dsh-app-boot@0.1.0-rc.8` 与 `cordis-plugin-hmr@1.0.17` 的集成 bug**，再加上几个环境层面的版本陷阱。

**如果你现在正卡在这里，直接跳到 → [快速修复](#快速修复)**

---

## 目录

- [快速修复](#快速修复)
- [环境准备要点](#环境准备要点)
- [四个真实根因（含定位过程）](#四个真实根因含定位过程)
  - [① HMR 服务作用域不匹配 —— 元凶](#-hmr-服务作用域不匹配--元凶)
  - [② 模型 ID 过期](#-模型-id-过期)
  - [③ bundles 不会被自动安装](#-bundles-不会被自动安装)
  - [④ pnpm 的 overrides 位置与行尾陷阱](#-pnpm-的-overrides-位置与行尾陷阱)
- [排查方法论](#排查方法论)
- [文件清单](#文件清单)
- [相关记录 · BKM](#相关记录--bkm)
  - [① 手机远程控制家里的 DSH](BKM/docs/01-dsh-remote.md)
  - [② 本地模型：Ollama 调优与 GGUF 元数据修复](BKM/docs/02-local-model.md)

---

## 快速修复

跑一次修补脚本，然后重启 bot：

```powershell
powershell -ExecutionPolicy Bypass -File .\reapply-patches.ps1
```

脚本会重新打上两个源码补丁（幂等，可反复跑）。

> **什么时候需要重跑**：升级 dsh-lark-bot、重装 DSH 运行时、或 `pnpm install --force` 之后 ——
> 这些操作会覆盖 npm 包里的源码。

---

## 环境准备要点

| 项 | 要求 | 说明 |
|---|---|---|
| DSH 运行时 | `0.1.0-rc.8` | bot 的 `dshWorkshop.compatibility.dshVersions` 只声明支持这个版本 |
| dsh-lark-bot | `0.19.16` | |
| Node.js | ≥ 22.19 | |
| pnpm | 任意近期版本 | bot 内部会调用它装依赖 |
| 独立 DSH CLI | 需要 | 桌面版把 DSH 嵌在 `app.asar` 里，**没有可用的 `dsh` 命令**，必须单独装一份 |

**为什么要独立的 DSH**：`dsh-lark-bot setup` 要求本机存在 dsh CLI，它在这些位置查找：

```
$DSH_HOME/profiles/node_modules/@deepseek-ai/dsh/lib/bin.js
~/.dsh/profiles/node_modules/@deepseek-ai/dsh/lib/bin.js
~/.npm/_npx/node_modules/@deepseek-ai/dsh/lib/bin.js
~/.cache/pnpm/dlx/node_modules/@deepseek-ai/dsh/lib/bin.js
```

桌面版一个都不满足。最省事的做法是把独立 DSH 装在**第一个位置**，
这样 bot 自动就能发现，无需额外配置。

**版本兼容性结论**：rc.8 插件**不能**跑在 `0.2.0-rc.2` 宿主上。
强行用 `dsh plugin allow-version` 豁免会通过兼容性检查，但运行时报一堆
`ctx.systemPrompt.getSectionOrder is not a function` 之类的 API 错误 ——
**必须用匹配的 rc.8 运行时**。

---

## 四个真实根因（含定位过程）

### ① HMR 服务作用域不匹配 —— 元凶

**症状**

- 飞书里每条消息都回"执行过程：出错"
- `jobs.json` 里所有任务 `state: "failed"`，`checkpoint.stage: "finalizing"`
- **bot 日志里完全没有错误**（这是最迷惑人的地方）
- `doctor` 全部显示 `ok`

**定位过程**

`jobs.json` 显示任务走到了 `finalizing` 阶段才失败 —— 说明 bot 端正常，
是 agent 运行时出了问题。但 bot 把它 spawn 成子进程并吞掉了 stderr。

关键一步是**绕开 bot，直接手动跑 agent 运行时并捕获它自己的输出**：

```powershell
$env:DSH_HOME="D:\dsh"
node D:\dsh\profiles\node_modules\@deepseek-ai\dsh\lib\bin.js --profile headless "reply with exactly OK"
```

立刻暴露真凶：

```
Error: dsh: user patch-layer watching requires the Cordis HMR service
    at watchUserPatches (dsh-app-boot/lib/index.js:764)
```

**为什么 `doctor` 显示正常**：这个错误**只在执行任务时**才触发。
不带任务参数时，dsh 在更早的位置（`a task is required`）就退出了，
所以所有"启动测试"看起来都通过。

**根因**

`dsh-app-boot` 的 `watchUserPatches()`：

```js
const hmr = ctx.get("hmr");
if (hmr === void 0) throw new Error(`... requires the Cordis HMR service`);
```

而 `cordis-plugin-hmr` 把服务注册在了**子 fiber 作用域**上，
根上下文的 `ctx.get("hmr")` 取不到 → 抛错 → **整个 profile 启动失败**。

**决定性证据**：把 timer 服务显式插入 profile 后，报错变成
`service "timer" has been registered` —— 证明**服务本来就在正常注册**，
只是作用域对不上，纯粹是查找方式的问题。

**修复**

```js
async function watchUserPatches(ctx, options) {
	const { binName, filename, compose = (patches) => patches } = options;
	let hmr = ctx.get("hmr");
	if (hmr === void 0) {
		// 从子作用域回退查找
		for (const scopeName of ["loader", "include"]) {
			try {
				const scope = ctx.get(scopeName);
				const scoped = scope !== void 0 && typeof scope.get === "function" ? scope.get("hmr") : void 0;
				if (scoped !== void 0) { hmr = scoped; break; }
			} catch {}
		}
	}
	if (hmr === void 0) {
		// 实在取不到也不让 profile 崩，只是失去补丁热重载
		return async () => {};
	}
	const entry = bootstrapIncludes.get(ctx);
	...
}
```

**验证**：修补后手动跑 headless 任务 → `exit code 0`，输出 `OK`。

---

### ② 模型 ID 过期

**症状**：模型调用返回空内容，任务失败。

**根因**：rc.8 的 `dsh-llm-deepseek` 注册的模型 id 是 `deepseek-v4-flash`，
但 DeepSeek API 现在提供的是 `deepseek-flash`。**名字对不上**。

用 `/models` 接口可以确认实际可用的 id：

```powershell
$key = "sk-..."
Invoke-WebRequest "https://api.deepseek.com/models" `
  -Headers @{ Authorization = "Bearer $key" } -UseBasicParsing | Select-Object -Expand Content
```

返回：

```json
{"data":[
  {"id":"deepseek-flash",  "name":"DeepSeek-V4.1-Flash"},
  {"id":"deepseek-v4-pro", "name":"DeepSeek-V4-Pro"}
]}
```

注意 **`deepseek-v4-pro` 反而是对的**，只有 flash 变了名字。这个不对称很容易骗过人。

**修复**：把 `dsh-llm-deepseek/lib/index.js` 里的 `"deepseek-v4-flash"` 改成 `"deepseek-flash"`。

> 为什么不能靠传参绕过：provider 内部有校验
> `connection.models.find(entry => entry.id === model)`，
> 只认已注册的 id，所以**必须改注册表本身**。

---

### ③ bundles 不会被自动安装

**症状**

```
dsh: unavailable (SDK runtime profile setup failed:
     @deepseek-ai/dsh-sdk-jsonrpc-server@0.1.0-rc.8 was not found after install)
```

**根因**：profile 的 `package.json` 里声明了

```json
"dsh": { "profile": { "bundles": ["@deepseek-ai/dsh-base"] } }
```

但 **`dsh.profile.bundles` 只是加载清单，pnpm 不会据此安装依赖**。
必须同时写进 `dependencies`：

```json
"dependencies": {
  "@deepseek-ai/dsh-base": "0.1.0-rc.8"
}
```

**相关的第二个陷阱**：`@deepseek-ai/cordis-plugin-hmr` 的版本范围是 `^1.0.16`，
但 pnpm 会解析到最新的 `1.0.19` —— 而 **1.0.18 起删掉了 `registerConfig()` 方法**：

| hmr 版本 | `registerConfig` |
|---|---|
| 1.0.16 | ✅ |
| 1.0.17 | ✅ |
| 1.0.18 | ❌ |
| 1.0.19 | ❌ |

必须钉到 **`1.0.17`**（比 1.0.16 新，且兼容 cordis 4.0.4）。

> **注意**：不要用 grep 源码里有没有 `registerConfig` 来判断版本好坏 ——
> 这个方法是挂在 Service 实例上的，能 import 成功也不代表运行时可用。

---

### ④ pnpm 的 overrides 位置与行尾陷阱

两个容易被忽略的点：

**1. pnpm 11 不再读 `package.json` 里的 `pnpm.overrides`**，会静默忽略并只给一行警告：

```
[WARN] The "pnpm" field in package.json is no longer read by pnpm.
```

必须写到 **`pnpm-workspace.yaml`** 里。

**2. `pnpm-workspace.yaml` 必须用 CRLF 行尾**。
用 LF 写会导致 YAML 把 `overrides:` 解析成上一条注释的延续，overrides 静默失效。

同理，**`.bat` 脚本必须 ASCII + CRLF** —— 否则 cmd.exe 用本地 ANSI 码页读取时
中文会被截断、换行错位，把注释当命令执行。

---

## 排查方法论

这次绕了不少弯路，值得记下的几条：

**1. 不要相信"启动正常"** —— 只在启动路径上测试会漏掉运行期才暴露的 bug。
必须真正跑一次完整任务。

**2. 错误被吞掉时，绕开上层直接跑底层**
bot spawn agent 运行时是独立子进程，stderr 被 `suppressShutdownError()` 静默了。
直接手动跑那个子进程并捕获输出，一步就抓到真凶。

**3. 用对照实验而不是反复改候选原因**
"insert timer → 报已注册"这个实验直接证明了服务在注册、是查找问题，
比继续猜配置快得多。

**4. 版本范围 `^x.y.z` 是不可信的**
`^1.0.16` 会装到 `1.0.19`，而后者删了需要的方法。**关键依赖要钉精确版本。**

**5. 核对 API 的模型列表，而不是信插件的内置定义**
插件的模型 id 可能已经过期。

**6. 记下"哪些操作会覆盖补丁"**
改 npm 包源码的补丁会被升级/重装冲掉，必须配一个幂等的重打脚本。

---

## 文件清单

| 文件 | 用途 |
|---|---|
| `reapply-patches.ps1` | 幂等重打两个源码补丁（升级/重装后跑一次） |
| `docs/troubleshooting.md` | 完整排查手册（含日志位置、逐项检查表） |
| `examples/start-lark.bat` | Windows 一键启动脚本示例（ASCII + CRLF） |
| `examples/pnpm-workspace.yaml` | profile 的 pnpm 配置参考（含必要的 overrides） |

---

## 相关记录 · BKM

同一个 DSH 生态里另外两个「卡死很久」的问题，完整过程放在 [`BKM/`](BKM/)：

### ① [手机远程控制家里的 DSH](BKM/docs/01-dsh-remote.md)

**症状**：在外面想用手机看/指挥家里的 DSH，Tailscale 怎么都调不通。

**结论**：Tailscale 在国内这套组合里三个硬伤（控制面不稳 / iOS 拦 http / 华为装不了），
改用**阿里云 nginx 反代 + SSH 反向隧道**，配合独立子域名和合法证书，任何网络都能开。

文档里有：完整 nginx 配置、acme.sh 的 sudo 限制绕法、fail2ban 的两处坑、
网关被 DSH 重启带走的解决方式、12 条排查清单。

### ② [本地模型：Ollama 调优与 GGUF 元数据修复](BKM/docs/02-local-model.md)

**症状 A**：DSH 调本地模型「奇慢无比」，慢到没法用。

> 真相不是算力：`OLLAMA_KEEP_ALIVE=1m` 让模型一分钟就卸载，
> 每次调用都重新加载 + 预热（实测生成 60 tok/s，但提示词处理只有 0.5 tok/s）。
> 顺带记录了 `gpt-oss:20b` + 32k 上下文在 16GB 卡上直接崩、残留 `llama-server` 占显存的坑。

**症状 B**：新架构模型导进 Ollama 报 `missing tensor 'blk.32.attn_norm.weight'`。

> GGUF 元数据写了 `block_count=33`（含 MTP 头）但文件里只有 32 层张量，
> 老版 llama.cpp 不认 `nextn_predict_layers`。
> 升级 Ollama 被 GitHub 卡死，最后直接**改 GGUF 元数据**绕过 ——
> 附可复用的改写脚本和结构校验脚本。

👉 [BKM 总览](BKM/README.md)

---

## 免责与致谢

- **dsh-lark-bot** 作者：[PlutoKeating](https://github.com/PlutoKeating)
- 本文档记录的是**特定版本组合下**遇到的问题与修复，不保证适用于其他版本。
  上游修好对应问题后，这里的补丁即可弃用。
- 两个补丁修改的是 npm 包内的源码，属于**临时绕过**而非正规修复；
  如果条件允许，向对应上游提 issue / PR 更合适。

---

## 许可

文档内容采用 [CC BY 4.0](https://creativecommons.org/licenses/by/4.0/)，
脚本部分采用 MIT。
