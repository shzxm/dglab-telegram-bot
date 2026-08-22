#!/bin/zsh
set -euo pipefail
project_dir="${0:A:h:h}"
token="$(/usr/bin/security find-generic-password -a "$USER" -s dglab-telegram-bot -w)"
export TG_BOT_TOKEN="$token"
exec "$(command -v node)" "$project_dir/node_modules/.bin/tsx" "$project_dir/src/index.ts"
