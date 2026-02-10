#!/bin/bash

# Memo: Prepares a fresh VPS (hostname, user, SSH hardening, packages, UFW).
# Exit on error
set -e

echo "Secure VPS setup starting..."
echo "--- 🚀 Starting Secure VPS Preparation ---"

# 1. Gather Information
prompt_var() {
    local prompt="$1"
    local __var_name="$2"

    if [ -t 0 ]; then
        read -r -p "$prompt" "$__var_name"
    elif [ -t 1 ] && [ -e /dev/tty ]; then
        read -r -p "$prompt" "$__var_name" </dev/tty
    else
        echo "ERROR: No TTY available for prompts. Run this script in an interactive shell." >&2
        exit 1
    fi
}

prompt_var "Enter the domain/hostname for this VPS: " MY_DOMAIN
prompt_var "Enter the username for the new sudo user: " NEW_USER
echo ""

# 2. Hostname Configuration
echo "--- 🛠 Configuring Hostname ---"
hostnamectl set-hostname "$MY_DOMAIN"
echo "127.0.1.1 $MY_DOMAIN $(hostname -s)" | sudo tee -a /etc/hosts

# 3. System Upgrade
echo "--- 🔄 Upgrading Packages ---"
export DEBIAN_FRONTEND=noninteractive
sudo apt-get update && sudo apt-get upgrade -y
sudo apt-get install -y zsh curl git ufw fail2ban htop wget chrony

# 4. User Creation & Passwordless Sudo
echo "--- 👤 Setting up User: $NEW_USER ---"
if id "$NEW_USER" &>/dev/null; then
    echo "User already exists."
else
    # Create user with no password requirement for sudo
    sudo useradd -m -s $(which zsh) -G sudo "$NEW_USER"
    # Disable password for the user entirely
    sudo passwd -d "$NEW_USER"
fi

# Enable passwordless sudo for this specific user
echo "$NEW_USER ALL=(ALL) NOPASSWD:ALL" | sudo tee "/etc/sudoers.d/$NEW_USER"

# 5. SSH Key Validation & Security
echo "--- 🔑 Configuring SSH Key-Based Auth ---"

# Ensure root has an authorized_keys file
if [ ! -f /root/.ssh/authorized_keys ] || [ ! -s /root/.ssh/authorized_keys ]; then
    echo "❌ ERROR: No SSH keys found in /root/.ssh/authorized_keys!"
    echo "Please add your public key to /root/.ssh/authorized_keys BEFORE running this script."
    exit 1
fi

# Setup keys for the new user
sudo mkdir -p "/home/$NEW_USER/.ssh"
sudo cp /root/.ssh/authorized_keys "/home/$NEW_USER/.ssh/authorized_keys"
sudo chown -R "$NEW_USER:$NEW_USER" "/home/$NEW_USER/.ssh"
sudo chmod 700 "/home/$NEW_USER/.ssh"
sudo chmod 600 "/home/$NEW_USER/.ssh/authorized_keys"

# Secure SSH Daemon
# 1. Disable password authentication
# 2. Disable root password login (prohibit-password allows keys only)
# 3. Disable empty passwords (even though we are using keys)
sudo sed -i 's/#\{0,1\}PasswordAuthentication yes/PasswordAuthentication no/g' /etc/ssh/sshd_config
sudo sed -i 's/PasswordAuthentication yes/PasswordAuthentication no/g' /etc/ssh/sshd_config
sudo sed -i 's/#\{0,1\}PermitRootLogin.*/PermitRootLogin prohibit-password/g' /etc/ssh/sshd_config
sudo sed -i 's/#\{0,1\}PubkeyAuthentication.*/PubkeyAuthentication yes/g' /etc/ssh/sshd_config

# Lock root password (deletes password, keys still work)
sudo passwd -l root

sudo systemctl restart ssh

# 6. Oh My Zsh & Cypher Theme
echo "--- 🐚 Configuring ZSH (Cypher Theme) ---"
sudo -u "$NEW_USER" sh -c "$(curl -fsSL https://raw.githubusercontent.com/ohmyzsh/ohmyzsh/master/tools/install.sh)" "" --unattended || true
sudo sed -i 's/ZSH_THEME=".*"/ZSH_THEME="cypher"/' "/home/$NEW_USER/.zshrc"

# Add useful aliases
cat <<EOF | sudo tee -a "/home/$NEW_USER/.zshrc"
alias ll='ls -lah'
alias update='sudo apt update && sudo apt upgrade -y'
alias myip='curl ifconfig.me'
EOF

# 7. Security (UFW)
echo "--- 🛡 Enabling Firewall ---"
sudo ufw allow 22/tcp
sudo ufw --force enable

echo "------------------------------------------------------"
echo "✅ Setup Complete!"
echo "Hostname: $(hostname)"
echo "User: $NEW_USER (can use sudo without password)"
echo "Root: Password locked (SSH Key only)"
echo "SSH: Password authentication DISABLED"
echo "------------------------------------------------------"
echo "Try to log in as: ssh $NEW_USER@$MY_DOMAIN"
