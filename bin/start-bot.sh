#!/bin/zsh
set -euo pipefail
project_dir="${0:A:h:h}"
# The credential is stored in macOS Keychain under the service name;
# its Keychain account does not necessarily match the macOS login name.
token="$(/usr/bin/security find-generic-password -s dglab-telegram-bot -w)"
export TG_BOT_TOKEN="$token"
exec /opt/homebrew/bin/node "$project_dir/dist/src/index.js"
