#!/usr/bin/env bash
# Persist config, read the VXLAN VTEP MAC, render the bigip1 Node, optionally apply it.
# env: BIGIP_HOST BIGIP_USER BIGIP_PASS TUNNEL NODE_NAME PUBLIC_IP POD_CIDR CREATE_NODE KUBECONFIG NODE_FILE
set -euo pipefail
: "${BIGIP_HOST:?}"; : "${BIGIP_USER:?}"; : "${BIGIP_PASS:?}"; : "${TUNNEL:?}"
: "${NODE_NAME:?}"; : "${PUBLIC_IP:?}"; : "${POD_CIDR:?}"; : "${NODE_FILE:?}"
: "${CREATE_NODE:=false}"

CRED="${BIGIP_USER}:${BIGIP_PASS}"
BASE="https://${BIGIP_HOST}/mgmt"
api() { curl -sk -K <(printf 'user = "%s"\n' "$CRED") -H 'Content-Type: application/json' "$@"; }

# persist tunnel + self-IP to disk
api -X POST "${BASE}/tm/util/bash" \
  -d '{"command":"run","utilCmdArgs":"-c \"tmsh save sys config\""}' >/dev/null || true

resp=$(api -X POST "${BASE}/tm/util/bash" \
  -d "{\"command\":\"run\",\"utilCmdArgs\":\"-c 'tmsh show net tunnels tunnel /Common/${TUNNEL} all-properties | grep -i mac'\"}")
cr=$(printf '%s' "$resp" | python3 -c 'import sys,json;print(json.load(sys.stdin).get("commandResult",""))')
mac=$(printf '%s' "$cr" | grep -oiE '([0-9a-f]{2}:){5}[0-9a-f]{2}' | head -n1 || true)
[ -n "$mac" ] || { echo "ERROR: could not parse VTEP MAC for ${TUNNEL}" >&2; exit 1; }
echo "VTEP MAC: ${mac}"

cat > "${NODE_FILE}" <<YAML
apiVersion: v1
kind: Node
metadata:
  name: ${NODE_NAME}
  annotations:
    flannel.alpha.coreos.com/backend-data: '{"VtepMAC":"${mac}"}'
    flannel.alpha.coreos.com/backend-type: "vxlan"
    flannel.alpha.coreos.com/kube-subnet-manager: "true"
    flannel.alpha.coreos.com/public-ip: "${PUBLIC_IP}"
spec:
  podCIDR: "${POD_CIDR}"
YAML
echo "wrote ${NODE_FILE}"

if [ "$CREATE_NODE" = "true" ]; then
  kubectl apply -f "${NODE_FILE}"
fi
