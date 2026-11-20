#!/bin/bash

# FileMaker Server Certificate Manager
# Unified script for Let's Encrypt certificate management using DNS validation
# Supports both certificate requests and renewals

set -euo pipefail

# Script metadata
SCRIPT_VERSION="2.0.0"
SCRIPT_NAME="simple-certificate-manager"
SCRIPT_AUTHOR="Daniel Smith"
SCRIPT_GITHUB="https://github.com/DanSmith888/simple-certificate-manager"

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Default values
DEBUG=false
FORCE_RENEW=false
IMPORT_CERT=false
RESTART_FMS=false
STAGING=true
LIVE=false
DNS_PROVIDER=""  # Will be set by --dns-provider parameter (digitalocean, route53, or linode)
DNS_CREDENTIALS_DIR="/etc/certbot"
DNS_CREDENTIALS_FILE=""  # Set by setup_dns_credentials, removed on exit
DNS_PLUGIN_ARGS=()       # Certbot plugin flags for the chosen provider

# ACME server endpoints
PROD_SERVER_URL="https://acme-v02.api.letsencrypt.org/directory"
STAGING_SERVER_URL="https://acme-staging-v02.api.letsencrypt.org/directory"

# Check if running on Ubuntu 22.04 LTS or above
check_ubuntu() {
    if [[ -f /etc/os-release ]]; then
        . /etc/os-release
        if [[ "$ID" != "ubuntu" ]]; then
            error_exit "This script only supports Ubuntu"
        fi
        
        # Check if version is 22.04 or above
        if ! dpkg --compare-versions "$VERSION_ID" ge "22.04"; then
            error_exit "This script requires Ubuntu 22.04 LTS or above"
        fi
    else
        error_exit "Cannot detect operating system"
    fi
}

# FileMaker Server paths (Ubuntu only)
FMS_CERTBOT_PATH="/opt/FileMaker/FileMaker Server/CStore/Certbot"
FMS_LOG_PATH="/opt/FileMaker/FileMaker Server/CStore/Certbot/logs"

# Logging functions
log() {
    local level="$1"
    shift
    local message="$*"
    local timestamp=$(date '+%Y-%m-%d %H:%M:%S')
    
    # Try to write to log file, fallback to stderr if it fails
    if ! echo "[$timestamp] [$level] $message" >> "$FMS_LOG_PATH/cert-manager.log" 2>/dev/null; then
        echo "[$timestamp] [$level] $message" >&2
    fi
}

log_info() {
    echo -e "${BLUE}[INFO]${NC} $*"
    log "INFO" "$@"
}

log_success() {
    echo -e "${GREEN}[SUCCESS]${NC} $*"
    log "SUCCESS" "$@"
}

log_error() {
    echo -e "${RED}[ERROR]${NC} $*" >&2
    log "ERROR" "$@"
}

log_warn() {
    echo -e "${YELLOW}[WARN]${NC} $*"
    log "WARN" "$@"
}

log_debug() {
    if [[ "$DEBUG" == "true" ]]; then
        echo -e "${BLUE}[DEBUG]${NC} $*"
        log "DEBUG" "$@"
    fi
}

# Error handling
error_exit() {
    log_error "$1"
    exit 1
}


