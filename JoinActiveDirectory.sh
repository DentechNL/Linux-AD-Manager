#
# Author:       Daniël van Ginneken <daniel@dentech.nl>
# Date:         Wednesday Dec 04 11:12:43 2024
#
# Note:         To debug the script change the shebang to: /usr/bin/env bash -vx
#
# Prerequisite: This release needs a shell that could handle functions.
#
# Purpose:      Install / Config script for connecting a Linux server to Active Directory domain
#

#!/usr/bin/env bash
# Define log file for tracking progress
LOG_FILE="/var/log/AD_join_script.log"

# Function to log messages with timestamp
log_message() {
    local message=$1
    local date_time=$(date '+%Y-%m-%d %H:%M:%S')
    
    # Log message to file with timestamp
    echo "$date_time - $message" >> $LOG_FILE
    
    # Print message to terminal without timestamp
    echo "$message"
}

# Function to exit with error message and code
exit_with_error() {
    local message=$1
    log_message "ERROR: $message"
    exit 1
}

# Function to ask for user input with validation
get_user_input() {
    local prompt=$1
    local var_name=$2
    while true; do
        read -p "$prompt: " $var_name
        if [[ -z "${!var_name}" ]]; then
            echo "Input cannot be empty. Please provide a valid value."
        else
            break
        fi
    done
}

# Check if a command was successful
check_command() {
    local command=$1
    local error_message=$2
    if ! eval $command; then
        exit_with_error "$error_message"
    fi
}

# Welcome message
log_message "==============================="
log_message "Starting Linux Active Directory Connector"
log_message "==============================="
echo "Starting Linux Active Directory Connector... Please follow the instructions."
log_message "Script initiated."

# Step 1: Update system
log_message "Updating system packages..."
check_command "apt update && apt upgrade -y" "System update failed."

# Step 2: Install required packages
log_message "Installing required packages..."
check_command "apt install -y realmd sssd-tools sssd-ad adcli" "Package installation failed."

# Step 3: Check if DNS configuration is required
get_user_input "Do you need to configure the DNS staticly? (y/n)" configure_dns

if [[ "$configure_dns" == "y" ]]; then
    get_user_input "Enter AD DNS server IP" ADIP
    log_message "Configuring DNS with IP: $ADIP..."
    
    # Overwrite /etc/resolv.conf with the new DNS entry
    echo "nameserver $ADIP" > /etc/resolv.conf
    check_command "echo 'nameserver $ADIP' > /etc/resolv.conf" "Failed to configure DNS in /etc/resolv.conf."
    
    # Only run ping if DNS IP is provided
    log_message "Pinging DNS server to test connectivity..."
    if ! ping -c 5 $ADIP; then
        exit_with_error "DNS server $ADIP is not reachable. Please check the IP and network connectivity."
    fi
else
    log_message "DNS configuration skipped."
fi

# Step 4: Discover the realm
get_user_input "Enter the domain (e.g., example.com)" domain
log_message "Discovering the realm: $domain..."
check_command "realm -v discover $domain" "Failed to discover the realm: $domain."

# Step 5: Configure Kerberos
get_user_input "Enter the realm (e.g., EXAMPLE.COM)" realm

# Log the realm input to verify it's correctly set
log_message "Configuring Kerberos with realm: $realm..."

# Check if the realm variable is not empty
if [[ -z "$realm" ]]; then
    exit_with_error "Realm is empty. Please provide a valid realm."
fi

# Backup existing /etc/krb5.conf if it exists
if [[ -f /etc/krb5.conf ]]; then
    log_message "Backing up existing /etc/krb5.conf to /etc/krb5.conf.bak"
    cp /etc/krb5.conf /etc/krb5.conf.bak >/dev/null 2>&1 || exit_with_error "Failed to back up existing /etc/krb5.conf"
fi

# Write the Kerberos configuration to /etc/krb5.conf
log_message "Writing Kerberos configuration..."
cat <<EOF | sudo tee /etc/krb5.conf >/dev/null 2>&1
[libdefaults]
    default_realm = $realm
    rdns = false
EOF

# Verify that the file was written successfully
if [[ $? -ne 0 ]]; then
    exit_with_error "Failed to write Kerberos configuration to /etc/krb5.conf"
fi

log_message "Kerberos configuration for realm $realm completed successfully."


# Step 6: Join the domain
get_user_input "Enter the admin username for joining the domain" ADMIN_USER
get_user_input "Enter the Organizational Unit (OU) for the computer object" ORGUNIT
log_message "Joining domain with admin user $ADMIN_USER..."

