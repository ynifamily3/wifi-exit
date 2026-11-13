#!/bin/zsh
# App routing is now integrated into the main app and ships with its system extension.
set -euo pipefail
cd "${0:A:h}/.."
exec ./build.sh "$@"
