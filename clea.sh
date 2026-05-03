#!/bin/bash
# Advanced Server Recovery & Hardening Script

# 1. STOP THE BLEEDING: High-Resource & Suspicious Processes
echo "[*] Killing suspicious processes..."
# Kill anything using >60% CPU (excluding common system heavyweights)
ps -eo pid,%cpu,comm --sort=-%cpu | awk '$2 > 60.0 && $3 !~ /(Xorg|node|java|mysql|php-fpm|apache2|nginx)/ {print $1}' | xargs -r kill -9
# Kill processes running from common malware landing zones (/tmp, /dev/shm)
ls -alR /proc/*/exe 2>/dev/null | grep -E "tmp|dev|shm" | awk '{print $NF}' | xargs -r kill -9

# 2. NEUTRALIZE PERSISTENCE: The "Undead" Check
echo "[*] Cleaning all persistence locations..."
# Clear standard crontabs and systemd timers often used by miners
truncate -s 0 /etc/crontab
rm -rf /var/spool/cron/* /etc/cron.d/*
# Search for and disable suspicious systemd services with curl/wget/mining keywords
grep -rE "http|curl|wget|xmrig|miner" /etc/systemd/system/ /lib/systemd/system/ | cut -d: -f1 | xargs -r rm -f
systemctl daemon-reload

# 3. FORCED USER PURGE: Identity Reclaim
echo "[*] Purging unauthorized users..."
# Automatically remove users with UID >= 1000 who aren't you or 'nobody'
CURRENT_USER=$(whoami)
awk -F: -v cur="$CURRENT_USER" '$3 >= 1000 && $1 != cur && $1 != "nobody" {print $1}' /etc/passwd | while read -r user; do
    pkill -u "$user"
    userdel -f -r "$user" 2>/dev/null
done
# Lock out all unauthorized SSH access
if [ -f /root/.ssh/authorized_keys ]; then
    mv /root/.ssh/authorized_keys /root/.ssh/authorized_keys.old_compromised
    touch /root/.ssh/authorized_keys
    chmod 600 /root/.ssh/authorized_keys
fi

# 4. FILE SYSTEM CLEANUP: Hidden Payloads
echo "[*] Deleting hidden malware artifacts..."
find /tmp /var/tmp /dev/shm -type f -name ".*" -delete
# Check for immutable files (often used by rootkits to prevent deletion)
lsattr -R /etc /bin /usr/bin 2>/dev/null | grep "\-i\-" | awk '{print $2}' | xargs -r chattr -i

# 5. DEEP HEALTH & SPECS SNAPSHOT
echo -e "\n--- [ SYSTEM HEALTH & SPECS ] ---"
echo "CPU Load: $(uptime | awk -F'load average:' '{print $2}')"
echo "RAM (Free/Used): $(free -h | awk '/Mem:/ {print $4 "/" $3}')"
echo "Active Connections (Unknown IPs):"
ss -tunp | grep ESTAB | awk '{print $5}' | cut -d: -f1 | sort | uniq -c

echo -e "\nCRITICAL: You MUST change all passwords (passwd root) and rotate SSH keys now."
