"""重写 GGUF 元数据，让不支持 nextn_predict_layers 的旧版 llama.cpp 能加载带 MTP 头的模型。

典型症状：
    llama_model_load: error loading model: missing tensor 'blk.32.attn_norm.weight'

原因：GGUF 元数据 block_count = 33（把 MTP/nextn 层算进去了），
      但文件里只有 32 层的张量（MTP 权重在单独的 safetensors 里，没打进 GGUF）。
      新版 llama.cpp 认识 nextn_predict_layers 会跳过缺失层；旧版不认，硬找第 33 层。

本脚本改三处元数据：
    *.block_count            33 -> 32
    *.nextn_predict_layers    1 -> 0
    *.attention.recurrent_layers  数组裁掉最后一项（33 -> 32）

注意：数组变短会让元数据整体变短，因此需要重写整个文件；
      tensor 里的 offset 是相对数据段起点的，所以数据段可以原样拷贝。

用法：
    python rewrite-gguf.py <输入.gguf> <输出.gguf>
"""

import os
import struct
import sys

T_STRING, T_ARRAY = 8, 9
FMT = {0: "<B", 1: "<b", 2: "<H", 3: "<h", 4: "<I", 5: "<i",
       6: "<f", 7: "<?", 10: "<Q", 11: "<q", 12: "<d"}
SIZE = {0: 1, 1: 1, 2: 2, 3: 2, 4: 4, 5: 4, 6: 4, 7: 1, 10: 8, 11: 8, 12: 8}


def read_str(f):
    """GGUF 字符串是 u64 长度 + 字节。返回纯字节（不含长度前缀）。"""
    n = struct.unpack("<Q", f.read(8))[0]
    return f.read(n)


def encode_str(b):
    """写回时必须补上长度前缀 —— 漏了这个文件必坏。"""
    return struct.pack("<Q", len(b)) + b


def main():
    if len(sys.argv) != 3:
        print(__doc__)
        sys.exit(1)

    src, dst = sys.argv[1], sys.argv[2]

    f = open(src, "rb")
    magic = f.read(4)
    if magic != b"GGUF":
        sys.exit("不是 GGUF 文件")
    version = struct.unpack("<I", f.read(4))[0]
    n_tensors, n_kv = struct.unpack("<QQ", f.read(16))
    print(f"版本={version} 张量={n_tensors} 元数据={n_kv}")

    kv = []           # (key_bytes, type, value_bytes)
    alignment = 32
    arch = None

    for _ in range(n_kv):
        key_b = read_str(f)
        key = key_b.decode("utf-8", "replace")
        t = struct.unpack("<I", f.read(4))[0]

        if t == T_STRING:
            val = encode_str(read_str(f))
        elif t in FMT:
            val = f.read(SIZE[t])
        elif t == T_ARRAY:
            it = struct.unpack("<I", f.read(4))[0]
            cnt = struct.unpack("<Q", f.read(8))[0]
            items = []
            for _ in range(cnt):
                if it == T_STRING:
                    items.append(encode_str(read_str(f)))
                elif it in SIZE:
                    items.append(f.read(SIZE[it]))
                else:
                    sys.exit(f"数组元素类型 {it} 不支持")
            val = struct.pack("<I", it) + struct.pack("<Q", cnt) + b"".join(items)
        else:
            sys.exit(f"类型 {t} 不支持")

        if key == "general.architecture":
            arch = val[8:].decode("utf-8", "replace")
        if key == "general.alignment":
            alignment = struct.unpack("<I", val)[0]

        # ---- 打补丁 ----
        if key.endswith(".block_count"):
            old = struct.unpack("<I", val)[0]
            if old > 32:
                val = struct.pack("<I", 32)
                print(f"  {key}: {old} -> 32")
        elif key.endswith(".nextn_predict_layers"):
            old = struct.unpack("<I", val)[0]
            if old:
                val = struct.pack("<I", 0)
                print(f"  {key}: {old} -> 0")
        elif key.endswith(".attention.recurrent_layers"):
            it, cnt = struct.unpack("<IQ", val[:12])
            body = val[12:]
            if cnt > 32:
                each = SIZE.get(it, 1)
                body = body[:32 * each]
                val = struct.pack("<I", it) + struct.pack("<Q", 32) + body
                print(f"  {key}: {cnt} -> 32 个元素（丢弃 MTP 层）")

        kv.append((key_b, t, val))

    if arch:
        print(f"  architecture = {arch}")

    # ---- 张量信息 ----
    tensor_info = []
    for _ in range(n_tensors):
        name_b = read_str(f)
        nd = struct.unpack("<I", f.read(4))[0]
        dims = f.read(8 * nd)
        ttype = f.read(4)
        off = f.read(8)
        # 张量名同样要带长度前缀
        tensor_info.append(encode_str(name_b) + struct.pack("<I", nd) + dims + ttype + off)

    # ---- 原数据段起点（按 alignment 向上对齐）----
    data_start = f.tell()
    data_start += (-data_start) % alignment
    f.seek(data_start)

    # ---- 写新文件 ----
    out = open(dst, "wb")
    out.write(magic)
    out.write(struct.pack("<I", version))
    out.write(struct.pack("<QQ", n_tensors, n_kv))

    for key_b, t, val in kv:
        out.write(encode_str(key_b))
        out.write(struct.pack("<I", t))
        out.write(val)

    for ti in tensor_info:
        out.write(ti)

    out.write(b"\x00" * ((-out.tell()) % alignment))

    copied = 0
    while True:
        chunk = f.read(8 * 1024 * 1024)
        if not chunk:
            break
        out.write(chunk)
        copied += len(chunk)

    out.close()
    f.close()

    print(f"\n完成: {dst}  ({os.path.getsize(dst)/1024/1024/1024:.3f} GB)")
    print(f"数据段拷贝: {copied} 字节")
    print("下一步：用 verify-gguf.py 校验结构，再 ollama create")


if __name__ == "__main__":
    main()
