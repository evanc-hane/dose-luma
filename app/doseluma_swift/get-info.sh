#!/bin/sh
# get-info.sh — retrieve Tailscale IP + API key from a running DoseLuma backend.
#
# Works for both the Python (backend/) and Go (backend-go/) containers.
# Two data sources tried in order:
#   1. Admin HTTP endpoint on localhost:9001 (requires container running)
#   2. Volume-mounted file ./data/.doseluma/server-info.json (offline fallback)
#
# Usage:
#   ./get-info.sh                          # auto-detect
#   ./get-info.sh --backend backend-go     # explicit backend directory
#   ./get-info.sh --file                   # file only (no HTTP)

BACKEND_DIR=""
FILE_ONLY=false

for arg in "$@"; do
  case "$arg" in
    --backend) shift; BACKEND_DIR="$1" ;;
    --file)    FILE_ONLY=true ;;
  esac
done

# ── Try admin HTTP endpoint ───────────────────────────────────────────────────
if [ "$FILE_ONLY" = false ]; then
  if command -v curl >/dev/null 2>&1; then
    RESPONSE=$(curl -sf --max-time 3 http://localhost:9001/admin/info 2>/dev/null)
    if [ -n "$RESPONSE" ] && echo "$RESPONSE" | grep -q '"tailscale_ip"'; then
      TS_IP=$(echo "$RESPONSE"     | grep -o '"tailscale_ip":"[^"]*"'     | cut -d'"' -f4)
      TS_HOST=$(echo "$RESPONSE"   | grep -o '"tailscale_hostname":"[^"]*"' | cut -d'"' -f4)
      API_KEY=$(echo "$RESPONSE"   | grep -o '"api_key":"[^"]*"'          | cut -d'"' -f4)
      BACKEND=$(echo "$RESPONSE"   | grep -o '"backend":"[^"]*"'          | cut -d'"' -f4)
      STARTED=$(echo "$RESPONSE"   | grep -o '"started_at":"[^"]*"'       | cut -d'"' -f4)
      print_info "$TS_IP" "$TS_HOST" "$API_KEY" "$BACKEND" "$STARTED" "admin endpoint"
      exit 0
    fi
  fi
fi

# ── Fall back to volume-mounted file ─────────────────────────────────────────
# Search both backend directories
for dir in "$BACKEND_DIR" "backend-go" "backend" "."; do
  [ -z "$dir" ] && continue
  FILE="$dir/data/.doseluma/server-info.json"
  if [ -f "$FILE" ]; then
    TS_IP=$(grep -o '"tailscale_ip":"[^"]*"'       "$FILE" | cut -d'"' -f4)
    TS_HOST=$(grep -o '"tailscale_hostname":"[^"]*"' "$FILE" | cut -d'"' -f4)
    API_KEY=$(grep -o '"api_key":"[^"]*"'           "$FILE" | cut -d'"' -f4)
    BACKEND=$(grep -o '"backend":"[^"]*"'           "$FILE" | cut -d'"' -f4)
    STARTED=$(grep -o '"started_at":"[^"]*"'        "$FILE" | cut -d'"' -f4)
    print_info "$TS_IP" "$TS_HOST" "$API_KEY" "$BACKEND" "$STARTED" "$FILE"
    exit 0
  fi
done

echo ""
echo "  ERROR: Could not reach admin endpoint (localhost:9001) or find server-info.json."
echo ""
echo "  Make sure the container is running:"
echo "    cd backend-go  &&  docker compose up -d    # Go backend"
echo "    cd backend     &&  docker compose up -d    # Python backend"
echo ""
exit 1

# ── Helper function ───────────────────────────────────────────────────────────
print_info() {
  TS_IP="$1"; TS_HOST="$2"; API_KEY="$3"; BACKEND="$4"; STARTED="$5"; SOURCE="$6"
  echo ""
  echo "  ── DoseLuma Server Info [$BACKEND] ──────────────────────────────────"
  echo "  Source     : $SOURCE"
  echo "  Started    : $STARTED"
  echo "  TS hostname: $TS_HOST"
  echo "  TS IP      : $TS_IP"
  echo "  API key    : $API_KEY"
  echo "  ───────────────────────────────────────────────────────────────────"
  echo ""
  echo "  In the iOS app — Settings → Backend Server → Configure Server:"
  echo ""
  echo "    Server URL  :  https://$TS_IP:3001"
  echo "    API key     :  $API_KEY"
  echo ""
  echo "  Enable 'Allow self-signed certificate' if using a self-signed cert."
  echo "  ───────────────────────────────────────────────────────────────────"
  echo ""
}
