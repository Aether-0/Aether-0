#!/bin/bash
###############################################################################
# WHITE HAT SERVER CLEANER v2.0
# - Harvests passwords, API keys, SSH keys, sensitive configs
# - Immunizes messagebus user
# - Cleans black hat persistence (crons, /tmp, ld_preload, systemd, etc.)
# - NEVER touches sshd_config or restarts sshd — your connection stays alive
###############################################################################
set -euo pipefail

# Colors
R='\033[1;31m'; G='\033[1;32m'; Y='\033[1;33m'; B='\033[1;34m'; C='\033[1;36m'; W='\033[1;37m'; N='\033[0m'

banner() {
  echo -e "${C}"
  echo "╔══════════════════════════════════════════════════════════════╗"
  echo "║            WHITE HAT SERVER CLEANER v2.0                    ║"
  echo "║   Harvest → Immunize → Clean → Preserve SSH                ║"
  echo "╚══════════════════════════════════════════════════════════════╝"
  echo -e "${N}"
}

log()  { echo -e "${G}[+]${N} $*"; }
warn() { echo -e "${Y}[!]${N} $*"; }
err()  { echo -e "${R}[✗]${N} $*"; }
info() { echo -e "${B}[i]${N} $*"; }
section() { echo -e "\n${C}═══ $* ═══${N}"; }

[[ $EUID -ne 0 ]] && { err "Run as root."; exit 1; }

TS=$(date +%Y%m%d_%H%M%S)
HARVEST="/root/server_harvest_${TS}"
mkdir -p "$HARVEST"/{creds,ssh_keys,configs,histories,crontabs,processes,network,systemd,users,misc}
CREDFILE="$HARVEST/creds/all_secrets.txt"
touch "$CREDFILE"

banner
log "Harvest dir: $HARVEST"

###############################################################################
# PHASE 1 — HARVEST
###############################################################################
section "PHASE 1: HARVESTING SENSITIVE DATA"

# 1a) System files
log "Backing up /etc/passwd, shadow, sudoers, group..."
for f in /etc/passwd /etc/shadow /etc/sudoers /etc/group /etc/gshadow; do
  [[ -f "$f" ]] && cp "$f" "$HARVEST/users/" 2>/dev/null
done
cp -r /etc/sudoers.d "$HARVEST/users/sudoers.d" 2>/dev/null || true

# 1b) SSH keys from all users
log "Collecting SSH keys & authorized_keys..."
while IFS=: read -r user _ _ _ _ home _; do
  [[ -d "$home/.ssh" ]] && {
    dest="$HARVEST/ssh_keys/${user}"
    mkdir -p "$dest"
    cp -a "$home/.ssh/"* "$dest/" 2>/dev/null || true
  }
done < /etc/passwd

# 1c) Shell histories
log "Collecting shell histories..."
while IFS=: read -r user _ _ _ _ home _; do
  for hf in .bash_history .zsh_history .sh_history .mysql_history .psql_history .python_history .node_repl_history .rediscli_history; do
    [[ -f "$home/$hf" ]] && cp "$home/$hf" "$HARVEST/histories/${user}_${hf}" 2>/dev/null
  done
done < /etc/passwd

# 1d) Config files with potential secrets
log "Collecting config files (.env, wp-config, database.yml, etc.)..."
CONF_PATTERNS=( "*.env" ".env" ".env.*" "wp-config.php" "config.php" "settings.php"
  "database.yml" "database.yaml" "secrets.yml" "credentials.yml"
  "config.json" "config.yaml" "config.yml" "appsettings.json"
  ".htpasswd" ".pgpass" ".my.cnf" ".netrc" ".git-credentials"
  "docker-compose.yml" "docker-compose.yaml" "Dockerfile"
  ".dockerenv" "shadow" "passwd" )

for pat in "${CONF_PATTERNS[@]}"; do
  find / -maxdepth 6 -name "$pat" -type f \
    ! -path "/proc/*" ! -path "/sys/*" ! -path "/dev/*" ! -path "$HARVEST/*" \
    -exec cp --parents -t "$HARVEST/configs/" {} \; 2>/dev/null || true
done

