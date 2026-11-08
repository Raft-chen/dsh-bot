# DSH BKM · 踩坑与最佳实践

> **BKM = Best Known Method**。这里记录我在真实环境里把 **DeepSeek Harness（DSH）**
> 用起来时踩过的坑、验证过的做法和可复制的脚本。
>
> 全部内容都是在 **Windows 10/11 + 国内网络** 这个有点麻烦的环境下趟出来的。
> 如果你也在这类环境里折腾 DSH，希望这些记录能让你少走几天弯路。

---

## 两个案例

| # | 主题 | 一句话结论 |
|---|---|---|
| 1 | [手机远程控制家里的 DSH](docs/01-dsh-remote.md) | Tailscale 在国内不稳，**阿里云 nginx + SSH 反向隧道** 才是稳的 |
| 2 | [把 HuggingFace 上的模型跑在本地](docs/02-local-model.md) | Ollama 慢多半是 `KEEP_ALIVE`；导入不了是 **GGUF 元数据带 MTP 头**，改元数据就能跑 |

---

## 案例 1 速览：手机远程访问

**目标**：人在外面用手机（iPhone / 华为）控制家里工作站上跑的 DSH。

**走过的弯路**

```
Tailscale  → 国内直连不稳、iOS Safari「仅 HTTPS」拦 http、华为无 GMS 装不了
   ↓
阿里云服务器做中转（已经有了，顺手用）
   ↓
nginx 子路径 /remote/  →  失败，DSH Remote 网关不支持 base path
   ↓
独立子域名 + SSH 反向隧道  →  成功，国内任何网络都能开
```

**最终架构**

```
手机(任意网络) ──https──> 阿里云 nginx ──反向隧道──> 家里工作站:8787 ──> DSH
```

**关键结论**

- HTML 页面 `Cache-Control: no-cache` 时，「网页还是旧的」99% 是浏览器缓存，不是服务器
- 给 IP 测速要在**服务器侧**测，从本机绕外网回自己测出来的数字没有意义
- 自建服务想扛住令牌爆破：`fail2ban` 在这类机器上问题多，**自写 40 行脚本 + cron** 更可控

👉 完整过程、12 个坑和排查命令：[docs/01-dsh-remote.md](docs/01-dsh-remote.md)

---

## 案例 2 速览：本地模型

**目标**：把 HuggingFace 上一个 9B 微调（Q6_K，6.9GB）跑在 RTX 5060 Ti 16GB 上。

**两个完全不同的问题**

1. **「DeepSeek 调用本地模型奇慢无比」**
   - 真凶不是模型，是 `OLLAMA_KEEP_ALIVE=1m` —— 模型 1 分钟就卸载，每次调用都要冷加载
   - 另一个坑：`gpt-oss:20b`(13GB) + 32k 上下文在 16GB 卡上直接崩（`0xC0000409`）
   - 还有：残留的 `llama-server` 占着 4.3GB 显存，导致新模型分配失败

2. **「这个模型导不进 Ollama」**
   ```
   load: missing tensor 'blk.32.attn_norm.weight'
   ```
   - GGUF 元数据写 `block_count=33`（含 MTP 头），但文件里只有 32 层张量
   - 老版本 llama.cpp 不认 `nextn_predict_layers`，硬找第 33 层
   - **升级 Ollama 被 GitHub 卡死 → 直接改 GGUF 元数据**：33→32、`nextn`→0、`recurrent_layers` 裁掉最后一项

**实测结果**：加载 3.4 秒、**52 tok/s**、常驻显存 8.4GB、中文/代码/指令遵循全部正常。

👉 完整过程、排查数据和两个可直接用的脚本：[docs/02-local-model.md](docs/02-local-model.md)

---

## 脚本

| 脚本 | 用途 |
|---|---|
| [`scripts/rewrite-gguf.py`](scripts/rewrite-gguf.py) | 改写 GGUF 元数据（去 MTP 层），让旧版 llama.cpp 能加载 |
| [`scripts/verify-gguf.py`](scripts/verify-gguf.py) | 校验改写后的 GGUF 结构（张量信息 / 偏移 / 数据段大小） |
| [`scripts/keep-tunnel.ps1`](scripts/keep-tunnel.ps1) | Windows 计划任务常驻 SSH 反向隧道，断线自动重连 |
| [`scripts/keep-gateway.ps1`](scripts/keep-gateway.ps1) | 常驻 DSH Remote 网关（自动探测 DSH 上游端口） |
| [`scripts/dsh-remote-guard.sh`](scripts/dsh-remote-guard.sh) | 按 401 次数封 IP，防令牌爆破（cron 每分钟） |
| [`scripts/download-model.py`](scripts/download-model.py) | 从 HuggingFace 镜像下载 GGUF（断点续传 + 完成校验） |

---

## 环境

| 项 | 我的环境 | 说明 |
|---|---|---|
| 系统 | Windows 11（26100） | |
| GPU | RTX 5060 Ti 16GB | 跑 9B Q6_K 有余量 |
| CPU / 内存 | Ryzen 7 9700X / 32GB | |
| Ollama | 0.30.11 | 旧版本，认不了带 MTP 的新架构 |
| 服务器 | 阿里云轻量 Alibaba Cloud Linux 3 | 已有，顺手当反代 |

> 文中所有域名、IP、令牌、路径都替换成了占位符，按你自己的环境替换即可。

---

## License

MIT
