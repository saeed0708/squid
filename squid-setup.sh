#!/bin/bash

# ============================================================
# Squid Setup Script
# Checks installation, optionally configures auth and IP filter
# ============================================================

set -e

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

print_header() {
    echo -e "\n${BLUE}=====================================================${NC}"
    echo -e "${BLUE}$1${NC}"
    echo -e "${BLUE}=====================================================${NC}\n"
}

print_error() {
    echo -e "${RED}[ERROR] $1${NC}"
}

print_success() {
    echo -e "${GREEN}[OK] $1${NC}"
}

print_info() {
    echo -e "${YELLOW}[INFO] $1${NC}"
}

if [[ $EUID -ne 0 ]]; then
   print_error "This script must be run with sudo!"
   exit 1
fi

# ------------------------------------------------------------
# Step 1: Check if Squid is installed, install only if missing
# ------------------------------------------------------------
print_header "Step 1: Check Squid Installation"

if command -v squid &> /dev/null; then
    SQUID_VERSION=$(squid -v 2>&1 | head -1)
    print_success "Squid is already installed"
    print_info "Version: $SQUID_VERSION"
    NEEDS_INSTALL=false
else
    print_info "Squid is not installed. Installing now..."
    NEEDS_INSTALL=true
fi

if [ "$NEEDS_INSTALL" = true ]; then
    apt-get update > /dev/null 2>&1 || print_info "apt-get update had warnings (some repos may have failed) - continuing anyway"
    apt-get install -y squid apache2-utils > /dev/null 2>&1

    if command -v squid &> /dev/null; then
        print_success "Squid installed successfully"
    else
        print_error "Squid installation failed!"
        exit 1
    fi
else
    if ! command -v htpasswd &> /dev/null; then
        print_info "Installing apache2-utils for htpasswd..."
        apt-get update > /dev/null 2>&1 || print_info "apt-get update had warnings (some repos may have failed) - continuing anyway"
        apt-get install -y apache2-utils > /dev/null 2>&1
    fi
fi

# ------------------------------------------------------------
# Detect the effective user Squid runs as (proxy on Ubuntu/Debian)
# ------------------------------------------------------------
SQUID_RUN_USER="proxy"
if ! id "$SQUID_RUN_USER" &> /dev/null; then
    SQUID_RUN_USER="squid"
fi

print_info "Squid will run as user: $SQUID_RUN_USER"

# ------------------------------------------------------------
# Step 2: Ask about authentication
# ------------------------------------------------------------
print_header "Step 2: Authentication Configuration"

echo "Do you want to set up username/password authentication?"
read -p "Enter (yes/no): " ENABLE_AUTH
ENABLE_AUTH=${ENABLE_AUTH,,}

PROXY_USER=""
PROXY_PASS=""
AUTH_ENABLED=false

if [[ "$ENABLE_AUTH" == "yes" || "$ENABLE_AUTH" == "y" ]]; then
    AUTH_ENABLED=true

    while true; do
        read -p "Enter proxy username: " PROXY_USER
        if [ -z "$PROXY_USER" ]; then
            print_error "Username cannot be empty!"
            continue
        fi
        break
    done

    while true; do
        read -sp "Enter proxy password: " PROXY_PASS
        echo ""
        if [ -z "$PROXY_PASS" ]; then
            print_error "Password cannot be empty!"
            continue
        fi

        read -sp "Confirm password: " PROXY_PASS_CONFIRM
        echo ""
        if [ "$PROXY_PASS" != "$PROXY_PASS_CONFIRM" ]; then
            print_error "Passwords do not match!"
            continue
        fi
        break
    done

    print_success "Authentication will be enabled for user: $PROXY_USER"
else
    print_info "Authentication will not be configured"
fi

# ------------------------------------------------------------
# Step 3: Ask about IP filtering
# ------------------------------------------------------------
print_header "Step 3: IP Filtering Configuration"

echo "Do you want to restrict access to specific IP address(es)?"
read -p "Enter (yes/no): " ENABLE_IP_FILTER
ENABLE_IP_FILTER=${ENABLE_IP_FILTER,,}

IP_FILTER_ENABLED=false
ALLOWED_IPS_LIST=""

if [[ "$ENABLE_IP_FILTER" == "yes" || "$ENABLE_IP_FILTER" == "y" ]]; then
    IP_FILTER_ENABLED=true

    echo "Enter IP addresses or networks one at a time."
    echo "Examples: 192.168.1.100/32  or  10.0.0.0/8"
    echo "Press Enter on an empty line when finished."
    echo ""

    while true; do
        read -p "IP/Network: " IP_ENTRY
        if [ -z "$IP_ENTRY" ]; then
            break
        fi
        ALLOWED_IPS_LIST="${ALLOWED_IPS_LIST}acl allowed_ips src ${IP_ENTRY}