# Check required dependencies
check_dependencies() {
    log_info "Checking system dependencies..."
    
    # Check certbot
    if ! command -v certbot &> /dev/null; then
        error_exit "Certbot is not installed. Please run: sudo apt install certbot"
    fi

    # jq reads and writes the state file, openssl reads certificate fingerprints
    local tool
    for tool in jq openssl; do
        if ! command -v "$tool" &> /dev/null; then
            error_exit "$tool is not installed. Please run: sudo apt install $tool"
        fi
    done
    
    # Check DNS provider plugin
    case "$DNS_PROVIDER" in
        "digitalocean")
            if ! certbot plugins | grep -q dns-digitalocean; then
                error_exit "DigitalOcean DNS plugin is not installed. Please run: sudo apt install python3-certbot-dns-digitalocean"
            fi
            ;;
        "route53")
            if ! certbot plugins | grep -q dns-route53; then
                error_exit "Route53 DNS plugin is not installed. Please run: sudo apt install python3-certbot-dns-route53"
            fi
            ;;
        "linode")
            if ! certbot plugins | grep -q dns-linode; then
                error_exit "Linode DNS plugin is not installed. Please run: sudo apt install python3-certbot-dns-linode"
            fi
            ;;
        *)
            error_exit "Unsupported DNS provider: $DNS_PROVIDER. Supported providers: digitalocean, route53, linode"
            ;;
    esac
    
    # Check fmsadmin
    if ! command -v fmsadmin &> /dev/null; then
        error_exit "fmsadmin is not available. Please ensure FileMaker Server is installed"
    fi
    
    log_success "All dependencies are available"
}

# Create necessary directories
setup_directories() {
    mkdir -p "$FMS_CERTBOT_PATH" "$FMS_LOG_PATH"

    # FileMaker Server reads the certificate files as fmserver during import
    if id "fmserver" &>/dev/null; then
        chown -R fmserver:fmsadmin "$FMS_CERTBOT_PATH"
    fi
    chmod 755 "$FMS_CERTBOT_PATH" "$FMS_LOG_PATH"

    # Private keys and the ACME account stay owner-only, as certbot creates them
    local private_dir
    for private_dir in accounts archive live; do
        if [[ -d "$FMS_CERTBOT_PATH/$private_dir" ]]; then
            chmod 700 "$FMS_CERTBOT_PATH/$private_dir"
        fi
    done
    if [[ -d "$FMS_CERTBOT_PATH/archive" ]]; then
        find "$FMS_CERTBOT_PATH/archive" -type f -name 'privkey*.pem' -exec chmod 600 {} +
    fi

    touch "$FMS_LOG_PATH/cert-manager.log"
    chmod 644 "$FMS_LOG_PATH/cert-manager.log"
}

# Write the provider credentials file so it is never readable by other users
write_credentials_file() {
    local content="$1"

    mkdir -p "$DNS_CREDENTIALS_DIR"
    rm -f "$DNS_CREDENTIALS_FILE"
    (umask 077 && printf '%s\n' "$content" > "$DNS_CREDENTIALS_FILE")
}

# Setup DNS provider credentials (temporary, removed again on exit)
setup_dns_credentials() {
    log_info "Setting up $DNS_PROVIDER credentials..."

    case "$DNS_PROVIDER" in
        "digitalocean")
            DNS_CREDENTIALS_FILE="$DNS_CREDENTIALS_DIR/digitalocean.ini"
            write_credentials_file "dns_digitalocean_token = $DO_TOKEN"
            DNS_PLUGIN_ARGS=(--dns-digitalocean --dns-digitalocean-credentials "$DNS_CREDENTIALS_FILE")
            ;;
        "route53")
            # The Route53 plugin reads its credentials from the environment
            export AWS_ACCESS_KEY_ID AWS_SECRET_ACCESS_KEY
            DNS_PLUGIN_ARGS=(--dns-route53)
            ;;
        "linode")
            DNS_CREDENTIALS_FILE="$DNS_CREDENTIALS_DIR/linode.ini"
            write_credentials_file "dns_linode_key = $LINODE_TOKEN"
            DNS_PLUGIN_ARGS=(--dns-linode --dns-linode-credentials "$DNS_CREDENTIALS_FILE")
            ;;
    esac

    log_success "$DNS_PROVIDER credentials configured"
}

# ACME server this run targets
expected_acme_server() {
    if [[ "$LIVE" == "true" ]]; then
        echo "$PROD_SERVER_URL"
    else
        echo "$STAGING_SERVER_URL"
    fi
}

# ACME server recorded in the existing lineage (empty if there is none)
get_lineage_server() {
    local hostname="$1"
    local renewal_conf="$FMS_CERTBOT_PATH/renewal/$hostname.conf"

    if [[ -f "$renewal_conf" ]]; then
        awk -F'=' '/^server[ \t]*=/ { gsub(/^[ \t]+|[ \t]+$/, "", $2); print $2; exit }' "$renewal_conf"
    fi
}

