#!/bin/bash
# =============================================================================
# TITAN AGGRESSIVE: Deep Malware / Miner / Watchdog Purge
# Requires root. No log file. Prints everything to stdout.
# =============================================================================

RED='\033[0;31m'; YEL='\033[1;33m'; GRN='\033[0;32m'; BLU='\033[0;34m'; NC='\033[0m'
die()  { echo -e "${RED}[KILL]${NC} $*"; }
warn() { echo -e "${YEL}[WARN]${NC} $*"; }
ok()   { echo -e "${GRN}[OK]${NC}   $*"; }
hdr()  { echo -e "\n${BLU}══════════════════════════════════════════════${NC}"; \
          echo -e "${BLU}  $*${NC}"; \
          echo -e "${BLU}══════════════════════════════════════════════${NC}"; }

[[ $EUID -ne 0 ]] && { echo "Run as root."; exit 1; }

# =============================================================================
# ██████  NEVER KILL LIST — EDIT THIS BEFORE RUNNING ██████
# Add your SOC / hidden admin usernames here.
# These users are PERMANENTLY protected — never killed, never deleted,
# never logged out, SSH keys never wiped — regardless of UID or appearance.
# =============================================================================
NEVER_KILL=(
  # "yoursocuser"       # <- replace with your actual hidden admin username
  # "monitor"
  # "soc01"
)
# =============================================================================

# is_protected <username>
# Returns 0 (true) if the user must never be touched under any circumstance.
is_protected() {
  local u="$1"
  # 1. Hardcoded NEVER_KILL list (highest priority — checked first)
  for nk in "${NEVER_KILL[@]}"; do
    [[ "$u" == "$nk" ]] && return 0
  done
  # 2. Active session users (SAFE_USERS populated below)
  [[ -n "${SAFE_USERS[$u]+_}" ]] && return 0
  return 1
}

# Collect ALL users that must never be touched:
#  - root itself
#  - whoever called sudo
#  - whoever is logged into any TTY / SSH session right now
#  - owner of the current TTY
declare -A SAFE_USERS
SAFE_USERS["root"]=1
[[ -n "${SUDO_USER:-}" ]] && SAFE_USERS["$SUDO_USER"]=1
# All active login sessions
while IFS= read -r u; do SAFE_USERS["$u"]=1; done < <(who | awk '{print $1}' | sort -u)
# Current SSH connection user (catches cases where 'who' misses it)
[[ -n "${SSH_CONNECTION:-}" ]] && [[ -n "${USER:-}"  ]] && SAFE_USERS["$USER"]=1
[[ -n "${LOGNAME:-}"         ]]                          && SAFE_USERS["$LOGNAME"]=1
logname 2>/dev/null                                      | { read -r ln && SAFE_USERS["$ln"]=1; } || true
# Owner of the current TTY
tty_user=$(stat -c '%U' "$(tty 2>/dev/null)" 2>/dev/null) && SAFE_USERS["$tty_user"]=1 || true
# Also protect NEVER_KILL users by adding them into SAFE_USERS
for nk in "${NEVER_KILL[@]}"; do SAFE_USERS["$nk"]=1; done

echo ""
ok "🔒 Hardcoded protected users : ${NEVER_KILL[*]:-"(none — fill NEVER_KILL list!)"}"
ok "🔒 Session protected users   : ${!SAFE_USERS[*]}"
echo ""

# ─────────────────────────────────────────────
# REGEX PATTERNS
# ─────────────────────────────────────────────
# Process / binary name patterns (case-insensitive match)
PROC_REGEX='(xmri?g|xmr.stak|cpuminer|minerd|kinsing|kdevtmpfsi|bioset|sysupdate|networkmanage[r]|crypto[night]|ddgs|masscan|pnscan|zmap|watchd0g|watchdog[0-9]|nezha|nbtscan|kerberods|khugepaged[0-9]|ld-musl|[a-z0-9]{32,})'

