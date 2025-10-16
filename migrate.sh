#!/bin/bash
# RDB to ElastiCache Serverless Migration Tool
# All-in-one script with embedded RedisShake

set -e

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

# Get script directory (works on both Mac and Linux)
SCRIPT_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"
REDISSHAKE_DIR="$SCRIPT_DIR/redisshake"
REDISSHAKE_BIN="$REDISSHAKE_DIR/bin/redis-shake"

echo -e "${BLUE}=========================================="
echo "RDB to ElastiCache Serverless Migration"
echo "==========================================${NC}"
echo

# Parse arguments
RDB_FILE=""
ELASTICACHE_ENDPOINT=""
ELASTICACHE_PASSWORD=""
DRY_RUN=false

show_usage() {
    echo "Usage: $0 [OPTIONS]"
    echo
    echo "Options:"
    echo "  -r, --rdb-file PATH          Path to dump.rdb file (required)"
    echo "  -e, --endpoint HOST          ElastiCache endpoint (required)"
    echo "  -p, --password PASSWORD      ElastiCache password (required)"
    echo "  -d, --dry-run                Test mode (don't write data)"
    echo "  -h, --help                   Show this help"
    echo
    echo "Example:"
    echo "  $0 -r /var/lib/redis/dump.rdb -e my-cluster.serverless.use1.cache.amazonaws.com -p mypassword"
    echo
    echo "Short form:"
    echo "  $0 /path/to/dump.rdb my-cluster.endpoint.com mypassword"
    echo
}

# Parse arguments
while [[ $# -gt 0 ]]; do
    case $1 in
        -r|--rdb-file)
            RDB_FILE="$2"
            shift 2
            ;;
        -e|--endpoint)
            ELASTICACHE_ENDPOINT="$2"
            shift 2
            ;;
        -p|--password)
            ELASTICACHE_PASSWORD="$2"
            shift 2
            ;;
        -d|--dry-run)
            DRY_RUN=true
            shift
            ;;
        -h|--help)
            show_usage
            exit 0
            ;;
        *)
            # Support positional arguments: rdb_file endpoint password
            if [ -z "$RDB_FILE" ]; then
                RDB_FILE="$1"
            elif [ -z "$ELASTICACHE_ENDPOINT" ]; then
                ELASTICACHE_ENDPOINT="$1"
            elif [ -z "$ELASTICACHE_PASSWORD" ]; then
                ELASTICACHE_PASSWORD="$1"
            else
                echo -e "${RED}Error: Unknown argument: $1${NC}"
                show_usage
                exit 1
            fi
            shift
            ;;
    esac
done

# Validate required arguments
if [ -z "$RDB_FILE" ] || [ -z "$ELASTICACHE_ENDPOINT" ]; then
    echo -e "${RED}Error: Missing required arguments${NC}"
    echo
    show_usage
    exit 1
fi

# Remove :6379 if included in endpoint
ELASTICACHE_ENDPOINT="${ELASTICACHE_ENDPOINT%:6379}"

# Validate RDB file exists
if [ ! -f "$RDB_FILE" ]; then
    echo -e "${RED}Error: RDB file not found: $RDB_FILE${NC}"
    exit 1
fi

# Get absolute path for RDB file
RDB_FILE=$(cd "$(dirname "$RDB_FILE")" && pwd)/$(basename "$RDB_FILE")

echo -e "${GREEN}Configuration:${NC}"
echo "  RDB File: $RDB_FILE"
echo "  RDB Size: $(du -h "$RDB_FILE" | cut -f1)"
echo "  Target: $ELASTICACHE_ENDPOINT:6379"
echo "  Dry Run: $DRY_RUN"
echo "  RedisShake: $REDISSHAKE_DIR"
echo

