#!/bin/bash

# FileMaker Server Certificate Manager Installer
# Installs the certificate manager script and dependencies for Let's Encrypt DNS challenge
# Supports DigitalOcean, AWS Route53, and Linode DNS providers

set -euo pipefail

# Get script directory (works with symlinks and piped scripts)
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"

# Script metadata
SCRIPT_VERSION="2.0.0"
SCRIPT_NAME="FileMaker Server Certificate Manager Installer"
SCRIPT_AUTHOR="Daniel Smith"
SCRIPT_GITHUB="https://github.com/DanSmith888/simple-certificate-manager"

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
BOLD='\033[1m'
NC='\033[0m' # No Color

# Install locations. The real script is root-owned and lives outside the
# FileMaker scripts folder, so the fmserver account cannot change what it is
# allowed to run as root. FileMaker schedules call a small launcher instead.
FMS_SCRIPTS_DIR="/opt/FileMaker/FileMaker Server/Data/Scripts"
FMS_LAUNCHER="$FMS_SCRIPTS_DIR/simple-certificate-manager.sh"
INSTALLED_SCRIPT="/usr/local/sbin/simple-certificate-manager.sh"
SUDOERS_FILE="/etc/sudoers.d/90-fmserver"
SCRIPT_DOWNLOAD_URL="https://raw.githubusercontent.com/DanSmith888/simple-certificate-manager/main/simple-certificate-manager.sh"

# FileMaker Server Admin API and schedule
FMS_API="https://localhost/fmi/admin/api/v2"
SCHEDULE_NAME="Simple Certificate Manager"
SCHEDULE_CREATED=false
SCHEDULE_PARAMS=""
SCHEDULE_PARAMS_DISPLAY=""

# Private scratch directory, removed on exit
INSTALL_TMP=""

cleanup_install_tmp() {
    if [[ -n "$INSTALL_TMP" && -d "$INSTALL_TMP" ]]; then
        rm -rf "$INSTALL_TMP"
    fi
}

# Logging functions with full line coloring
log_info() {
    echo -e "${BLUE}[INFO] $1${NC}"
}

log_success() {
    echo -e "${GREEN}[SUCCESS] $1${NC}"
}

log_warn() {
    echo -e "${YELLOW}[WARN] $1${NC}"
}

log_error() {
    echo -e "${RED}[ERROR] $1${NC}" >&2
}

log_step() {
    echo -e "${CYAN}[STEP] $1${NC}"
}

log_prompt() {
    echo -e "${BOLD}[PROMPT] $1${NC}"
}

# Display welcome message
show_welcome() {
    clear
    echo -e "${BOLD}${CYAN}========================================${NC}"
    echo -e "${BOLD}${CYAN}  FileMaker Server Certificate Manager  ${NC}"
    echo -e "${BOLD}${CYAN}           Installer v$SCRIPT_VERSION           ${NC}"
    echo -e "${BOLD}${CYAN}========================================${NC}"
    echo
    echo -e "${BOLD}What this script does:${NC}"
    echo "• Installs Let's Encrypt certificate management for FileMaker Server"
    echo "• Sets up DNS challenge support for DigitalOcean, AWS Route53, or Linode"
    echo "• Downloads and configures the certificate manager script"
    echo "• Installs all required dependencies"
    echo
    echo -e "${BOLD}How to use:${NC}"
    echo "curl -fsSL https://raw.githubusercontent.com/DanSmith888/simple-certificate-manager/main/install.sh -o /tmp/install.sh && sudo bash /tmp/install.sh && rm /tmp/install.sh"
    echo
    echo -e "${YELLOW}This script will:${NC}"
    echo "1. Check system requirements"
    echo "2. Let you choose your DNS provider"
    echo "3. Test your DNS provider credentials"
    echo "4. Install all required packages"
    echo "5. Download and install the certificate manager script"
    echo
    read -r -p "Press Enter to continue or Ctrl+C to exit..."
    echo
}

# Check if running as root
check_root() {
    log_step "Checking if running as root..."
    if [[ $EUID -ne 0 ]]; then
        log_error "This script must be run as root or with sudo"
        log_error "Please run: sudo $0"
        exit 1
    fi
    log_success "Running as root"
}

