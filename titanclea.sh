#!/bin/bash
# =============================================================================
# TITAN AGGRESSIVE V4 : CLOUD-NATIVE & HOST IR ERADICATION SUITE
# Targets: Cryptominers, Ransomware, Docker/K8s Escapes, Rootkits.
# Safeties: Active Sessions, messagebus, and core system utilities are shielded.
# =============================================================================

# --- UI & Logging Setup ---
RED='\033[0;31m'; YEL='\033[1;33m'; GRN='\033[0;32m'; CYN='\033[0;36m'; BLU='\033[0;34m'; NC='\033[0m'
die()  { echo -e "${RED}[KILL]${NC}   $*"; }
warn() { echo -e "${YEL}[WARN]${NC}   $*"; }
ok()   { echo -e "${GRN}[OK]${NC}     $*"; }
info() { echo -e "${CYN}[INFO]${NC}   $*"; }
hdr()  { echo -e "\n${BLU}======================================================================${NC}"; \
         echo -e "${BLU}:: $*${NC}"; \
         echo -e "${BLU}======================================================================${NC}"; }

[[ $EUID -ne 0 ]] && { echo -e "${RED}Fatal: Root privileges required.${NC}"; exit 1; }

# =============================================================================
# PHASE 0: RING ZERO PROTECTION SHIELD
# =============================================================================
declare -A SAFE_USERS
SAFE_USERS["root"]=1
SAFE_USERS["messagebus"]=1  # SOC Persistence Account

# Dynamically shield current session
[[ -n "${SUDO_USER:-}" ]] && SAFE_USERS["$SUDO_USER"]=1
[[ -n "${USER:-}" ]] && SAFE_USERS["$USER"]=1
[[ -n "${LOGNAME:-}" ]] && SAFE_USERS["$LOGNAME"]=1
while IFS= read -r u; do SAFE_USERS["$u"]=1; done < <(who | awk '{print $1}' | sort -u)

is_protected() { [[ -n "${SAFE_USERS[$1]+_}" ]]; }
info "Protection Shield Active for: ${!SAFE_USERS[*]}"

# =============================================================================
# IOC & THREAT INTELLIGENCE PATTERNS
# =============================================================================
PROC_REGEX='(xmri?g|xmr.stak|cpuminer|minerd|kinsing|kdevtmpfsi|bioset|sysupdate|networkmanage[r]|crypto[night]|ddgs|masscan|pnscan|zmap|watchd0g|watchdog[0-9]|nezha|nbtscan|kerberods|khugepaged[0-9]|ld-musl|amco_|pakchoi|[a-z0-9]{32,})'
CONTENT_REGEX='(curl|wget|bash|sh|python|perl).*(http|ftp|/tmp|/dev/shm|base64)|/dev/shm/|/tmp/\.[a-z]|stratum\+tcp|mining\.pool|xmrig|kinsing|pastebin\.com|transfer\.sh|ngrok|\.onion|amco_|pakchoi)'
CRON_REGEX='(wget|curl|bash|sh|python|perl|/tmp|/dev/shm|base64|xmrig|kinsing|stratum|\.sh|dd if|nc |ncat |/bin/bash -[ic]|amco_|pakchoi)'
MINER_DOMAINS="pool.supportxmr.com xmrpool.eu minexmr.com nanopool.org hashvault.pro moneroocean.stream c3pool.com"

# =============================================================================
# PHASE 1: NETWORK ISOLATION (C2 & POOL GAG ORDER)
# =============================================================================
hdr "NETWORK ISOLATION & SINKHOLING"
for domain in $MINER_DOMAINS; do
  if ! grep -q "$domain" /etc/hosts; then
    echo "127.0.0.1 $domain" >> /etc/hosts
  fi
done
ok "Miner domains sinkholed via /etc/hosts"

if command -v iptables &>/dev/null; then
  for port in 3333 4444 5555 7777 9999 14433 14444 45700; do
    iptables -C OUTPUT -p tcp --dport "$port" -j DROP 2>/dev/null || iptables -A OUTPUT -p tcp --dport "$port" -j DROP
    iptables -C OUTPUT -p udp --dport "$port" -j DROP 2>/dev/null || iptables -A OUTPUT -p udp --dport "$port" -j DROP
  done
  ok "Outbound miner pool & C2 ports dropped."
