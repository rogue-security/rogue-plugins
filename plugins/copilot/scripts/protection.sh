#!/bin/sh
# Shared installation credential and pause gate. No activity payload is read here.
rogue_protection_now() { date +%s; }
rogue_protection_lock() {
  ln -s "$$" "$1" 2>/dev/null && return 0
  _rp_owner=$(readlink "$1" 2>/dev/null) || return 1
  case "$_rp_owner" in *[!0-9]*|'') return 1 ;; esac
  kill -0 "$_rp_owner" 2>/dev/null || rm -f "$1"
  return 1
}
rogue_protection_escape() { printf '%s' "$1" | sed 's/\\/\\\\/g;s/"/\\"/g'; }
rogue_protection_load() {
  [ -r "$ROGUE_PROTECTION_STATE/decision" ] || return 1
  IFS=' ' read -r RP_PROTOCOL RP_REV RP_AIDR RP_AIDR_EXP RP_AISPM RP_AISPM_EXP RP_SERVER RP_AIDR_REV RP_AISPM_REV RP_RECEIVED < "$ROGUE_PROTECTION_STATE/decision"
  [ "$RP_PROTOCOL" = 1 ] || return 1
  RP_NOW=$(( $(rogue_protection_now) - RP_RECEIVED + RP_SERVER ))
  [ "$RP_AIDR_EXP" -eq 0 ] || [ "$RP_AIDR_EXP" -gt "$RP_NOW" ] || RP_AIDR=0
  [ "$RP_AISPM_EXP" -eq 0 ] || [ "$RP_AISPM_EXP" -gt "$RP_NOW" ] || RP_AISPM=0
}
rogue_protection_refresh() {
  [ -n "${ROGUE_PROTECTION_STATE:-}" ] || return 0
  rogue_protection_lock "$ROGUE_PROTECTION_STATE/refresh.lock" || return 0
  # A failed request is throttled too; an unavailable server must not cause a retry storm.
  rogue_protection_now > "$ROGUE_PROTECTION_STATE/attempt"
  _rp_decision=$(curl -fsS --max-time 5 -H "x-rogue-api-key: $ROGUE_API_KEY" -H 'accept: text/tab-separated-values' "$ROGUE_PROTECTION_BASE/api/v1/hooks/protection/state" 2>/dev/null) || _rp_decision=''
  case "$_rp_decision" in *[!0-9\ \	]*|'') ;; *)
    set -- $_rp_decision
    if [ "$#" -eq 9 ] && [ "$1" = 1 ]; then
      _rp_old=0
      rogue_protection_load && _rp_old=$RP_REV
      if [ "$2" -ge "$_rp_old" ]; then
        if printf '%s %s\n' "$*" "$(rogue_protection_now)" > "$ROGUE_PROTECTION_STATE/decision.tmp" && [ ! -d "$ROGUE_PROTECTION_STATE/decision" ] && mv -f "$ROGUE_PROTECTION_STATE/decision.tmp" "$ROGUE_PROTECTION_STATE/decision"; then
          RP_PERSISTENCE_FAILED=0
          rm -f "$ROGUE_PROTECTION_STATE/persistence-failed"
        else
          RP_PERSISTENCE_FAILED=1
          touch "$ROGUE_PROTECTION_STATE/persistence-failed" 2>/dev/null || true
          _rp_a=false; [ "$3" = 1 ] && _rp_a=true
          _rp_s=false; [ "$5" = 1 ] && _rp_s=true
          curl -fsS --max-time 5 -H "x-rogue-api-key: $ROGUE_API_KEY" -H 'content-type: application/json' --data "{\"protocolVersion\":1,\"revision\":$2,\"status\":\"failed\",\"aidrPaused\":$_rp_a,\"aispmPaused\":$_rp_s,\"error\":\"state_persistence_failed\"}" "$ROGUE_PROTECTION_BASE/api/v1/hooks/protection/ack" >/dev/null 2>&1 || true
        fi
      fi
    fi ;;
  esac
  rm -f "$ROGUE_PROTECTION_STATE/refresh.lock" 2>/dev/null || true
  rogue_protection_ack
}
rogue_protection_busy() {
  for _rp_lease in "$ROGUE_PROTECTION_STATE"/active.*; do
    [ -f "$_rp_lease" ] || continue
    kill -0 "${_rp_lease##*.}" 2>/dev/null && return 0
  done
  return 1
}
rogue_protection_ack() {
  [ "${RP_PERSISTENCE_FAILED:-0}" = 0 ] && [ ! -e "$ROGUE_PROTECTION_STATE/persistence-failed" ] || return 0
  rogue_protection_load || return 0
  _rp_busy=0
  for _rp_lease in "$ROGUE_PROTECTION_STATE"/active.*; do
    [ -f "$_rp_lease" ] || continue
    _rp_pid=${_rp_lease##*.}
    if kill -0 "$_rp_pid" 2>/dev/null; then _rp_busy=1; else rm -f "$_rp_lease"; fi
  done
  [ "$_rp_busy" -eq 0 ] || return 0
  _rp_a=false; [ "$RP_AIDR" = 1 ] && _rp_a=true
  _rp_s=false; [ "$RP_AISPM" = 1 ] && _rp_s=true
  _rp_ack="$RP_REV:$RP_AIDR:$RP_AISPM"
  [ "$(cat "$ROGUE_PROTECTION_STATE/ack" 2>/dev/null)" != "$_rp_ack" ] || return 0
  if curl -fsS --max-time 5 -H "x-rogue-api-key: $ROGUE_API_KEY" -H 'content-type: application/json' --data "{\"protocolVersion\":1,\"revision\":$RP_REV,\"status\":\"applied\",\"aidrPaused\":$_rp_a,\"aispmPaused\":$_rp_s}" "$ROGUE_PROTECTION_BASE/api/v1/hooks/protection/ack" >/dev/null 2>&1; then
    printf '%s' "$_rp_ack" > "$ROGUE_PROTECTION_STATE/ack"
  fi
}
rogue_protection_current() {
  [ "${RP_PERSISTENCE_FAILED:-0}" = 0 ] && [ ! -e "${ROGUE_PROTECTION_STATE:-}/persistence-failed" ] || return 1
  [ -n "${ROGUE_PROTECTION_STATE:-}" ] || return 0
  rogue_protection_load || return 1
  [ "$RP_AIDR" = 0 ] && [ "${ROGUE_PROTECTION_REVISION:-$RP_AIDR_REV}" = "$RP_AIDR_REV" ]
}
rogue_protection_leave() {
  [ -n "${ROGUE_PROTECTION_STATE:-}" ] || return 0
  rm -f "$ROGUE_PROTECTION_STATE/active.$$"
  rogue_protection_ack
}
rogue_protection_init() {
  # Arguments: log slug, agent family, script directory, optional surface.
  [ -n "${ROGUE_API_KEY:-}" ] || return 0
  ROGUE_PROTECTION_BASE=${ROGUE_BASE_URL:-https://api.rogue.security}
  ROGUE_PROTECTION_BASE=${ROGUE_PROTECTION_BASE%/}
  _rp_hash=$(printf '%s\n%s' "$ROGUE_PROTECTION_BASE" "$ROGUE_API_KEY" | shasum -a 256 2>/dev/null | cut -d' ' -f1)
  [ -n "$_rp_hash" ] || _rp_hash=$(printf '%s\n%s' "$ROGUE_PROTECTION_BASE" "$ROGUE_API_KEY" | sha256sum 2>/dev/null | cut -d' ' -f1)
  [ -n "$_rp_hash" ] || return 0
  case "${ROGUE_PROTECTION_STATE:-}" in
    */"$1-default-"*)
      [ "$(cat "$ROGUE_PROTECTION_STATE/credential" 2>/dev/null)" = "$ROGUE_API_KEY" ] || ROGUE_PROTECTION_STATE='' ;;
    *) ROGUE_PROTECTION_STATE='' ;;
  esac
  ROGUE_PROTECTION_STATE="${ROGUE_PROTECTION_STATE:-${ROGUE_PROTECTION_DIR:-$HOME/.rogue/protection}/$1-default-$_rp_hash}"
  (umask 077; mkdir -p "$ROGUE_PROTECTION_STATE") || return 0
  _rp_link=$(cat "$ROGUE_PROTECTION_STATE/installation-directory" 2>/dev/null)
  case "$_rp_link" in "${ROGUE_PROTECTION_STATE%/*}/$1-default-"*)
    if [ "$(cat "$_rp_link/base" 2>/dev/null)" = "$ROGUE_PROTECTION_BASE" ] && [ -s "$_rp_link/credential" ]; then ROGUE_PROTECTION_STATE=$_rp_link; fi ;;
  esac
  rogue_protection_now > "$ROGUE_PROTECTION_STATE/used"
  printf '%s' "$ROGUE_PROTECTION_BASE" > "$ROGUE_PROTECTION_STATE/base"
  if [ ! -s "$ROGUE_PROTECTION_STATE/credential" ]; then
    for _rp_previous in "${ROGUE_PROTECTION_STATE%/*}/$1-default-"*; do
      [ "$_rp_previous" != "$ROGUE_PROTECTION_STATE" ] || continue
      [ "$(cat "$_rp_previous/base" 2>/dev/null)" = "$ROGUE_PROTECTION_BASE" ] || continue
      _rp_previous_key=$(cat "$_rp_previous/credential" 2>/dev/null) || continue
      [ -n "$_rp_previous_key" ] || continue
      _rp_restored=$(curl -sS -w '\n%{http_code}' --max-time 5 -H "x-rogue-api-key: $ROGUE_API_KEY" -H "x-rogue-installation-key: $_rp_previous_key" -H 'content-type: application/json' --data "{\"type\":\"coding_agent\",\"name\":\"$1\",\"family\":\"$2\",\"host\":\"$(rogue_protection_escape "$(hostname)")\",\"version\":\"unknown\"}" "$ROGUE_PROTECTION_BASE/api/v1/hooks/protection/enroll" 2>/dev/null) || return 0
      _rp_restore_status=$(printf '%s' "$_rp_restored" | tail -n 1)
      case "$_rp_restore_status" in 401|403) continue ;; 2??) ;; *) return 0 ;; esac
      _rp_restored_key=$(printf '%s' "$_rp_restored" | sed -n 's/.*"apiKey":"\([A-Za-z0-9_-][A-Za-z0-9_-]*\)".*/\1/p')
      [ "$_rp_restored_key" = "$_rp_previous_key" ] || continue
      (umask 077; printf '%s' "$_rp_previous" > "$ROGUE_PROTECTION_STATE/installation-directory")
      ROGUE_PROTECTION_STATE=$_rp_previous
      rogue_protection_now > "$ROGUE_PROTECTION_STATE/used"
      break
    done
  fi
  if [ ! -s "$ROGUE_PROTECTION_STATE/credential" ]; then
    _rp_enroll_attempt=$(cat "$ROGUE_PROTECTION_STATE/enroll-attempt" 2>/dev/null) || _rp_enroll_attempt=0
    if [ $(( $(rogue_protection_now) - ${_rp_enroll_attempt:-0} )) -lt 60 ]; then [ ! -f "$ROGUE_PROTECTION_STATE/legacy-server" ] || ROGUE_PROTECTION_STATE=''; return 0; fi
    rogue_protection_lock "$ROGUE_PROTECTION_STATE/enroll.lock" || return 0
    rogue_protection_now > "$ROGUE_PROTECTION_STATE/enroll-attempt"
    if [ ! -s "$ROGUE_PROTECTION_STATE/enrollment-nonce" ]; then
      (umask 077; od -An -N32 -tx1 /dev/urandom | tr -d ' \n' > "$ROGUE_PROTECTION_STATE/enrollment-nonce.tmp" && mv "$ROGUE_PROTECTION_STATE/enrollment-nonce.tmp" "$ROGUE_PROTECTION_STATE/enrollment-nonce") || { rm -f "$ROGUE_PROTECTION_STATE/enroll.lock"; return 0; }
    fi
    _rp_nonce=$(cat "$ROGUE_PROTECTION_STATE/enrollment-nonce")
    [ "${#_rp_nonce}" -eq 64 ] || { rm -f "$ROGUE_PROTECTION_STATE/enroll.lock"; return 0; }
    _rp_response=$(curl -sS -w '\n%{http_code}' --max-time 5 -H "x-rogue-api-key: $ROGUE_API_KEY" -H 'content-type: application/json' --data "{\"enrollmentNonce\":\"$_rp_nonce\",\"type\":\"coding_agent\",\"name\":\"$1\",\"family\":\"$2\",\"host\":\"$(rogue_protection_escape "$(hostname)")\",\"version\":\"$(rogue_protection_escape "${ROGUE_INSTALL_VERSION:-unknown}")\"}" "$ROGUE_PROTECTION_BASE/api/v1/hooks/protection/enroll" 2>/dev/null) || _rp_response=''
    if [ "$(printf '%s' "$_rp_response" | tail -n 1)" = 404 ]; then touch "$ROGUE_PROTECTION_STATE/legacy-server"; else rm -f "$ROGUE_PROTECTION_STATE/legacy-server"; fi
    _rp_key=$(printf '%s' "$_rp_response" | sed -n 's/.*"apiKey":"\([A-Za-z0-9_-][A-Za-z0-9_-]*\)".*/\1/p')
    case "$_rp_response" in *'"alreadyEnrolled":true'*) _rp_key=$ROGUE_API_KEY ;; esac
    if [ -n "$_rp_key" ]; then (umask 077; printf '%s' "$_rp_key" > "$ROGUE_PROTECTION_STATE/credential.tmp"; mv "$ROGUE_PROTECTION_STATE/credential.tmp" "$ROGUE_PROTECTION_STATE/credential"); fi
    rm -f "$ROGUE_PROTECTION_STATE/enroll.lock" 2>/dev/null || true
  fi
  if [ ! -s "$ROGUE_PROTECTION_STATE/credential" ]; then [ ! -f "$ROGUE_PROTECTION_STATE/legacy-server" ] || ROGUE_PROTECTION_STATE=''; return 0; fi
  ROGUE_API_KEY=$(cat "$ROGUE_PROTECTION_STATE/credential")
  ROGUE_LOG_FILE="$ROGUE_PROTECTION_STATE/$1.log"
  export ROGUE_API_KEY ROGUE_PROTECTION_STATE ROGUE_PROTECTION_BASE ROGUE_LOG_FILE
  _rp_attempt=$(cat "$ROGUE_PROTECTION_STATE/attempt" 2>/dev/null) || _rp_attempt=0
  [ $(( $(rogue_protection_now) - ${_rp_attempt:-0} )) -lt 15 ] || rogue_protection_refresh
  if mkdir "$ROGUE_PROTECTION_STATE/poll.lock" 2>/dev/null; then
    nohup sh "$3/protection.sh" --poll "$ROGUE_PROTECTION_STATE" "$ROGUE_PROTECTION_BASE" </dev/null >/dev/null 2>&1 &
    printf '%s' "$!" > "$ROGUE_PROTECTION_STATE/poll.lock/pid"
  else
    _rp_poll_pid=$(cat "$ROGUE_PROTECTION_STATE/poll.lock/pid" 2>/dev/null)
    if [ -n "$_rp_poll_pid" ] && ! kill -0 "$_rp_poll_pid" 2>/dev/null; then rm -f "$ROGUE_PROTECTION_STATE/poll.lock/pid"; rmdir "$ROGUE_PROTECTION_STATE/poll.lock" 2>/dev/null; fi
  fi
  rogue_protection_load && ROGUE_PROTECTION_REVISION=$RP_AIDR_REV
  export ROGUE_PROTECTION_REVISION
}
rogue_protection_fail() {
  RP_PERSISTENCE_FAILED=1
  rogue_protection_load || return 0
  _rp_a=false; [ "$RP_AIDR" = 1 ] && _rp_a=true
  _rp_s=false; [ "$RP_AISPM" = 1 ] && _rp_s=true
  curl -fsS --max-time 5 -H "x-rogue-api-key: $ROGUE_API_KEY" -H 'content-type: application/json' --data "{\"protocolVersion\":1,\"revision\":$RP_REV,\"status\":\"failed\",\"aidrPaused\":$_rp_a,\"aispmPaused\":$_rp_s,\"error\":\"state_persistence_failed\"}" "$ROGUE_PROTECTION_BASE/api/v1/hooks/protection/ack" >/dev/null 2>&1 || true
}
rogue_protection_read_input() (
  rogue_protection_current || exit 1
  [ -n "${ROGUE_PROTECTION_STATE:-}" ] || { cat; exit; }
  umask 077
  _rp_input=$(mktemp "$ROGUE_PROTECTION_STATE/input.XXXXXX") || exit 1
  exec 3<&0
  cat <&3 > "$_rp_input" &
  _rp_reader=$!
  (
    while kill -0 "$_rp_reader" 2>/dev/null; do
      if ! rogue_protection_current || ! kill -0 "$$" 2>/dev/null; then kill "$_rp_reader" 2>/dev/null; exit; fi
      sleep 0.2
    done
  ) >&2 &
  _rp_watch=$!
  trap 'kill "$_rp_reader" "$_rp_watch" 2>/dev/null; rm -f "$_rp_input"' EXIT
  wait "$_rp_reader" || exit 1
  kill "$_rp_watch" 2>/dev/null
  rogue_protection_current || exit 1
  cat "$_rp_input"
)
rogue_protection_enter() {
  rogue_protection_current || return 1
  if [ -n "${ROGUE_PROTECTION_STATE:-}" ] && ! printf '%s' "${ROGUE_PROTECTION_REVISION:-0}" > "$ROGUE_PROTECTION_STATE/active.$$"; then rogue_protection_fail; return 1; fi
  rogue_protection_current
}
if [ "${0##*/}" = protection.sh ] && [ "${1:-}" = --poll ]; then
  ROGUE_PROTECTION_STATE=$2; ROGUE_PROTECTION_BASE=$3
  ROGUE_API_KEY=$(cat "$ROGUE_PROTECTION_STATE/credential")
  while [ $(( $(rogue_protection_now) - $(cat "$ROGUE_PROTECTION_STATE/used" 2>/dev/null || echo 0) )) -lt 90 ] || rogue_protection_busy; do
    rogue_protection_refresh
    sleep 15
  done
  rm -f "$ROGUE_PROTECTION_STATE/poll.lock/pid"
  rmdir "$ROGUE_PROTECTION_STATE/poll.lock" 2>/dev/null || true
fi
