"""Analyse the dashboard's power log (/mnt/us/deskdash_power.csv, one row per hour + on plug/unplug).

  python tools/power.py            # fetch from the Kindle over ssh, print per-interval table + battery summary
  python tools/power.py file.csv   # analyse a local copy
  python tools/power.py --metrics [file.csv]   # hourly per-phase timings (/mnt/us/deskdash_metrics.csv)

Average current = drop of the fuel gauge's coulomb counter (charge_mAh) per hour, on battery intervals only.
A least-squares fit  mA = sleep_mA + k * awake_fraction  splits the drain into "asleep" and "awake" cost.
"""
import csv, io, os, subprocess, sys

HERE = os.path.dirname(os.path.abspath(__file__))
FULL_MAH = 1503   # charge_full on this PW4
# Raw coulomb-counter counts (BD71827 regs 0x79-0x7C) per mAh. Calibrated on 2026-11-05 against the gauge's
# charge_now over 40 min / 1 h of discharge and against 1 s current_now samples: ~19.4 counts/s per mA.
CC_PER_MAH = 69800


def load(kind, local=None):
    if local:
        with open(local, encoding="utf-8") as f:
            return f.read()
    host = os.environ.get("KINDLE_SSH", "kindle")
    r = subprocess.run(["ssh", "-o", "ConnectTimeout=8", "-o", "BatchMode=yes", host, f"cat /mnt/us/deskdash_{kind}.csv"],
                       capture_output=True, text=True)
    if r.returncode:
        sys.exit("can't read the log (Kindle asleep? plug it in or press the power button)\n" + r.stderr)
    inbox = os.path.join(HERE, "inbox")
    os.makedirs(inbox, exist_ok=True)
    with open(os.path.join(inbox, f"{kind}.csv"), "w", encoding="utf-8") as f:
        f.write(r.stdout)
    return r.stdout


def metrics(local=None):
    """Totals per metric over the whole file, sorted by total time: where the awake milliseconds go."""
    rows = list(csv.DictReader(io.StringIO(load("metrics", local))))
    tot = {}
    for r in rows:
        try:
            n, sm, mx = int(r["n"]), float(r["sum"]), float(r["max"])
        except (KeyError, ValueError):
            continue
        t = tot.setdefault(r["metric"], [0, 0.0, 0.0])
        t[0] += n; t[1] += sm; t[2] = max(t[2], mx)
    hours = len({r["time"] for r in rows if r.get("event") == "hour"}) or 1
    print(f"{len(rows)} rows, ~{hours} hourly flushes ({rows[0]['time'] if rows else '-'} .. {rows[-1]['time'] if rows else '-'})\n")
    print(f'{"metric":34} {"n":>7} {"mean":>9} {"max":>9} {"total s":>9} {"s/hour":>8}')
    for k, (n, sm, mx) in sorted(tot.items(), key=lambda kv: -kv[1][1]):
        print(f"{k:34} {n:7d} {sm / max(n, 1):9.1f} {mx:9.1f} {sm / 1000:9.1f} {sm / 1000 / hours:8.2f}")
    print("\nms unless noted; refresh.* and suspend.failed are counts (mean 1). wake.* phases of a minute wake:"
          " tick_and_weather, build, submit (paint), epdc_wait (e-ink), radios, suspend_resume_awake (kernel), total.")


def main():
    args = [a for a in sys.argv[1:] if not a.startswith("--")]
    if "--metrics" in sys.argv:
        return metrics(args[0] if args else None)
    rows = list(csv.DictReader(io.StringIO(load("power", args[0] if args else None))))
    ivs = []   # battery intervals
    for prev, cur in zip(rows, rows[1:]):
        try:
            # A plug row may already include some charging. Start rows reset the interval counters.
            on_battery = prev["ac"] == cur["ac"] == "0" and cur["event"] not in ("start", "unplug")
            if not on_battery or not prev["charge_mAh"] or not cur["charge_mAh"]:
                continue
            wall = float(cur["wall_s"])
            if wall < 600:
                continue   # too short for the gauge's resolution
            if prev.get("cc") and cur.get("cc"):   # raw gauge counter: far finer than charge_mAh's 1 mAh steps
                mah = (int(prev["cc"]) - int(cur["cc"])) / CC_PER_MAH
            else:
                mah = float(prev["charge_mAh"]) - float(cur["charge_mAh"])
            ivs.append(dict(end=cur["time"], h=wall / 3600, mah=mah,
                            awake=float(cur["awake_s"]) / wall, wakes=int(cur["wakes"]), early=int(cur["early"]),
                            fetches=int(cur["fetches"]), fails=int(cur["fails"]), wifi=float(cur["wifi_s"]),
                            pct=f'{prev["pct"]}->{cur["pct"]}'))
        except (KeyError, ValueError):
            continue
    print(f"{len(rows)} rows, {len(ivs)} battery intervals\n")
    if not ivs:
        print("No battery data yet: unplug the Kindle and come back after a few hours.")
        return
    print(f'{"interval end":17} {"hours":>5} {"mA":>6} {"awake%":>6} {"wakes":>5} {"early":>5} {"fetch":>5} {"fail":>4} {"wifi_s":>6}  pct')
    for i in ivs:
        print(f'{i["end"]:17} {i["h"]:5.2f} {i["mah"] / i["h"]:6.2f} {100 * i["awake"]:6.2f} {i["wakes"]:5d} '
              f'{i["early"]:5d} {i["fetches"]:5d} {i["fails"]:4d} {i["wifi"]:6.1f}  {i["pct"]}')

    H = sum(i["h"] for i in ivs)
    mah = sum(i["mah"] for i in ivs)
    ma = mah / H
    awake = sum(i["awake"] * i["h"] for i in ivs) / H
    fetches = sum(i["fetches"] for i in ivs)
    print(f"\nOn battery: {H:.1f} h, {mah:.0f} mAh used -> average {ma:.2f} mA")
    print(f"Awake {100 * awake:.2f}% of the time ({awake * 60:.2f} s per minute), "
          f"{sum(i['wakes'] for i in ivs) / H:.1f} wakes/h, {sum(i['early'] for i in ivs)} power-button wakes")
    print(f"Weather: {fetches} fetches, {sum(i['fails'] for i in ivs)} failed, "
          f"{sum(i['wifi'] for i in ivs) / max(fetches, 1):.1f} s waiting for Wi-Fi per fetch")
    if ma > 0:
        print(f"Projected runtime on a full charge ({FULL_MAH} mAh): {FULL_MAH / ma / 24:.1f} days")

    # mA = a + b * awake  (needs some spread in awake fraction, e.g. a power-button session or a plugged hour)
    if ma > 0 and len(ivs) >= 3:
        xs, ys = [i["awake"] for i in ivs], [i["mah"] / i["h"] for i in ivs]
        mx, my = sum(xs) / len(xs), sum(ys) / len(ys)
        sxx = sum((x - mx) ** 2 for x in xs)
        if sxx > 1e-6:
            b = sum((x - mx) * (y - my) for x, y in zip(xs, ys)) / sxx
            a = my - b * mx
            print(f"Fit: asleep ~{a:.2f} mA, awake ~{a + b:.0f} mA  -> being awake is {100 * b * awake / ma:.0f}% of the drain")
        else:
            print("Fit: not enough variation in awake time yet")


if __name__ == "__main__":
    main()