# 1e) Grep for hardcoded secrets, API keys, passwords
log "Scanning filesystem for hardcoded secrets & API keys..."
SECRET_REGEX='(password|passwd|pwd|secret|api[_-]?key|apikey|access[_-]?key|token|auth[_-]?token|private[_-]?key|client[_-]?secret|db[_-]?pass|database[_-]?password|smtp[_-]?pass|mail[_-]?pass|redis[_-]?pass|mongo[_-]?pass|mysql[_-]?pass|aws[_-]?secret|stripe[_-]?key|sendgrid|twilio|slack[_-]?token|github[_-]?token|gitlab[_-]?token|bearer|openai[_-]?key|openai[_-]?api|OPENAI_API_KEY|anthropic[_-]?key|anthropic[_-]?api|ANTHROPIC_API_KEY|claude[_-]?key|gemini[_-]?key|GOOGLE_AI_KEY|GOOGLE_API_KEY|cohere[_-]?key|COHERE_API_KEY|huggingface|HF_TOKEN|hf[_-]?api|replicate[_-]?token|REPLICATE_API_TOKEN|sk-[a-zA-Z0-9]{20,}|sk-ant-[a-zA-Z0-9]{20,}|AIza[a-zA-Z0-9_-]{35})\s*[:=]\s*.+'

for d in /var/www /home /opt /etc /root /srv; do
  [[ -d "$d" ]] && grep -rIl --include="*.php" --include="*.py" --include="*.js" \
    --include="*.rb" --include="*.yml" --include="*.yaml" --include="*.json" \
    --include="*.xml" --include="*.conf" --include="*.cfg" --include="*.ini" \
    --include="*.env" --include="*.sh" --include="*.toml" \
    -iE "$SECRET_REGEX" "$d" 2>/dev/null | head -500 | while read -r f; do
      echo "=== FILE: $f ===" >> "$CREDFILE"
      grep -inE "$SECRET_REGEX" "$f" 2>/dev/null >> "$CREDFILE"
      echo "" >> "$CREDFILE"
  done
done

# 1f) AWS / cloud credentials
log "Collecting cloud credentials..."
for u in /root /home/*; do
  for cf in .aws/credentials .aws/config .boto .azure/credentials .config/gcloud/credentials.db \
    .kube/config .docker/config.json .terraform.d/credentials.tfrc.json; do
    [[ -f "$u/$cf" ]] && { mkdir -p "$HARVEST/creds/cloud"; cp "$u/$cf" "$HARVEST/creds/cloud/$(basename "$u")_$(basename "$cf")" 2>/dev/null; }
  done
done

# 1g) Database credentials from running processes
log "Extracting credentials from process cmdlines..."
ps auxwwe 2>/dev/null | grep -iE '(password|passwd|pass=|secret|token|key=|dsn=)' > "$HARVEST/creds/process_secrets.txt" 2>/dev/null || true

# 1h) Crontabs
log "Collecting all crontabs..."
for u in $(cut -d: -f1 /etc/passwd); do
  crontab -l -u "$u" > "$HARVEST/crontabs/${u}_crontab.txt" 2>/dev/null || true
done
cp -r /etc/cron.* "$HARVEST/crontabs/" 2>/dev/null || true
cp /var/spool/cron/crontabs/* "$HARVEST/crontabs/" 2>/dev/null || true

# 1i) Network state
log "Capturing network state..."
ss -tulnp > "$HARVEST/network/listening_ports.txt" 2>/dev/null || true
ss -anp > "$HARVEST/network/all_connections.txt" 2>/dev/null || true
iptables-save > "$HARVEST/network/iptables_rules.txt" 2>/dev/null || true
ip a > "$HARVEST/network/interfaces.txt" 2>/dev/null || true
cat /etc/resolv.conf > "$HARVEST/network/resolv.conf" 2>/dev/null || true

# 1j) Running processes
log "Snapshotting all processes..."
ps auxwwf > "$HARVEST/processes/ps_tree.txt" 2>/dev/null || true
ls -la /proc/*/exe 2>/dev/null | grep -v "Permission denied" > "$HARVEST/processes/proc_exe_links.txt" 2>/dev/null || true

