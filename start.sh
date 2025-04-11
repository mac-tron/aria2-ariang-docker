#!/bin/sh
set -e

conf_path=/aria2/conf
conf_copy_path=/aria2/conf-copy
data_path=/aria2/data
ariang_js_path=/usr/local/www/ariang/js/aria-ng*.js
pid_file=/aria2/conf/aria2.pid

# Create directories if they don't exist
mkdir -p "$conf_path" "$data_path"

# If config does not exist - use default
if [ ! -f "$conf_path/aria2.conf" ]; then
    cp "$conf_copy_path/aria2.conf" "$conf_path/aria2.conf"
fi

# Handle RPC secret
if [ -n "$RPC_SECRET" ]; then
    sed -i '/^rpc-secret=/d' "$conf_path/aria2.conf"
    printf 'rpc-secret=%s\n' "${RPC_SECRET}" >>"$conf_path/aria2.conf"

    if [ -n "$EMBED_RPC_SECRET" ]; then
        echo "Embedding RPC secret into ariang Web UI"
        RPC_SECRET_BASE64=$(echo -n "${RPC_SECRET}" | base64 -w 0)
        sed -i 's,secret:"[^"]*",secret:"'"${RPC_SECRET_BASE64}"'",g' $ariang_js_path
    fi
fi

# Handle basic auth
if [ -n "$BASIC_AUTH_USERNAME" ] && [ -n "$BASIC_AUTH_PASSWORD" ]; then
    echo "Enabling caddy basic auth"
    echo "
        basicauth / {
            $BASIC_AUTH_USERNAME $(caddy hash-password -plaintext "${BASIC_AUTH_PASSWORD}")
        }
    " >>/usr/local/caddy/Caddyfile
fi

# Create session file if it doesn't exist
touch "$conf_path/aria2.session"

# Handle RPC port
if [ -n "$ARIA2RPCPORT" ]; then
    echo "Changing rpc request port to $ARIA2RPCPORT"
    sed -i "s/6800/${ARIA2RPCPORT}/g" $ariang_js_path
fi

# Set user and group IDs
userid=${PUID:-$(id -u)}
groupid=${PGID:-$(id -g)}

echo "Running as user $userid:$groupid"

# Set permissions
chown -R "$userid":"$groupid" "$conf_path"
chown -R "$userid":"$groupid" "$data_path"

# Start services
echo "Starting Caddy..."
caddy start -config /usr/local/caddy/Caddyfile -adapter=caddyfile

echo "Starting aria2c..."
# Run aria2c in daemon mode
su-exec "$userid":"$groupid" aria2c --daemon --pid-file="$pid_file" "$@"

# Function to handle shutdown
shutdown() {
    echo "Shutting down..."
    if [ -f "$pid_file" ]; then
        kill -TERM "$(cat "$pid_file")"
        rm -f "$pid_file"
    fi
    caddy stop
    exit 0
}

# Trap SIGTERM and SIGINT
trap shutdown SIGTERM SIGINT

# Keep the container running and wait for signals
while true; do
    if [ ! -f "$pid_file" ] || ! kill -0 "$(cat "$pid_file")" 2>/dev/null; then
        echo "aria2c process died, shutting down..."
        shutdown
    fi
    sleep 5
done
