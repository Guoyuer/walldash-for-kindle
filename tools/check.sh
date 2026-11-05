#!/bin/sh
# Fast local checks (< 1 s, no Kindle needed): compile every plugin file, flag unknown globals, run tests/run.lua.
# Usage: sh tools/check.sh      (deploy_dash.sh runs it first and stops if it fails)
cd "$(dirname "$0")/.." || exit 1
LJ=$(command -v luajit || ls "$LOCALAPPDATA/Programs/LuaJIT/bin/luajit.exe" 2>/dev/null)
[ -n "$LJ" ] || { echo "luajit not found (winget install DEVCOM.LuaJIT)"; exit 1; }

# Globals the plugin may use: Lua builtins + what KOReader provides.
OK="arg assert error getmetatable ipairs io math next os package pairs pcall print rawget rawset require select setmetatable
string table tonumber tostring type unpack xpcall G_reader_settings"
fail=0
for f in deskdash.koplugin/*.lua; do
  out=$("$LJ" -bl "$f" 2>&1) || { echo "SYNTAX ERROR: $out"; fail=1; continue; }
  for g in $(echo "$out" | grep -oE '(GGET|GSET) .*"[A-Za-z_][A-Za-z0-9_]*"' | grep -oE '"[^"]+"$' | tr -d '"' | sort -u); do
    case " $(echo $OK) " in *" $g "*) ;; *) echo "$f: unknown global '$g' (missing local?)"; fail=1 ;; esac
  done
done
"$LJ" tests/run.lua || fail=1
exit $fail
