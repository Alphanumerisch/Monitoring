#!/usr/bin/env bash
set -euo pipefail
source "$(dirname "$0")/../../onboarding.env"
HERE=$(cd "$(dirname "$0")" && pwd)
ROOT=$(cd "$HERE/../.." && pwd)
"$ROOT/bin/onb" smoke veeam.metrics agrarware
"$ROOT/bin/onb" smoke veeam.syslog agrarware

