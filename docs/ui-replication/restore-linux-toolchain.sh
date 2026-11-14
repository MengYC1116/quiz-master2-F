#!/usr/bin/env bash
# Linux 演示机工具链恢复脚本。
#
# 背景：VM 重启会丢 /usr 下后装的东西（2026-11-13 下午丢过一次：
# ninja、clang、GTK 开发包 sysroot、xdotool、ImageMagick 全没了，
# 导致 flutter build 与截图验证都跑不起来）。本脚本按当初实际
# 生效的办法重装：ninja 用 GitHub 官方二进制；其余走 Ubuntu
# noble/noble-updates 的 Packages 索引解析依赖闭包、dpkg-deb -x
# 解到 /（apt 本身是坏的，别用 apt-get install）。
#
# 注意：Mesa 必须用 noble-updates 的版本——基础镜像的
# libgl1-mesa-dri 是 25.2.8，只用 noble 索引会装上 24.0.5 的
# libegl-mesa0，EGL 与 DRI 驱动版本对不上，应用启动即
# "libEGL fatal: did not find extension DRI_Mesa version 1"。
# 本脚本索引按 noble-updates 优先，避免重蹈覆辙。
#
# 用法：sudo ./restore-linux-toolchain.sh（本机以 root 跑，直接跑也行）
set -euo pipefail

# 1. ninja（GitHub 官方静态二进制）
if ! command -v ninja >/dev/null 2>&1; then
  cd /tmp
  curl -fsSL -o ninja-linux.zip \
    https://github.com/ninja-build/ninja/releases/download/v1.12.1/ninja-linux.zip
  unzip -o ninja-linux.zip ninja -d /tmp/ninja-bin
  cp /tmp/ninja-bin/ninja /usr/bin/ninja
fi
echo "ninja: $(ninja --version)"

# 2. 其余包：内嵌解析器（依赖闭包，noble-updates 优先）
python3 - <<'PYEOF'
import gzip, re, subprocess, urllib.request, os

BASE = "http://archive.ubuntu.com/ubuntu"
TARGETS = ["clang", "libgtk-3-dev", "xdotool", "imagemagick"]
DEBDIR = "/tmp/toolchain-debs"
os.makedirs(DEBDIR, exist_ok=True)

def fetch_packages(dist, comp):
    url = f"{BASE}/dists/{dist}/{comp}/binary-amd64/Packages.gz"
    text = gzip.decompress(
        urllib.request.urlopen(url, timeout=120).read()).decode("utf-8", "replace")
    pkgs = {}
    for stanza in text.split("\n\n"):
        name = ver = fname = deps = None
        for line in stanza.splitlines():
            if line.startswith("Package: "): name = line[9:].strip()
            elif line.startswith("Version: "): ver = line[9:].strip()
            elif line.startswith("Filename: "): fname = line[10:].strip()
            elif line.startswith("Depends: "): deps = line[9:].strip()
        if name and fname and name not in pkgs:  # 先到的（updates）优先
            pkgs[name] = {"version": ver, "filename": fname,
                          "depends": deps or ""}
    return pkgs

installed = set(subprocess.run(
    ["dpkg-query", "-W", "-f=${Package}\n"],
    capture_output=True, text=True, check=True).stdout.split())

pkgs = {}
for dist, comp in (("noble-updates", "main"), ("noble-updates", "universe"),
                   ("noble", "main"), ("noble", "universe")):
    pkgs.update(fetch_packages(dist, comp))
print(f"index: {len(pkgs)} packages", flush=True)

need, seen, order = list(TARGETS), set(), []
while need:
    name = need.pop(0)
    if name in seen or name in installed:
        continue
    seen.add(name)
    entry = pkgs.get(name)
    if entry is None:
        print(f"WARN: {name} not in index", flush=True)
        continue
    order.append(entry)
    for group in entry["depends"].split(","):
        m = re.match(r"([A-Za-z0-9.+\-]+)", group.split("|")[0].strip())
        if m and m.group(1) not in seen and m.group(1) not in installed:
            need.append(m.group(1))

for entry in order:
    fn = entry["filename"].split("/")[-1]
    dest = os.path.join(DEBDIR, fn)
    if not os.path.exists(dest):
        print(f"get {fn}", flush=True)
        urllib.request.urlretrieve(f"{BASE}/{entry['filename']}", dest)
    subprocess.run(["dpkg-deb", "-x", dest, "/"], check=True)
print(f"extracted {len(order)} packages", flush=True)
PYEOF

# 3. ImageMagick 的 import/convert 是 update-alternatives 的名字，
#    dpkg-deb -x 不建，手动补符号链接。
ln -sf import-im6.q16 /usr/bin/import
ln -sf convert-im6.q16 /usr/bin/convert
ldconfig 2>/dev/null || true

echo "clang++: $(clang++ --version | head -1)"
echo "gtk: $(pkg-config --modversion gtk+-3.0)"
echo "import: $(import -version 2>/dev/null | head -1)"
echo "xdotool: $(xdotool --version)"
echo "OK"