# Suspicious file content patterns (scripts, binaries)
CONTENT_REGEX='(curl|wget|bash|sh|python|perl).*(http|ftp|/tmp|/dev/shm|base64)|/dev/shm/|/tmp/\.[a-z]|stratum\+tcp|mining\.pool|xmrig|kinsing|pastebin\.com|transfer\.sh|ngrok|\.onion'

# Suspicious cron job patterns
CRON_REGEX='(wget|curl|bash|sh|python|perl|/tmp|/dev/shm|base64|xmrig|kinsing|stratum|\.sh|dd if|nc |ncat |/bin/bash -[ic])'

# Watchdog / persistence script patterns
WATCHDOG_REGEX='(while true|inotifywait|sleep [0-9].*restart|systemctl start|service.*start|pkill.*-[0-9].*start|crond|crontab -[li]|nohup.*&)'

# ─────────────────────────────────────────────
hdr "1. KILL WATCHDOG & MONITOR PROCESSES"
# ─────────────────────────────────────────────

# Kill anything matching watchdog/monitor patterns in cmdline
while IFS= read -r pid; do
  cmd=$(tr -d '\0' < /proc/"$pid"/cmdline 2>/dev/null) || continue
  if echo "$cmd" | grep -iqE "$WATCHDOG_REGEX"; then
    comm=$(cat /proc/"$pid"/comm 2>/dev/null)
    die "Watchdog PID $pid ($comm): $cmd"
    kill -9 "$pid" 2>/dev/null || true
  fi
done < <(ls /proc | grep -E '^[0-9]+$')

# Specific watchdog service names
for svc in \
  watchdog watchd0g inotify-watch crond.service atd.service \
  nezha-agent kinsing sysupdate crypto networkmanager \
  update-notifier xmrig kerberods bioset; do
  systemctl stop    "$svc" 2>/dev/null || true
  systemctl disable "$svc" 2>/dev/null || true
  rm -f /etc/systemd/system/"${svc}".service \
        /lib/systemd/system/"${svc}".service \
        /usr/lib/systemd/system/"${svc}".service 2>/dev/null || true
done
systemctl daemon-reload 2>/dev/null || true
ok "Watchdog services killed."

# ─────────────────────────────────────────────
hdr "2. KILL ALL MALWARE / MINER PROCESSES"
# ─────────────────────────────────────────────

# Helper: get the username owning a PID
pid_owner() {
  local pid="$1"
  local uid
  uid=$(awk '/^Uid:/{print $2; exit}' /proc/"$pid"/status 2>/dev/null) || echo ""
  getent passwd "$uid" 2>/dev/null | cut -d: -f1
}

# Kill by name regex
while IFS= read -r pid; do
  comm=$(cat /proc/"$pid"/comm 2>/dev/null) || continue
  cmdline=$(tr -d '\0' < /proc/"$pid"/cmdline 2>/dev/null) || continue
  if echo "$comm $cmdline" | grep -iqE "$PROC_REGEX"; then
    owner=$(pid_owner "$pid")
    if is_protected "$owner"; then
      warn "PID $pid ($comm) matches malware regex but owner '$owner' is protected — skipping"
      continue
    fi
    die "Killing PID $pid ($comm) owned by '$owner'"
    kill -9 "$pid" 2>/dev/null || true
  fi
done < <(ls /proc | grep -E '^[0-9]+$')

# Kill processes running from temp / hidden paths
while IFS= read -r pid; do
  exe=$(readlink -f /proc/"$pid"/exe 2>/dev/null) || continue
  if echo "$exe" | grep -qE '^(/tmp|/dev/shm|/var/tmp|/run/shm)'; then
    owner=$(pid_owner "$pid")
    if is_protected "$owner"; then
      warn "PID $pid running from temp ($exe) but owner '$owner' is protected — skipping"
      continue
    fi
    die "Killing process from temp path: PID $pid -> $exe (owner: $owner)"
    kill -9 "$pid" 2>/dev/null || true
  fi
done < <(ls /proc | grep -E '^[0-9]+$')