# Check Ubuntu version
check_ubuntu() {
    log_step "Checking Ubuntu version..."
    if [[ -f /etc/os-release ]]; then
        . /etc/os-release
        if [[ "$ID" != "ubuntu" ]]; then
            log_error "This script only supports Ubuntu"
            log_error "Detected: $PRETTY_NAME"
            exit 1
        fi
        
        # Check if version is 22.04 or above
        if ! dpkg --compare-versions "$VERSION_ID" ge "22.04"; then
            log_error "This script requires Ubuntu 22.04 LTS or above"
            log_error "Detected: $PRETTY_NAME"
            exit 1
        fi
    else
        log_error "Cannot detect operating system"
        exit 1
    fi
    
    log_success "Detected OS: $PRETTY_NAME"
}

# Check FileMaker Server installation
check_filemaker_server() {
    log_step "Checking FileMaker Server installation..."
    if ! command -v fmsadmin &> /dev/null; then
        log_error "FileMaker Server is not installed or fmsadmin is not available"
        log_error "Please install FileMaker Server first"
        exit 1
    fi
    log_success "FileMaker Server is installed"
}

# Check fmshelper service
check_fmshelper_service() {
    log_step "Checking fmshelper service..."
    if ! systemctl is-active --quiet fmshelper; then
        log_error "fmshelper service is not running"
        log_error "Please start FileMaker Server first"
        exit 1
    fi
    log_success "fmshelper service is running"
}

# Check if FileMaker Server scripts directory exists

check_fms_scripts_directory() {
    log_step "Checking FileMaker Server scripts directory..."
    local script_dir="/opt/FileMaker/FileMaker Server/Data/Scripts"
    if [[ ! -d "$script_dir" ]]; then
        log_error "FileMaker Server scripts directory does not exist: $script_dir"
        log_error "Please ensure FileMaker Server is properly installed"
        exit 1
    fi
    log_success "FileMaker Server scripts directory found: $script_dir"
}

# DNS provider selection menu
select_dns_provider() {
    log_step "Selecting DNS provider..."
    echo
    echo "Which DNS provider do you want to use for Let's Encrypt DNS challenges?"
    echo
    echo "1) DigitalOcean"
    echo "2) AWS Route53"
    echo "3) Linode"
    echo
    while true; do
        read -r -p "Enter your choice (1-3): " choice
        case $choice in
            1)
                DNS_PROVIDER="digitalocean"
                log_success "Selected DigitalOcean DNS"
                break
                ;;
            2)
                DNS_PROVIDER="route53"
                log_success "Selected AWS Route53 DNS"
                break
                ;;
            3)
                DNS_PROVIDER="linode"
                log_success "Selected Linode DNS"
                break
                ;;
            *)
                log_error "Invalid choice. Please enter 1, 2, or 3."
                ;;
        esac
    done
}

# Get domain name
get_domain_name() {
    log_step "Getting domain name..."
    echo
    echo "Enter the fully qualified domain name for your SSL certificate."
    echo "This domain must be managed by your selected DNS provider ($DNS_PROVIDER)."
    echo
    while true; do
        read -r -p "Fully qualified domain name (e.g. filemaker.example.com): " DOMAIN_NAME
        if [[ -n "$DOMAIN_NAME" ]] && [[ "$DOMAIN_NAME" =~ ^[a-zA-Z0-9][a-zA-Z0-9.-]*[a-zA-Z0-9]$ ]]; then
            log_success "Domain name: $DOMAIN_NAME"
            break
        else
            log_error "Invalid domain name. Please enter a valid domain (e.g. filemaker.example.com)"
        fi
    done
}

# Prompt for a secret without showing it. $1 is the label, $2 the variable to set.
prompt_secret() {
    local label="$1"
    local var_name="$2"
    local value=""

    while true; do
        if [[ -n "${!var_name:-}" ]]; then
            read -r -s -p "$label (input hidden, press Enter to keep the current value): " value
            echo
            value="${value:-${!var_name}}"
        else
            read -r -s -p "$label (input hidden): " value
            echo
        fi
        if [[ -n "$value" ]]; then
            printf -v "$var_name" '%s' "$value"
            return 0
        fi
        log_error "$label cannot be empty"
    done
}

