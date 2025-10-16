#!/bin/bash
# RDB to ElastiCache Migration using RedisShake
# This is a simpler approach that uses RedisShake's built-in RDB reader

set -e

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

echo "=========================================="
echo "RDB to ElastiCache Serverless Migration"
echo "Using RedisShake"
echo "=========================================="
echo

# Configuration
RDB_FILE="${1:-}"
ELASTICACHE_ENDPOINT="${2:-}"
ELASTICACHE_PASSWORD="${3:-}"
REDISSHAKE_PATH="${4:-/Users/smashal/dev/RedisShake}"

# Validate inputs
if [ -z "$RDB_FILE" ]; then
    echo -e "${RED}Error: RDB file path is required${NC}"
    echo "Usage: $0 <rdb_file> <elasticache_endpoint> <password> [redisshake_path]"
    echo "Example: $0 /path/to/dump.rdb my-cluster.serverless.use1.cache.amazonaws.com mypassword"
    exit 1
fi

if [ -z "$ELASTICACHE_ENDPOINT" ]; then
    echo -e "${RED}Error: ElastiCache endpoint is required${NC}"
    echo "Usage: $0 <rdb_file> <elasticache_endpoint> <password> [redisshake_path]"
    exit 1
fi

if [ ! -f "$RDB_FILE" ]; then
    echo -e "${RED}Error: RDB file not found: $RDB_FILE${NC}"
    exit 1
fi

if [ ! -d "$REDISSHAKE_PATH" ]; then
    echo -e "${RED}Error: RedisShake not found at: $REDISSHAKE_PATH${NC}"
    exit 1
fi

echo -e "${GREEN}Configuration:${NC}"
echo "  RDB File: $RDB_FILE"
echo "  Target: $ELASTICACHE_ENDPOINT"
echo "  RedisShake: $REDISSHAKE_PATH"
echo

# Create temporary config file
CONFIG_FILE=$(mktemp /tmp/redisshake-rdb-migration.XXXXXX.toml)
echo -e "${YELLOW}Creating configuration: $CONFIG_FILE${NC}"

cat > "$CONFIG_FILE" << EOF
# Auto-generated RedisShake configuration for RDB migration
# Generated: $(date)

[rdb_reader]
filepath = "$RDB_FILE"

[redis_writer]
cluster = true
address = "$ELASTICACHE_ENDPOINT:6379"
username = ""
password = "$ELASTICACHE_PASSWORD"
tls = true
off_reply = false

[filter]
# Lua function to handle multi-database migration to cluster mode
# Keys from db0 remain unchanged
# Keys from other databases get prefixed with "db{N}:"
function = """
-- Add database prefix to all keys (except db 0)
if DB ~= 0 then
    local prefix = "db" .. DB .. ":"

    -- Log transformation for debugging
    shake.log("DB " .. DB .. ": Transforming " .. #KEY_INDEXES .. " keys with prefix " .. prefix)

    -- Add prefix to each key in the command
    for _, index in ipairs(KEY_INDEXES) do
        local key = ARGV[index]
        if key then
            local old_key = key
            ARGV[index] = prefix .. key
            shake.log("  " .. old_key .. " -> " .. ARGV[index])
        end
    end
end

-- Always write to database 0 (cluster mode only supports db 0)
shake.call(0, ARGV)
"""

[advanced]
dir = "data"
ncpu = 0
pprof_port = 0
status_port = 0

# Logging
log_file = "rdb-elasticache-migration.log"
log_level = "info"
log_interval = 5
log_rotation = true
log_max_size = 512
log_max_age = 7
log_max_backups = 3
log_compress = true

# Restore behavior
rdb_restore_command_behavior = "rewrite"

# Performance tuning for ElastiCache Serverless
pipeline_count_limit = 512
target_redis_max_qps = 50000

# Protocol limits
target_redis_client_max_querybuf_len = 1073741824
target_redis_proto_max_bulk_len = 512_000_000

aws_psync = ""
empty_db_before_sync = false

[module]
target_mbbloom_version = 20603
EOF

echo -e "${GREEN}Configuration created successfully${NC}"
echo

# Check if RedisShake binary exists
REDISSHAKE_BIN="$REDISSHAKE_PATH/bin/redis-shake"
if [ ! -f "$REDISSHAKE_BIN" ]; then
    echo -e "${YELLOW}RedisShake binary not found. Building...${NC}"
    cd "$REDISSHAKE_PATH"
    ./build.sh
    cd - > /dev/null
fi

if [ ! -f "$REDISSHAKE_BIN" ]; then
    echo -e "${RED}Error: Failed to build RedisShake${NC}"
    exit 1
fi

# Run migration
echo -e "${GREEN}Starting migration...${NC}"
echo "Log file: $REDISSHAKE_PATH/data/rdb-elasticache-migration.log"
echo "=========================================="
echo

"$REDISSHAKE_BIN" "$CONFIG_FILE"

EXIT_CODE=$?

echo
echo "=========================================="
if [ $EXIT_CODE -eq 0 ]; then
    echo -e "${GREEN}Migration completed successfully!${NC}"
    echo
    echo "Summary:"
    echo "  - Check logs: $REDISSHAKE_PATH/data/rdb-elasticache-migration.log"
    echo "  - Config file: $CONFIG_FILE (temporary)"
    echo
    echo "Key transformation:"
    echo "  db0 keys: unchanged"
    echo "  db1 keys: prefixed with 'db1:'"
    echo "  db2 keys: prefixed with 'db2:'"
    echo "  etc."
else
    echo -e "${RED}Migration failed with exit code: $EXIT_CODE${NC}"
    echo "Check the log file for details: $REDISSHAKE_PATH/data/rdb-elasticache-migration.log"
fi

echo
echo "Cleanup: To remove the config file, run: rm $CONFIG_FILE"
echo "=========================================="

exit $EXIT_CODE
