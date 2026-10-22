#!/usr/bin/env bash
# Relaunch the Amaneɛbɔ VPS from its preserved boot volume, retrying until Oracle has
# capacity for the Ampere A1 shape, then re-attach the reserved public IP and wait for
# the API to answer. Safe to leave running for days (nohup/tmux/systemd-run).
#
#   deploy/oracle/retry-launch.sh [launch.env]
#
# Exit codes: 0 instance running and IP attached · 2 service-limit/quota error (needs the
# pay-as-you-go upgrade, retrying is pointless) · 3 DEADLINE_SECONDS reached · 1 any other non-capacity error.
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONF="${1:-$HERE/launch.env}"
[ -f "$CONF" ] || { echo "config not found: $CONF (run discover.sh first)"; exit 1; }
# shellcheck disable=SC1090
source "$CONF"

: "${COMPARTMENT_ID:?}" "${AVAILABILITY_DOMAIN:?}" "${SUBNET_ID:?}" "${BOOT_VOLUME_ID:?}"
OCPUS="${OCPUS:-2}"; MEMORY_GB="${MEMORY_GB:-12}"
DISPLAY_NAME="${DISPLAY_NAME:-amanebo-vps}"
PRIVATE_IP="${PRIVATE_IP:-}"                 # e.g. 10.0.0.115 (the old instance's address)
RESERVED_PUBLIC_IP_ID="${RESERVED_PUBLIC_IP_ID:-}"
RESERVED_PUBLIC_IP="${RESERVED_PUBLIC_IP:-}"  # dotted form, used only for the final checks
HEALTH_URL="${HEALTH_URL:-https://api.ghparliamentai.edsghana.com/api/health}"
INTERVAL="${INTERVAL:-60}"                   # seconds between capacity retries
MAX_INTERVAL="${MAX_INTERVAL:-300}"          # ceiling for the 429 backoff
OCI="${OCI:-oci}"
LOG="${LOG:-$HOME/oracle-retry.log}"
DEADLINE_SECONDS="${DEADLINE_SECONDS:-0}"   # stop looping after this many seconds (0 = never) and exit 3, for schedulers with a job time limit
START_TS=$(date +%s)