# True when the existing lineage was issued by the environment this run targets
lineage_matches_environment() {
    local hostname="$1"
    local configured_server
    configured_server=$(get_lineage_server "$hostname")

    [[ -z "$configured_server" || "$configured_server" == "$(expected_acme_server)" ]]
}

# Certbot keeps an existing lineage when asked for the same hostname again, so a
# lineage from the other ACME server has to be deleted before requesting.
delete_lineage() {
    local hostname="$1"

    log_info "Deleting existing certificate lineage for '$hostname'"
    if ! certbot delete --non-interactive --cert-name "$hostname" \
        --config-dir "$FMS_CERTBOT_PATH" \
        --work-dir "$FMS_CERTBOT_PATH" \
        --logs-dir "$FMS_LOG_PATH" >> "$FMS_LOG_PATH/cert-manager.log" 2>&1; then
        error_exit "Could not delete the existing lineage for '$hostname'. Check $FMS_LOG_PATH/cert-manager.log"
    fi
}

# Older versions could mark a cert as non-renewable; flip that back on so renew works.
ensure_lineage_autorenew_enabled() {
    local hostname="$1"
    local renewal_conf="$FMS_CERTBOT_PATH/renewal/$hostname.conf"

    if [[ ! -f "$renewal_conf" ]]; then
        return 0
    fi

    if grep -Eq '^[[:space:]]*autorenew[[:space:]]*=[[:space:]]*False([[:space:]]*)$' "$renewal_conf"; then
        log_info "Legacy autorenew=False found for '$hostname'; enabling renewals in renewal config"
        sed -i -E 's/^[[:space:]]*autorenew[[:space:]]*=[[:space:]]*False([[:space:]]*)$/autorenew = True/' "$renewal_conf"
        log_success "Updated renewal config: autorenew = True"
    fi
}

# Remove DNS provider credentials. Runs from the EXIT trap, so it must be safe
# to call at any point, including before the credentials were written.
cleanup_dns_credentials() {
    if [[ -n "$DNS_CREDENTIALS_FILE" && -f "$DNS_CREDENTIALS_FILE" ]]; then
        rm -f "$DNS_CREDENTIALS_FILE"
        log_info "Removed $DNS_PROVIDER credentials file"
    fi
    unset AWS_ACCESS_KEY_ID AWS_SECRET_ACCESS_KEY
}

# Cleanup FileMaker Server certbot files for testing
cleanup_all() {
    echo "[INFO] Cleaning up FileMaker Server certbot files..."

    # Remove FileMaker Server certbot directory
    if [[ -n "$FMS_CERTBOT_PATH" && -d "$FMS_CERTBOT_PATH" ]]; then
        rm -rf "$FMS_CERTBOT_PATH"
        echo "[SUCCESS] Removed: $FMS_CERTBOT_PATH"
    fi

    # Remove DNS provider credentials left behind by an interrupted run
    local credentials_file
    for credentials_file in "$DNS_CREDENTIALS_DIR/digitalocean.ini" "$DNS_CREDENTIALS_DIR/linode.ini"; do
        if [[ -f "$credentials_file" ]]; then
            rm -f "$credentials_file"
            echo "[SUCCESS] Removed: $credentials_file"
        fi
    done

    echo "[SUCCESS] Cleanup complete! FileMaker Server certbot files have been removed."
    echo "[INFO] You can now run the script fresh for testing."
}

# State management functions
get_state_file() {
    echo "$FMS_CERTBOT_PATH/simple-certificate-manager-state.json"
}

