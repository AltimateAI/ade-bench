#!/bin/bash
set -e

# Configure Altimate API URL with trailing slash to avoid 307 redirects
# Use environment variables with sensible defaults
export ALTIMATE_URL="${ALTIMATE_URL:-https://api.getaltimate.com/}"
export ALTIMATE_API_URL="${ALTIMATE_API_URL:-https://api.getaltimate.com/}"

# Start datamate session server in the background, log to file
# Bind to 0.0.0.0 so it listens on both IPv4 and IPv6
echo "Starting datamate session server..."
datamate start-session-server --host 0.0.0.0 > /logs/datamate-server.log 2>&1 &

# Wait a moment for server to start
sleep 2

# Execute the main command
exec "$@"
