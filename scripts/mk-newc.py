#!/usr/bin/env python3
# 生成 Linux initramfs 用的 newc 格式 cpio（不依赖 cpio 命令，CI / 精简环境都能跑）。
# 用法：mk-newc.py <源目录> <输出文件>
import os
import stat
import sys

MAGIC = b"070701"


def entry(name: str, mode: int, size: int, data: bytes, ino: int, nlink: int = 1) -> bytes:
    hdr = MAGIC + b"".join(
        b"%08X" % v
        for v in (ino, mode, 0, 0, nlink, 0, size, 0, 0, 0, 0, len(name) + 1, 0)
    )
    out = hdr + name.encode() + b"\0"
    out += b"\0" * ((4 - len(out) % 4) % 4)
    out += data
    out += b"\0" * ((4 - len(data) % 4) % 4)
    return out


def main() -> int:
    src, dst = sys.argv[1], sys.argv[2]
    buf = []
    ino = 1
    for root, dirs, files in os.walk(src):
        rel = os.path.relpath(root, src)
        if rel != ".":
            buf.append(entry("./" + rel, stat.S_IFDIR | 0o755, 0, b"", ino))
            ino += 1
        dirs.sort()
        files.sort()
        for f in files:
            path = os.path.join(root, f)
            relp = os.path.relpath(path, src)
            st = os.lstat(path)
            if stat.S_ISLNK(st.st_mode):
                target = os.readlink(path).encode()
                buf.append(entry("./" + relp, stat.S_IFLNK | 0o777, len(target), target, ino, 1))
            elif stat.S_ISREG(st.st_mode):
                with open(path, "rb") as fh:
                    data = fh.read()
                mode = stat.S_IFREG | (0o755 if st.st_mode & 0o111 else 0o644)
                buf.append(entry("./" + relp, mode, len(data), data, ino))
            ino += 1
    buf.append(entry("TRAILER!!!", 0, 0, b"", 0, 1))
    with open(dst, "wb") as fh:
        fh.write(b"".join(buf))
    return 0


if __name__ == "__main__":
    sys.exit(main())