# Read state from file
read_state() {
    local state_file
    state_file=$(get_state_file)

    STATE_HOSTNAME=""
    STATE_STAGING=""
    STATE_CERT_FINGERPRINT=""
    STATE_IMPORTED_FINGERPRINT=""

    if [[ ! -f "$state_file" ]]; then
        return 0
    fi

    if ! jq -e . "$state_file" >/dev/null 2>&1; then
        log_warn "State file is not valid JSON, treating this as a first run: $state_file"
        return 0
    fi

    STATE_HOSTNAME=$(jq -r '.hostname // ""' "$state_file")
    STATE_STAGING=$(jq -r '.staging // ""' "$state_file")
    STATE_CERT_FINGERPRINT=$(jq -r '.cert_fingerprint // ""' "$state_file")
    STATE_IMPORTED_FINGERPRINT=$(jq -r '.imported_fingerprint // ""' "$state_file")
}

# Write state to file
write_state() {
    local hostname="$1"
    local staging="$2"
    local cert_fingerprint="$3"
    local imported_fingerprint="$4"
    local state_file
    state_file=$(get_state_file)

    jq -n \
        --arg hostname "$hostname" \
        --arg staging "$staging" \
        --arg last_run "$(date -Iseconds)" \
        --arg cert_fingerprint "$cert_fingerprint" \
        --arg imported_fingerprint "$imported_fingerprint" \
        '{hostname: $hostname, staging: $staging, last_run: $last_run, cert_fingerprint: $cert_fingerprint, imported_fingerprint: $imported_fingerprint}' \
        > "$state_file"

    chmod 600 "$state_file"
    if id "fmserver" &>/dev/null; then
        chown fmserver:fmsadmin "$state_file"
    fi

    log_debug "State written to $state_file"
}

# Check if certificate exists
certificate_exists() {
    local hostname="$1"
    local cert_path="$FMS_CERTBOT_PATH/live/$hostname"
    
    if [[ -d "$cert_path" ]] && [[ -f "$cert_path/fullchain.pem" ]] && [[ -f "$cert_path/privkey.pem" ]]; then
        return 0
    else
        return 1
    fi
}

# Get certificate expiry info (human-readable notAfter= value only)
get_cert_expiry() {
    local hostname="$1"
    local cert_file="$FMS_CERTBOT_PATH/live/$hostname/fullchain.pem"
    
    if [[ -f "$cert_file" ]]; then
        openssl x509 -in "$cert_file" -noout -enddate 2>/dev/null | cut -d= -f2- | tr -d '\r' | sed 's/^[[:space:]]*//;s/[[:space:]]*$//'
    else
        echo ""
    fi
}

# Get certificate fingerprint (empty if the certificate is missing or unreadable)
get_cert_fingerprint() {
    local hostname="$1"
    local cert_file="$FMS_CERTBOT_PATH/live/$hostname/fullchain.pem"

    if [[ -f "$cert_file" ]]; then
        # Callers treat an empty result as "no certificate", so a failed read must not abort here
        openssl x509 -in "$cert_file" -noout -fingerprint -sha256 2>/dev/null | cut -d= -f2 || true
    else
        echo ""
    fi
}
# Check if certificate needs renewal
cert_needs_renewal() {
    local hostname="$1"
    local cert_file="$FMS_CERTBOT_PATH/live/$hostname/fullchain.pem"
    local expiry_date

    if [[ ! -f "$cert_file" ]]; then
        return 1
    fi

    expiry_date=$(get_cert_expiry "$hostname")
    if [[ -z "$expiry_date" ]]; then
        log_debug "Could not read certificate notAfter"
        return 1
    fi

    # Debug-only: days until expiry (openssl makes the real decision below; date parsing is flaky across locale/TZ).
    local expiry_timestamp
    expiry_timestamp=$(LC_ALL=C date -u -d "$expiry_date" +%s 2>/dev/null || true)
    if [[ -n "${expiry_timestamp:-}" ]]; then
        local current_timestamp
        current_timestamp=$(LC_ALL=C date -u +%s)
        local days_until_expiry=$(( (expiry_timestamp - current_timestamp) / 86400 ))
        log_debug "Certificate expires in $days_until_expiry days (notAfter: $expiry_date)"
    else
        log_debug "Could not parse notAfter for day count (notAfter: $expiry_date); using openssl -checkend"
    fi

    # Exit 0 if the cert is still valid for more than 30 days; nonzero if it expires sooner (or is already expired).
    if openssl x509 -in "$cert_file" -noout -checkend $((30 * 86400)) 2>/dev/null; then
        return 1
    else
        return 0
    fi
}