# Kill high-CPU unknown processes (>70%)
SAFE_PROCS='mysql|mariadb|php|java|node|nginx|apache|postgres|python|ruby|sshd|bash|systemd|kernel|kworker|ksoftirq|migration|rcu_'
while IFS= read -r line; do
  pid=$(awk  '{print $1}' <<< "$line")
  cpu=$(awk  '{print $2}' <<< "$line")
  comm=$(awk '{print $3}' <<< "$line")
  if ! echo "$comm" | grep -qE "$SAFE_PROCS"; then
    owner=$(pid_owner "$pid")
    if is_protected "$owner"; then
      warn "High-CPU ($cpu%) PID $pid ($comm) but owner '$owner' is protected — skipping"
      continue
    fi
    die "High CPU ($cpu%) unknown process '$comm' PID $pid (owner: $owner) — killing"
    kill -9 "$pid" 2>/dev/null || true
  fi
done < <(ps -eo pid,%cpu,comm --no-headers --sort=-%cpu | awk '$2+0 > 70.0')

ok "Process sweep done."

# ─────────────────────────────────────────────
hdr "3. DEEP CRON JOB PURGE (REGEX-BASED)"
# ─────────────────────────────────────────────

purge_cron_file() {
  local file="$1"
  [[ -f "$file" ]] || return
  if grep -qiE "$CRON_REGEX" "$file" 2>/dev/null; then
    die "Suspicious cron entries in $file:"
    grep -iE "$CRON_REGEX" "$file"
    # Remove only suspicious lines, keep safe ones
    grep -viE "$CRON_REGEX" "$file" > "${file}.clean" && mv "${file}.clean" "$file" || truncate -s 0 "$file"
    ok "Cleaned: $file"
  fi
}

