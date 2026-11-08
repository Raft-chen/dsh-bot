# 案例 2：把 HuggingFace 上的模型跑在本地（Ollama + GGUF MTP 头）

> 目标：把一个 9B 的 HF 微调（Q6_K GGUF，6.9GB）跑在 RTX 5060 Ti 16GB 上，
> 并接进 DSH 当作可选模型。
>
> 结果：加载 3.4 秒、**52 tok/s**、常驻显存 8.4GB、中文/代码/指令遵循全部正常。
>
> 但中间遇到的是**两个完全不同的问题**，都值得记下来。

---

## 问题一：DSH 调用本地模型「奇慢无比」

### 现象

- 会话里一切正常，但每次让模型干活都要等很久，感觉像卡住
- 同样的模型在 `ollama run` 里好像也慢，但生成速度看起来又正常

### 实测数据（关键）

```
冷启动一次 ollama run（qwen3.5:9b，32k 上下文）：
  load duration       : 15.0 s
  prompt eval         : 14 tokens / 30.0 s = 0.47 tok/s      ← 慢得离谱
  eval (生成)         : 2922 tokens / 48.6 s = 60.1 tok/s    ← 完全正常

热状态第二次：
  load duration       : 0.17 s
  prompt eval         : 12 tokens / 3.8 s = 3.17 tok/s
  eval                : 62.4 tok/s
```

**生成 60 tok/s，提示词处理 0.5~3 tok/s —— 差 130 倍。**

DSH 每轮会发几千 token 的系统提示 + 工具定义，按 3 tok/s 算，光处理提示词就要十几分钟。

### 排查过程

用 `/api/generate` 直接测（绕开 CLI 的终端渲染），结果完全不同：

| 上下文 | 提示词处理 | 生成 |
|---|---|---|
| ctx=8192 | 1779 tok/s | 61.2 tok/s |
| ctx=16384 | 1873 tok/s | 63.7 tok/s |
| ctx=32768 | 1877 tok/s | 63.7 tok/s |
| ctx=65536 | 1830 tok/s | 63.9 tok/s |

**API 层面根本不慢** → 那 CLI 的 0.47 tok/s 是什么？

再测「冷启动 vs 热状态」的 **TTFT（首个 token 时间）**，用 ~5100 token 的提示词模拟 DSH：

| 场景 | 加载 | 首 token | 提示词处理 |
|---|---|---|---|
| 冷启动（模型被卸载后） | 2.6 s | **4.6 s** | 2600 tok/s |
| 热状态（已驻留） | 0.2 s | **0.6 s** | 12626 tok/s |

### 三个真凶

**1. `OLLAMA_KEEP_ALIVE=1m`**

默认 1 分钟没请求就卸载模型。DSH 是**突发式**调用（做完一步、等你确认、再继续），
间隔经常 > 1 分钟 → **每次调用都要重新加载模型 + 预热**。

```powershell
# 永久驻留（显存够就设 -1）
[Environment]::SetEnvironmentVariable("OLLAMA_KEEP_ALIVE", "-1", "User")
```

验证：

```powershell
ollama ps
# NAME          ID    SIZE    PROCESSOR  CONTEXT  UNTIL
# qwen3.5:9b    ...   6.2 GB  100% GPU   32768    Forever   ← 看到 Forever 就对了
```

> **重点**：改环境变量后必须重启 Ollama 服务，而且要用**带新环境变量的父进程**去启动它，
> 否则 `Start-Process` 继承的是旧环境，改了等于没改。

**2. `gpt-oss:20b`（13GB）+ 32k 上下文 = 显存不足崩溃**

```
HTTP 500
llama-server terminated: exit status 0xc0000409
GGML_ASSERT(ctx->mem_buffer != NULL) failed
```

13GB 模型 + 32k KV cache 在 16GB 卡上放不下，直接崩。
本机实测只有 `qwen3.5:9b` / `llama3.1:8b` / `r1-14b-nothink` 之类的能稳。

**3. 残留 `llama-server` 进程占显存**

重启 Ollama 时如果只杀 `ollama.exe`，`llama-server.exe` 子进程可能还活着，占着 4.3GB：