# Get DNS provider credentials
get_dns_credentials() {
    log_step "Getting DNS provider credentials..."
    echo
    echo "You need to provide credentials for $DNS_PROVIDER."
    echo "Make sure you have configured the appropriate access tokens or IAM policies. See README.md for more information."
    echo

    case "$DNS_PROVIDER" in
        "digitalocean")
            echo "For DigitalOcean, you need an API token with DNS read/write permissions."
            echo "Create one at: https://cloud.digitalocean.com/account/api/tokens"
            echo
            prompt_secret "DigitalOcean API Token" DO_TOKEN
            log_success "DigitalOcean token provided"
            ;;
        "route53")
            echo "For AWS Route53, you need an IAM user with Route53 permissions."
            echo "Required permissions: route53:ChangeResourceRecordSets, route53:GetChange, route53:ListHostedZones"
            echo
            while true; do
                if [[ -n "${AWS_ACCESS_KEY_ID:-}" ]]; then
                    read -r -p "AWS Access Key ID [$AWS_ACCESS_KEY_ID]: " input_key
                    AWS_ACCESS_KEY_ID="${input_key:-$AWS_ACCESS_KEY_ID}"
                else
                    read -r -p "AWS Access Key ID: " AWS_ACCESS_KEY_ID
                fi
                if [[ -n "$AWS_ACCESS_KEY_ID" ]]; then
                    break
                else
                    log_error "Access Key ID cannot be empty"
                fi
            done
            prompt_secret "AWS Secret Access Key" AWS_SECRET_ACCESS_KEY
            log_success "AWS credentials provided"
            ;;
        "linode")
            echo "For Linode, you need an API token with DNS read/write permissions."
            echo "Create one at: https://cloud.linode.com/profile/tokens"
            echo
            prompt_secret "Linode API Token" LINODE_TOKEN
            log_success "Linode token provided"
            ;;
    esac
}

# Test DNS provider
test_dns_provider() {
    log_step "Testing $DNS_PROVIDER DNS access..."
    echo
    echo "This will test your DNS credentials using certbot --dry-run:"
    echo "• Creates a test TXT record for: $DOMAIN_NAME"
    echo "• Verifies DNS challenge works with your provider"
    echo "• No certificates created, no files left behind"
    echo
    read -r -p "Continue with DNS test? (y/N): " confirm
    if [[ "$confirm" != "y" && "$confirm" != "Y" ]]; then
        log_warn "Skipping DNS test"
        return 0
    fi

    if [[ -z "$INSTALL_TMP" || ! -d "$INSTALL_TMP" ]]; then
        log_error "Installer scratch directory is missing"
        exit 1
    fi

    # Everything for the test lives in the installer's private scratch directory
    local test_dir="$INSTALL_TMP/dns-test"
    local temp_creds="$test_dir/credentials.ini"
    rm -rf "$test_dir"
    mkdir -p "$test_dir"

    local -a certbot_cmd=(certbot certonly)
    case "$DNS_PROVIDER" in
        "digitalocean")
            printf 'dns_digitalocean_token = %s\n' "$DO_TOKEN" > "$temp_creds"
            chmod 600 "$temp_creds"
            certbot_cmd+=(--dns-digitalocean --dns-digitalocean-credentials "$temp_creds")
            ;;
        "linode")
            printf 'dns_linode_key = %s\n' "$LINODE_TOKEN" > "$temp_creds"
            chmod 600 "$temp_creds"
            certbot_cmd+=(--dns-linode --dns-linode-credentials "$temp_creds")
            ;;
        "route53")
            # The Route53 plugin reads its credentials from the environment
            export AWS_ACCESS_KEY_ID AWS_SECRET_ACCESS_KEY
            certbot_cmd+=(--dns-route53)
            ;;
    esac

    certbot_cmd+=(
        --agree-tos --non-interactive --dry-run
        --email "test@$DOMAIN_NAME" -d "$DOMAIN_NAME"
        --config-dir "$test_dir/certbot"
        --work-dir "$test_dir/certbot"
        --logs-dir "$test_dir/certbot"
    )

    # Execute test with live output
    log_info "Running certbot DNS challenge test..."
    echo

    local certbot_exit_code=0
    "${certbot_cmd[@]}" || certbot_exit_code=$?
    rm -rf "$test_dir"

    if [[ $certbot_exit_code -eq 0 ]]; then
        echo
        log_success "$DNS_PROVIDER DNS test completed successfully"
        return 0
    fi

    echo
    log_error "$DNS_PROVIDER DNS test failed (exit code: $certbot_exit_code)"
    log_error "This could be due to:"
    log_error "  • Invalid DNS credentials"
    log_error "  • Domain not managed by $DNS_PROVIDER"
    log_error "  • Insufficient API permissions"
    log_error "  • Network connectivity issues"
    echo
    echo "What would you like to do?"
    echo "1) Try again (re-enter credentials)"
    echo "2) Continue anyway (skip DNS test)"
    echo "3) Exit installation"
    echo
    read -r -p "Enter your choice (1-3): " choice

    case "$choice" in
        1)
            log_info "Let's try again..."
            echo
            get_dns_credentials
            test_dns_provider
            ;;
        2)
            log_warn "Continuing despite DNS test failure..."
            ;;
        *)
            log_error "Installation aborted"
            exit 1
            ;;
    esac
}

