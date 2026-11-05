"""Control the Kindle over SSH (host alias "kindle" in ~/.ssh/config; override with KINDLE_SSH).

  python tools/kctl.py run "uname -a"
  python tools/kctl.py shot [out.png]
  python tools/kctl.py dash <next|prev|refresh|close|quit|restart|sleep|page N> [out.png]
  python tools/kctl.py push file ...        (repo-relative files -> same path under /mnt/us)
"""
import os, subprocess, sys

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(HERE)
HOST = os.environ.get("KINDLE_SSH", "kindle")
SSH = ["ssh", "-o", "ConnectTimeout=10", "-o", "BatchMode=yes", HOST]


def run(cmd):
    return subprocess.run(SSH + [cmd]).returncode


def capture(cmd):
    r = subprocess.run(SSH + [cmd], capture_output=True)
    return r.returncode, r.stdout


VISIBLE_H = int(os.environ.get("KINDLE_H", "1448"))
# /dev/fb0 holds several frames (6.8 MB): read only the visible one, gzipped (mostly white: 1.5 MB -> ~35 KB).
FB = ("F=/sys/class/graphics/fb0; S=$(cat $F/stride); echo $(cat $F/virtual_size $F/bits_per_pixel) $S; "
      f"head -c $((S*{VISIBLE_H})) /dev/fb0 | gzip -1")


def shot(out, before=""):
    """Screenshot in one ssh call; `before` runs first on the device (e.g. send a command and wait)."""
    import gzip
    from PIL import Image
    rc, data = capture(before + FB)
    if rc:
        sys.exit(f"screenshot failed (rc={rc})")
    meta, raw = data.split(b"\n", 1)
    size, bpp, stride = meta.decode().split()
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
    elif a[0] == "dash":
        # send a command to the KOReader dashboard plugin, wait for the redraw, screenshot
        out = a[-1] if a[-1].endswith(".png") else os.path.join(inbox, "dash.png")
        cmd = " ".join(x for x in a[1:] if not x.endswith(".png"))
        shot(out, before=f"echo '{cmd}' > /tmp/deskdash_cmd; sleep 2; ")
    elif a[0] == "push":
        push(a[1:])
    else:
        print(__doc__)


if __name__ == "__main__":
    main()