"
    done

    if [ -z "$ALLOWED_IPS_LIST" ]; then
        print_error "No IPs entered. IP filtering will be disabled."
        IP_FILTER_ENABLED=false
    else
        print_success "IP filtering configured"
    fi
else
    print_info "IP filtering will not be configured"
fi

# ------------------------------------------------------------
# Step 4: Port, cache size, log rotation
# ------------------------------------------------------------
print_header "Step 4: General Settings"

read -p "Enter Squid port (default: 3128): " SQUID_PORT
SQUID_PORT=${SQUID_PORT:-3128}

read -p "Enter cache size in MB (default: 1000): " CACHE_SIZE
CACHE_SIZE=${CACHE_SIZE:-1000}

read -p "Keep logs for how many days (default: 7): " LOG_ROTATE
LOG_ROTATE=${LOG_ROTATE:-7}

print_success "Port: $SQUID_PORT, Cache: ${CACHE_SIZE}MB, Log rotation: ${LOG_ROTATE} days"

# ------------------------------------------------------------
# Step 5: Stop Squid before reconfiguring
# ------------------------------------------------------------
print_header "Step 5: Stopping Squid"

systemctl stop squid 2>/dev/null || true
sleep 1
print_success "Squid stopped"

# ------------------------------------------------------------
# Step 6: Set up directories with correct ownership
# ------------------------------------------------------------
print_header "Step 6: Preparing Directories"

mkdir -p /var/spool/squid
mkdir -p /var/log/squid
mkdir -p /var/run/squid

chown -R "$SQUID_RUN_USER":"$SQUID_RUN_USER" /var/spool/squid
chown -R "$SQUID_RUN_USER":"$SQUID_RUN_USER" /var/log/squid
chown -R "$SQUID_RUN_USER":"$SQUID_RUN_USER" /var/run/squid

chmod 750 /var/spool/squid
chmod 750 /var/log/squid
chmod 750 /var/run/squid

print_success "Directories ready with owner: $SQUID_RUN_USER"

# ------------------------------------------------------------
# Step 7: Create password file if authentication is enabled
# ------------------------------------------------------------
if [ "$AUTH_ENABLED" = true ]; then
    print_header "Step 7: Creating Authentication File"

    htpasswd -cb /etc/squid/passwd "$PROXY_USER" "$PROXY_PASS"
    chown "$SQUID_RUN_USER":"$SQUID_RUN_USER" /etc/squid/passwd
    chmod 640 /etc/squid/passwd

    print_success "Password file created at /etc/squid/passwd"
fi

# ------------------------------------------------------------
# Step 8: Backup old config and write new one
# ------------------------------------------------------------
print_header "Step 8: Writing Squid Configuration"

if [ -f /etc/squid/squid.conf ]; then
    cp /etc/squid/squid.conf "/etc/squid/squid.conf.backup.$(date +%s)"
    print_success "Old configuration backed up"
fi

{
    echo "#"
    echo "# Squid Configuration - generated by setup script"
    echo "#"
    echo ""
    echo "acl localnet src 0.0.0.1-0.255.255.255"
    echo "acl localnet src 10.0.0.0/8"
    echo "acl localnet src 100.64.0.0/10"
    echo "acl localnet src 169.254.0.0/16"
    echo "acl localnet src 172.16.0.0/12"
    echo "acl localnet src 192.168.0.0/16"
    echo "acl localnet src fc00::/7"
    echo "acl localnet src fe80::/10"
    echo ""
    echo "acl SSL_ports port 443"
    echo "acl Safe_ports port 80"
    echo "acl Safe_ports port 21"
    echo "acl Safe_ports port 443"
    echo "acl Safe_ports port 70"
    echo "acl Safe_ports port 210"
    echo "acl Safe_ports port 1025-65535"
    echo "acl Safe_ports port 280"
    echo "acl Safe_ports port 488"
    echo "acl Safe_ports port 591"
    echo "acl Safe_ports port 777"
    echo "acl CONNECT method CONNECT"
} > /etc/squid/squid.conf

if [ "$AUTH_ENABLED" = true ]; then
    {
        echo ""
        echo "# Authentication"
        echo "auth_param basic program /usr/lib/squid/basic_ncsa_auth /etc/squid/passwd"
        echo "auth_param basic children 5"
        echo "auth_param basic realm \"Proxy Authentication Required\""
        echo "auth_param basic credentialsttl 2 hours"
        echo "acl authenticated proxy_auth REQUIRED"
    } >> /etc/squid/squid.conf
fi

if [ "$IP_FILTER_ENABLED" = true ]; then
    {
        echo ""
        echo "# IP Filtering"
        printf '%s' "$ALLOWED_IPS_LIST"
    } >> /etc/squid/squid.conf
fi

{
    echo ""
    echo "# Access Rules"
    echo "http_access deny !Safe_ports"
    echo "http_access deny CONNECT !SSL_ports"
    echo "http_access allow localhost manager"
    echo "http_access deny manager"
} >> /etc/squid/squid.conf