# Install packages
install_packages() {
    log_step "Installing required packages..."
    echo
    echo "Installing the following packages:"
    echo "• certbot (Let's Encrypt client)"
    echo "• DNS provider plugin for $DNS_PROVIDER"
    echo "• curl, openssl, jq (utilities)"
    echo
    read -r -p "Continue with package installation? (y/N): " confirm
    if [[ "$confirm" != "y" && "$confirm" != "Y" ]]; then
        log_error "Package installation cancelled"
        exit 1
    fi
    
    # Update package list
    log_info "Updating package list..."
    apt update -y
    
    # Install packages based on DNS provider
    log_info "Installing certbot, $DNS_PROVIDER plugin, and utilities..."
    case "$DNS_PROVIDER" in
        "digitalocean")
            apt install -y certbot python3-certbot-dns-digitalocean curl openssl jq
            ;;
        "route53")
            apt install -y certbot python3-certbot-dns-route53 curl openssl jq
            ;;
        "linode")
            apt install -y certbot python3-certbot-dns-linode curl openssl jq
            ;;
    esac
    
    log_success "Packages installed successfully"
}

# Download and install certificate manager script
install_certificate_manager() {
    log_step "Installing certificate manager script..."
    echo
    echo "This will download the certificate manager script from GitHub and install:"
    echo "• The script itself, owned by root: $INSTALLED_SCRIPT"
    echo "• A launcher for FileMaker schedules: $FMS_LAUNCHER"
    echo
    read -r -p "Continue with script installation? (y/N): " confirm
    if [[ "$confirm" != "y" && "$confirm" != "Y" ]]; then
        log_error "Script installation cancelled"
        exit 1
    fi

    # Download to the scratch directory first so a failed or bogus download
    # never replaces a working install
    local download="$INSTALL_TMP/simple-certificate-manager.sh"
    log_info "Downloading certificate manager script..."
    if ! curl -fsSL "$SCRIPT_DOWNLOAD_URL" -o "$download"; then
        log_error "Failed to download script from $SCRIPT_DOWNLOAD_URL"
        exit 1
    fi
    if ! head -n 1 "$download" | grep -q '^#!/bin/bash' || ! bash -n "$download"; then
        log_error "The downloaded file is not a valid script"
        exit 1
    fi
    log_success "Script downloaded successfully"

    install -o root -g root -m 755 "$download" "$INSTALLED_SCRIPT"

    cat > "$FMS_LAUNCHER" << EOF
#!/bin/bash
# Launcher for FileMaker Server schedules. The certificate manager itself is
# root-owned at $INSTALLED_SCRIPT and runs through sudo.
exec sudo -n "$INSTALLED_SCRIPT" "\$@"
EOF
    chmod 755 "$FMS_LAUNCHER"
    chown fmserver:fmsadmin "$FMS_LAUNCHER"

    log_success "Certificate manager script installed successfully"
}