# Request new certificate
request_certificate() {
    local hostname="$1"
    local email="$2"
    local server
    server=$(expected_acme_server)

    log_info "Requesting new certificate for $hostname using $DNS_PROVIDER"
    if [[ "$LIVE" == "true" ]]; then
        log_info "Using Let's Encrypt production environment"
    else
        log_info "Using Let's Encrypt staging environment add --live to use production environment"
    fi

    local -a certbot_cmd=(
        certbot certonly "${DNS_PLUGIN_ARGS[@]}"
        --agree-tos --non-interactive
        --email "$email"
        -d "$hostname"
        --config-dir "$FMS_CERTBOT_PATH"
        --work-dir "$FMS_CERTBOT_PATH"
        --logs-dir "$FMS_LOG_PATH"
        --server "$server"
    )

    log_debug "Running: ${certbot_cmd[*]}"
    if "${certbot_cmd[@]}"; then
        log_success "Certificate requested successfully"
        return 0
    else
        log_error "Certificate request failed"
        return 1
    fi
}

# Renew existing certificate
renew_certificate() {
    local hostname="$1"

    log_info "Renewing certificate for $hostname using $DNS_PROVIDER"

    # Renewal uses the ACME server stored in the lineage, which main has
    # already checked against the requested environment.
    local -a certbot_cmd=(
        certbot renew "${DNS_PLUGIN_ARGS[@]}"
        --non-interactive
        --cert-name "$hostname"
        --config-dir "$FMS_CERTBOT_PATH"
        --work-dir "$FMS_CERTBOT_PATH"
        --logs-dir "$FMS_LOG_PATH"
    )

    if [[ "$FORCE_RENEW" == "true" ]]; then
        certbot_cmd+=(--force-renewal)
        log_info "Force renewal requested"
    fi

    log_debug "Running: ${certbot_cmd[*]}"
    if "${certbot_cmd[@]}"; then
        log_info "Certbot renew completed successfully (certificate may or may not have been reissued)"
        return 0
    else
        log_error "Certificate renewal failed"
        return 1
    fi
}

# Import certificate to FileMaker Server
import_certificate() {
    local hostname="$1"
    
    log_info "Importing certificate to FileMaker Server"
    
    local cert_file="$FMS_CERTBOT_PATH/live/$hostname/fullchain.pem"
    local key_file="$FMS_CERTBOT_PATH/live/$hostname/privkey.pem"
    
    # Resolve symlinks to actual files because fmsadmin cant deal with symlinks.
    cert_file=$(readlink -f "$cert_file")
    key_file=$(readlink -f "$key_file")
    
    # Verify files exist
    if [[ ! -f "$cert_file" ]] || [[ ! -f "$key_file" ]]; then
        error_exit "Certificate files not found: $cert_file, $key_file"
    fi
    
    # Set proper ownership and permissions
    chown fmserver:fmsadmin "$cert_file" "$key_file"
    chmod 644 "$cert_file"
    chmod 600 "$key_file"
    
    # Import certificate
    if fmsadmin certificate import "$cert_file" --keyfile "$key_file" -y -u "$FMS_USERNAME" -p "$FMS_PASSWORD" >> "$FMS_LOG_PATH/fms-import.log" 2>&1; then
        log_success "Certificate imported successfully"
        return 0
    else
        log_error "Certificate import failed. Check $FMS_LOG_PATH/fms-import.log"
        return 1
    fi
}

