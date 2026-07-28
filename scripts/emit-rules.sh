#!/bin/sh
# Emit the Kiro proxy rules as a Claude Code hook JSON payload.
# POSIX sh + sed + awk only — no jq, no python, no bash-isms.
#
# Usage: emit-rules.sh <HookEventName>

event="${1:-SessionStart}"
root="${CLAUDE_PLUGIN_ROOT:-$(dirname "$0")/..}"
rules="$root/scripts/kiro-proxy-rules.txt"

[ -r "$rules" ] || exit 0

# JSON-escape: backslash first, then double quote, then fold newlines into \n.
body=$(
  sed -e 's/\\/\\\\/g' -e 's/"/\\"/g' -e 's/	/\\t/g' "$rules" |
    awk 'BEGIN{ORS=""} {print (NR>1 ? "\\n" : "") $0}'
)

printf '{"hookSpecificOutput":{"hookEventName":"%s","additionalContext":"%s"},"suppressOutput":true}\n' \
  "$event" "$body"
