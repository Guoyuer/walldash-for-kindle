"""Control the Kindle over SSH (host alias "kindle" in ~/.ssh/config; override with KINDLE_SSH).

  python tools/kctl.py run "uname -a"
  python tools/kctl.py shot [out.png]
  python tools/kctl.py tap X Y [hold_ms]   (screen pixel coordinates, portrait; stock UI only)
  python tools/kctl.py swipe X1 Y1 X2 Y2 [steps]
  python tools/kctl.py dash <next|prev|refresh|close|quit|page N> [out.png]
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


def shot(out):
    from PIL import Image
    rc, raw = capture("cat /dev/fb0")
    if rc:
        sys.exit(f"screenshot failed (rc={rc})")
    _, meta = capture("F=/sys/class/graphics/fb0; cat $F/virtual_size $F/bits_per_pixel $F/stride")
    size, bpp, stride = meta.decode().split()
    w, h = (int(x) for x in size.split(","))
    bpp, stride = int(bpp), int(stride)
    if bpp == 8:
        img = Image.frombuffer("L", (w, h), raw, "raw", "L", stride, 1)
    elif bpp == 16:
        img = Image.frombuffer("RGB", (w, h), raw, "raw", "BGR;16", stride, 1)
    else:
        img = Image.frombuffer("RGBA", (w, h), raw, "raw", "BGRA", stride, 1).convert("RGB")
    img = img.crop((0, 0, min(int(os.environ.get("KINDLE_W", "1072")), w), min(int(os.environ.get("KINDLE_H", "1448")), h)))
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
    elif a[0] == "tap":
        sys.exit(run("sh /mnt/us/kdev/ktap " + " ".join(a[1:])))
    elif a[0] == "swipe":
        sys.exit(run("sh /mnt/us/kdev/ktap swipe " + " ".join(a[1:])))
    elif a[0] == "dash":
        # send a command to the KOReader dashboard plugin, wait for the redraw, screenshot
        out = a[-1] if a[-1].endswith(".png") else os.path.join(inbox, "dash.png")
        cmd = " ".join(x for x in a[1:] if not x.endswith(".png"))
        run(f"echo '{cmd}' > /tmp/deskdash_cmd; sleep 4")
        shot(out)
    elif a[0] == "push":
        push(a[1:])
    else:
        print(__doc__)


if __name__ == "__main__":
    main()