```powershell
# 检查
nvidia-smi --query-compute-apps=pid,process_name,used_memory --format=csv
# 显存被占满时任何新模型都会 GGML_ASSERT 失败
```

清理：

```powershell
Get-CimInstance Win32_Process |
  Where-Object { $_.Name -match 'llama-server|ollama' } |
  ForEach-Object { Stop-Process -Id $_.ProcessId -Force }
```

### 结论

- 本地模型"慢"，**先看 `ollama ps` 里 `UNTIL` 是不是 `Forever`**
- 慢的如果是「首 token」而不是「生成」，就是加载/预热问题，不是算力问题
- 大模型要按显存挑：16GB 卡别碰 13GB 模型 + 32k 上下文

---

## 问题二：新架构模型导不进 Ollama

### 现象

```bash
$ ollama create mymodel -f Modelfile
success        # 导入看起来成功了

$ ollama run mymodel
Error: llama-server terminated
      error loading model: missing tensor 'blk.32.attn_norm.weight'
```

### 排查

```powershell
ollama show mymodel
#   architecture  qwen35
#   parameters    9.0B
#   context length 262144
#   quantization  Q6_K
#   Capabilities  tools / thinking / completion
```

文件本身没问题：

```python
# GGUF 头部解析结果
magic=GGUF version=3 n_tensors=427 n_kv=54
arch = qwen35
blk 范围: 0..31（共 32 层），无缺失
```

但元数据里有：

```
qwen35.block_count             = 33      ← 说 33 层
qwen35.nextn_predict_layers    = 1       ← 第 33 层是 MTP 头
qwen35.attention.recurrent_layers = [33 个布尔值]   ← 也是 33
```

**矛盾点**：元数据说 33 层，文件里只有 32 层张量（MTP 头在单独的 safetensors 里，没打进 GGUF）。

- 新版 llama.cpp：知道 `nextn_predict_layers`，会跳过缺失的 MTP 层
- 我的 Ollama 0.30.11：不认这个字段，硬找 `blk.32.*` → 报错

### 为什么没走"升级 Ollama"

升级是正解，但国内网络下载 GitHub Release（1.6GB 安装包）只有 **0.07 MB/s**，
各种 GitHub 代理也全挂。所以换了个更快的办法：

### 解决：直接改 GGUF 元数据

三处改动：

| 键 | 原值 | 改成 |
|---|---|---|
| `qwen35.block_count` | 33 | **32** |
| `qwen35.nextn_predict_layers` | 1 | **0** |
| `qwen35.attention.recurrent_layers` | 33 个元素 | **32 个**（裁掉最后一个，即 MTP 层）|

前两个是 `uint32`，**原地改字节**即可，文件大小不变。
第三个是数组，删一个元素会让元数据变短 1 字节 → 需要**重写整个文件**。

脚本：[`scripts/rewrite-gguf.py`](../scripts/rewrite-gguf.py)

```bash
python rewrite-gguf.py
#   版本=3 张量=427 元数据=54
#     qwen35.block_count: 33 -> 32
#     qwen35.nextn_predict_layers: 1 -> 0
#     qwen35.attention.recurrent_layers: 33 -> 32 个元素（丢弃 MTP 层）
#   完成: ...Q6_K_fixed.gguf  (6.854 GB)
```

然后重新导入：

```bash
# Modelfile
FROM ./model-Q6_K_fixed.gguf
PARAMETER num_ctx 16384
PARAMETER temperature 0.2
PARAMETER top_p 0.9
PARAMETER repeat_penalty 1.05

ollama create deepseek-v4-uncensored -f Modelfile
```

### 重写 GGUF 时踩的坑（很重要）

**第一次重写后文件损坏，`ollama create` 直接 panic。**

原因：GGUF 里字符串是 **`u64 长度 + 字节`**，我漏写了长度前缀 ——
包括元数据的字符串值、数组里的字符串元素、以及**张量名**。

```python
# 错误
val = read_str(f)                    # 只有字节
out.write(val)

# 正确
b = read_str(f)
val = struct.pack("<Q", len(b)) + b  # 带长度前缀
```

校验脚本：[`scripts/verify-gguf.py`](../scripts/verify-gguf.py)

