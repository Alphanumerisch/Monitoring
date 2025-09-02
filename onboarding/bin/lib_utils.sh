#!/usr/bin/env bash
set -euo pipefail


ok() { echo -e "\e[32m✔\e[0m $*"; }
info() { echo -e "\e[36mℹ\e[0m $*"; }
warn() { echo -e "\e[33m!\e[0m $*"; }
fail(){ echo -e "\e[31m✖\e[0m $*"; exit 1; }
need(){ command -v "$1" >/dev/null || fail "need $1"; }