# Setup sudo permissions for fmserver user
setup_sudo_permissions() {
    local sudoers_rule="fmserver ALL=(root) NOPASSWD: $INSTALLED_SCRIPT"

    log_step "Setting up sudo permissions for fmserver user..."
    echo
    echo "The certificate manager script needs to run with elevated privileges to:"
    echo "• Import certificates into FileMaker Server using fmsadmin"
    echo "• Restart the FileMaker Server service when certificates are updated"
    echo
    echo "We will create a secure sudoers file that allows the fmserver user to run"
    echo "ONLY the certificate manager script with sudo (no password required)."
    echo
    echo "==== The following will be written to $SUDOERS_FILE ===="
    echo "$sudoers_rule"
    echo "====================================================================="
    echo "Permissions: 440 (read-only, only root can modify)"
    echo
    read -r -p "Continue with sudo setup? (y/N): " setup_sudo

    if [[ "$setup_sudo" != "y" && "$setup_sudo" != "Y" ]]; then
        log_warn "Sudo setup skipped. FileMaker schedules will not be able to run the certificate manager."
        return 0
    fi

    # A broken file in sudoers.d locks everyone out of sudo, so check it first
    local sudoers_tmp="$INSTALL_TMP/sudoers"
    log_info "Creating sudoers file..."
    printf '%s\n' \
        "# Allow fmserver user to run certificate manager script with sudo" \
        "$sudoers_rule" > "$sudoers_tmp"
    if ! visudo -cf "$sudoers_tmp" >/dev/null; then
        log_error "Generated sudoers file did not pass validation, not installing it"
        exit 1
    fi
    install -o root -g root -m 440 "$sudoers_tmp" "$SUDOERS_FILE"

    log_success "Sudo permissions configured"
    log_info "Created: $SUDOERS_FILE"
    log_info "Permissions: $(ls -l "$SUDOERS_FILE")"
    echo

    # Test sudo permissions by running the launcher with -v as fmserver user
    log_info "Testing sudo permissions..."
    local test_result
    local test_exit_code=0
    test_result=$(sudo -u fmserver "$FMS_LAUNCHER" -v 2>&1) || test_exit_code=$?

    if [[ $test_exit_code -eq 0 ]]; then
        log_success "Sudo permissions test passed"
        log_info "Script version: $(echo "$test_result" | head -n1)"
    else
        log_error "Sudo permissions test failed (exit code: $test_exit_code)"
        log_error "Output: $test_result"
        log_warn "The script may not work correctly in scheduled tasks"
    fi
}

# Build the schedule parameters, plus a copy with secrets masked for display
build_schedule_params() {
    local provider_params=""
    local provider_display=""

    case "$DNS_PROVIDER" in
        "digitalocean")
            provider_params="--do-token $DO_TOKEN"
            provider_display="--do-token ********"
            ;;
        "route53")
            provider_params="--aws-access-key-id $AWS_ACCESS_KEY_ID --aws-secret-key $AWS_SECRET_ACCESS_KEY"
            provider_display="--aws-access-key-id $AWS_ACCESS_KEY_ID --aws-secret-key ********"
            ;;
        "linode")
            provider_params="--linode-token $LINODE_TOKEN"
            provider_display="--linode-token ********"
            ;;
    esac

    local prefix="--hostname $DOMAIN_NAME --email $EMAIL --dns-provider $DNS_PROVIDER"
    SCHEDULE_PARAMS="$prefix $provider_params --fms-username $FMS_USERNAME --fms-password $FMS_PASSWORD --import-cert --restart-fms"
    SCHEDULE_PARAMS_DISPLAY="$prefix $provider_display --fms-username $FMS_USERNAME --fms-password ******** --import-cert --restart-fms"
}

# Call the local Admin API: fms_api METHOD PATH [curl options...]
# FileMaker Server still has its self-signed certificate at this point, so
# certificate verification is off for this localhost-only connection.
fms_api() {
    local method="$1"
    local path="$2"
    shift 2

    curl -s -k --connect-timeout 10 --max-time 30 -X "$method" \
        -H "Content-Type: application/json" "$@" "$FMS_API$path"
}

fms_api_logout() {
    local fms_token="$1"

    log_info "Logging out of FileMaker Server Admin API..."
    if ! fms_api DELETE "/user/auth/$fms_token" -H "Authorization: Bearer $fms_token" >/dev/null 2>&1; then
        log_warn "Could not log out of the Admin API. The session will expire on its own."
    fi
}

