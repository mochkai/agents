#!/usr/bin/env bash
# Notify the human about a farm event: append it to logs/notifications.log and, if configured, send an email.
#   usage: bin/notify.sh <event> <subject> [body-file|-]
# The body comes from the file, from stdin with `-`, or is empty when omitted.
#
# Settings (in ~/agents/.env, git-ignored, KEY=VALUE lines; see .env.example):
#   NOTIFY_EMAIL=<address>          recipient; leave unset to only log
#   NOTIFY_ON=ready,needs_human     events that notify; any other event is a no-op
#   MSMTP_ACCOUNT=gmail             msmtp account used to send (see README: "Project manager & notifications")
# Environment:
#   NOTIFY_TASK=<id>                task id recorded on the status event (optional)
#
# Exit codes: 0 notified, logged only, or skipped; 1 the email could not be sent; 2 bad input
set -euo pipefail

FARM="$(cd "$(dirname "$0")/.." && pwd)"
die() { echo "ERROR: $*" >&2; exit 2; }
status() { node "$FARM/bin/status.js" "$@" || true; }

[ $# -ge 2 ] || die "usage: $0 <event> <subject> [body-file|-]"
EVENT="$1"; SUBJECT="$2"; BODY_SRC="${3:-}"
[ -z "$BODY_SRC" ] || [ "$BODY_SRC" = - ] || [ -f "$BODY_SRC" ] || die "body file not found: $BODY_SRC"

# Read only the known keys from .env. The file is parsed, never sourced, so it cannot run code.
NOTIFY_EMAIL=""; NOTIFY_ON="ready,needs_human"; MSMTP_ACCOUNT="gmail"
if [ -f "$FARM/.env" ]; then
  while IFS='=' read -r key value; do
    value="${value%$'\r'}"; value="${value#\"}"; value="${value%\"}"
    case "$key" in
      NOTIFY_EMAIL) NOTIFY_EMAIL="$value" ;;
      NOTIFY_ON) NOTIFY_ON="$value" ;;
      MSMTP_ACCOUNT) MSMTP_ACCOUNT="$value" ;;
    esac
  done < <(grep -E '^[A-Z_]+=' "$FARM/.env" || true)
fi

# Only the configured events notify
case ",${NOTIFY_ON// /}," in *",$EVENT,"*) ;; *) exit 0 ;; esac

mkdir -p "$FARM/logs"
NLOG="$FARM/logs/notifications.log"
log() { printf '%s %s %s: %s\n' "$(date -Iseconds)" "$EVENT" "$1" "$SUBJECT" >> "$NLOG"; }

BODY=""
if [ "$BODY_SRC" = - ]; then BODY="$(cat)"; elif [ -n "$BODY_SRC" ]; then BODY="$(cat "$BODY_SRC")"; fi

if ! command -v msmtp >/dev/null 2>&1 || [ -z "$NOTIFY_EMAIL" ]; then
  log "logged (email not configured)"
  echo "WARNING: email not configured: see README (Project manager & notifications)" >&2
  status notified event_type="$EVENT" task="${NOTIFY_TASK:-}" subject="$SUBJECT" channel=log
  exit 0
fi

# Plain-text email; the sender and the credentials come from the msmtp account, never from here
if { printf 'To: %s\nSubject: [agent-farm] %s\nMIME-Version: 1.0\nContent-Type: text/plain; charset=UTF-8\n\n' "$NOTIFY_EMAIL" "$SUBJECT"
     printf '%s\n' "$BODY"
   } | msmtp -a "$MSMTP_ACCOUNT" "$NOTIFY_EMAIL" 2>>"$FARM/logs/notify.err"; then
  log "emailed"
  status notified event_type="$EVENT" task="${NOTIFY_TASK:-}" subject="$SUBJECT" channel=email
else
  log "email FAILED (see logs/notify.err)"
  echo "WARNING: could not send the email (see $FARM/logs/notify.err)" >&2
  status notify_failed event_type="$EVENT" task="${NOTIFY_TASK:-}" subject="$SUBJECT"
  exit 1
fi
