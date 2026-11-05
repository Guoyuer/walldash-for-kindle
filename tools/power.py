"""Analyse the dashboard's power log (/mnt/us/deskdash_power.csv, one row per hour + on plug/unplug).

  python tools/power.py            # fetch from the Kindle over ssh, print per-interval table + battery summary
  python tools/power.py file.csv   # analyse a local copy

Average current = drop of the fuel gauge's coulomb counter (charge_mAh) per hour, on battery intervals only.
A least-squares fit  mA = sleep_mA + k * awake_fraction  splits the drain into "asleep" and "awake" cost.
"""
import csv, io, os, subprocess, sys

HERE = os.path.dirname(os.path.abspath(__file__))
FULL_MAH = 1503   # charge_full on this PW4


def load():
    if len(sys.argv) > 1:
        return open(sys.argv[1], encoding="utf-8").read()
    host = os.environ.get("KINDLE_SSH", "kindle")
    r = subprocess.run(["ssh", "-o", "ConnectTimeout=8", "-o", "BatchMode=yes", host, "cat /mnt/us/deskdash_power.csv"],
                       capture_output=True, text=True)
    if r.returncode:
        sys.exit("can't read the log (Kindle asleep? plug it in or press the power button)\n" + r.stderr)
    with open(os.path.join(HERE, "inbox", "power.csv"), "w", encoding="utf-8") as f:
        f.write(r.stdout)
    return r.stdout


def main():
    rows = list(csv.DictReader(io.StringIO(load())))
    ivs = []   # battery intervals
    for prev, cur in zip(rows, rows[1:]):
        try:
            # on battery from prev to cur ("plug" rows close a battery interval)
            on_battery = prev["ac"] == "0" and (cur["ac"] == "0" or cur["event"] == "plug")
            if not on_battery or not prev["charge_mAh"] or not cur["charge_mAh"]:
                continue
            wall = float(cur["wall_s"])
            if wall < 600:
                continue   # too short for the gauge's resolution
            ivs.append(dict(end=cur["time"], h=wall / 3600, mah=float(prev["charge_mAh"]) - float(cur["charge_mAh"]),
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
    if len(ivs) >= 3:
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
