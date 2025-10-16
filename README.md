# RDB to ElastiCache Serverless Migration Tool

Two approaches to migrate Redis dump.rdb files to AWS ElastiCache Serverless (cluster mode):
1. **Simple Shell Script** (Uses RedisShake - Recommended)
2. **Python Tool** (Standalone, more customizable)

## Problem Statement

ElastiCache Serverless runs in cluster mode, which **only supports database 0**. If your source Redis has data across multiple databases (db0, db1, db2, etc.), you cannot directly migrate them using the standard approach.

This tool solves this by:
- Reading all databases from your dump.rdb file
- Prefixing keys from non-zero databases (e.g., `user:123` in db1 becomes `db1:user:123` in db0)
- Writing everything to database 0 in ElastiCache Serverless
- Preserving all key types: strings, hashes, lists, sets, sorted sets
- Maintaining TTLs and expiration times

## How RDB Reading Works

Both tools can read RDB files:

### Option 1: RedisShake (Recommended - Simpler)
- RedisShake has a **built-in RDB parser** (written in Go)
- Located in: `/internal/rdb/rdb.go` and `/internal/reader/rdb_reader.go`
- Supports all RDB versions and Redis data types
- **No external dependencies** needed
- Uses the `[rdb_reader]` configuration section

### Option 2: Python Tool
- Uses the `rdbtools` Python library
- Also supports all RDB versions and Redis data types
- Requires Python dependencies installation

## Features

**Both tools provide:**
- Parses Redis RDB files of any version
- Supports all Redis data types (string, hash, list, set, zset)
- Preserves TTLs and expiration times
- Automatic database prefixing for multi-database sources
- TLS/SSL support for ElastiCache
- Cluster mode support
- Dry-run mode for testing
- Detailed logging and statistics
- Error handling and recovery

## Quick Start - Option 1: RedisShake Script (Easiest)

This uses RedisShake's built-in RDB reader - **No dependencies to install!**

```bash
cd ~/dev/rdb-elasticache-migrator

# Run migration (one command!)
./migrate-with-redisshake.sh \
  /path/to/dump.rdb \
  your-cluster.serverless.use1.cache.amazonaws.com \
  YOUR_AUTH_TOKEN
```

That's it! The script will:
1. Auto-generate a RedisShake config
2. Build RedisShake if needed
3. Run the migration
4. Show progress and results

### How It Works

RedisShake contains a complete RDB parser that:
- Reads the RDB file binary format directly
- Parses all databases (db0, db1, db2, etc.)
- Applies Lua transformation to prefix keys
- Writes to ElastiCache in real-time

The RDB reader is in RedisShake at:
- Parser: `internal/rdb/rdb.go:71-230`
- Reader: `internal/reader/rdb_reader.go:34-76`

---

## Option 2: Python Tool (More Customizable)

### Prerequisites

- Python 3.7+
- pip

### Setup

```bash
cd ~/dev/rdb-elasticache-migrator

# Create virtual environment (recommended)
python3 -m venv venv
source venv/bin/activate

# Install dependencies
pip install -r requirements.txt
```

## Configuration

1. Copy the example configuration:

```bash
cp config.example.json config.json
```

2. Edit `config.json` with your settings:

```json
{
  "source": {
    "rdb_file": "/path/to/your/dump.rdb"
  },
  "target": {
    "host": "your-cluster.serverless.use1.cache.amazonaws.com",
    "port": 6379,
    "password": "YOUR_ELASTICACHE_AUTH_TOKEN",
    "tls": true,
    "cluster": true
  },
  "dry_run": false,
  "prefix_dbs": true
}
```

### Configuration Options

| Option | Description | Required |
|--------|-------------|----------|
| `source.rdb_file` | Path to your Redis dump.rdb file | Yes |
| `target.host` | ElastiCache endpoint | Yes |
| `target.port` | Redis port (default: 6379) | No |
| `target.password` | ElastiCache auth token | Yes (for ElastiCache) |
| `target.tls` | Enable TLS/SSL (required for ElastiCache) | Yes |
| `target.cluster` | Use cluster mode (true for ElastiCache Serverless) | Yes |
| `dry_run` | If true, only log operations without writing | No (default: false) |
| `prefix_dbs` | If true, prefix keys from non-zero databases | No (default: true) |

## Usage

### Basic Usage

```bash
python migrate.py --config config.json
```

### Dry Run (Test Mode)

Test the migration without actually writing data:

```bash
# Set dry_run to true in config.json, then:
python migrate.py --config config.json
```

### Get RDB File from Running Redis

If you need to create an RDB file from a running Redis instance:

```bash
# Connect to your Redis instance
redis-cli -h localhost -p 6379

# Trigger a background save
BGSAVE

# Wait for it to complete (check with)
LASTSAVE

# Find the RDB file (usually in /var/lib/redis/dump.rdb or check redis.conf)
# Copy it to your migration machine
scp user@redis-server:/var/lib/redis/dump.rdb ./dump.rdb
```