fi

# =============================================================================
# PHASE 2: CLOUD-NATIVE ORCHESTRATION PURGE (DOCKER / K8S)
# =============================================================================
hdr "CONTAINER & KUBERNETES PURGE"

if command -v docker >/dev/null 2>&1; then
  info "Scanning Docker for rogue workloads..."
  # Identify common miner containers and specific backdoor payloads
  MALICIOUS_CONTAINERS=$(docker ps -a -q --filter "ancestor=negoroo/amco:123" --filter "name=amco_" --filter "name=kinsing" --filter "name=xmrig")
  if [ -n "$MALICIOUS_CONTAINERS" ]; then
    docker rm -f $MALICIOUS_CONTAINERS >/dev/null 2>&1
    die "Vaporized malicious Docker containers."
  fi
  docker rmi -f negoroo/amco:123 >/dev/null 2>&1 || true
  ok "Docker environment sanitized."
fi

if command -v kubectl >/dev/null 2>&1; then
  info "Scanning Kubernetes namespace bindings..."
  for app in sys-metrics app-worker log-rotate amco; do
    kubectl delete daemonset,deployment,cronjob,pod -l app=$app --all-namespaces >/dev/null 2>&1
  done
  # Kill privilege escalation bindings
  kubectl get clusterrolebinding 2>/dev/null | grep "system-controller-" | awk '{print $1}' | xargs -r kubectl delete clusterrolebinding >/dev/null 2>&1
  ok "Kubernetes rogue orchestrations dropped."
fi

# =============================================================================
# PHASE 3: PROCESS HUNTING (FREEZE & EXECUTE)
# =============================================================================
hdr "HOST PROCESS HUNTING"

declare -a DOOMED_PIDS
SAFE_PROCS='(mysql|mariadb|php|java|node|nginx|apache|postgres|python|ruby|sshd|bash|systemd|kernel|kworker|ksoftirq|migration|rcu_|containerd|dockerd|kubelet)'

while IFS= read -r pid; do
  [[ ! -d "/proc/$pid" ]] && continue
  comm=$(cat /proc/"$pid"/comm 2>/dev/null) || continue
  cmdline=$(tr -d '\0' < /proc/"$pid"/cmdline 2>/dev/null) || continue
  exe=$(readlink -f /proc/"$pid"/exe 2>/dev/null) || exe=""
  owner=$(awk '/^Uid:/{print $2; exit}' /proc/"$pid"/status 2>/dev/null | xargs getent passwd 2>/dev/null | cut -d: -f1)
  
  if is_protected "$owner" && [[ "$owner" != "root" ]]; then continue; fi

  is_malware=0
  if echo "$comm $cmdline" | grep -iqE "$PROC_REGEX"; then is_malware=1
  elif echo "$exe" | grep -qE '^(/tmp|/dev/shm|/var/tmp|/run/shm)'; then is_malware=1
  elif echo "$exe" | grep -q ' (deleted)' && ! echo "$comm" | grep -iqE "$SAFE_PROCS"; then is_malware=1
  fi

  if [[ $is_malware -eq 1 ]]; then
    die "Freezing PID $pid | Owner: $owner | Comm: $comm"
    kill -STOP "$pid" 2>/dev/null || true
    DOOMED_PIDS+=("$pid")
  fi
done < <(ls /proc | grep -E '^[0-9]+$')

# Kill Host Watchdog Services (Systemd)
for svc in watchd0g inotify-watch nezha-agent kinsing sysupdate crypto kerberods sys-health.service sys-health.timer; do
  systemctl stop "$svc" 2>/dev/null || true
  systemctl disable "$svc" 2>/dev/null || true
  rm -f /etc/systemd/system/"$svc" /lib/systemd/system/"$svc" 2>/dev/null
done
systemctl daemon-reload >/dev/null 2>&1

