#!/bin/sh
set -e

conf_path="/aria2/conf"
conf_copy_path="/aria2/conf-copy"
data_path="/aria2/data"
ariang_js_path="/usr/local/www/ariang/js/aria-ng*.js"
pid_file="${conf_path}/aria2.pid"
caddyfile="/usr/local/caddy/Caddyfile"
log_prefix="[$(date '+%Y-%m-%d %H:%M:%S')]"

# Set default ports (can be overridden by environment variables)
: "${UI_PORT:=8080}"
: "${ARIA2_RPC_PORT:=6800}"

# Function to log messages
log_info() {
    echo "${log_prefix} INFO: $1"
}

log_warn() {
    echo "${log_prefix} WARNING: $1" >&2
}

log_error() {
    echo "${log_prefix} ERROR: $1" >&2
}

# Set user and group IDs
userid="$(id -u)" # Default to current user
groupid="$(id -g)" # Default to current group

if [ -n "${PUID}" ] && [ -n "${PGID}" ]; then
    log_info "Running as user ${PUID}:${PGID}"
    userid="${PUID}"
    groupid="${PGID}"
else
    log_info "Running as user ${userid}:${groupid}"
fi

# Create directories with proper ownership
mkdir -p "${conf_path}" "${data_path}" || { log_error "Failed to create required directories"; exit 1; }

# Copy config file only if it doesn't exist
if [ ! -f "${conf_path}/aria2.conf" ]; then
    log_info "Copying default configuration file"
    cp "${conf_copy_path}/aria2.conf" "${conf_path}/aria2.conf" || { log_error "Could not copy default config file"; exit 1; }
fi

# Create session file if it doesn't exist
if [ ! -f "${conf_path}/aria2.session" ]; then
    touch "${conf_path}/aria2.session" || { log_error "Could not create session file"; exit 1; }
fi

# Handle RPC secret
ARIA2_SECRET_OPTION=""
if [ -n "${RPC_SECRET}" ]; then
    log_info "Setting RPC secret via command line"
    ARIA2_SECRET_OPTION="--rpc-secret=${RPC_SECRET}"
fi

# Update ports if needed
log_info "Using UI Port: ${UI_PORT}"
log_info "Using Aria2 RPC Port: ${ARIA2_RPC_PORT}"
export UI_PORT # Export for Caddy
export ARIA2_RPC_PORT # Export for Caddy

# Handle basic auth
if [ -n "${BASIC_AUTH_USERNAME}" ] && [ -n "${BASIC_AUTH_PASSWORD}" ]; then
    log_info "Enabling caddy basic auth"
    echo "
        basicauth / {
            ${BASIC_AUTH_USERNAME} $(caddy hash-password -plaintext "${BASIC_AUTH_PASSWORD}")
        }
    " >> "${caddyfile}" || log_warn "Could not update Caddyfile"
fi

# Ensure log directory exists
mkdir -p /var/log/caddy || log_warn "Could not create Caddy log directory"

# Set permissions
chown -R "${userid}:${groupid}" "${conf_path}" "${data_path}" /var/log/caddy /config || log_warn "Could not set ownership of directories"

# Verify Caddyfile
log_info "Validating Caddy configuration..."
if ! caddy validate --config "${caddyfile}" --adapter=caddyfile; then
    log_error "Invalid Caddy configuration. Exiting."
    exit 1
fi

# Clean up stale PID file if it exists
if [ -f "${pid_file}" ]; then
    log_warn "Removing stale PID file"
    rm -f "${pid_file}" || log_warn "Could not remove stale PID file"
fi

# Function to handle shutdown
shutdown() {
    log_info "Shutting down..."
    if [ -n "${ARIA2_PID}" ] && kill -0 "${ARIA2_PID}" 2>/dev/null; then
        kill -TERM "${ARIA2_PID}" 2>/dev/null || true
        # Wait for process to terminate
        for i in $(seq 1 10); do
            if ! kill -0 "${ARIA2_PID}" 2>/dev/null; then
                break
            fi
            sleep 1
        done
        # Force kill if still running
        if kill -0 "${ARIA2_PID}" 2>/dev/null; then
            log_warn "aria2c didn't terminate gracefully, forcing..."
            kill -9 "${ARIA2_PID}" 2>/dev/null || true
        fi
    fi
    rm -f "${pid_file}" 2>/dev/null || true
    caddy stop
    log_info "Services stopped gracefully"
    exit 0
}

# Trap SIGTERM and SIGINT
trap shutdown TERM INT

# Start services
log_info "Starting Caddy..."
caddy start --config "${caddyfile}" --adapter=caddyfile || { log_error "Failed to start Caddy"; exit 1; }
sleep 1  # Give Caddy a moment to start

log_info "Starting aria2c..."
# Check if move.sh exists and is executable
if [ -f "/aria2/conf/move.sh" ]; then
    if [ ! -x "/aria2/conf/move.sh" ]; then
        log_warn "move.sh exists but is not executable. Adding execute permission."
        chmod +x "/aria2/conf/move.sh" || log_warn "Could not set execute permission on move.sh"
    fi
else
    log_warn "move.sh does not exist. This may cause aria2c to fail."
fi

# Run aria2c and capture error output in detail
ERROR_LOG="/tmp/aria2c_error.log"
log_info "Running aria2c"
su-exec "$userid":"$groupid" aria2c "$@" --rpc-listen-port="${ARIA2_RPC_PORT}" ${ARIA2_SECRET_OPTION} 2> "${ERROR_LOG}" || {
    log_error "Failed to start aria2c. Error: $(cat $ERROR_LOG)"
    exit 1
}

# Try to get the PID
sleep 1
ARIA2_PID=$(pgrep aria2c)
if [ -z "$ARIA2_PID" ]; then
    log_error "Failed to start aria2c. Error: $(cat $ERROR_LOG 2>/dev/null || echo 'No error output captured')"
    exit 1
fi

echo "${ARIA2_PID}" > "${pid_file}" || log_warn "Could not write PID file"

# Verify services are running
if ! pgrep caddy >/dev/null; then
    log_error "Caddy failed to start"
    exit 1
fi

log_info "Setup complete - AriaNG is available at http://localhost:${UI_PORT}"

# Keep the container running and monitor processes
while true; do
    if ! kill -0 "${ARIA2_PID}" 2>/dev/null; then
        log_error "aria2c process died, shutting down..."
        shutdown
    fi
    
    if ! pgrep caddy >/dev/null; then
        log_error "Caddy process died, shutting down..."
        shutdown
    fi
    
    sleep 5
done
