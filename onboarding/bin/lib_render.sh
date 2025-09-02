#!/usr/bin/env bash
set -euo pipefail


# Platzhalter in Vorlagen ersetzen: <kunde>, <policy>, ...
render_file(){ # render_file INPUT KEY1=VAL1 KEY2=VAL2 ...
local f="$1"; shift
local out; out=$(cat "$f")
for kv in "$@"; do
local k="${kv%%=*}" v="${kv#*=}"
out=${out//<$k>/$v}
done
printf '%s' "$out"
}