log() { printf '%s  %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$*" | tee -a "$LOG"; }
notify() { command -v notify-send >/dev/null 2>&1 && notify-send "Amaneɛbɔ VPS" "$*" || true; }

# Session-token auth (oci session authenticate) expires hourly; refresh it while we loop.
LAST_REFRESH=$(date +%s)
maybe_refresh() {
  if [ "${OCI_CLI_AUTH:-}" = "security_token" ] && [ $(( $(date +%s) - LAST_REFRESH )) -gt 2400 ]; then
    $OCI session refresh >/dev/null 2>&1 && LAST_REFRESH=$(date +%s) && log "session token refreshed"
  fi
}

# SHAPES is a space-separated list of ocpus:gb pairs tried in order on every attempt.
# Smaller requests fit free capacity more often; a 1 OCPU / 6 GB box still boots the
# same volume and can be resized later, so the fallback gets the data back sooner.
SHAPES="${SHAPES:-${OCPUS}:${MEMORY_GB}}"

build_launch_args() {  # $1 = ocpus, $2 = memory GB
  launch_args=(compute instance launch
    --compartment-id "$COMPARTMENT_ID"
    --availability-domain "$AVAILABILITY_DOMAIN"
    --shape VM.Standard.A1.Flex
    --shape-config "{\"ocpus\": $1, \"memoryInGBs\": $2}"
    --source-details "{\"sourceType\": \"bootVolume\", \"bootVolumeId\": \"$BOOT_VOLUME_ID\"}"
    --subnet-id "$SUBNET_ID"
    --assign-public-ip false
    --display-name "$DISPLAY_NAME")
  [ -n "$PRIVATE_IP" ] && launch_args+=(--private-ip "$PRIVATE_IP")
  [ -n "${SSH_PUBLIC_KEY_FILE:-}" ] && launch_args+=(--ssh-authorized-keys-file "$SSH_PUBLIC_KEY_FILE")
  return 0
}

log "starting: shape A1.Flex sizes [${SHAPES}] in $AVAILABILITY_DOMAIN from boot volume ${BOOT_VOLUME_ID##*.}"
attempt=0; sleep_for=$INTERVAL; instance_id=""
while :; do
  attempt=$((attempt + 1)); maybe_refresh
  capacity_only=1; out=""
  for pair in $SHAPES; do
    build_launch_args "${pair%%:*}" "${pair##*:}"
    out="$($OCI "${launch_args[@]}" 2>&1)"; rc=$?
    if [ $rc -eq 0 ]; then
      instance_id="$(printf '%s' "$out" | python3 -c 'import json,sys; print(json.load(sys.stdin)["data"]["id"])' 2>/dev/null)"
      [ -n "$instance_id" ] && { log "LAUNCH ACCEPTED on attempt $attempt at ${pair%%:*} OCPU / ${pair##*:} GB: $instance_id"; break 2; }
      log "launch returned 0 but no instance id; raw output follows"; printf '%s\n' "$out" >> "$LOG"; exit 1
    fi
    printf '%s' "$out" | grep -qiE 'out of (host )?capacity' && continue   # try the next size
    capacity_only=0; break
  done
  if [ $capacity_only -eq 1 ]; then
    [ $((attempt % 10)) -eq 1 ] && log "attempt $attempt: out of capacity at every size, retrying every ${INTERVAL}s"
    sleep_for=$INTERVAL
  elif printf '%s' "$out" | grep -qE '"code": "TooManyRequests"|"status": 429'; then
    sleep_for=$(( sleep_for * 2 > MAX_INTERVAL ? MAX_INTERVAL : sleep_for * 2 ))
    log "attempt $attempt: rate limited, backing off to ${sleep_for}s"
  elif printf '%s' "$out" | grep -qiE 'timed out|timeout|connection (error|refused|reset|aborted)|max retries|temporary failure|name or service not known|service unavailable|502|503|504'; then
    log "attempt $attempt: network/endpoint error, retrying in ${INTERVAL}s"
    sleep_for=$INTERVAL
  elif printf '%s' "$out" | grep -qiE 'LimitExceeded|QuotaExceeded|service limit'; then
    log "attempt $attempt: SERVICE LIMIT — retrying cannot help; lower SHAPES or upgrade to pay-as-you-go"
    printf '%s\n' "$out" >> "$LOG"; notify "Launch blocked by a service limit"; exit 2
  elif printf '%s' "$out" | grep -qiE '"code": "NotAuthenticated"|"status": 401|security token|not authorized'; then
    log "attempt $attempt: AUTH ERROR — fix ~/.oci/config or re-run 'oci session authenticate'"
    printf '%s\n' "$out" >> "$LOG"; notify "Launch stopped: authentication error"; exit 1
  else
    log "attempt $attempt: unexpected error, stopping"; printf '%s\n' "$out" >> "$LOG"; notify "Launch stopped on an unexpected error"; exit 1
  fi
  if [ "$DEADLINE_SECONDS" -gt 0 ] && [ $(( $(date +%s) - START_TS + sleep_for )) -ge "$DEADLINE_SECONDS" ]; then
    log "DEADLINE: ${DEADLINE_SECONDS}s elapsed after $attempt attempts, exiting for the scheduler to start a fresh job"; exit 3
  fi
  sleep "$sleep_for"
done

log "waiting for RUNNING…"
for _ in $(seq 1 60); do
  state="$($OCI compute instance get --instance-id "$instance_id" --query 'data."lifecycle-state"' --raw-output 2>/dev/null)"
  [ "$state" = "RUNNING" ] && break
  [ "$state" = "TERMINATED" ] || [ "$state" = "TERMINATING" ] && { log "instance went $state"; exit 1; }
  sleep 10
done
log "instance state: ${state:-unknown}"

if [ -n "$RESERVED_PUBLIC_IP_ID" ]; then
  vnic_id="$($OCI compute instance list-vnics --instance-id "$instance_id" --query 'data[0].id' --raw-output 2>/dev/null)"
  priv_id="$($OCI network private-ip list --vnic-id "$vnic_id" --query 'data[0].id' --raw-output 2>/dev/null)"
  if [ -n "$priv_id" ] && $OCI network public-ip update --public-ip-id "$RESERVED_PUBLIC_IP_ID" --private-ip-id "$priv_id" --force >/dev/null 2>&1; then
    log "reserved public IP attached to $priv_id"
  else
    log "could not attach the reserved IP automatically — attach it in the console (Networking → Reserved IPs)"
  fi
fi

host="${RESERVED_PUBLIC_IP:-}"
if [ -n "$host" ]; then
  log "waiting for SSH on $host…"
  for _ in $(seq 1 60); do nc -z -w 3 "$host" 22 2>/dev/null && { log "SSH port open"; break; }; sleep 10; done
fi
log "waiting for the API health check at $HEALTH_URL…"
for _ in $(seq 1 60); do
  if curl -fsS --max-time 8 "$HEALTH_URL" >/dev/null 2>&1; then log "API healthy: $HEALTH_URL"; notify "VPS is back online and the API is healthy"; exit 0; fi
  sleep 10
done
log "instance is running but the API did not answer in 10 min — SSH in and check: sudo systemctl status amanebo-api; cd /opt/amanebo/supabase && docker compose ps"
notify "VPS is running; API not yet healthy — check services"
exit 0
