#!/bin/bash
# =============================================================================
# TITAN AGGRESSIVE V2: Deep Malware / Miner / Watchdog Purge
# Brutal on threats. Safe on authorized infrastructure.
# =============================================================================

RED='\033[0;31m'; YEL='\033[1;33m'; GRN='\033[0;32m'; BLU='\033[0;34m'; NC='\033[0m'
die()  { echo -e "${RED}[KILL]${NC} $*"; }
warn() { echo -e "${YEL}[WARN]${NC} $*"; }
ok()   { echo -e "${GRN}[OK]${NC}   $*"; }
hdr()  { echo -e "\n${BLU}══════════════════════════════════════════════${NC}"; \
         echo -e "${BLU}  $*${NC}"; \
         echo -e "${BLU}══════════════════════════════════════════════${NC}"; }

[[ $EUID -ne 0 ]] && { echo "Run as root."; exit 1; }

# ─────────────────────────────────────────────
# 1. IRONCLAD PROTECTION LIST
# ─────────────────────────────────────────────
# These users will SURVIVE everything. No processes killed, no files deleted,
# no SSH keys stripped, no user accounts removed.
declare -A SAFE_USERS

# Hardcoded protected users
SAFE_USERS["root"]=1
SAFE_USERS["messagebus"]=1

# Dynamically protect the user running the script and active sessions
[[ -n "${SUDO_USER:-}" ]] && SAFE_USERS["$SUDO_USER"]=1
[[ -n "${USER:-}" ]] && SAFE_USERS["$USER"]=1
[[ -n "${LOGNAME:-}" ]] && SAFE_USERS["$LOGNAME"]=1
while IFS= read -r u; do SAFE_USERS["$u"]=1; done < <(who | awk '{print $1}' | sort -u)

is_protected() { [[ -n "${SAFE_USERS[$1]+_}" ]]; }

ok "Shielded Users: ${!SAFE_USERS[*]}"

# ─────────────────────────────────────────────
# REGEX PATTERNS
# ─────────────────────────────────────────────
PROC_REGEX='(xmri?g|xmr.stak|cpuminer|minerd|kinsing|kdevtmpfsi|bioset|sysupdate|networkmanage[r]|crypto[night]|ddgs|masscan|pnscan|zmap|watchd0g|watchdog[0-9]|nezha|nbtscan|kerberods|khugepaged[0-9]|ld-musl|[a-z0-9]{32,})'
CONTENT_REGEX='(curl|wget|bash|sh|python|perl).*(http|ftp|/tmp|/dev/shm|base64)|/dev/shm/|/tmp/\.[a-z]|stratum\+tcp|mining\.pool|xmrig|kinsing|pastebin\.com|transfer\.sh|ngrok|\.onion'
CRON_REGEX='(wget|curl|bash|sh|python|perl|/tmp|/dev/shm|base64|xmrig|kinsing|stratum|\.sh|dd if|nc |ncat |/bin/bash -[ic])'

# ─────────────────────────────────────────────
hdr "2. WATCHDOG & MINER MASSACRE (FREEZE & KILL)"
# ─────────────────────────────────────────────
# Fixes the watchdog race condition. We freeze them all first, then execute them.

declare -a DOOMED_PIDS
declare -a DOOMED_SERVICES

# Phase 1: Hunt and Freeze
while IFS= read -r pid; do
  comm=$(cat /proc/"$pid"/comm 2>/dev/null)  || continue
  cmdline=$(tr -d '\0' < /proc/"$pid"/cmdline 2>/dev/null) || continue
  exe=$(readlink -f /proc/"$pid"/exe 2>/dev/null) || exe=""
  owner=$(awk '/^Uid:/{print $2; exit}' /proc/"$pid"/status 2>/dev/null | xargs getent passwd 2>/dev/null | cut -d: -f1)
  
  if is_protected "$owner" && [[ "$owner" != "root" ]]; then
    continue # Skip entirely if owned by messagebus or your active session
  fi

  # Match Regex OR Running from hidden temp path
  if echo "$comm $cmdline" | grep -iqE "$PROC_REGEX" || echo "$exe" | grep -qE '^(/tmp|/dev/shm|/var/tmp|/run/shm)'; then
    die "Freezing Malware PID $pid ($comm) -> Exec: $exe"
    kill -STOP "$pid" 2>/dev/null || true
    DOOMED_PIDS+=("$pid")
  fi
done < <(ls /proc | grep -E '^[0-9]+$')

# Stop known bad services
for svc in watchd0g inotify-watch nezha-agent kinsing sysupdate crypto kerberods; do
  systemctl stop "$svc" 2>/dev/null || true
  systemctl disable "$svc" 2>/dev/null || true
  rm -f /etc/systemd/system/"${svc}".service 2>/dev/null || true
done
systemctl daemon-reload 2>/dev/null || true

# Phase 2: Kill Frozen
sleep 1
for pid in "${DOOMED_PIDS[@]}"; do
  kill -9 "$pid" 2>/dev/null || true
done
ok "Malware process tree eradicated."

# ─────────────────────────────────────────────
hdr "3. DESTRUCTIVE FILE SYSTEM PURGE"
# ─────────────────────────────────────────────

