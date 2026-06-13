#!/usr/bin/env bash
# Idempotent BIG-IP base prep over iControl REST.
# Inputs via environment: BIGIP_HOST BIGIP_USER BIGIP_PASS
#   PROVISION_LTM PROVISION_ASM ENABLE_GTM AS3_RPM PARTITION VXLAN_PROFILE VXLAN_PORT
set -euo pipefail

: "${BIGIP_HOST:?}"; : "${BIGIP_USER:?}"; : "${BIGIP_PASS:?}"
: "${PROVISION_LTM:=nominal}"; : "${PROVISION_ASM:=nominal}"; : "${ENABLE_GTM:=false}"
: "${PARTITION:=kubernetes}"; : "${VXLAN_PROFILE:=fl-vxlan}"; : "${VXLAN_PORT:=8472}"

CRED="${BIGIP_USER}:${BIGIP_PASS}"
BASE="https://${BIGIP_HOST}/mgmt"
# curl reads credentials from a config on stdin so the password never appears in argv/ps.
api() { curl -sk -K <(printf 'user = "%s"\n' "$CRED") -H 'Content-Type: application/json' "$@"; }
code() { curl -sk -K <(printf 'user = "%s"\n' "$CRED") -o /dev/null -w '%{http_code}' "$@"; }

py() { python3 "$@"; }

wait_ready() {
  echo "  waiting for BIG-IP REST to stabilize..."
  local ok=0
  for _ in $(seq 1 180); do          # up to ~15 min (covers a GTM/ASM reboot)
    if [ "$(code "${BASE}/tm/sys/version")" = "200" ]; then
      ok=$((ok + 1)); [ "$ok" -ge 3 ] && { echo "  ready."; return 0; }
    else
      ok=0
    fi
    sleep 5
  done
  echo "  ERROR: BIG-IP did not become ready in time" >&2; return 1
}

provision() {
  local mod="$1" level="$2" cur
  cur=$(api "${BASE}/tm/sys/provision/${mod}" | py -c 'import sys,json;print(json.load(sys.stdin).get("level","none"))')
  if [ "$cur" != "$level" ]; then
    echo "  provisioning ${mod}: ${cur} -> ${level}"
    api -X PATCH "${BASE}/tm/sys/provision/${mod}" -d "{\"level\":\"${level}\"}" >/dev/null
    CHANGED=1
  else
    echo "  ${mod} already ${level}"
  fi
}

install_as3() {
  if [ "$(code "${BASE}/shared/appsvcs/info")" = "200" ]; then
    local v; v=$(api "${BASE}/shared/appsvcs/info" | py -c 'import sys,json;print(json.load(sys.stdin).get("version",""))' 2>/dev/null || true)
    [ -n "$v" ] && { echo "  AS3 already installed: ${v}"; return 0; }
  fi
  : "${AS3_RPM:?AS3_RPM not set}"
  [ -f "$AS3_RPM" ] || { echo "  ERROR: AS3 RPM not found: ${AS3_RPM}" >&2; return 1; }

  local fn size chunk start end
  fn=$(basename "$AS3_RPM"); size=$(stat -c%s "$AS3_RPM"); chunk=1048576; start=0
  echo "  uploading ${fn} (${size} bytes)"
  while [ "$start" -lt "$size" ]; do
    end=$((start + chunk)); [ "$end" -gt "$size" ] && end="$size"
    curl -sk -K <(printf 'user = "%s"\n' "$CRED") \
      -H 'Content-Type: application/octet-stream' \
      -H "Content-Range: ${start}-$((end - 1))/${size}" \
      --data-binary @<(tail -c "+$((start + 1))" "$AS3_RPM" | head -c "$((end - start))") \
      "${BASE}/shared/file-transfer/uploads/${fn}" >/dev/null
    start="$end"
  done

  echo "  installing AS3..."
  local tid
  tid=$(api -X POST "${BASE}/shared/iapp/package-management-tasks" \
        -d "{\"operation\":\"INSTALL\",\"packageFilePath\":\"/var/config/rest/downloads/${fn}\"}" \
        | py -c 'import sys,json;print(json.load(sys.stdin)["id"])')
  for _ in $(seq 1 60); do
    local st; st=$(api "${BASE}/shared/iapp/package-management-tasks/${tid}" | py -c 'import sys,json;print(json.load(sys.stdin).get("status",""))')
    case "$st" in
      FINISHED) echo "  AS3 installed"; return 0 ;;
      FAILED)   echo "  ERROR: AS3 install failed" >&2; return 1 ;;
    esac
    sleep 3
  done
  echo "  ERROR: AS3 install timed out" >&2; return 1
}

ensure_partition() {
  if [ "$(code "${BASE}/tm/auth/partition/${PARTITION}")" = "200" ]; then
    echo "  partition ${PARTITION} exists"
  else
    echo "  creating partition ${PARTITION}"
    api -X POST "${BASE}/tm/auth/partition" -d "{\"name\":\"${PARTITION}\"}" >/dev/null
  fi
}

ensure_vxlan_profile() {
  if [ "$(code "${BASE}/tm/net/tunnels/vxlan/~Common~${VXLAN_PROFILE}")" = "200" ]; then
    echo "  vxlan profile ${VXLAN_PROFILE} exists"
  else
    echo "  creating vxlan profile ${VXLAN_PROFILE} (flooding-type none)"
    api -X POST "${BASE}/tm/net/tunnels/vxlan" \
      -d "{\"name\":\"${VXLAN_PROFILE}\",\"port\":${VXLAN_PORT},\"floodingType\":\"none\"}" >/dev/null
  fi
}

save_config() {
  api -X POST "${BASE}/tm/util/bash" \
    -d '{"command":"run","utilCmdArgs":"-c \"tmsh save sys config\""}' >/dev/null || true
}

CHANGED=0
echo "[1/4] provisioning"
provision ltm "$PROVISION_LTM"
provision asm "$PROVISION_ASM"
[ "$ENABLE_GTM" = "true" ] && provision gtm nominal
[ "$CHANGED" = "1" ] && wait_ready

echo "[2/4] AS3 extension"
install_as3

echo "[3/4] partition"
ensure_partition

echo "[4/4] vxlan profile"
ensure_vxlan_profile

save_config
echo "BIG-IP base prep complete."