if [ "$AUTH_ENABLED" = true ] && [ "$IP_FILTER_ENABLED" = true ]; then
    echo "http_access allow allowed_ips authenticated" >> /etc/squid/squid.conf
elif [ "$AUTH_ENABLED" = true ]; then
    echo "http_access allow authenticated" >> /etc/squid/squid.conf
elif [ "$IP_FILTER_ENABLED" = true ]; then
    echo "http_access allow allowed_ips" >> /etc/squid/squid.conf
else
    echo "http_access allow localnet" >> /etc/squid/squid.conf
    echo "http_access allow localhost" >> /etc/squid/squid.conf
fi

echo "http_access deny all" >> /etc/squid/squid.conf

{
    echo ""
    echo "http_port $SQUID_PORT"
    echo ""
    echo "cache_dir ufs /var/spool/squid $CACHE_SIZE 16 256"
    echo "maximum_object_size 100 MB"
    echo ""
    echo "pid_filename /var/run/squid/squid.pid"
    echo ""
    echo "access_log /var/log/squid/access.log squid"
    echo "cache_log /var/log/squid/cache.log"
    echo "logfile_rotate $LOG_ROTATE"
    echo ""
    echo "coredump_dir /var/spool/squid"
    echo ""
    echo "refresh_pattern ^ftp:           1440    20%     10080"
    echo "refresh_pattern ^gopher:        1440    0%      1440"
    echo "refresh_pattern -i (/cgi-bin/|\?) 0     0%      0"
    echo "refresh_pattern .               0       20%     4320"
} >> /etc/squid/squid.conf

print_success "Configuration file written to /etc/squid/squid.conf"

# ------------------------------------------------------------
# Step 9: Initialize cache directory
# ------------------------------------------------------------
print_header "Step 9: Initializing Cache"

rm -rf /var/spool/squid
mkdir -p /var/spool/squid
chown "$SQUID_RUN_USER":"$SQUID_RUN_USER" /var/spool/squid
chmod 750 /var/spool/squid

# Note: on newer Squid versions (6.x), the systemd unit itself runs
# "squid -z" automatically via ExecStartPre before starting the service.
# Running -z manually here AND letting systemd run it again causes a
# "File exists" collision on the swap directories. So we only run -z
# manually if the systemd unit does NOT already do it.
SQUID_UNIT_FILE=$(systemctl show -p FragmentPath squid 2>/dev/null | cut -d= -f2)

if [ -n "$SQUID_UNIT_FILE" ] && [ -f "$SQUID_UNIT_FILE" ] && grep -q '\-z' "$SQUID_UNIT_FILE"; then
    print_info "systemd unit already initializes the cache (ExecStartPre -z), skipping manual init"
else
    sudo -u "$SQUID_RUN_USER" /usr/sbin/squid -z -f /etc/squid/squid.conf
    print_success "Cache initialized manually"
fi

# Always remove any stale PID file before starting, regardless of path above
rm -f /var/run/squid/squid.pid

print_success "Cache directory ready"

# ------------------------------------------------------------
# Step 10: Start Squid
# ------------------------------------------------------------
print_header "Step 10: Starting Squid"

systemctl start squid
systemctl enable squid > /dev/null 2>&1
sleep 2

if systemctl is-active --quiet squid; then
    print_success "Squid is running"
else
    print_error "Squid failed to start!"
    systemctl status squid
    exit 1
fi

# ------------------------------------------------------------
# Summary
# ------------------------------------------------------------
print_header "Configuration Summary"

echo -e "${GREEN}============================================${NC}"
echo -e "  ${GREEN}Port:${NC}             $SQUID_PORT"
echo -e "  ${GREEN}Cache Size:${NC}       ${CACHE_SIZE} MB"
echo -e "  ${GREEN}Log Retention:${NC}    ${LOG_ROTATE} days"
echo ""

if [ "$AUTH_ENABLED" = true ]; then
    echo -e "  ${GREEN}Authentication:${NC}   ENABLED (user: $PROXY_USER)"
else
    echo -e "  ${GREEN}Authentication:${NC}   DISABLED"
fi

if [ "$IP_FILTER_ENABLED" = true ]; then
    echo -e "  ${GREEN}IP Filtering:${NC}     ENABLED"
    echo "$ALLOWED_IPS_LIST" | grep "src" | sed 's/acl allowed_ips /    /'
else
    echo -e "  ${GREEN}IP Filtering:${NC}     DISABLED"
fi

echo -e "${GREEN}============================================${NC}"
echo ""
echo "Test the proxy with:"
echo "  curl -x http://127.0.0.1:$SQUID_PORT -I https://www.google.com"
echo ""
echo "Useful commands:"
echo "  systemctl status squid"
echo "  tail -f /var/log/squid/access.log"
echo "  systemctl restart squid"
echo ""

print_success "Setup completed successfully!"