# 1k) Systemd & init persistence
log "Collecting systemd units and rc.local..."
cp /etc/rc.local "$HARVEST/systemd/" 2>/dev/null || true
find /etc/systemd/system /usr/lib/systemd/system /run/systemd/system -maxdepth 2 -name "*.service" -newer /var/log/syslog 2>/dev/null \
  -exec cp --parents -t "$HARVEST/systemd/" {} \; 2>/dev/null || true
systemctl list-units --type=service --all > "$HARVEST/systemd/all_services.txt" 2>/dev/null || true
systemctl list-timers --all > "$HARVEST/systemd/all_timers.txt" 2>/dev/null || true

# 1l) Kernel modules
log "Listing loaded kernel modules..."
lsmod > "$HARVEST/misc/lsmod.txt" 2>/dev/null || true

# 1m) LD_PRELOAD
log "Checking LD_PRELOAD..."
cat /etc/ld.so.preload > "$HARVEST/misc/ld_so_preload.txt" 2>/dev/null || true
env | grep -i ld_preload > "$HARVEST/misc/env_ld_preload.txt" 2>/dev/null || true

# 1n) PAM config
log "Backing up PAM configs..."
cp -r /etc/pam.d "$HARVEST/misc/pam.d" 2>/dev/null || true

# 1o) SUID/SGID binaries
log "Finding SUID/SGID binaries..."
find / -perm -4000 -type f 2>/dev/null > "$HARVEST/misc/suid_bins.txt"
find / -perm -2000 -type f 2>/dev/null > "$HARVEST/misc/sgid_bins.txt"

# 1p) World-writable files in sensitive dirs
log "Finding world-writable files..."
find /etc /usr/bin /usr/sbin /usr/lib -writable -type f 2>/dev/null > "$HARVEST/misc/world_writable.txt" || true

# 1q) Recently modified files (last 7 days)
log "Finding recently modified files in system dirs..."
find /usr/bin /usr/sbin /usr/lib /etc -mtime -7 -type f 2>/dev/null > "$HARVEST/misc/recently_modified.txt" || true

log "Harvest complete → $HARVEST"

###############################################################################
# PHASE 2 — IMMUNIZE MESSAGEBUS USER
###############################################################################
section "PHASE 2: IMMUNIZING MESSAGEBUS USER"

if id messagebus &>/dev/null; then
  log "Locking messagebus account..."
  usermod -s /usr/sbin/nologin messagebus 2>/dev/null || true
  passwd -l messagebus 2>/dev/null || true

  log "Removing messagebus crontab..."
  crontab -r -u messagebus 2>/dev/null || true

  log "Making messagebus crontab immutable..."
  MBCRON="/var/spool/cron/crontabs/messagebus"
  touch "$MBCRON" 2>/dev/null || true
  chmod 000 "$MBCRON" 2>/dev/null || true
  chattr +i "$MBCRON" 2>/dev/null || true

  log "Killing any processes running as messagebus (except dbus-daemon)..."
  pgrep -u messagebus 2>/dev/null | while read -r pid; do
    PNAME=$(cat /proc/$pid/comm 2>/dev/null || echo "")
    if [[ "$PNAME" != "dbus-daemon" && "$PNAME" != "dbus-broker" ]]; then
      warn "Killing suspicious messagebus process: PID=$pid ($PNAME)"
      kill -9 "$pid" 2>/dev/null || true
    fi
  done

  log "Removing messagebus from sudo/admin groups..."
  for grp in sudo wheel adm admin; do
    gpasswd -d messagebus "$grp" 2>/dev/null || true
  done

  log "messagebus immunized ✓"
else
  info "messagebus user not found — skipping"
fi

###############################################################################
# PHASE 3 — CLEAN BLACK HAT PERSISTENCE
###############################################################################
section "PHASE 3: CLEANING BLACK HAT PERSISTENCE"

# 3a) Clean /tmp /var/tmp /dev/shm
log "Cleaning temp directories..."
for d in /tmp /var/tmp /dev/shm; do
  [[ -d "$d" ]] || continue

  # Kill processes running from temp dirs
  find "$d" -type f -executable 2>/dev/null | while read -r f; do
    fuser "$f" 2>/dev/null | tr ' ' '\n' | while read -r pid; do
      [[ -n "$pid" ]] && { warn "Killing process $pid running from $f"; kill -9 "$pid" 2>/dev/null || true; }
    done
  done

  # Remove hidden files and executables (skip system sockets)
  find "$d" -maxdepth 3 -name ".*" -type f -delete 2>/dev/null || true
  find "$d" -maxdepth 3 -type f -executable -delete 2>/dev/null || true
  find "$d" -maxdepth 3 -name "*.sh" -type f -delete 2>/dev/null || true

  log "Cleaned $d"