# System cron files
purge_cron_file /etc/crontab
for f in /etc/cron.d/*; do purge_cron_file "$f"; done

# Per-user crontabs
for user_cron in /var/spool/cron/crontabs/* /var/spool/cron/*; do
  [[ -f "$user_cron" ]] || continue
  owner=$(basename "$user_cron")
  if grep -qiE "$CRON_REGEX" "$user_cron" 2>/dev/null; then
    die "Malicious cron for user '$owner' in $user_cron:"
    grep -iE "$CRON_REGEX" "$user_cron"
    grep -viE "$CRON_REGEX" "$user_cron" > "${user_cron}.clean" && \
      mv "${user_cron}.clean" "$user_cron" || truncate -s 0 "$user_cron"
    ok "Cleaned crontab for $owner"
  fi
done

# At jobs
for atjob in /var/spool/at/jobs/* /var/spool/at/*; do
  [[ -f "$atjob" ]] || continue
  if grep -qiE "$CRON_REGEX" "$atjob" 2>/dev/null; then
    die "Malicious at-job: $atjob"
    rm -f "$atjob"
  fi
done

# Systemd timers acting as cron replacements
while IFS= read -r unit; do
  unit_file=$(systemctl cat "$unit" 2>/dev/null || true)
  if echo "$unit_file" | grep -qiE "$CRON_REGEX|$PROC_REGEX"; then
    die "Malicious systemd timer: $unit"
    systemctl stop    "$unit" 2>/dev/null || true
    systemctl disable "$unit" 2>/dev/null || true
    rm -f "$(systemctl show -P FragmentPath "$unit" 2>/dev/null)" 2>/dev/null || true
  fi
done < <(systemctl list-units --type=timer --no-legend 2>/dev/null | awk '{print $1}')

ok "Cron / timer sweep done."

# ─────────────────────────────────────────────
hdr "4. KILL MALWARE FILES (DEEP SCAN)"
# ─────────────────────────────────────────────

# Known explicit paths
KNOWN_MALWARE=(
  /root/.run.sh /root/.rsyslogd /root/.config.json
  /usr/.local/run.sh /opt/nezha
  /tmp/.ICEd-unix /tmp/.X11-unix/.font
  /dev/shm/.s /var/tmp/.x
  /usr/local/bin/kinsing /usr/local/bin/kdevtmpfsi
  /bin/networkmanager /usr/bin/sysupdate
  /usr/bin/bioset /usr/local/bin/xmrig
)
for f in "${KNOWN_MALWARE[@]}"; do
  if [[ -e "$f" ]]; then
    die "Removing known malware: $f"
    chattr -i "$f" 2>/dev/null || true
    rm -rf "$f"
  fi
done

# All hidden files in temp dirs
find /tmp /var/tmp /dev/shm /run/shm -maxdepth 3 \( -type f -o -type l \) 2>/dev/null | while read -r f; do
  name=$(basename "$f")
  if [[ "$name" == .* ]] || echo "$f" | grep -qiE "$PROC_REGEX"; then
    die "Removing temp file: $f"
    chattr -i "$f" 2>/dev/null || true
    rm -f "$f"
  fi
done

# Deep scan: executable files in /tmp /dev/shm /var/tmp
find /tmp /var/tmp /dev/shm /run/shm -maxdepth 4 -type f -executable 2>/dev/null | while read -r f; do
  die "Executable in temp: $f — removing"
  chattr -i "$f" 2>/dev/null || true
  rm -f "$f"
done

# Scan shell scripts & configs with suspicious content (non-system paths)
find /root /home /var/tmp /tmp /dev/shm /etc/init.d /etc/profile.d \
     -maxdepth 5 -type f \( -name "*.sh" -o -name "*.py" -o -name "*.pl" \
     -o -name ".bashrc" -o -name ".profile" -o -name ".bash_profile" \) 2>/dev/null | \
while read -r f; do
  if grep -lqiE "$CONTENT_REGEX" "$f" 2>/dev/null; then
    die "Suspicious content in: $f"
    # Show the suspicious lines
    grep -niE "$CONTENT_REGEX" "$f" 2>/dev/null | head -5
    # Remove only if clearly malware (not user's own .bashrc — warn only)
    if echo "$f" | grep -qE '^(/tmp|/dev/shm|/var/tmp|/etc/init.d|/etc/profile.d)'; then
      rm -f "$f" && die "Deleted: $f"
    else
      warn "Review manually (not auto-deleted — could be your file): $f"
    fi
  fi
done

# Check /etc/rc.local /etc/rc.d for injections
for rcfile in /etc/rc.local /etc/rc.d/rc.local; do
  [[ -f "$rcfile" ]] || continue
  if grep -qiE "$CONTENT_REGEX|$CRON_REGEX" "$rcfile"; then
    die "Injection in $rcfile:"
    grep -niE "$CONTENT_REGEX|$CRON_REGEX" "$rcfile"
    grep -viE "$CONTENT_REGEX|$CRON_REGEX" "$rcfile" > "${rcfile}.clean"
    mv "${rcfile}.clean" "$rcfile"
    ok "Cleaned $rcfile"
  fi
done

# Scan /etc/ld.so.preload (rootkit LD_PRELOAD injection)
if [[ -s /etc/ld.so.preload ]]; then
  die "Suspicious /etc/ld.so.preload contents:"
  cat /etc/ld.so.preload
  > /etc/ld.so.preload
  ok "Cleared /etc/ld.so.preload"
fi

# Known legitimate system accounts that may have UID 0 on some distros
SYSTEM_UID0_WHITELIST=(
  root toor sync shutdown halt operator daemon
  messagebus dbus systemd-network systemd-resolve
  systemd-timesync syslog _apt uucp www-data
)

# Check /etc/passwd for injected users with root UID
while IFS=: read -r user _ uid gid _ home shell; do
  if [[ "$uid" -eq 0 && "$user" != "root" ]]; then
    # Always check is_protected first — covers NEVER_KILL, active sessions,
    # AND known system accounts (messagebus, dbus, systemd-*, etc.)
    if is_protected "$user" || [[ " ${SYSTEM_UID0_WHITELIST[*]} " == *" $user "* ]]; then
      warn "UID-0 user '$user' is protected/whitelisted — skipping (verify manually)"
      continue
    fi
    die "Shadow root user found: $user (UID 0) — removing"
    pkill -u "$user" 2>/dev/null || true
    userdel -f -r "$user" 2>/dev/null || true
  fi
done < /etc/passwd

ok "File sweep done."

# ─────────────────────────────────────────────
hdr "5. REMOVE UNEXPECTED USERS"
# ─────────────────────────────────────────────

while IFS=: read -r username _ uid _ _ _ _; do
  [[ "$uid" -lt 1000 ]] && continue
  [[ "$username" == "nobody" ]] && continue
  if is_protected "$username"; then
    ok "Skipping protected user: $username (UID $uid)"
    continue
  fi
  die "Removing unexpected user: $username (UID $uid)"
  pkill -u "$username" 2>/dev/null || true
  userdel -f -r "$username" 2>/dev/null || true
done < /etc/passwd

ok "User sweep done."

# ─────────────────────────────────────────────
hdr "6. SSH LOCKDOWN"
# ─────────────────────────────────────────────

for dir in /root /home/*; do
  KEY_FILE="$dir/.ssh/authorized_keys"
  [[ -f "$KEY_FILE" ]] || continue
  dir_owner=$(stat -c '%U' "$dir" 2>/dev/null)
  # Never wipe keys for protected users (NEVER_KILL list takes priority)
  if is_protected "$dir_owner"; then
    ok "Skipping authorized_keys for protected user: $dir_owner"
    if grep -qiE '(kinsing|xmrig|miner|hack|attack|bot|@[0-9]+\.[0-9]+)' "$KEY_FILE" 2>/dev/null; then
      warn "Suspicious SSH key comment in $KEY_FILE — review manually:"
      grep -iE '(kinsing|xmrig|miner|hack|attack|bot)' "$KEY_FILE"
    fi
    continue
  fi
  die "Wiping authorized_keys: $KEY_FILE (owner: $dir_owner)"
  > "$KEY_FILE"
done

# Check for unexpected PermitRootLogin or PasswordAuth changes
SSHD="/etc/ssh/sshd_config"
if grep -qiE '^\s*PermitRootLogin\s+yes' "$SSHD" 2>/dev/null; then
  warn "PermitRootLogin is YES — setting to prohibit-password"
  sed -i 's/^\s*PermitRootLogin\s.*/PermitRootLogin prohibit-password/' "$SSHD"
