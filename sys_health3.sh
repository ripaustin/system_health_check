#!/bin/bash

# === Settings ===
TIMESTAMP=$(date +'%F_%H-%M-%S')
LOGFILE="/var/log/sys_health_${TIMESTAMP}.log"
WEBHOOK_URL="https://discord.com/api/webhooks/1371200349414752438/4VWOoSGI1XGOUoDKtGxHBTqepdpn0rGXsi5m0RsBmCYvcSbxIGAdf-3Th3NPM2v2pWze"  # <-- keep private or move to env var
MAX_DISCORD_CHARS=1900
MAX_RETRIES=3
RETRY_DELAY=60  # seconds

# === Ensure script is run as root ===
if [[ $EUID -ne 0 ]]; then
   echo "Please run this script as root." >&2
   exit 1
fi

# === Redirect output to log file ===
exec > >(tee -a "$LOGFILE") 2>&1
echo "===== SYSTEM HEALTH CHECK ====="
echo "Report generated at: $(date)"
echo "Hostname: $(hostname)"
echo "Uptime: $(uptime -p)"
echo

echo "== CPU Load =="
uptime
echo

echo "== Memory Usage =="
free -h
echo

echo "== Disk Usage =="
df -h --total
echo

echo "== Disk Usage Warnings (over 80%) =="
df -h --output=target,pcent | awk '$2+0 > 80 {print $0}'
echo

echo "== Top Memory-Consuming Processes =="
ps -eo pid,ppid,cmd,%mem,%cpu --sort=-%mem | head -10
echo

echo "== Network Interfaces =="
ip a
echo

echo "== Listening Ports =="
ss -tuln
echo

echo "== Running Services (systemd) =="
systemctl list-units --type=service --state=running | head -20
echo

echo "===== END ====="

# === Read & escape full log ===
CONTENT_RAW=$(< "$LOGFILE")
# Escape quotes and newlines for JSON payload
ESCAPED=$(printf '%s' "$CONTENT_RAW" \
            | sed 's/\\/\\\\/g' \
            | sed 's/"/\\"/g' \
            | sed ':a;N;$!ba;s/\n/\\n/g')

# === Function to send one chunk ===
send_chunk() {
  local chunk="$1"
  local retries=0
  while (( retries < MAX_RETRIES )); do
    payload="{\"content\": \"\`\`\`$chunk\`\`\`\"}"
    response=$(curl -s -H "Content-Type: application/json" \
                     -X POST \
                     -d "$payload" \
                     "$WEBHOOK_URL")
    if [[ "$response" == *"rate limited"* ]]; then
      (( retries++ ))
      echo "Rate limit hit; retry #$retries after ${RETRY_DELAY}s..."
      sleep $RETRY_DELAY
    else
      # assume success or other error that won’t succeed on retry
      break
    fi
  done
}

# === Split & send in chunks ===
while [ ${#ESCAPED} -gt $MAX_DISCORD_CHARS ]; do
  chunk=${ESCAPED:0:$MAX_DISCORD_CHARS}
  send_chunk "$chunk"
  ESCAPED=${ESCAPED:$MAX_DISCORD_CHARS}
done

# Send any remaining
if [ -n "$ESCAPED" ]; then
  send_chunk "$ESCAPED"
fi

echo "All log content sent to Discord."