# Restart FileMaker Server
restart_filemaker_server() {
    if [[ "$RESTART_FMS" != "true" ]]; then
        log_info "FileMaker Server restart skipped (--restart-fms not set)"
        return 0
    fi

    # Restart in the background so this script can finish first: when it runs
    # from a FileMaker schedule, the restart takes its parent process down.
    log_info "Scheduling FileMaker Server restart in 5 seconds..."
    nohup bash -c 'sleep 5 && systemctl restart fmshelper && echo "FileMaker Server restarted successfully" >> "$1"' \
        _ "$FMS_LOG_PATH/cert-manager.log" > /dev/null 2>&1 &

    log_success "FileMaker Server restart scheduled"
}

# Display version information
show_version() {
    cat << EOF
$SCRIPT_NAME v$SCRIPT_VERSION

Author: $SCRIPT_AUTHOR
GitHub: $SCRIPT_GITHUB

A unified script for Let's Encrypt certificate management using DNS validation
for FileMaker Server. Supports both certificate requests and renewals with
semi-intelligent state management.

EOF
}

# Display usage information
usage() {
    cat << EOF
FileMaker Server Certificate Manager v$SCRIPT_VERSION

USAGE:
    $0 [OPTIONS]

REQUIRED OPTIONS:
    --hostname HOSTNAME     Domain name for the certificate
    --email EMAIL          Email for Let's Encrypt notifications
    --dns-provider PROVIDER DNS provider: digitalocean, route53, or linode

DNS PROVIDER OPTIONS (choose one):
    --do-token TOKEN        DigitalOcean API token (for DigitalOcean DNS)
    --aws-access-key-id KEY AWS Access Key ID (for Route53 DNS)
    --aws-secret-key KEY    AWS Secret Access Key (for Route53 DNS)
    --linode-token TOKEN    Linode API token (for Linode DNS)

OPTIONAL OPTIONS:
    --live                  Use Let's Encrypt production environment (default: staging)
    --force-renew           Force renewal even if not needed
    --import-cert           Import certificate to FileMaker Server
    --fms-username USER     FileMaker Admin Console username (required with --import-cert)
    --fms-password PASS     FileMaker Admin Console password (required with --import-cert)
    --restart-fms           Restart FileMaker Server after import (only runs if --import-cert is also set)
    --debug                 Enable debug logging
    --version, -v            Show version information
    --cleanup               Remove all certbot files and logs (for development/testing only)

EXAMPLES:
    # Basic certificate request (staging, no import) - DigitalOcean
    $0 --hostname example.com --email admin@example.com --dns-provider digitalocean --do-token dop_v1_xxx

    # Full workflow: certificate + import + restart (production) - DigitalOcean
    $0 --hostname example.com --email admin@example.com --dns-provider digitalocean --do-token dop_v1_xxx --fms-username admin --fms-password password --live --import-cert --restart-fms

    # Route53 with full workflow (production)
    $0 --hostname example.com --email admin@example.com --dns-provider route53 --aws-access-key-id AKIA... --aws-secret-key secret... --fms-username admin --fms-password password --live --import-cert --restart-fms

    # Linode with full workflow (production)
    $0 --hostname example.com --email admin@example.com --dns-provider linode --linode-token your_token... --fms-username admin --fms-password password --live --import-cert --restart-fms

    # Debug mode with full workflow - DigitalOcean
    $0 --debug --hostname example.com --email admin@example.com --dns-provider digitalocean --do-token dop_v1_xxx --fms-username admin --fms-password password --live --import-cert --restart-fms

EOF
}