## Key Transformation Examples

With `prefix_dbs: true`, keys from different databases are transformed:

| Source | Target |
|--------|--------|
| db0: `user:123` | db0: `user:123` (unchanged) |
| db1: `user:123` | db0: `db1:user:123` |
| db2: `cache:xyz` | db0: `db2:cache:xyz` |
| db15: `temp:abc` | db0: `db15:temp:abc` |

## Output

The tool provides:

1. **Console output**: Real-time progress and statistics
2. **Log file** (`migration.log`): Detailed operation log
3. **Statistics**:
   - Total keys processed
   - Keys per database
   - Keys per type (string, hash, list, set, zset)
   - Error count

Example output:

```
2025-10-16 13:45:00 - INFO - ============================================================
2025-10-16 13:45:00 - INFO - RDB to ElastiCache Serverless Migration
2025-10-16 13:45:00 - INFO - ============================================================
2025-10-16 13:45:00 - INFO - Source RDB: /path/to/dump.rdb
2025-10-16 13:45:00 - INFO - Target: your-cluster.serverless.use1.cache.amazonaws.com
2025-10-16 13:45:00 - INFO - Dry run: False
2025-10-16 13:45:00 - INFO - Prefix databases: True
2025-10-16 13:45:00 - INFO - ============================================================
2025-10-16 13:45:01 - INFO - Successfully connected to your-cluster.serverless.use1.cache.amazonaws.com:6379
2025-10-16 13:45:01 - INFO - Starting RDB parse...
2025-10-16 13:45:01 - INFO - Processing database 0
2025-10-16 13:45:15 - INFO - Completed database 0: 15234 keys
2025-10-16 13:45:15 - INFO - Processing database 1
2025-10-16 13:45:28 - INFO - Completed database 1: 8456 keys
2025-10-16 13:45:28 - INFO - RDB parse complete!
2025-10-16 13:45:28 - INFO - Total keys processed: 23690
2025-10-16 13:45:28 - INFO - Errors: 0
2025-10-16 13:45:28 - INFO - By database: {0: 15234, 1: 8456}
2025-10-16 13:45:28 - INFO - By type: {'string': 12000, 'hash': 8000, 'set': 2500, 'list': 890, 'zset': 300}
2025-10-16 13:45:28 - INFO - ============================================================
2025-10-16 13:45:28 - INFO - Migration completed!
2025-10-16 13:45:28 - INFO - ============================================================
```

## Accessing Migrated Data

After migration, access your data in ElastiCache:

```python
import redis

# Connect to ElastiCache
r = redis.Redis(
    host='your-cluster.serverless.use1.cache.amazonaws.com',
    port=6379,
    password='YOUR_AUTH_TOKEN',
    ssl=True
)

# Access data from original db0 (unchanged)
value = r.get('user:123')

# Access data from original db1 (now prefixed)
value = r.get('db1:user:123')

# Access data from original db2 (now prefixed)
value = r.get('db2:cache:xyz')
```

## Troubleshooting

### Connection Issues

```
Error: Failed to connect to Redis
```

**Solutions:**
- Verify ElastiCache security group allows your IP
- Check that TLS is enabled in config
- Verify the auth token is correct
- Ensure the endpoint URL is correct

### RDB Parse Errors

```
Error parsing RDB file
```

**Solutions:**
- Verify the RDB file path is correct
- Ensure the RDB file is not corrupted
- Check file permissions
- Try creating a fresh RDB dump

### Memory Issues

For very large RDB files:
- Run on a machine with sufficient RAM
- Consider splitting the migration by filtering databases
- Process in batches if needed

## Alternative: Using RedisShake

If you prefer using RedisShake (the tool you already have), you can also use it with an RDB file:

```bash
cd /Users/smashal/dev/RedisShake

# Create config for RDB reader
cat > elasticache-from-rdb.toml << 'EOF'
[rdb_reader]
filepath = "/path/to/your/dump.rdb"

[redis_writer]
cluster = true
address = "your-cluster.serverless.use1.cache.amazonaws.com:6379"
password = "YOUR_AUTH_TOKEN"
tls = true

[filter]
function = """
if DB ~= 0 then
    local prefix = "db" .. DB .. ":"
    for _, index in ipairs(KEY_INDEXES) do
        local key = ARGV[index]
        if key then
            ARGV[index] = prefix .. key
        end
    end
end
shake.call(0, ARGV)
"""

[advanced]
log_file = "rdb-migration.log"
log_level = "info"
rdb_restore_command_behavior = "rewrite"
pipeline_count_limit = 512
target_redis_max_qps = 50000
EOF

# Run migration
./bin/redis-shake elasticache-from-rdb.toml
```

## License

MIT

## Support

For issues or questions:
1. Check the `migration.log` file for detailed error messages
2. Verify your configuration
3. Test with `dry_run: true` first
4. Review ElastiCache security group and network settings