fi
if grep -qiE '^\s*PasswordAuthentication\s+yes' "$SSHD" 2>/dev/null; then
  warn "PasswordAuthentication is YES — setting to no"
  sed -i 's/^\s*PasswordAuthentication\s.*/PasswordAuthentication no/' "$SSHD"
fi
systemctl restart sshd 2>/dev/null || service ssh restart 2>/dev/null || true
ok "SSH lockdown done."

# ─────────────────────────────────────────────
hdr "7. FIREWALL: BLOCK MINER POOL PORTS"
# ─────────────────────────────────────────────

if command -v iptables &>/dev/null; then
  # Common stratum / mining pool ports
  for port in 3333 4444 5555 7777 9999 14433 14444 45700 8080 1080 9050; do
    iptables -A OUTPUT -p tcp --dport "$port" -j DROP 2>/dev/null && \
      ok "Blocked outbound TCP $port" || true
    iptables -A OUTPUT -p udp --dport "$port" -j DROP 2>/dev/null || true
  done
  # Block known miner pool domains via OUTPUT — DNS block
  for ip in \
    pool.supportxmr.com xmrpool.eu minexmr.com nanopool.org \
    hashvault.pro moneroocean.stream c3pool.com; do
    resolved=$(getent hosts "$ip" 2>/dev/null | awk '{print $1}') || true
    [[ -n "$resolved" ]] && \
      iptables -A OUTPUT -d "$resolved" -j DROP 2>/dev/null && \
      ok "Blocked miner pool IP: $resolved ($ip)" || true
  done
  iptables-save > /etc/iptables/rules.v4 2>/dev/null || true
else
  warn "iptables not found — skipping firewall"
fi

