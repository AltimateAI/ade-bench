#!/bin/bash
# Setup MCP server for installed agents
# Arguments: db_type project_type agent_name
# Supports both dbt-mcp and datamate MCP servers

echo "Setting up MCP server..."

# Parse arguments
DB_TYPE="${1:-unknown}"
PROJECT_TYPE="${2:-unknown}"
AGENT_NAME="${3:-unknown}"

echo "Database type: $DB_TYPE"
echo "Project type: $PROJECT_TYPE"
echo "Agent: $AGENT_NAME"

# Determine which MCP server to use (default: datamate)
MCP_SERVER_TYPE="${MCP_SERVER_TYPE:-datamate}"
echo "MCP server type: $MCP_SERVER_TYPE"

# ============================================================================
# DATAMATE MCP SERVER SETUP
# ============================================================================
setup_datamate_mcp() {
    echo "Setting up datamate MCP server..."

    # Wait for datamate server to be ready
    DATAMATE_URL="${DATAMATE_MCP_URL:-http://localhost:7700/sse}"
    echo "Waiting for datamate server at port 7700..."
    MAX_RETRIES=30
    RETRY_COUNT=0
    while ! curl -s --noproxy localhost --max-time 2 "http://localhost:7700/health" >/dev/null 2>&1; do
        RETRY_COUNT=$((RETRY_COUNT + 1))
        if [ $RETRY_COUNT -ge $MAX_RETRIES ]; then
            echo "ERROR: Datamate server not ready after ${MAX_RETRIES} seconds"
            echo "Checking if datamate process is running..."
            ps aux | grep datamate || true
            exit 1
        fi
        echo "  Waiting... (attempt $RETRY_COUNT/$MAX_RETRIES)"
        sleep 1
    done
    echo "Datamate server is ready!"

    # Datamate MCP server configuration via environment variables
    DATAMATE_URL="${DATAMATE_MCP_URL:-http://localhost:7700/sse}"
    DATAMATE_TOKEN="${DATAMATE_MCP_TOKEN:-}"
    DATAMATE_ID="${DATAMATE_MCP_ID:-}"
    DATAMATE_TENANT="${DATAMATE_MCP_TENANT:-}"
    DATAMATE_ALTIMATE_URL="${DATAMATE_ALTIMATE_URL:-https://api.getaltimate.com}"

    # Check if token is set
    if [ -z "$DATAMATE_TOKEN" ]; then
        echo "WARNING: DATAMATE_MCP_TOKEN is not set. MCP authentication may fail."
    fi

    if [[ "$AGENT_NAME" == "claude" ]]; then
        echo "Registering datamate MCP server with Claude..."

        # Unset proxy for localhost MCP connections and set NO_PROXY
        unset HTTP_PROXY HTTPS_PROXY ALL_PROXY http_proxy https_proxy all_proxy
        export NO_PROXY="localhost,127.0.0.1,::1,0.0.0.0"
        export no_proxy="localhost,127.0.0.1,::1,0.0.0.0"

        # Show datamate server log
        echo "=== Datamate server log ==="
        cat /logs/datamate-server.log 2>/dev/null | tail -20 || echo "No log file"
        echo "=== End log ==="

        # Test with explicit noproxy
        echo ""
        echo "Testing SSE with noproxy:"
        timeout 2 curl -s --noproxy '*' "http://127.0.0.1:7700/sse" \
            -H "Authorization: Bearer $DATAMATE_TOKEN" \
            -H "x-datamate-id: $DATAMATE_ID" \
            -H "x-tenant: $DATAMATE_TENANT" || echo "(timeout - expected for SSE stream)"

        echo ""
        echo "Testing health endpoint:"
        curl -s --noproxy '*' "http://127.0.0.1:7700/health" || echo "(failed)"

        # Register with Claude using the sse transport (use 127.0.0.1 to avoid proxy issues)
        DATAMATE_URL_IPV4="${DATAMATE_URL/localhost/127.0.0.1}"
        echo "Using URL: $DATAMATE_URL_IPV4"
        claude mcp add datamate --transport sse "$DATAMATE_URL_IPV4" \
            -H "Authorization: Bearer $DATAMATE_TOKEN" \
            -H "x-datamate-id: $DATAMATE_ID" \
            -H "x-connection-dbt: 30" \
            -H "x-tenant: $DATAMATE_TENANT" \
            -H "x-altimate-url: $DATAMATE_ALTIMATE_URL"

        echo "Claude config after registration:"
        cat /root/.claude.json 2>/dev/null || echo "Config file not found"

        echo ""
        echo "Running claude mcp list..."
        claude mcp list

    elif [[ "$AGENT_NAME" == "codex" ]]; then
        echo "Registering datamate MCP server with Codex..."
        unset HTTP_PROXY HTTPS_PROXY ALL_PROXY http_proxy https_proxy all_proxy
        codex mcp add datamate --transport sse "$DATAMATE_URL" \
            -H "Authorization: Bearer $DATAMATE_TOKEN" \
            -H "x-datamate-id: $DATAMATE_ID" \
            -H "x-tenant: $DATAMATE_TENANT" \
            -H "x-altimate-url: $DATAMATE_ALTIMATE_URL"
        codex mcp list

    elif [[ "$AGENT_NAME" == "gemini" ]]; then
        echo "Registering datamate MCP server with Gemini..."
        unset HTTP_PROXY HTTPS_PROXY ALL_PROXY http_proxy https_proxy all_proxy
        gemini mcp add datamate --transport sse "$DATAMATE_URL" \
            -H "Authorization: Bearer $DATAMATE_TOKEN" \
            -H "x-datamate-id: $DATAMATE_ID" \
            -H "x-tenant: $DATAMATE_TENANT" \
            -H "x-altimate-url: $DATAMATE_ALTIMATE_URL"
        gemini mcp list

    else
        echo "Skipping datamate MCP setup - '$AGENT_NAME' is not supported"
        exit 0
    fi
}