# Parse command line arguments
parse_arguments() {
    while [[ $# -gt 0 ]]; do
        case $1 in
            --hostname|--email|--do-token|--aws-access-key-id|--aws-secret-key|--linode-token|--dns-provider|--fms-username|--fms-password)
                if [[ $# -lt 2 ]]; then
                    error_exit "Option $1 requires a value"
                fi
                ;;
        esac
        case $1 in
            --hostname)
                DOMAIN_NAME="$2"
                shift 2
                ;;
            --email)
                EMAIL="$2"
                shift 2
                ;;
            --do-token)
                DO_TOKEN="$2"
                shift 2
                ;;
            --aws-access-key-id)
                AWS_ACCESS_KEY_ID="$2"
                shift 2
                ;;
            --aws-secret-key)
                AWS_SECRET_ACCESS_KEY="$2"
                shift 2
                ;;
            --linode-token)
                LINODE_TOKEN="$2"
                shift 2
                ;;
            --dns-provider)
                DNS_PROVIDER="$2"
                shift 2
                ;;
            --live)
                LIVE=true
                shift
                ;;
            --force-renew)
                FORCE_RENEW=true
                shift
                ;;
            --import-cert)
                IMPORT_CERT=true
                shift
                ;;
            --restart-fms)
                RESTART_FMS=true
                shift
                ;;
            --fms-username)
                FMS_USERNAME="$2"
                shift 2
                ;;
            --fms-password)
                FMS_PASSWORD="$2"
                shift 2
                ;;
            --debug)
                DEBUG=true
                shift
                ;;
            --help|-h)
                usage
                exit 0
                ;;
            --version|-v)
                show_version
                exit 0
                ;;
            --cleanup)
                cleanup_all
                exit 0
                ;;
            *)
                error_exit "Unknown option: $1"
                ;;
        esac
    done
}