# Setup FileMaker Server script schedule
setup_fms_schedule() {
    log_step "Setting up FileMaker Server script schedule..."
    echo
    echo "Would you like to create an automated FileMaker Server script schedule?"
    echo
    echo "This will create a scheduled task that will:"
    echo "• Check for certificate renewal needs"
    echo "• Create/renew SSL certificates using Let's Encrypt"
    echo "• Import certificates into FileMaker Server"
    echo "• Restart FileMaker Server service when needed"
    echo
    echo "The schedule will run every Sunday at 3:00 AM by default."
    echo "You can adjust the script schedule day/time to suit your maintenance window, though it is recommended to run it at least once a week to ensure certificates are renewed before expiry."
    echo
    read -r -p "Create automated schedule? (y/N): " create_schedule

    if [[ "$create_schedule" != "y" && "$create_schedule" != "Y" ]]; then
        log_info "Skipping schedule setup. You can set this up manually later."
        return 0
    fi

    # Get FileMaker Server credentials
    log_step "Getting FileMaker Server credentials..."
    echo
    echo "We need FileMaker Server Admin Console credentials to create the schedule."
    echo
    while true; do
        read -r -p "FileMaker Admin Console username: " FMS_USERNAME
        if [[ -n "$FMS_USERNAME" ]]; then
            break
        else
            log_error "Username cannot be empty"
        fi
    done

    FMS_PASSWORD=""
    prompt_secret "FileMaker Admin Console password" FMS_PASSWORD

    # Get email for Let's Encrypt
    while true; do
        read -r -p "Email address for Let's Encrypt notifications: " EMAIL
        if [[ -n "$EMAIL" ]] && [[ "$EMAIL" =~ ^[a-zA-Z0-9._%+-]+@[a-zA-Z0-9.-]+\.[a-zA-Z]{2,}$ ]]; then
            break
        else
            log_error "Please enter a valid email address"
        fi
    done

    build_schedule_params

    local schedule_value
    for schedule_value in "$FMS_USERNAME" "$FMS_PASSWORD" "${DO_TOKEN:-}" "${AWS_SECRET_ACCESS_KEY:-}" "${LINODE_TOKEN:-}"; do
        if [[ "$schedule_value" =~ [[:space:]] ]]; then
            log_warn "A username, password or token contains a space. FileMaker Server splits schedule"
            log_warn "parameters on spaces, so the schedule may not run until that value is changed."
            break
        fi
    done

    # Show the command that will be scheduled
    log_step "Certificate manager command configuration..."
    echo
    echo "The following System Script will be scheduled in FileMaker Server:"
    echo
    echo "Script Name: $SCHEDULE_NAME"
    echo "System Script: simple-certificate-manager.sh"
    echo
    echo "Parameters (secrets hidden):"
    echo "  $SCHEDULE_PARAMS_DISPLAY"
    echo
    echo -e "${YELLOW}Note: Currently configured in staging mode. Test the schedule manually first.${NC}"
    echo -e "${YELLOW}When ready for production, add --live flag and update the schedule.${NC}"
    echo
    read -r -p "Continue with schedule creation? (y/N): " continue_schedule

    if [[ "$continue_schedule" != "y" && "$continue_schedule" != "Y" ]]; then
        log_info "Schedule creation cancelled. You can set this up manually later."
        return 0
    fi

    # Authenticate with FileMaker Admin API
    log_info "Authenticating with FileMaker Server Admin API as $FMS_USERNAME..."
    local auth_response
    local curl_exit_code=0
    auth_response=$(fms_api POST "/user/auth" -u "$FMS_USERNAME:$FMS_PASSWORD" -d '{}' 2>&1) || curl_exit_code=$?

    if [[ $curl_exit_code -ne 0 ]]; then
        log_error "Failed to connect to FileMaker Server Admin API (curl exit code: $curl_exit_code)"
        log_error "Response: $auth_response"
        log_warn "No schedule was created. You can create it in FileMaker Server Admin Console."
        return 0
    fi

    local fms_token
    # An unparseable response leaves the token empty, which is handled below
    fms_token=$(echo "$auth_response" | jq -r '.response.token // empty' 2>/dev/null || true)
    if [[ -z "$fms_token" ]]; then
        log_error "Failed to authenticate with FileMaker Server Admin API"
        log_error "Response: $auth_response"
        log_warn "No schedule was created. Check the credentials, or create it in FileMaker Server Admin Console."
        return 0
    fi
    log_success "Successfully authenticated with FileMaker Server Admin API"
    echo

    # Replace an existing schedule rather than adding a second one
    local existing_ids
    existing_ids=$(fms_api GET "/schedules" -H "Authorization: Bearer $fms_token" 2>/dev/null \
        | jq -r --arg name "$SCHEDULE_NAME" '.response.schedules[]? | select(.name == $name) | .id' 2>/dev/null || true)
    if [[ -n "$existing_ids" ]]; then
        log_warn "A schedule named '$SCHEDULE_NAME' already exists."
        read -r -p "Replace it? (y/N): " replace_schedule
        if [[ "$replace_schedule" != "y" && "$replace_schedule" != "Y" ]]; then
            log_info "Keeping the existing schedule. No changes made."
            SCHEDULE_CREATED=true
            fms_api_logout "$fms_token"
            return 0
        fi
        local existing_id
        for existing_id in $existing_ids; do
            if fms_api DELETE "/schedules/$existing_id" -H "Authorization: Bearer $fms_token" >/dev/null 2>&1; then
                log_info "Removed existing schedule (ID: $existing_id)"
            else
                log_warn "Could not remove existing schedule (ID: $existing_id). Remove it in Admin Console."
            fi
        done
    fi

    # Create FileMaker Server schedule via API
    log_info "Creating FileMaker Server schedule..."
    local schedule_payload
    schedule_payload=$(jq -n \
        --arg name "$SCHEDULE_NAME" \
        --arg script "filelinux:$FMS_LAUNCHER" \
        --arg params "$SCHEDULE_PARAMS" \
        '{
            name: $name,
            enabled: true,
            systemScriptType: {osScript: $script, osScriptParam: $params, autoAbort: true, timeout: 10},
            weeklyType: {daysOfTheWeek: ["SUN"], startTimeStamp: "2000-01-01T03:00:00"}
        }')

    local schedule_response
    curl_exit_code=0
    schedule_response=$(fms_api POST "/schedules/systemscript" \
        -H "Authorization: Bearer $fms_token" -d "$schedule_payload" 2>&1) || curl_exit_code=$?

    if [[ $curl_exit_code -ne 0 ]]; then
        log_error "Failed to connect to FileMaker Server Admin API for schedule creation (curl exit code: $curl_exit_code)"
        log_error "Response: $schedule_response"
        log_warn "You can manually create the schedule in FileMaker Server Admin Console"
        fms_api_logout "$fms_token"
        return 0
    fi

    # The Admin API reports success as message code 0
    if echo "$schedule_response" | jq -e '.response.id != null or ((.messages[0].code // "" | tostring) == "0")' >/dev/null 2>&1; then
        SCHEDULE_CREATED=true
        log_success "$SCHEDULE_NAME schedule created successfully"
        echo
        echo "=========================================="
        echo "Schedule Details:"
        echo "=========================================="
        echo "Schedule Name: $SCHEDULE_NAME"
        echo "Frequency: Every Sunday at 3:00 AM"
        echo "System Script: simple-certificate-manager.sh"
        echo "Status: Enabled"
        echo
        echo "Parameters (secrets hidden):"
        echo "  $SCHEDULE_PARAMS_DISPLAY"
        echo
        echo "Mode: STAGING (test certificates)"
        echo "=========================================="
        echo
    else
        log_error "Failed to create FileMaker Server schedule"
        log_error "Response: $schedule_response"
        log_warn "You can manually create the schedule in FileMaker Server Admin Console"
    fi

    fms_api_logout "$fms_token"
    log_success "Schedule setup completed"
}