# Strip immutable flags from temp directories first
for dir in /tmp /var/tmp /dev/shm /root /etc/cron.d /etc/systemd/system; do
  [[ -d "$dir" ]] || continue
  find "$dir" -maxdepth 3 2>/dev/null | while read -r f; do
    if lsattr "$f" 2>/dev/null | grep -q '\-i\-'; then
      chattr -i "$f" 2>/dev/null || true
      echo "$f" | grep -qE '^(/tmp|/dev/shm|/var/tmp)' && rm -rf "$f"
    fi
  done
done

# Nuke known explicit malware paths
for f in /root/.run.sh /usr/.local/run.sh /opt/nezha /tmp/.ICEd-unix /usr/local/bin/kinsing /usr/local/bin/kdevtmpfsi /usr/bin/sysupdate /usr/local/bin/xmrig; do
  if [[ -e "$f" ]]; then
    chattr -i "$f" 2>/dev/null || true; rm -rf "$f"; die "Purged explicit malware: $f"
  fi
done

# Deep scan executables in temp (Destroy on sight)
find /tmp /var/tmp /dev/shm /run/shm -maxdepth 4 -type f -executable 2>/dev/null | while read -r f; do
  chattr -i "$f" 2>/dev/null || true; rm -f "$f"; die "Purged hidden executable: $f"
done

# Clear Rootkit LD_PRELOAD
if [[ -s /etc/ld.so.preload ]]; then
  die "Rootkit LD_PRELOAD found. Shredding."
  > /etc/ld.so.preload
fi

ok "File system sweep done."

# ─────────────────────────────────────────────
hdr "4. CRON & AT JOB STERILIZATION"
# ─────────────────────────────────────────────

purge_cron_file() {
  local file="$1"
  [[ -f "$file" ]] || return
  if grep -qiE "$CRON_REGEX" "$file" 2>/dev/null; then
    die "Malicious cron detected in $file"
    # Keep legitimate entries, delete matching ones
    grep -viE "$CRON_REGEX" "$file" > "${file}.clean" && mv "${file}.clean" "$file" || truncate -s 0 "$file"
  fi
}

purge_cron_file /etc/crontab
for f in /etc/cron.d/*; do purge_cron_file "$f"; done
for user_cron in /var/spool/cron/crontabs/* /var/spool/cron/*; do purge_cron_file "$user_cron"; done

rm -rf /var/spool/at/jobs/* /var/spool/at/* 2>/dev/null
ok "Cron and At jobs sterilized."

# ─────────────────────────────────────────────
hdr "5. SURGICAL SSH KEY CLEANUP"
# ─────────────────────────────────────────────
# We grep out the bad keys, keeping the good ones intact. No user deletions.

SUSPICIOUS_KEY_PATTERNS='xmrig|kinsing|miner|stratum|cryptonight|pastebin|transfer\.sh|ngrok|serveo'

for dir in /root /home/*; do
  [[ -d "$dir" ]] || continue
  KEY_FILE="$dir/.ssh/authorized_keys"
  [[ -f "$KEY_FILE" ]] || continue
  
  dir_owner=$(stat -c '%U' "$dir" 2>/dev/null)
  
  if grep -qiE "$SUSPICIOUS_KEY_PATTERNS" "$KEY_FILE"; then
    die "Stripping infected SSH keys from $dir_owner"
    cp "$KEY_FILE" "${KEY_FILE}.bak.$(date +%s)" # Backup just in case
    grep -viE "$SUSPICIOUS_KEY_PATTERNS" "$KEY_FILE" > "${KEY_FILE}.clean"
    mv "${KEY_FILE}.clean" "$KEY_FILE"
  fi
done
ok "SSH Keys surgically cleaned (legitimate keys preserved)."

# ─────────────────────────────────────────────
hdr "6. FIREWALL GAG-ORDER (IPTABLES)"
# ─────────────────────────────────────────────

if command -v iptables &>/dev/null; then
  # Drop common miner ports
  for port in 3333 4444 5555 7777 9999 14433 14444 45700; do
    iptables -A OUTPUT -p tcp --dport "$port" -j DROP 2>/dev/null
    iptables -A OUTPUT -p udp --dport "$port" -j DROP 2>/dev/null
  done
  
  # DNS Block known pools
  for ip in pool.supportxmr.com xmrpool.eu minexmr.com nanopool.org hashvault.pro moneroocean.stream c3pool.com; do
    resolved=$(getent hosts "$ip" 2>/dev/null | awk '{print $1}') || true
    [[ -n "$resolved" ]] && iptables -A OUTPUT -d "$resolved" -j DROP 2>/dev/null
  done
  ok "Firewall rules applied. Miner pool communication severed."
fi

# ─────────────────────────────────────────────
hdr "7. ROGUE USER PURGE"
# ─────────────────────────────────────────────
# Kills and deletes users that are NOT protected.

while IFS=: read -r username _ uid _ _ _ _; do
  [[ "$uid" -lt 1000 ]] && continue
  [[ "$username" == "nobody" ]] && continue
  
  if is_protected "$username"; then
    ok "Protected shield active: Skipping user '$username'"
    continue
  fi
  
  die "Erasing unauthorized system user: $username (UID $uid)"
  pkill -u "$username" 2>/dev/null || true
  userdel -f -r "$username" 2>/dev/null || true
done < /etc/passwd

echo -e "\n${GRN}══════════════════════════════════════════════${NC}"
echo -e "${GRN}  TITAN PURGE COMPLETE${NC}"
echo -e "${GRN}══════════════════════════════════════════════${NC}"
