#!/bin/bash

# Exit on error
set -e

# Default settings for Oh My Zsh installer
RUNZSH=${RUNZSH:-no}
CHSH=${CHSH:-no}
KEEP_ZSHRC=${KEEP_ZSHRC:-yes}

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
if [ ! -s "/home/$NEW_USER/.ssh/authorized_keys" ]; then
    sudo cp /root/.ssh/authorized_keys "/home/$NEW_USER/.ssh/authorized_keys"
fi
sudo chown -R "$NEW_USER:$NEW_USER" "/home/$NEW_USER/.ssh"
sudo chmod 700 "/home/$NEW_USER/.ssh"
sudo chmod 600 "/home/$NEW_USER/.ssh/authorized_keys"

# Secure SSH Daemon
# 1. Disable password authentication
# 2. Disable root password login (prohibit-password allows keys only)
# 3. Disable empty passwords (even though we are using keys)
set_ssh_config() {
    local param="$1"
    local value="$2"
    if grep -qE "^#?${param}[[:space:]]" /etc/ssh/sshd_config; then
        sudo sed -i "s/^#\?${param}[[:space:]].*/${param} ${value}/" /etc/ssh/sshd_config
    else
        echo "${param} ${value}" | sudo tee -a /etc/ssh/sshd_config >/dev/null
    fi
}

set_ssh_config "PasswordAuthentication" "no"
set_ssh_config "PermitRootLogin" "prohibit-password"
set_ssh_config "PubkeyAuthentication" "yes"

# Lock root password (deletes password, keys still work)
sudo passwd -l root

sudo systemctl restart ssh

# 6. Oh My Zsh & ZSH Themes
echo "--- 🐚 Configuring ZSH ---"
# Move to /tmp to avoid "can't cd to /root" error when running as another user.
cd /tmp

# Function to configure Oh My Zsh for a user
setup_omz() {
    local target_user="$1"
    local target_home="$2"
    local theme="$3"

    echo "Installing Oh My Zsh for $target_user..."
    if [ "$target_user" = "root" ]; then
        env HOME="$target_home" USER="$target_user" RUNZSH="$RUNZSH" CHSH="$CHSH" KEEP_ZSHRC="$KEEP_ZSHRC" \
            sh -c 'curl -fsSL https://raw.githubusercontent.com/ohmyzsh/ohmyzsh/master/tools/install.sh | sh' || true
    else
        sudo -u "$target_user" env HOME="$target_home" USER="$target_user" RUNZSH="$RUNZSH" CHSH="$CHSH" KEEP_ZSHRC="$KEEP_ZSHRC" \
            sh -c 'curl -fsSL https://raw.githubusercontent.com/ohmyzsh/ohmyzsh/master/tools/install.sh | sh' || true
    fi

    if [ -f "$target_home/.zshrc" ]; then
        if [ -z "$theme" ]; then
            sudo sed -i 's/ZSH_THEME=".*"/ZSH_THEME=""/' "$target_home/.zshrc"
        else
            sudo sed -i "s/ZSH_THEME=\".*\"/ZSH_THEME=\"$theme\"/" "$target_home/.zshrc"
        fi
        
        # Ensure plugins are defined before sourcing Oh My Zsh to avoid warnings.
        if awk '/^source .*oh-my-zsh\.sh/{print NR; exit}' "$target_home/.zshrc" >/tmp/omz_source_line \
            && awk '/^plugins=/{print NR; exit}' "$target_home/.zshrc" >/tmp/omz_plugins_line; then
            SOURCE_LINE="$(cat /tmp/omz_source_line)"
            PLUGINS_LINE="$(cat /tmp/omz_plugins_line)"
            if [ -n "$SOURCE_LINE" ] && [ -n "$PLUGINS_LINE" ] && [ "$PLUGINS_LINE" -gt "$SOURCE_LINE" ]; then
                awk '
                    /^plugins=/{plugins=$0; next}
                    /^source .*oh-my-zsh\.sh/{
                        if (plugins != "") print plugins
                        print
                        next
                    }
                    {print}
                    END{if (plugins != "") print plugins}
                ' "$target_home/.zshrc" | sudo tee "$target_home/.zshrc.tmp" >/dev/null
                sudo mv "$target_home/.zshrc.tmp" "$target_home/.zshrc"
            fi
        fi
    else
        cat <<EOF | sudo tee "$target_home/.zshrc" >/dev/null
export ZSH="\$HOME/.oh-my-zsh"
ZSH_THEME="$theme"
plugins=(git)

source "\$ZSH/oh-my-zsh.sh"
EOF
    fi

    # Add useful aliases
    if ! grep -q "# SLY.TEAM Aliases" "$target_home/.zshrc"; then
        cat <<EOF | sudo tee -a "$target_home/.zshrc" >/dev/null

# SLY.TEAM Aliases
alias ll='ls -lah'
alias update='sudo apt update && sudo apt upgrade -y'
alias myip='curl ifconfig.me'
EOF
    fi
    
    sudo chown -R "$target_user:$target_user" "$target_home/.oh-my-zsh" || true
    sudo chown "$target_user:$target_user" "$target_home/.zshrc" || true
}

# Setup for root
setup_omz "root" "/root" "bira"

# Setup for new user
setup_omz "$NEW_USER" "/home/$NEW_USER" "$ZSH_THEME_CHOICE"

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