if ! sudo realm join --user=$ADMIN_USER $domain --computer-ou="$ORGUNIT"; then
    exit_with_error "Failed to join the domain $domain. Please check credentials and OU settings."
fi
log_message "Successfully joined the domain."

# Step 7: Verify the join
log_message "Verifying the domain join..."
check_command "realm -v discover $domain" "Failed to verify the domain join."
log_message "Domain verified successfully."

# Step 8: Restart the SSSD service
log_message "Restarting SSSD service..."
check_command "systemctl restart sssd" "Failed to restart SSSD service."
log_message "SSSD service restarted."

# Step 9: Display AD info
log_message "Fetching domain information..."
check_command "adcli info $domain" "Failed to fetch domain information."
log_message "Domain information fetched."

# Step 10: Enable PAM authentication
log_message "Enabling PAM authentication and mkhomedir..."
check_command "pam-auth-update --enable mkhomedir" "Failed to enable PAM mkhomedir."
log_message "PAM authentication and mkhomedir enabled."

# Step 11: Configure sudo access and login permissions for Active Directory users

get_user_input "Do you want to configure sudo access and login permissions? (y/n)" configure_permissions

if [[ "$configure_permissions" == "y" ]]; then
    # Prompt for sudo and login access options
    while true; do
        echo "Choose the sudo and login access configuration:"
        echo " 1) Grant sudo and login access to all domain users"
        echo " 2) Grant login access (no sudo) to all domain users"
        echo " 3) Grant sudo access to a specific AD group"
        echo " 4) No access for anyone in AD"
        read -p "Enter your choice [1-4]: " choice

        SUDOERS_FILE="/etc/sudoers.d/activedirectory"

        case $choice in
            1)
                # Grant sudo and login access to all domain users
                log_message "Granting sudo and login access to all domain users..."
                AD_GROUP="Domain Users@$DOMAIN"
                ESCAPED_GROUP=$(echo "$AD_GROUP" | sed 's/ /\\ /g')
                echo "%$ESCAPED_GROUP ALL=(ALL:ALL) ALL" | sudo tee -a $SUDOERS_FILE > /dev/null
                sudo chmod 440 $SUDOERS_FILE
                sudo realm permit --all
                log_message "Sudo and login access granted to all domain users."
                break
                ;;

            2)
                # Grant login access (no sudo) to all domain users
                log_message "Granting login access (no sudo) to all domain users..."
                sudo realm permit --all
                log_message "Login access granted to all domain users."
                break
                ;;
            3)
                # Grant sudo access to a specific AD group
                get_user_input "Enter the AD group to grant sudo and login access" AD_GROUP
                log_message "Granting sudo and login access to group: $AD_GROUP..."
                ESCAPED_GROUP=$(echo "$AD_GROUP" | sed 's/ /\\ /g')
                echo "%$ESCAPED_GROUP ALL=(ALL:ALL) ALL" | sudo tee $SUDOERS_FILE > /dev/null
                sudo chmod 440 $SUDOERS_FILE
                sudo realm permit --all
                log_message "Sudo and login access granted to group: $AD_GROUP."
                break
                ;;

            4)
                # No access for anyone in AD
                log_message "No sudo or login access granted to anyone."
                sudo realm deny --all
                break
                ;;
            *)
                echo "Invalid input. Please choose a number between 1 and 4."
                ;;
        esac
    done
else
    log_message "No sudo or login permissions configured. Skipping this step."
fi
log_message "To manually add/change/remove the allowed groups, modify /etc/sudoers.d/activedirectory"

# Completion message
log_message "==============================="
log_message "Linux Active Directory Connector Script Completed Successfully"
log_message "==============================="
echo "The Linux Active Directory Connector process has been completed successfully."

# Prompt for reboot
while true; do
    read -p "Would you like to reboot the system now? (yes/no): " REBOOT_CHOICE
    case "$REBOOT_CHOICE" in
        yes|y|YES|Y)
            log_message "Rebooting the system now..."
            reboot || { log_message "Failed to reboot the system. Please reboot manually."; exit 1; }
            break
            ;;
        no|n|NO|N)
            log_message "Please reboot the system later to apply changes."
            break
            ;;
        *)
            echo "Invalid input. Please enter 'yes' or 'no'."
            ;;
    esac
done

# Exit with success code
exit 0
