"""校验 GGUF 结构，特别是「重写后有没有被改坏」。

对比两个文件：
  - 头部（magic / version / n_tensors / n_kv / alignment / data_start）
  - 每个张量的 (名字, 维度, 类型, 偏移)  —— 应该完全一致
  - 数据段大小 (file_size - data_start)  —— 应该完全一致
  - 最大张量偏移是否越界

用法：
    python verify-gguf.py <原始.gguf> <改写后.gguf>
"""

import os
import struct
import sys

FMT = {0: "<B", 1: "<b", 2: "<H", 3: "<h", 4: "<I", 5: "<i",
       6: "<f", 7: "<?", 10: "<Q", 11: "<q", 12: "<d"}
SIZE = {0: 1, 1: 1, 2: 2, 3: 2, 4: 4, 5: 4, 6: 4, 7: 1, 10: 8, 11: 8, 12: 8}


def read_str(f):
    n = struct.unpack("<Q", f.read(8))[0]
    return f.read(n)


def parse(path):
    f = open(path, "rb")
    magic = f.read(4)
    ver = struct.unpack("<I", f.read(4))[0]
    nt, nkv = struct.unpack("<QQ", f.read(16))

    keys = []
    align = 32
    for _ in range(nkv):
        kb = read_str(f)
        k = kb.decode("utf-8", "replace")
        t = struct.unpack("<I", f.read(4))[0]
        if t == 8:
            v = read_str(f)
            keys.append((k, t, len(v)))
        elif t in FMT:
            v = f.read(SIZE[t])
            keys.append((k, t, v))
            if k == "general.alignment":
                align = struct.unpack("<I", v)[0]
        elif t == 9:
            it = struct.unpack("<I", f.read(4))[0]
            cnt = struct.unpack("<Q", f.read(8))[0]
            total = 0
            for _ in range(cnt):
                if it == 8:
                    total += len(read_str(f)) + 8
                elif it in SIZE:
                    f.read(SIZE[it])
                    total += SIZE[it]
            keys.append((k, t, cnt, it, total))
        else:
            sys.exit(f"{path}: 未知类型 {t}")

    tensors = []
    for _ in range(nt):
        nb = read_str(f)
        nd = struct.unpack("<I", f.read(4))[0]
        dims = struct.unpack("<" + "Q" * nd, f.read(8 * nd))
        tt = struct.unpack("<I", f.read(4))[0]
        off = struct.unpack("<Q", f.read(8))[0]
        tensors.append((nb.decode("utf-8", "replace"), dims, tt, off))

    pos = f.tell()
    data_start = pos + ((-pos) % align)
    size = os.path.getsize(path)
    f.close()
    return {"ver": ver, "nt": nt, "nkv": nkv, "keys": keys, "tensors": tensors,
            "align": align, "data_start": data_start, "size": size}


def main():
    if len(sys.argv) != 3:
        print(__doc__)
        sys.exit(1)

    a, b = sys.argv[1], sys.argv[2]
    o, n = parse(a), parse(b)

    print("=== 头部 ===")
    print(f"  原始: ver={o['ver']} 张量={o['nt']} 元数据={o['nkv']} align={o['align']} "
          f"data_start={o['data_start']} size={o['size']}")
    print(f"  新版: ver={n['ver']} 张量={n['nt']} 元数据={n['nkv']} align={n['align']} "
          f"data_start={n['data_start']} size={n['size']}")

    print("\n=== 数据段大小 ===")
    od = o["size"] - o["data_start"]
    nd = n["size"] - n["data_start"]
    print(f"  原始={od}  新版={nd}  {'OK' if od == nd else 'MISMATCH'}")

    print("\n=== 张量信息差异 ===")
    diff = [i for i in range(min(len(o["tensors"]), len(n["tensors"])))
            if o["tensors"][i] != n["tensors"][i]]
    print(f"  差异数量: {len(diff)}")
    for i in diff[:5]:
        print(f"    [{i}] 原始 {o['tensors'][i]}")
        print(f"         新版 {n['tensors'][i]}")

    print("\n=== 偏移越界检查 ===")
    max_off = max(t[3] for t in n["tensors"])
    print(f"  最大偏移 {max_off} < 数据段 {nd} ? {'OK' if max_off < nd else 'OVERFLOW'}")

    print("\n=== 实际改动的元数据 ===")
    ok = {k[0]: k for k in o["keys"]}
    nk = {k[0]: k for k in n["keys"]}
    changed = 0
    for k in ok:
        if k in nk and ok[k] != nk[k]:
            print(f"  {k}: {ok[k]} -> {nk[k]}")
            changed += 1
    if not changed:
        print("  （无差异）")

    ok_all = (od == nd) and not diff and max_off < nd
    print(f"\n结论: {'结构一致，可以导入' if ok_all else '有问题，别急着导入'}")
    sys.exit(0 if ok_all else 2)


if __name__ == "__main__":
    main()