# Show completion message
show_completion() {
    echo
    log_success "Installation completed successfully!"
    echo
    echo -e "${BOLD}${CYAN}========================================${NC}"
    echo -e "${BOLD}${CYAN}  Next Steps - Testing & Production  ${NC}"
    echo -e "${BOLD}${CYAN}========================================${NC}"
    echo
    if [[ "$SCHEDULE_CREATED" == "true" ]]; then
        echo -e "${BOLD}1. Test the Schedule Manually${NC}"
        echo
        echo "   Go to FileMaker Server Admin Console → Configuration → Schedules"
        echo "   Find: '$SCHEDULE_NAME'"
        echo "   Click: 'Run Schedule Now'"
    else
        echo -e "${BOLD}1. Create and Test the Schedule${NC}"
        echo
        echo "   No schedule was created by this installer."
        echo "   Go to FileMaker Server Admin Console → Configuration → Schedules"
        echo "   Create a System Script schedule for: simple-certificate-manager.sh"
        echo "   See the README for the parameters, then click 'Run Schedule Now'"
    fi
    echo
    echo "   This will create a STAGING certificate (not trusted by browsers)."
    echo "   FileMaker Server will restart if the certificate is successfully imported."
    echo
    echo -e "${BOLD}2. Switch to Production Certificates${NC}"
    echo
    echo "   Once testing is successful, update the schedule to use production certificates:"
    echo "   • Edit the schedule in FileMaker Server Admin Console"
    echo "   • Add '--live' flag to the parameters"
    echo "   • Run the schedule again"
    echo
    echo -e "${YELLOW}   ⚠️  IMPORTANT - Let's Encrypt Rate Limits:${NC}"
    echo "   • 5 duplicate certificates per week"
    echo "   • 50 certificates per domain per week"
    echo "   • Test with staging first to avoid hitting limits!"
    echo "   • More info: https://letsencrypt.org/docs/rate-limits/"
    echo
    echo -e "${BOLD}3. Optional: Remove Auto-Restart${NC}"
    echo
    echo "   If you prefer to restart FileMaker Server manually:"
    echo "   • Edit the schedule in FileMaker Server Admin Console"
    echo "   • Remove '--restart-fms' flag from the parameters"
    echo "   • You'll need to manually restart after certificate renewal"
    echo
    echo -e "${BOLD}4. Monitor Logs${NC}"
    echo
    echo "   Certificate Manager Logs:"
    echo "   • /opt/FileMaker/FileMaker Server/CStore/Certbot/logs/cert-manager.log"
    echo "   • /opt/FileMaker/FileMaker Server/CStore/Certbot/logs/fms-import.log"
    echo
    echo "   Certbot Logs:"
    echo "   • /opt/FileMaker/FileMaker Server/CStore/Certbot/logs/letsencrypt.log"
    echo
    echo -e "${BOLD}5. Schedule Details${NC}"
    echo
    if [[ "$SCHEDULE_CREATED" == "true" ]]; then
        echo "   Schedule Name: $SCHEDULE_NAME"
        echo "   Frequency: Every Sunday at 3:00 AM"
        echo "   Action: Check for renewal, import cert, restart if needed"
        echo
        echo "   You can adjust the schedule day/time in FileMaker Server Admin Console"
        echo "   to match your preferred maintenance window."
    else
        echo "   Run the schedule at least once a week so the certificate is renewed"
        echo "   before it expires."
    fi
    echo
    echo -e "${BOLD}6. Smart State Management${NC}"
    echo
    echo "   The certificate manager uses semi intelligent state tracking:"
    echo
    echo "   • First Run: Requests new certificate"
    echo "   • Subsequent Runs: Only renews if certificate expires within 30 days"
    echo "   • State File: /opt/FileMaker/FileMaker Server/CStore/Certbot/simple-certificate-manager-state.json"
    echo "   • Environment Changes: Switching staging/live triggers new certificate request"
    echo "   • Hostname Changes: Changing domain triggers new certificate request"
    echo
    echo -e "${BOLD}7. Debugging${NC}"
    echo
    echo "   If you encounter issues, add the '--debug' flag to see detailed output:"
    echo "   • Edit the schedule in FileMaker Server Admin Console"
    echo "   • Add '--debug' to the parameters"
    echo "   • Check logs for detailed execution information"
    echo
    echo -e "${BOLD}${CYAN}========================================${NC}"
    echo
    echo "For detailed instructions, see: $SCRIPT_GITHUB"
    echo
    echo "Questions or issues? Open an issue on GitHub!"
    echo
    echo "Made in Australia by Daniel Smith"
    echo "https://github.com/DanSmith888"
    echo
    log_success "Happy certificate managing!"
}

# Main execution
main() {
    show_welcome
    check_root

    INSTALL_TMP=$(mktemp -d)
    trap cleanup_install_tmp EXIT

    check_ubuntu
    check_filemaker_server
    check_fmshelper_service
    check_fms_scripts_directory
    select_dns_provider
    get_domain_name
    get_dns_credentials
    install_packages
    test_dns_provider
    install_certificate_manager
    setup_sudo_permissions
    setup_fms_schedule
    show_completion
}

# Script entry point
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    main "$@"
fi