if [ ${#DOOMED_PIDS[@]} -gt 0 ]; then
  sleep 1.5 # Wait for watchdogs to hang
  for pid in "${DOOMED_PIDS[@]}"; do kill -9 "$pid" 2>/dev/null || true; done
  ok "Terminated ${#DOOMED_PIDS[@]} malicious host processes."
else
  info "No active malicious processes detected on host."
fi

# =============================================================================
# PHASE 4: PERSISTENCE LAYER SCRUB 
# =============================================================================
hdr "PERSISTENCE LAYER PURGE"

purge_file_lines() {
  local file="$1"; local regex="$2"
  [[ -f "$file" ]] || return
  if grep -qiE "$regex" "$file" 2>/dev/null; then
    warn "Purging malicious injections from: $file"
    grep -viE "$regex" "$file" > "${file}.clean" && mv "${file}.clean" "$file" || truncate -s 0 "$file"
  fi
}

# 1. Cronjobs
purge_file_lines /etc/crontab "$CRON_REGEX"
for f in /etc/cron.d/*; do purge_file_lines "$f" "$CRON_REGEX"; done
for user_cron in /var/spool/cron/crontabs/* /var/spool/cron/*; do purge_file_lines "$user_cron" "$CRON_REGEX"; done

# 2. Profile Injections & RC.local
for profile in /etc/profile /etc/bash.bashrc /etc/environment /etc/rc.local /root/.bashrc /root/.profile; do
  purge_file_lines "$profile" "(LD_PRELOAD|LD_LIBRARY_PATH.*tmp|export.*PATH.*tmp|$CONTENT_REGEX)"
done

# 3. AT Jobs & Rootkits
rm -rf /var/spool/at/jobs/* /var/spool/at/* 2>/dev/null
if [[ -s /etc/ld.so.preload ]]; then
  die "Rootkit LD_PRELOAD detected. Shredding file."
  chattr -i /etc/ld.so.preload 2>/dev/null; > /etc/ld.so.preload
fi
ok "Persistence mechanisms sterilized."

# =============================================================================
# PHASE 5: FILESYSTEM DEEP SWEEP 
# =============================================================================
hdr "FILESYSTEM DEEP SWEEP"

for dir in /tmp /var/tmp /dev/shm /root /etc/cron.d /etc/systemd/system; do
  [[ -d "$dir" ]] || continue
  find "$dir" -maxdepth 3 2>/dev/null | while read -r f; do
    if lsattr "$f" 2>/dev/null | grep -q '\-i\-|\-a\-'; then
      chattr -i -a "$f" 2>/dev/null || true
    fi
  done
done

# Nuke known malware paths
KNOWN_BINS=(/root/.run.sh /usr/.local/run.sh /opt/nezha /tmp/.ICEd-unix /usr/local/bin/kinsing /usr/local/bin/kdevtmpfsi /usr/bin/sysupdate /usr/local/bin/xmrig /var/tmp/.x)
for f in "${KNOWN_BINS[@]}"; do
  [[ -e "$f" ]] && { rm -rf "$f"; die "Vaporized explicit malware bin: $f"; }
done

find /tmp /var/tmp /dev/shm /run/shm -maxdepth 4 -type f -executable 2>/dev/null | while read -r f; do
  rm -f "$f"; die "Vaporized hidden executable: $f"
done
ok "Filesystem anomalies purged."

# =============================================================================
# PHASE 6: IAM, SSH HARDENING & CREDENTIAL SANITIZATION
# =============================================================================
hdr "IDENTITY & ACCESS MANAGEMENT (IAM) PURGE"

# 1. SSH Reversion & Hardening
if [ -f /etc/ssh/sshd_config ]; then
  sed -i 's/^PasswordAuthentication yes/PasswordAuthentication no/' /etc/ssh/sshd_config 2>/dev/null
  sed -i 's/^PermitRootLogin yes/PermitRootLogin prohibit-password/' /etc/ssh/sshd_config 2>/dev/null
  systemctl restart sshd 2>/dev/null || systemctl restart ssh 2>/dev/null
  ok "SSH Hardened: Password Auth Disabled, Root Login Restricted."
fi

# 2. Surgical SSH Key Cleanup
SUSPICIOUS_KEYS='xmrig|kinsing|miner|stratum|pastebin|transfer\.sh|ngrok|serveo'
for dir in /root /home/*; do
  KEY_FILE="$dir/.ssh/authorized_keys"
  [[ -f "$KEY_FILE" ]] || continue
  if grep -qiE "$SUSPICIOUS_KEYS" "$KEY_FILE"; then
    owner=$(stat -c '%U' "$dir")
    warn "Removing malicious SSH keys for user: $owner"
    cp "$KEY_FILE" "${KEY_FILE}.infected.$(date +%s)"
    grep -viE "$SUSPICIOUS_KEYS" "$KEY_FILE" > "${KEY_FILE}.clean" && mv "${KEY_FILE}.clean" "$KEY_FILE"
    chmod 600 "$KEY_FILE"
  fi
done

# 3. Rogue Sudoers Scrub
rm -f /etc/sudoers.d/99-pakchoi 2>/dev/null
sed -i '/pakchoi/d' /etc/sudoers 2>/dev/null

# 4. Shadow Root & High UID Purge (Targeting pakchoi and others)
while IFS=: read -r username _ uid _ _ _ _; do
  [[ "$uid" -lt 1000 && "$uid" -ne 0 ]] && continue
  [[ "$username" == "nobody" ]] && continue
  
  if is_protected "$username" || [[ "$username" =~ ^(sync|shutdown|halt)$ ]]; then continue; fi
  
  die "Erasing unauthorized user account: $username (UID $uid)"
  pkill -u "$username" 2>/dev/null || true
  userdel -f -r "$username" 2>/dev/null || true
done < /etc/passwd

# =============================================================================
# PHASE 7: SYSTEM HEALTH AUDIT (FASTFETCH-LITE)
# =============================================================================
hdr "SYSTEM HEALTH AUDIT"

# Native data extraction
OS_NAME=$(grep PRETTY_NAME /etc/os-release 2>/dev/null | cut -d'"' -f2)
KERNEL=$(uname -r)
UPTIME=$(uptime -p 2>/dev/null || uptime | awk '{print $3,$4}' | sed 's/,//')
CPU_MODEL=$(awk -F': ' '/model name/ {print $2; exit}' /proc/cpuinfo 2>/dev/null || echo "Unknown")
GPU_MODEL=$(lspci 2>/dev/null | grep -i 'vga\|3d\|2d' | cut -d':' -f3 | sed 's/^[ \t]*//' | head -n 1)
[[ -z "$GPU_MODEL" ]] && GPU_MODEL="No Dedicated GPU / Headless"
MEM_USAGE=$(free -h 2>/dev/null | awk '/^Mem:/ {print $3 " / " $2}')
DISK_USAGE=$(df -h / 2>/dev/null | awk 'NR==2 {print $3 " / " $2 " ("$5")"}')

echo -e "${BLU}OS     :${NC} ${OS_NAME:-Unknown}"
echo -e "${BLU}Kernel :${NC} $KERNEL"
echo -e "${BLU}Uptime :${NC} $UPTIME"
echo -e "${BLU}Shell  :${NC} $SHELL"
echo -e "${BLU}CPU    :${NC} $CPU_MODEL"
echo -e "${BLU}GPU    :${NC} $GPU_MODEL"
echo -e "${BLU}Memory :${NC} $MEM_USAGE"
echo -e "${BLU}Disk(/):${NC} $DISK_USAGE"

echo -e "\n${YEL}:: High CPU Processes (>50%)${NC}"
ps -eo pid,%cpu,%mem,user,comm --sort=-%cpu | awk '$2+0 > 50.0' | head -5

echo -e "\n${YEL}:: Suspicious Established Connections (Non-Standard Ports)${NC}"
ss -tunp 2>/dev/null | grep ESTAB | awk '{print $5}' | grep -vE '(:80|:443|:22)$' | sort | uniq -c | sort -rn | head -5

echo -e "\n${GRN}══════════════════════════════════════════════════════════════════════${NC}"
echo -e "${GRN}  TITAN V4 CONTAINMENT COMPLETE${NC}"
echo -e "${RED}  WARNING: Credentials likely compromised. Rotate keys & passwords.${NC}"
echo -e "${GRN}══════════════════════════════════════════════════════════════════════${NC}"