# Validate required parameters
validate_parameters() {
    local errors=()

    # Hostname and email end up in file paths and certbot arguments, so only
    # plain values are accepted.
    if [[ -z "${DOMAIN_NAME:-}" ]]; then
        errors+=("--hostname is required")
    elif [[ ! "$DOMAIN_NAME" =~ ^[A-Za-z0-9]([A-Za-z0-9.-]*[A-Za-z0-9])?$ ]]; then
        errors+=("--hostname is not a valid domain name: $DOMAIN_NAME")
    fi

    if [[ -z "${EMAIL:-}" ]]; then
        errors+=("--email is required")
    elif [[ ! "$EMAIL" =~ ^[A-Za-z0-9._%+][A-Za-z0-9._%+-]*@[A-Za-z0-9.-]+$ ]]; then
        errors+=("--email is not a valid email address: $EMAIL")
    fi

    if [[ "$IMPORT_CERT" == "true" ]]; then
        if [[ -z "${FMS_USERNAME:-}" ]]; then
            errors+=("--fms-username is required with --import-cert")
        fi

        if [[ -z "${FMS_PASSWORD:-}" ]]; then
            errors+=("--fms-password is required with --import-cert")
        fi
    fi

    # Validate DNS provider credentials
    case "$DNS_PROVIDER" in
        "digitalocean")
            if [[ -z "${DO_TOKEN:-}" ]]; then
                errors+=("--do-token is required for DigitalOcean DNS")
            fi
            ;;
        "route53")
            if [[ -z "${AWS_ACCESS_KEY_ID:-}" ]]; then
                errors+=("--aws-access-key-id is required for Route53 DNS")
            fi
            if [[ -z "${AWS_SECRET_ACCESS_KEY:-}" ]]; then
                errors+=("--aws-secret-key is required for Route53 DNS")
            fi
            ;;
        "linode")
            if [[ -z "${LINODE_TOKEN:-}" ]]; then
                errors+=("--linode-token is required for Linode DNS")
            fi
            ;;
        "")
            errors+=("--dns-provider is required")
            ;;
        *)
            errors+=("--dns-provider must be 'digitalocean', 'route53', or 'linode'")
            ;;
    esac

    if [[ ${#errors[@]} -gt 0 ]]; then
        for error in "${errors[@]}"; do
            log_error "$error"
        done
        error_exit "Parameter validation failed"
    fi
}

# Main execution
main() {
    # Check prerequisites first (before any logging)
    check_ubuntu

    # Setup directories (before any logging)
    setup_directories

    log_info "Starting $SCRIPT_NAME v$SCRIPT_VERSION"
    log_debug "Debug mode: $DEBUG"
    log_info "Hostname: $DOMAIN_NAME"
    log_info "Email: $EMAIL"
    log_info "Environment: $([ "$LIVE" == "true" ] && echo "production" || echo "staging")"

    # Check remaining prerequisites
    check_dependencies

    # Credentials must not outlive the run, whichever way it ends
    trap cleanup_dns_credentials EXIT
    setup_dns_credentials

    # Read previous state
    read_state
    log_debug "Previous state - Hostname: $STATE_HOSTNAME, Staging: $STATE_STAGING, Imported fingerprint: $STATE_IMPORTED_FINGERPRINT"

    local current_staging="true"
    if [[ "$LIVE" == "true" ]]; then
        current_staging="false"
    fi

    if [[ -n "$STATE_HOSTNAME" && "$STATE_HOSTNAME" != "$DOMAIN_NAME" ]]; then
        log_info "Different hostname detected. Previous: $STATE_HOSTNAME, Current: $DOMAIN_NAME"
    fi

    # Decide what to do from what is on disk, not from the state file
    local action
    if certificate_exists "$DOMAIN_NAME"; then
        if ! lineage_matches_environment "$DOMAIN_NAME"; then
            log_info "Existing certificate is from the other Let's Encrypt environment (found: $(get_lineage_server "$DOMAIN_NAME")) - requesting new certificate"
            delete_lineage "$DOMAIN_NAME"
            action="request"
        elif [[ "$FORCE_RENEW" == "true" ]]; then
            action="renew"
            log_info "Force renewal requested - renewing certificate"
        elif cert_needs_renewal "$DOMAIN_NAME"; then
            action="renew"
            log_info "Certificate exists but needs renewal"
        else
            action="none"
            log_info "Certificate exists and is valid"
        fi
    else
        action="request"
        log_info "No certificate found - requesting new certificate"
    fi

    # Execute action
    case "$action" in
        "request")
            request_certificate "$DOMAIN_NAME" "$EMAIL" || error_exit "Certificate request failed"
            ;;
        "renew")
            ensure_lineage_autorenew_enabled "$DOMAIN_NAME"
            renew_certificate "$DOMAIN_NAME" || error_exit "Certificate renewal failed"
            ;;
    esac

    local fingerprint
    fingerprint=$(get_cert_fingerprint "$DOMAIN_NAME")
    if [[ -z "$fingerprint" ]]; then
        error_exit "No readable certificate found for $DOMAIN_NAME in $FMS_CERTBOT_PATH/live"
    fi

    if [[ "$action" == "renew" && "$fingerprint" == "$STATE_CERT_FINGERPRINT" ]]; then
        log_info "Certbot did not change the certificate (still within its renewal policy)"
    fi

    # Import whenever the certificate on disk is not the one FileMaker Server
    # last imported. This also retries an import that failed on an earlier run.
    local imported_fingerprint="$STATE_IMPORTED_FINGERPRINT"
    if [[ "$IMPORT_CERT" != "true" ]]; then
        log_info "Certificate import skipped (--import-cert not set)"
    elif [[ "$fingerprint" == "$imported_fingerprint" ]]; then
        log_info "Certificate is already imported into FileMaker Server"
    elif import_certificate "$DOMAIN_NAME"; then
        imported_fingerprint="$fingerprint"
        write_state "$DOMAIN_NAME" "$current_staging" "$fingerprint" "$imported_fingerprint"
        restart_filemaker_server
    else
        write_state "$DOMAIN_NAME" "$current_staging" "$fingerprint" "$imported_fingerprint"
        error_exit "Certificate import failed - it will be retried on the next run"
    fi

    write_state "$DOMAIN_NAME" "$current_staging" "$fingerprint" "$imported_fingerprint"
    log_success "Certificate manager run completed"
}

# Script entry point
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    # Check root first, before any logging
    if [[ $EUID -ne 0 ]]; then
        # Check if we can use sudo for this specific script
        if command -v sudo &> /dev/null && sudo -l "$0" &>/dev/null; then
            echo "[INFO] Auto-escalating to root using sudo"
            exec sudo "$0" "$@"
        else
            echo "ERROR: This script must be run as root or with sudo. Please run: sudo $0 [OPTIONS]" >&2
            exit 1
        fi
    fi

    parse_arguments "$@"
    validate_parameters
    main
fi