done

# 3b) LD_PRELOAD hook removal
if [[ -f /etc/ld.so.preload ]]; then
  if [[ -s /etc/ld.so.preload ]]; then
    warn "Non-empty /etc/ld.so.preload found! Backing up and clearing..."
    cp /etc/ld.so.preload "$HARVEST/misc/ld_so_preload_backup.txt"
    : > /etc/ld.so.preload
    log "ld.so.preload cleared"
  fi
fi

# 3c) Suspicious crontab entries
log "Auditing crontabs for suspicious entries..."
SUSP_PATTERNS='(wget|curl|nc |ncat|bash -i|python.*socket|perl.*socket|xmrig|minergate|kinsing|kdevtmpfsi|ld\.so\.preload|/tmp/|/dev/shm/|/var/tmp/|\|bash|\|sh|base64|eval|exec\()'

for u in $(cut -d: -f1 /etc/passwd); do
  CTAB=$(crontab -l -u "$u" 2>/dev/null) || continue
  if echo "$CTAB" | grep -qiE "$SUSP_PATTERNS"; then
    warn "Suspicious crontab found for user: $u"
    echo "$CTAB" > "$HARVEST/crontabs/${u}_suspicious_backup.txt"
    echo "$CTAB" | sed -E "s/^(.*($(echo "$SUSP_PATTERNS" | sed 's/[()]/\\&/g')).*)$/# DISABLED_BY_CLEANER: \1/I" | crontab -u "$u" - 2>/dev/null
    log "Suspicious entries commented out for $u"
  fi
done

# System cron dirs
for crondir in /etc/cron.d /etc/cron.daily /etc/cron.hourly /etc/cron.weekly /etc/cron.monthly; do
  [[ -d "$crondir" ]] || continue
  find "$crondir" -type f | while read -r f; do
    if grep -qiE "$SUSP_PATTERNS" "$f" 2>/dev/null; then
      warn "Suspicious system cron: $f"
      cp "$f" "$HARVEST/crontabs/sys_$(basename "$f")_backup"
      sed -i -E "s/^(.*(wget|curl|nc |xmrig|kinsing|kdevtmpfsi|base64).*)$/# DISABLED_BY_CLEANER: \1/I" "$f"
    fi
  done
done

# 3d) Suspicious systemd services
log "Checking for suspicious systemd services..."
SUSP_SERVICES='(crypto|miner|xmrig|kinsing|kdevtmpfsi|botnet|ddos|scan)'
systemctl list-unit-files --type=service 2>/dev/null | grep -iE "$SUSP_SERVICES" | awk '{print $1}' | while read -r svc; do
  warn "Suspicious service found: $svc"
  systemctl stop "$svc" 2>/dev/null || true
  systemctl disable "$svc" 2>/dev/null || true
  log "Stopped & disabled: $svc"
done

# 3e) Kill known malware processes
log "Hunting known malware processes..."
MALWARE_NAMES='(xmrig|kinsing|kdevtmpfsi|kthreaddk|dbused|sysguard|bioset|ksoftirqds|watchdogs|kerberods|sysupdate|networkservice|\.rsync|cryptonight|minerd|cpuminer)'
ps aux 2>/dev/null | grep -iE "$MALWARE_NAMES" | grep -v grep | awk '{print $2}' | while read -r pid; do
  PNAME=$(cat /proc/$pid/comm 2>/dev/null || echo "unknown")
  warn "Killing malware process: PID=$pid ($PNAME)"
  kill -9 "$pid" 2>/dev/null || true
done

# 3f) Remove unauthorized SSH keys (backup first — don't delete root's)
log "Auditing authorized_keys files..."
while IFS=: read -r user _ _ _ _ home _; do
  AK="$home/.ssh/authorized_keys"
  [[ -f "$AK" ]] || continue
  # Already backed up in harvest phase
  NKEYS=$(wc -l < "$AK" 2>/dev/null || echo 0)
  if [[ "$NKEYS" -gt 0 ]]; then
    info "  $user: $NKEYS key(s) in authorized_keys — backed up to harvest (NOT deleted)"
  fi