# ============================================================================
# DBT-MCP SERVER SETUP
# ============================================================================
setup_dbt_mcp() {
    echo "Setting up dbt MCP server..."

    # Check if project type is dbt
    if [[ ! " dbt dbt-fusion " =~ " $PROJECT_TYPE " ]]; then
        echo "Skipping dbt MCP setup - '$PROJECT_TYPE' is not supported"
        exit 0
    fi

    # Check if database type is supported
    if [[ ! " snowflake " =~ " $DB_TYPE " ]]; then
        echo "Skipping dbt MCP setup - '$DB_TYPE' is not supported"
        exit 0
    fi

    # Get working directory and env file location
    project_dir=$(pwd)
    env_file="${project_dir}/.env"

    # Find dbt path
    dbt_path=$(which dbt)
    if [ -z "$dbt_path" ]; then
        echo "WARNING: dbt not found in PATH, skipping MCP setup"
        exit 0
    fi

    # Create .env file for dbt-mcp
    cat > "$env_file" << EOF
DBT_PROJECT_DIR=$project_dir
DBT_PATH=$dbt_path
DISABLE_DBT_CLI=false
DISABLE_SEMANTIC_LAYER=true
DISABLE_DISCOVERY=true
DISABLE_ADMIN_API=true
DISABLE_SQL=true
DISABLE_DBT_CODEGEN=true
EOF

    # Check if dbt-mcp is already installed (pre-installed in Docker image)
    if ! command -v dbt-mcp &> /dev/null; then
        echo "dbt-mcp not found, installing..."
        uv tool install dbt-mcp --force
        echo "dbt-mcp installed"
    fi

    if [[ "$AGENT_NAME" == "claude" ]]; then
        echo "Registering dbt MCP server with Claude..."
        claude mcp add dbt -- uvx --env-file "$env_file" dbt-mcp
        claude mcp list

    elif [[ "$AGENT_NAME" == "codex" ]]; then
        echo "Registering dbt MCP server with Codex..."
        codex mcp add dbt -- uvx --env-file "$env_file" dbt-mcp
        codex mcp list

    elif [[ "$AGENT_NAME" == "gemini" ]]; then
        echo "Registering dbt MCP server with Gemini..."
        gemini mcp add dbt uvx -- --env-file "$env_file" dbt-mcp
        gemini mcp list

    else
        echo "Skipping dbt MCP setup - '$AGENT_NAME' is not supported"
        exit 0
    fi
}

# ============================================================================
# MAIN: Select and run appropriate MCP server setup
# ============================================================================
if [[ "$MCP_SERVER_TYPE" == "dbt-mcp" ]]; then
    setup_dbt_mcp
elif [[ "$MCP_SERVER_TYPE" == "datamate" ]]; then
    setup_datamate_mcp
else
    echo "Unknown MCP_SERVER_TYPE: $MCP_SERVER_TYPE"
    echo "Valid options: 'datamate' or 'dbt-mcp'"
    exit 1
fi
