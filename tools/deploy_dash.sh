#!/bin/sh
# Deploy the deskdash plugin to the Kindle: local checks -> upload -> restart KOReader -> verify -> screenshot.
# If the new version doesn't come up cleanly, the previous one is put back automatically (tools/kindle_deploy.sh).
# Usage: sh tools/deploy_dash.sh [--shots]     (--shots: screenshot all 4 pages + the demo notices)
cd "$(dirname "$0")/.." || exit 1
H=${KINDLE_SSH:-kindle}
V=$(git describe --always --dirty 2>/dev/null || echo unknown)

sh tools/check.sh >/dev/null || { sh tools/check.sh; echo "local checks failed - not deploying"; exit 1; }

# One ssh session: upload plugin + device-side script, then run it (each extra ssh login costs ~1 s).
tar cf - deskdash.koplugin tools/kindle_deploy.sh | ssh -o ConnectTimeout=6 "$H" \
  "rm -rf /tmp/dd && mkdir -p /tmp/dd && tar xf - -C /tmp/dd && sh /tmp/dd/tools/kindle_deploy.sh '$V'"
rc=$?
[ $rc = 255 ] && echo "Kindle not reachable - on battery it sleeps between minutes: plug it in or press the power button"
[ $rc = 0 ] || exit 1

if [ "$1" = "--shots" ]; then
  for p in 2 3 4 1; do python tools/kctl.py dash "page $p" "tools/inbox/p$p.png"; done
  python tools/kctl.py dash demo tools/inbox/demo.png      # page 1 with fake alert / rain / low-battery notices
  python tools/kctl.py run "echo 'demo off' > /tmp/deskdash_cmd"
else
  python tools/kctl.py shot tools/inbox/dash.png
fi
