#!/bin/sh
# Fast local checks (< 1 s, no Kindle needed): compile every plugin file, flag unknown globals, run tests/run.lua.
# Usage: sh tools/check.sh      (deploy_dash.sh runs it first and stops if it fails)
cd "$(dirname "$0")/.." || exit 1
LJ=$(command -v luajit)
if [ -z "$LJ" ] && [ -n "$LOCALAPPDATA" ] && [ -x "$LOCALAPPDATA/Programs/LuaJIT/bin/luajit.exe" ]; then
  LJ="$LOCALAPPDATA/Programs/LuaJIT/bin/luajit.exe"
fi
[ -n "$LJ" ] || { echo "LuaJIT 2.1 not found. See CONTRIBUTING.md."; exit 1; }

# Globals the plugin may use: Lua builtins + what KOReader provides.
OK="arg assert error getmetatable ipairs io math next os package pairs pcall print rawget rawset require select setmetatable
string table tonumber tostring type unpack xpcall G_reader_settings"
fail=0
for f in deskdash.koplugin/*.lua; do
  out=$("$LJ" -bl "$f" 2>&1) || { echo "SYNTAX ERROR: $out"; fail=1; continue; }
  printf '%s\n' "$out" | awk -F '"' -v allowed="$OK" -v file="$f" '
    BEGIN {
      count = split(allowed, names, /[[:space:]]+/)
      for (i = 1; i <= count; i++) known[names[i]] = 1
    }
    $2 && $1 ~ /^[[:digit:]]+[[:space:]]+G(GET|SET)[[:space:]]/ && !known[$2] && !seen[$2]++ {
      printf "%s: unknown global %s (missing local?)\n", file, $2
      failed = 1
    }
    END { exit failed }
  ' || fail=1
done
"$LJ" tests/run.lua || fail=1
exit $fail
