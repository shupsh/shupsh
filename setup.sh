#!/bin/bash

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
prompt_var "Enter ZSH theme (default: cypher, use 'none' for no theme): " ZSH_THEME_CHOICE
if [ -z "$ZSH_THEME_CHOICE" ]; then
    ZSH_THEME_CHOICE="cypher"
elif [ "$ZSH_THEME_CHOICE" = "none" ]; then
    ZSH_THEME_CHOICE=""
fi
echo ""

# 2. Hostname Configuration
echo "--- 🛠 Configuring Hostname ---"
hostnamectl set-hostname "$MY_DOMAIN"
# Ensure hostname resolves locally even if DNS is not set up yet.
if [ -w /etc/hosts ]; then
    if grep -q '^127\.0\.1\.1' /etc/hosts; then
        sed -i "s/^127\.0\.1\.1.*/127.0.1.1 $MY_DOMAIN $(hostname -s)/" /etc/hosts
    else
        echo "127.0.1.1 $MY_DOMAIN $(hostname -s)" >> /etc/hosts
    fi
else
    if sudo grep -q '^127\.0\.1\.1' /etc/hosts; then
        sudo sed -i "s/^127\.0\.1\.1.*/127.0.1.1 $MY_DOMAIN $(hostname -s)/" /etc/hosts
    else
        echo "127.0.1.1 $MY_DOMAIN $(hostname -s)" | sudo tee -a /etc/hosts >/dev/null
    fi
fi

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
# Ensure HOME is set for the target user so Oh My Zsh installs in the right place.
sudo -u "$NEW_USER" -H sh -c "$(curl -fsSL https://raw.githubusercontent.com/ohmyzsh/ohmyzsh/master/tools/install.sh)" "" --unattended || true
if [ -f "/home/$NEW_USER/.zshrc" ]; then
    if [ -z "$ZSH_THEME_CHOICE" ]; then
        sudo sed -i 's/ZSH_THEME=".*"/ZSH_THEME=""/' "/home/$NEW_USER/.zshrc"
    else
        sudo sed -i "s/ZSH_THEME=\".*\"/ZSH_THEME=\"$ZSH_THEME_CHOICE\"/" "/home/$NEW_USER/.zshrc"
    fi
else
    sudo tee "/home/$NEW_USER/.zshrc" >/dev/null <<'EOF'
export ZSH="$HOME/.oh-my-zsh"
ZSH_THEME=""
plugins=(git)

source "$ZSH/oh-my-zsh.sh"
EOF
    if [ -n "$ZSH_THEME_CHOICE" ]; then
        sudo sed -i "s/ZSH_THEME=\"\"/ZSH_THEME=\"$ZSH_THEME_CHOICE\"/" "/home/$NEW_USER/.zshrc"
    fi
    sudo chown "$NEW_USER:$NEW_USER" "/home/$NEW_USER/.zshrc"
fi

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
