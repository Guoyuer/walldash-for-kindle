"""Control the Kindle over SSH (host alias "kindle" in ~/.ssh/config; override with KINDLE_SSH).

  python tools/kctl.py run "uname -a"
  python tools/kctl.py shot [out.png]
  python tools/kctl.py dash <next|prev|refresh|close|demo|page N> [out.png]
  python tools/kctl.py command <dashboard command>   # without a screenshot
  python tools/kctl.py push file ...        (repo-relative files -> same path under /mnt/us)
"""
import os
import shlex
import subprocess
import sys
import uuid

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(HERE)
HOST = os.environ.get("KINDLE_SSH", "kindle")
SSH = ["ssh", "-o", "ConnectTimeout=10", "-o", "BatchMode=yes", HOST]


def run(cmd):
    return subprocess.run(SSH + [cmd]).returncode


def capture(cmd):
    r = subprocess.run(SSH + [cmd], capture_output=True)
    if r.returncode and r.stderr:
        sys.stderr.write(r.stderr.decode(errors="replace"))
    return r.returncode, r.stdout


VISIBLE_H = int(os.environ.get("KINDLE_H", "1448"))
# /dev/fb0 holds several frames (6.8 MB): read only the visible one, gzipped (mostly white: 1.5 MB -> ~35 KB).
FB = ("F=/sys/class/graphics/fb0; S=$(cat $F/stride); R=$(cat /tmp/deskdash_rotation 2>/dev/null || echo 0); "
      "echo $(cat $F/virtual_size $F/bits_per_pixel) $S $R; "
      f"head -c $((S*{VISIBLE_H})) /dev/fb0 | gzip -1")


def dashboard_command(cmd):
    if cmd in ("quit", "restart", "sleep"):
        # These leave the dashboard or suspend the device, so send them one-way.
        return f"printf '%s\\n' {shlex.quote(cmd)} > /tmp/deskdash_cmd", False
    token = uuid.uuid4().hex
    request = shlex.quote(f"@{token} {cmd}")
    staging = f"/tmp/deskdash_cmd.{token}"
    attempts = 1800 if cmd == "refresh" else 200
    remote = (
        f"printf '%s\\n' {request} > {staging} && mv {staging} /tmp/deskdash_cmd || exit 1; "
        f'i=0; while [ "$i" -lt {attempts} ]; do '
        'reply=$(cat /tmp/deskdash_ack 2>/dev/null); '
        f'[ "$reply" = "{token} ok" ] && break; '
        f'if [ "$reply" = "{token} error" ]; then echo "dashboard command failed" >&2; exit 1; fi; '
        'usleep 100000; i=$((i+1)); done; '
        f'if [ "$i" -ge {attempts} ]; then echo "timed out waiting for dashboard repaint" >&2; exit 1; fi; '
    )
    return remote, True


def shot(out, before=""):
    """Screenshot in one ssh call; `before` runs first on the device (e.g. send a command and wait)."""
    import gzip
    from PIL import Image
    rc, data = capture(before + FB)
    if rc:
        sys.exit(f"screenshot failed (rc={rc})")
    meta, raw = data.split(b"\n", 1)
    size, bpp, stride, rotation = meta.decode().split()
    raw = gzip.decompress(raw)
    w, h = (int(x) for x in size.split(","))
    h = min(h, VISIBLE_H)
    bpp, stride = int(bpp), int(stride)
    if bpp == 8:
        img = Image.frombuffer("L", (w, h), raw, "raw", "L", stride, 1)
    elif bpp == 16:
        img = Image.frombuffer("RGB", (w, h), raw, "raw", "BGR;16", stride, 1)
    else:
        img = Image.frombuffer("RGBA", (w, h), raw, "raw", "BGRA", stride, 1).convert("RGB")
    img = img.crop((0, 0, min(int(os.environ.get("KINDLE_W", "1072")), w), h))
    if int(rotation):
        img = img.rotate(int(rotation) * 90, expand=True)
    os.makedirs(os.path.dirname(os.path.abspath(out)), exist_ok=True)
    img.save(out)
    print(f"saved {out} ({img.size[0]}x{img.size[1]})")


def push(files):
    dirs = sorted({os.path.dirname(f).replace("\\", "/") for f in files})
    if run("mkdir -p " + " ".join(f"/mnt/us/{d}" for d in dirs if d)):
        sys.exit("push: mkdir failed")
    for f in files:
        dst = f"{HOST}:/mnt/us/{f.replace(os.sep, '/')}"
        if subprocess.run(["scp", "-q", "-o", "BatchMode=yes", os.path.join(ROOT, f), dst]).returncode:
            sys.exit(f"push failed: {f}")
        print(f"pushed {f}")


def main():
    a = sys.argv[1:]
    inbox = os.path.join(HERE, "inbox")
    if not a:
        print(__doc__)
    elif a[0] == "run":
        sys.exit(run(" ".join(a[1:])))
    elif a[0] == "shot":
        shot(a[1] if len(a) > 1 else os.path.join(inbox, "shot.png"))
    elif a[0] in ("dash", "command"):
        has_output = a[0] == "dash" and a[-1].endswith(".png")
        cmd = " ".join(a[1:-1] if has_output else a[1:])
        if not cmd:
            sys.exit("missing dashboard command")
        remote, acknowledged = dashboard_command(cmd)
        if a[0] == "command" or not acknowledged:
            sys.exit(run(remote))
        shot(a[-1] if has_output else os.path.join(inbox, "dash.png"), before=remote)
    elif a[0] == "push":
        push(a[1:])
    else:
        print(__doc__)


if __name__ == "__main__":
    main()