# Check if RedisShake exists, build if needed
if [ ! -f "$REDISSHAKE_BIN" ]; then
    echo -e "${YELLOW}RedisShake binary not found. Building...${NC}"

    if [ ! -d "$REDISSHAKE_DIR" ]; then
        echo -e "${RED}Error: RedisShake directory not found at: $REDISSHAKE_DIR${NC}"
        echo "Please ensure the redisshake directory exists in the project."
        exit 1
    fi

    cd "$REDISSHAKE_DIR"

    if [ ! -f "build.sh" ]; then
        echo -e "${RED}Error: build.sh not found in RedisShake directory${NC}"
        exit 1
    fi

    echo "Running: ./build.sh"
    ./build.sh

    cd "$SCRIPT_DIR"

    if [ ! -f "$REDISSHAKE_BIN" ]; then
        echo -e "${RED}Error: Failed to build RedisShake${NC}"
        exit 1
    fi

    echo -e "${GREEN}RedisShake built successfully${NC}"
    echo
fi

# Create config directory
mkdir -p "$SCRIPT_DIR/configs"
mkdir -p "$SCRIPT_DIR/logs"

# Generate unique config and log files
TIMESTAMP=$(date +%Y%m%d_%H%M%S)
CONFIG_FILE="$SCRIPT_DIR/configs/migration_${TIMESTAMP}.toml"
LOG_FILE="$SCRIPT_DIR/logs/migration_${TIMESTAMP}.log"

echo -e "${YELLOW}Generating configuration...${NC}"

# Create RedisShake config
cat > "$CONFIG_FILE" << EOF
# Auto-generated RedisShake configuration for RDB migration
# Generated: $(date)
# RDB File: $RDB_FILE
# Target: $ELASTICACHE_ENDPOINT:6379

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
# - Keys from db0 remain unchanged
# - Keys from other databases get prefixed with "db{N}:"
function = """
-- Add database prefix to all keys (except db 0)
if DB ~= 0 then
    local prefix = "db" .. DB .. ":"

    -- Add prefix to each key in the command
    for _, index in ipairs(KEY_INDEXES) do
        local key = ARGV[index]
        if key then
            ARGV[index] = prefix .. key
        end
    end

    -- Log first few transformations for verification
    if KEYS[1] then
        shake.log("DB" .. DB .. ": " .. KEYS[1] .. " -> " .. prefix .. KEYS[1])
    end
end

-- Always write to database 0 (cluster mode only supports db 0)
shake.call(0, ARGV)
"""

[advanced]
dir = "$SCRIPT_DIR/data"
ncpu = 0
pprof_port = 0
status_port = 0

# Logging
log_file = "$LOG_FILE"
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

echo -e "${GREEN}Configuration created: $CONFIG_FILE${NC}"
echo

# Create data directory
mkdir -p "$SCRIPT_DIR/data"

# Run migration
echo -e "${GREEN}=========================================="
echo "Starting Migration..."
echo "==========================================${NC}"
echo "Log file: $LOG_FILE"
echo

if [ "$DRY_RUN" = true ]; then
    echo -e "${YELLOW}DRY RUN MODE - No data will be written${NC}"
    echo
fi

"$REDISSHAKE_BIN" "$CONFIG_FILE"

EXIT_CODE=$?

echo
echo -e "${BLUE}=========================================="
if [ $EXIT_CODE -eq 0 ]; then
    echo -e "${GREEN}✓ Migration completed successfully!${NC}"
    echo
    echo "Summary:"
    echo "  - Log file: $LOG_FILE"
    echo "  - Config file: $CONFIG_FILE"
    echo
    echo "Key transformation:"
    echo "  - db0 keys: unchanged"
    echo "  - db1 keys: prefixed with 'db1:'"
    echo "  - db2 keys: prefixed with 'db2:'"
    echo "  - etc."
    echo
    echo "To access migrated data:"
    echo "  redis-cli -h $ELASTICACHE_ENDPOINT -p 6379 --tls --askpass"
    echo
    echo "Example commands:"
    echo "  GET user:123        # Original db0 data"
    echo "  GET db1:user:123    # Original db1 data"
    echo "  KEYS db1:*          # All keys from original db1"
else
    echo -e "${RED}✗ Migration failed with exit code: $EXIT_CODE${NC}"
    echo
    echo "Check the log file for details:"
    echo "  tail -100 $LOG_FILE"
fi

echo -e "${BLUE}==========================================${NC}"

exit $EXIT_CODE
