"""Control a Kindle running devagent through devserver.py.

  python tools/kctl.py status
  python tools/kctl.py run "uname -a"
  python tools/kctl.py shot [out.png]
  python tools/kctl.py tap X Y [hold_ms]   (screen pixel coordinates, portrait)
  python tools/kctl.py swipe X1 Y1 X2 Y2 [steps]
  python tools/kctl.py push devagent/agent.sh deskclock/clock.sh ... [--restart]
"""
import os, sys, urllib.request, urllib.error

HERE = os.path.dirname(os.path.abspath(__file__))
BASE = f"http://127.0.0.1:{os.environ.get('KINDLE_DEV_PORT', '8765')}"


def http(method, path, body=None, timeout=90):
    req = urllib.request.Request(BASE + path, data=body, method=method)
    with urllib.request.urlopen(req, timeout=timeout) as r:
        return r.read()


def run(cmd, timeout=60):
    cid = http("POST", "/enqueue", cmd.encode()).decode()
    try:
        return http("GET", f"/wait?id={cid}&timeout={timeout}", timeout=timeout + 10).decode("utf-8", "replace")
    except urllib.error.HTTPError as e:
        return f"[kctl] {e.code}: {e.read().decode()}"


SHOT_CMD = r"""
F=/sys/class/graphics/fb0
echo "vsize=$(cat $F/virtual_size) bpp=$(cat $F/bits_per_pixel) stride=$(cat $F/stride 2>/dev/null) rotate=$(cat $F/rotate 2>/dev/null)"
cat /dev/fb0 > /tmp/fb.raw && sh /mnt/us/devagent/bin/kup fb.raw < /tmp/fb.raw && echo uploaded
rm -f /tmp/fb.raw
"""


def shot(out):
    from PIL import Image
    info = run(SHOT_CMD)
    meta = dict(kv.split("=", 1) for kv in info.split("\n")[0].split() if "=" in kv)
    w, h = (int(x) for x in meta["vsize"].split(","))
    bpp = int(meta["bpp"])
    raw = open(os.path.join(HERE, "inbox", "fb.raw"), "rb").read()
    stride = int(meta["stride"]) if meta.get("stride") else len(raw) // h
    vis_w = int(os.environ.get("KINDLE_W", "1072"))
    vis_h = int(os.environ.get("KINDLE_H", "1448"))
    if bpp == 8:
        img = Image.frombuffer("L", (w, h), raw, "raw", "L", stride, 1)
    elif bpp == 16:
        img = Image.frombuffer("RGB", (w, h), raw, "raw", "BGR;16", stride, 1)
    else:
        img = Image.frombuffer("RGBA", (w, h), raw, "raw", "BGRA", stride, 1).convert("RGB")
    img = img.crop((0, 0, min(vis_w, w), min(vis_h, h)))
    img.save(out)
    print(info.strip())
    print(f"saved {out} ({img.size[0]}x{img.size[1]})")


def main():
    a = sys.argv[1:]
    if not a or a[0] == "status":
        print(http("GET", "/status").decode())
    elif a[0] == "run":
        print(run(" ".join(a[1:]), timeout=int(os.environ.get("KCTL_TIMEOUT", "60"))), end="")
    elif a[0] == "shot":
        shot(a[1] if len(a) > 1 else os.path.join(HERE, "inbox", "shot.png"))
    elif a[0] == "tap":
        print(run("sh /mnt/us/devagent/bin/ktap " + " ".join(a[1:])), end="")
    elif a[0] == "swipe":
        print(run("sh /mnt/us/devagent/bin/ktap swipe " + " ".join(a[1:])), end="")
    elif a[0] == "dash":
        # send a command to the KOReader dashboard plugin, wait for the redraw, screenshot
        cmd = " ".join(a[1:-1]) if len(a) > 2 and a[-1].endswith(".png") else " ".join(a[1:])
        out = a[-1] if a[-1].endswith(".png") else os.path.join(HERE, "inbox", "dash.png")
        run(f"echo '{cmd}' > /tmp/deskdash_cmd; sleep 4")
        shot(out)
    elif a[0] == "push":
        # push repo-relative files to the same path under /mnt/us; "--restart" re-execs the agent
        files = [f for f in a[1:] if f != "--restart"]
        cmd = "\n".join(f"mkdir -p /mnt/us/{os.path.dirname(f)} && sh /mnt/us/devagent/bin/kget {f} /mnt/us/{f}" for f in files)
        if "--restart" in a:
            cmd += "\ntouch /tmp/devagent_restart"
        print(run(cmd), end="")
    else:
        print(__doc__)


if __name__ == "__main__":
    main()
