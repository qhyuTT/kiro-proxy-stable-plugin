#!/bin/sh
# Emit the Kiro proxy rules as a Claude Code hook JSON payload.
# POSIX sh + sed + awk + tr only — no jq, no python, no bash-isms.
#
# Usage: emit-rules.sh <HookEventName>

event="${1:-SessionStart}"
root="${CLAUDE_PLUGIN_ROOT:-$(dirname "$0")/..}"
rules="$root/scripts/kiro-proxy-rules.txt"

[ -r "$rules" ] || exit 0

# Strip CR first (a CRLF checkout would otherwise emit raw \r into the JSON
# string, which strict parsers reject), then JSON-escape: backslash, double
# quote, tab. Finally fold newlines into \n.
body=$(
  tr -d '\r' < "$rules" |
    sed -e 's/\\/\\\\/g' -e 's/"/\\"/g' -e 's/	/\\t/g' |
    awk 'BEGIN{ORS=""} {print (NR>1 ? "\\n" : "") $0}'
)

printf '{"hookSpecificOutput":{"hookEventName":"%s","additionalContext":"%s"},"suppressOutput":true}\n' \
  "$event" "$body"
