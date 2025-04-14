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
: "${ARIA2RPCPORT:=6800}"

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

# Function to check if a port is available
check_port() {
    port="$1"
    if nc -z 127.0.0.1 "${port}" 2>/dev/null; then
        log_error "Port ${port} is already in use. Please check for other services using this port."
        return 1
    fi
    return 0
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

# Check required ports first, before making any changes
log_info "Checking if required ports are available..."
check_port "${UI_PORT}" || { log_error "Web UI port ${UI_PORT} is unavailable. Exiting."; exit 1; }
check_port "${ARIA2RPCPORT}" || { log_error "Aria2 RPC port ${ARIA2RPCPORT} is unavailable. Exiting."; exit 1; }

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
if [ -n "${RPC_SECRET}" ]; then
    log_info "Setting RPC secret"
    if grep -q "^rpc-secret=" "${conf_path}/aria2.conf"; then
        # Remove existing rpc-secret line
        sed -i '/^rpc-secret=/d' "${conf_path}/aria2.conf" || { log_error "Could not update RPC secret in config"; exit 1; }
    fi
    
    # Add new RPC secret
    printf 'rpc-secret=%s\n' "${RPC_SECRET}" >> "${conf_path}/aria2.conf" || { log_error "Could not add RPC secret to config"; exit 1; }

    if [ -n "${EMBED_RPC_SECRET}" ]; then
        log_info "Embedding RPC secret into ariang Web UI"
        RPC_SECRET_BASE64=$(echo -n "${RPC_SECRET}" | base64 -w 0)
        sed -i 's,secret:"[^"]*",secret:"'"${RPC_SECRET_BASE64}"'",g' ${ariang_js_path} || log_warn "Could not embed RPC secret in AriaNG"
    fi
fi

# Update ports if needed
ARIA2_PORT_OPTION=""
if [ "${ARIA2RPCPORT}" != "6800" ]; then
    log_info "Changing RPC port to ${ARIA2RPCPORT}"
    # Update AriaNG
    sed -i "s/6800/${ARIA2RPCPORT}/g" ${ariang_js_path} || log_warn "Could not update RPC port in AriaNG"
    # Update Caddyfile
    sed -i "s/127.0.0.1:6800/127.0.0.1:${ARIA2RPCPORT}/g" "${caddyfile}" || log_warn "Could not update RPC port in Caddyfile"
    # Add port option for aria2c
    ARIA2_PORT_OPTION="--rpc-listen-port=${ARIA2RPCPORT}"
fi

if [ "${UI_PORT}" != "8080" ]; then
    log_info "Changing Web UI port to ${UI_PORT}"
    sed -i "s/:8080/:${UI_PORT}/g" "${caddyfile}" || log_warn "Could not update UI port in Caddyfile"
fi

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
chown -R "${userid}:${groupid}" "${conf_path}" "${data_path}" /var/log/caddy || log_warn "Could not set ownership of directories"

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
    if [ -f "${pid_file}" ]; then
        aria2_pid=$(cat "${pid_file}" 2>/dev/null)
        if [ -n "${aria2_pid}" ] && kill -0 "${aria2_pid}" 2>/dev/null; then
            kill -TERM "${aria2_pid}" 2>/dev/null || true
            # Wait for process to terminate
            for i in $(seq 1 10); do
                if ! kill -0 "${aria2_pid}" 2>/dev/null; then
                    break
                fi
                sleep 1
            done
            # Force kill if still running
            if kill -0 "${aria2_pid}" 2>/dev/null; then
                log_warn "aria2c didn't terminate gracefully, forcing..."
                kill -9 "${aria2_pid}" 2>/dev/null || true
            fi
        fi
        rm -f "${pid_file}" 2>/dev/null || true
    fi
    caddy stop
    log_info "Services stopped gracefully"
    exit 0
}

# Trap SIGTERM and SIGINT
trap shutdown SIGTERM SIGINT

# Start services
log_info "Starting Caddy..."
caddy start -config "${caddyfile}" -adapter=caddyfile || { log_error "Failed to start Caddy"; exit 1; }
sleep 1  # Give Caddy a moment to start

log_info "Starting aria2c..."
# Run aria2c in daemon mode with proper user permissions
su-exec "${userid}:${groupid}" aria2c --daemon --pid-file="${pid_file}" ${ARIA2_PORT_OPTION} "$@" || { log_error "Failed to start aria2c"; exit 1; }
sleep 1  # Give aria2c a moment to start

# Verify services are running
if ! pgrep caddy >/dev/null; then
    log_error "Caddy failed to start"
    exit 1
fi

if [ ! -f "${pid_file}" ] || ! kill -0 "$(cat "${pid_file}")" 2>/dev/null; then
    log_error "aria2c failed to start"
    exit 1
fi

log_info "Setup complete - AriaNG is available at http://localhost:${UI_PORT}"

# Keep the container running and monitor processes
while true; do
    if [ ! -f "${pid_file}" ] || ! kill -0 "$(cat "${pid_file}")" 2>/dev/null; then
        log_error "aria2c process died, shutting down..."
        shutdown
    fi
    
    if ! pgrep caddy >/dev/null; then
        log_error "Caddy process died, shutting down..."
        shutdown
    fi
    
    sleep 5
done