# ─────────────────────────────────────────────
hdr "8. IMMUTABLE FLAG SWEEP"
# ─────────────────────────────────────────────

# Malware often sets +i on files to prevent deletion
# Strip it from suspicious locations
for dir in /tmp /var/tmp /dev/shm /root /etc/cron.d /etc/systemd/system; do
  [[ -d "$dir" ]] || continue
  find "$dir" -maxdepth 3 2>/dev/null | while read -r f; do
    if lsattr "$f" 2>/dev/null | grep -q '\-i\-'; then
      die "Removing immutable flag from: $f"
      chattr -i "$f" 2>/dev/null || true
      # If in a temp dir, delete it too
      echo "$f" | grep -qE '^(/tmp|/dev/shm|/var/tmp)' && rm -rf "$f"
    fi
  done
done
ok "Immutable flag sweep done."

# ─────────────────────────────────────────────
hdr "9. ENVIRONMENT & PROFILE INJECTION CHECK"
# ─────────────────────────────────────────────

# Check for LD_PRELOAD in environment files
for f in /etc/environment /etc/profile /etc/bash.bashrc \
          /root/.bashrc /root/.profile /root/.bash_profile; do
  [[ -f "$f" ]] || continue
  if grep -qiE '(LD_PRELOAD|LD_LIBRARY_PATH.*tmp|export.*PATH.*tmp)' "$f"; then
    die "Environment injection in $f:"
    grep -niE '(LD_PRELOAD|LD_LIBRARY_PATH.*tmp|export.*PATH.*tmp)' "$f"
    sed -i '/LD_PRELOAD/d; /LD_LIBRARY_PATH.*tmp/d; /export.*PATH.*tmp/d' "$f"
    ok "Cleaned: $f"
  fi
  if grep -qiE "$CONTENT_REGEX" "$f" 2>/dev/null; then
    die "Suspicious content in $f:"
    grep -niE "$CONTENT_REGEX" "$f"
    warn "Review and clean $f manually."
  fi
done
ok "Environment check done."

# ─────────────────────────────────────────────
hdr "10. SYSTEM HEALTH SUMMARY"
# ─────────────────────────────────────────────

echo ""
echo "── Top CPU Processes ──────────────────────────"
ps -eo pid,%cpu,%mem,user,comm --sort=-%cpu | head -12

echo ""
echo "── Established Connections ────────────────────"
ss -tunp | grep ESTAB | awk '{print $5, $7}' | sort | uniq -c | sort -rn | head -20

echo ""
echo "── Listening Ports ────────────────────────────"
ss -tlnp

echo ""
echo "── Memory & Load ──────────────────────────────"
free -h
uptime

echo ""
echo "── Remaining Cron Jobs ────────────────────────"
crontab -l 2>/dev/null || echo "(none)"
for f in /etc/crontab /etc/cron.d/*; do
  [[ -f "$f" ]] && echo "[$f]" && cat "$f"
done

echo ""
echo "── Systemd Units (non-standard) ───────────────"
systemctl list-units --type=service --state=running --no-legend 2>/dev/null | \
  grep -vE '(ssh|cron|rsyslog|systemd|network|dbus|getty|login|udev|polkit|accounts|avahi|bluetooth|cups|kernel|lvm|multipathd|packagekit|snapd|udisks|upower)'

echo -e "\n${RED}══════════════════════════════════════════════${NC}"
echo -e "${RED}  PURGE COMPLETE${NC}"
echo -e "${RED}══════════════════════════════════════════════${NC}"
echo ""
echo -e "${YEL}REQUIRED ACTIONS:${NC}"
echo "  1.  passwd root"
for u in "${!SAFE_USERS[@]}"; do [[ "$u" != "root" ]] && echo "  2.  passwd $u"; done
echo "  3.  Re-add YOUR SSH public key to ~/.ssh/authorized_keys"
echo "  4.  Reboot to clear any in-memory rootkits: reboot"
echo "  5.  After reboot, run: rkhunter --update && rkhunter --check"
echo "  6.  After reboot, run: chkrootkit"
echo ""
