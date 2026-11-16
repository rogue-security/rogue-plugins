#!/bin/sh
# Usage: detach.sh <script> [args...]
# Runs a plugin script in the background, detached from the hook, so slow work
# (heartbeat, auto-update) never delays Claude Code. Always exits 0.
( nohup sh "$@" >/dev/null 2>&1 & )
exit 0