done < /etc/passwd

# 3g) Remove immutable attributes from common attack targets
log "Removing immutable attrs from common attack paths..."
for f in /tmp/.* /var/tmp/.* /dev/shm/.* /etc/cron.d/* /var/spool/cron/crontabs/*; do
  [[ -e "$f" ]] && chattr -i "$f" 2>/dev/null || true
done
# Re-set immutable on messagebus crontab
[[ -f "/var/spool/cron/crontabs/messagebus" ]] && chattr +i "/var/spool/cron/crontabs/messagebus" 2>/dev/null || true

# 3h) Check /etc/profile.d and bashrc for injections
log "Checking shell profile injections..."
for f in /etc/profile.d/*.sh /etc/bash.bashrc /etc/profile; do
  [[ -f "$f" ]] || continue
  if grep -qiE '(wget|curl|nc |python.*socket|bash -i|/tmp/|/dev/shm/|base64)' "$f" 2>/dev/null; then
    warn "Suspicious content in $f"
    cp "$f" "$HARVEST/misc/profile_$(basename "$f")_backup"
    sed -i -E "s/^(.*(wget|curl|nc |python.*socket|bash -i|base64).*)$/# DISABLED_BY_CLEANER: \1/I" "$f"
  fi
done

# 3i) Check for rogue users with UID 0
log "Checking for rogue UID-0 users..."
awk -F: '$3 == 0 && $1 != "root" {print $1}' /etc/passwd | while read -r rogue; do
  warn "ROGUE UID-0 USER: $rogue — logged to harvest (manual removal recommended)"
  echo "ROGUE UID-0: $rogue" >> "$HARVEST/users/rogue_uid0.txt"
done

# 3j) Check for users with empty passwords
log "Checking for empty passwords..."
awk -F: '($2 == "" || $2 == "!") && $1 != "messagebus" {print $1}' /etc/shadow 2>/dev/null > "$HARVEST/users/empty_passwords.txt" || true

###############################################################################
# PHASE 4 — SSH PRESERVATION CHECK (READ-ONLY — NO CHANGES)
###############################################################################
section "PHASE 4: SSH ACCESS VERIFICATION (READ-ONLY)"

SSHD_CFG="/etc/ssh/sshd_config"
if [[ -f "$SSHD_CFG" ]]; then
  log "Backing up sshd_config (NO modifications will be made)..."
  cp "$SSHD_CFG" "$HARVEST/misc/sshd_config_backup"

  # Just report status
  PA=$(grep -i "^PasswordAuthentication" "$SSHD_CFG" 2>/dev/null | tail -1 || echo "not set")
  PRL=$(grep -i "^PermitRootLogin" "$SSHD_CFG" 2>/dev/null | tail -1 || echo "not set")
  info "PasswordAuthentication: $PA"
  info "PermitRootLogin: $PRL"
  log "SSH config left UNTOUCHED — your connection is safe ✓"
else
  warn "sshd_config not found at $SSHD_CFG"
fi

###############################################################################
# PHASE 5 — SUMMARY REPORT
###############################################################################
section "PHASE 5: GENERATING SUMMARY REPORT"

# Print summary to stdout only — no log files left on server
echo -e "${C}"
cat <<REPORTEOF
═══════════════════════════════════════════════════════════════
  SERVER CLEANER — SUMMARY
  $(date) | $(hostname) | $(uname -r)
═══════════════════════════════════════════════════════════════

  Secrets found:     $(wc -l < "$CREDFILE" 2>/dev/null || echo 0) lines
  SSH keys:          $(find "$HARVEST/ssh_keys" -type f 2>/dev/null | wc -l) files
  Config files:      $(find "$HARVEST/configs" -type f 2>/dev/null | wc -l) files
  Histories:         $(find "$HARVEST/histories" -type f 2>/dev/null | wc -l) files
  messagebus:        immunized
  SSH password login: preserved (config untouched)
  Harvest dir:       $HARVEST

═══════════════════════════════════════════════════════════════
REPORTEOF
echo -e "${N}"
