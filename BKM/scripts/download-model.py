"""从 HuggingFace / hf-mirror 下载 GGUF，带断点续传和「真完成」校验。

为什么不用 curl/wget：
  - 需要断点续传（大文件经常断）
  - 需要区分「下载完成」和「连接中断」—— 一个裸的 read 循环会把中途断开当成完成

关键点：
  下载结束后比对最终大小与 Content-Length，不一致就退出码 1 让上层重试。

用法：
  python download-model.py <url> <输出路径>
  # 国内建议用 https://hf-mirror.com/... 且关掉 VPN（实测快 50 倍）
"""

import os
import sys
import time
import urllib.request

CHUNK = 1024 * 1024


def log(path, msg):
    line = f"{time.strftime('%H:%M:%S')}  {msg}"
    print(line, flush=True)
    with open(path, "a", encoding="utf-8") as f:
        f.write(line + "\n")


def main():
    if len(sys.argv) != 3:
        print(__doc__)
        sys.exit(1)

    url, out = sys.argv[1], sys.argv[2]
    logfile = out + ".log"

    have = os.path.getsize(out) if os.path.exists(out) else 0
    log(logfile, f"start (already {have/1024/1024:.1f} MB)")

    req = urllib.request.Request(url, headers={"User-Agent": "gguf-downloader"})
    if have:
        req.add_header("Range", f"bytes={have}-")

    with urllib.request.urlopen(req, timeout=60) as resp:
        status = resp.getcode()
        length = resp.headers.get("Content-Length")
        total = (int(length) + have) if length else None
        log(logfile, f"HTTP {status}  total {(total/1024/1024 if total else 0):.0f} MB")

        mode = "ab" if status == 206 else "wb"
        if status != 206:
            have = 0

        done = have
        start = time.time()
        last = 0.0
        with open(out, mode) as f:
            while True:
                chunk = resp.read(CHUNK)
                if not chunk:
                    break
                f.write(chunk)
                done += len(chunk)
                now = time.time() - start
                if now - last >= 10:
                    last = now
                    pct = (done / total * 100) if total else 0
                    spd = (done - have) / max(now, 1) / 1024 / 1024
                    log(logfile, f"{done/1024/1024:.0f}/"
                                 f"{(total/1024/1024 if total else 0):.0f} MB  "
                                 f"{pct:.1f}%  {spd:.2f} MB/s")

    final = os.path.getsize(out)
    if total and final < total:
        # 连接中途断了 —— 千万别当成完成
        log(logfile, f"INCOMPLETE {final/1024/1024:.1f}/"
                     f"{total/1024/1024:.1f} MB, retry needed")
        sys.exit(1)

    log(logfile, f"done  {final/1024/1024:.1f} MB")


if __name__ == "__main__":
    try:
        main()
    except Exception as e:
        print(f"failed: {e}", file=sys.stderr)
        sys.exit(1)
