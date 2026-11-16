#!/usr/bin/env bash
# The whole lab, start to finish, on a freshly started instance.
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
set -euo pipefail

bash "$HERE/deploy.sh"
bash "$HERE/drill.sh"
bash "$HERE/perf.sh"
bash "$HERE/maintain.sh"
bash "$HERE/migrate.sh"
bash "$HERE/test.sh"