它对比原始文件和新文件的：

- 头部（magic / version / n_tensors / n_kv / alignment）
- **每个张量的 (名字, 维度, 类型, 偏移) —— 必须 0 差异**
- **数据段大小**（file_size - data_start）—— 必须相等
- 最大张量偏移是否越界

输出示例：

```
张量信息差异数量: 0
数据段大小: 原始 7348291584 / 新版 7348291584  一致: OK
最大偏移: 7348275200  (< 7348291584 ? OK)
```

> 重写后 `data_start` 甚至没变（1 字节的差异被 32 字节对齐吸收了），
> 所以张量偏移完全不用动。

### 最终实测

```
ollama ps
NAME                        SIZE    PROCESSOR  CONTEXT  UNTIL
deepseek-v4-uncensored      7.1 GB  100% GPU   16384    Forever

首次加载: 3.4 s
生成速度: 52 tok/s
显存占用: 8.4 / 16 GB
```

中文理解、写代码、指令遵循都正常（它是推理模型，会输出 `<think>` 过程）。

---

## 三、下载：国内下 HuggingFace

### 现象

7GB 的 GGUF，直接下 HuggingFace 和 hf-mirror 都慢得没法用。

### 实测（同一文件，8MB 测速）

| 源 | 速度 |
|---|---|
| hf-mirror.com（**VPN 开着**） | **0.03 MB/s** → 全量 69 小时 |
| huggingface.co 直连 | 超时 |
| hf-mirror.com（**VPN 关着**） | **1.67 MB/s** |
| hf-mirror.com（VPN 关着，实际多线程下载） | **8.4 MB/s** → 全量 14.6 分钟 |

**结论：下 HuggingFace 请关掉 VPN。** 开了代理反而绕远路，慢 50 倍。

### 下载脚本的坑

自己写的下载脚本，第一次"完成"其实只下了 16MB —— 因为**连接中断时 `read()` 返回空就被当成结束**。

正确做法：下完后**比对最终大小与 Content-Length**，不一致就判失败重试。

```python
final = os.path.getsize(OUT)
if total and final < total:
    log(f"未完成 {final}/{total}，稍后重试")
    sys.exit(1)
```

脚本见 [`scripts/download-model.py`](../scripts/download-model.py)（带断点续传）。

---

## 四、坑位清单（10 条）

| # | 坑 | 解决 |
|---|---|---|
| 1 | 本地模型调用奇慢 | 查 `ollama ps` 的 `UNTIL`，设 `OLLAMA_KEEP_ALIVE=-1` |
| 2 | 改环境变量没生效 | 用带新环境的父进程重启 Ollama（`Start-Process` 会继承旧环境）|
| 3 | 13GB 模型 + 32k 直接崩 | 按显存选模型；16GB 卡别超 ~9GB 模型 + 32k |
| 4 | `GGML_ASSERT(ctx->mem_buffer != NULL)` | 多半是显存被残留 `llama-server` 占着 |
| 5 | `missing tensor blk.32.*` | GGUF 元数据含 MTP 头，改元数据或升级 llama.cpp |
| 6 | 改 GGUF 后文件损坏 | 字符串/张量名漏写 u64 长度前缀 |
| 7 | 重写后不敢确定对不对 | 用 `verify-gguf.py` 对比张量信息 + 数据段大小 |
| 8 | HF 下载慢 | 关 VPN 走 hf-mirror |
| 9 | 下载"假完成" | 比对最终大小与 Content-Length |
| 10 | 升级 Ollama 卡在 GitHub | 走代理；或像本文一样绕开 |

---

## 五、方法论

1. **先量化再优化**：`load_duration` / `prompt_eval_rate` / `eval_rate` 分开看，
   才能判断是"加载慢"、"处理提示词慢"还是"生成慢"
2. **API 测比 CLI 测可信**：CLI 的终端渲染和首次预热会污染数据
3. **改二进制文件要能自证**：写个校验脚本（结构 + 偏移 + 大小），别靠"看起来能跑"
4. **升级不了就绕**：老运行时 + 新模型 = 改模型元数据，比死磕下载快得多
5. **记录每一步的实测数字**：下次遇到同类问题，数字就是最快的判断依据
