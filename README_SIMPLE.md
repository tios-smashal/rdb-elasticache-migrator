# RDB to ElastiCache Migration - Complete Package

This is a self-contained project with everything you need to migrate Redis RDB files to ElastiCache Serverless.

## What's Included

```
rdb-elasticache-migrator/
├── migrate.sh              # Main migration script (USE THIS!)
├── redisshake/             # Complete RedisShake source code
├── configs/                # Generated configs (auto-created)
├── logs/                   # Migration logs (auto-created)
└── data/                   # Working directory (auto-created)
```

## Quick Start

### Option 1: Simple Command (Recommended)

```bash
cd ~/dev/rdb-elasticache-migrator

./migrate.sh \
  /var/lib/redis/dump.rdb \
  saif-serverlesss-eyty4q.serverless.use1.cache.amazonaws.com \
  YOUR_PASSWORD
```

### Option 2: With Named Arguments

```bash
./migrate.sh \
  --rdb-file /var/lib/redis/dump.rdb \
  --endpoint saif-serverlesss-eyty4q.serverless.use1.cache.amazonaws.com \
  --password YOUR_PASSWORD
```

### Option 3: Dry Run (Test First)

```bash
./migrate.sh \
  --rdb-file /var/lib/redis/dump.rdb \
  --endpoint saif-serverlesss-eyty4q.serverless.use1.cache.amazonaws.com \
  --password YOUR_PASSWORD \
  --dry-run
```

## What the Script Does

1. **Validates** your RDB file exists
2. **Builds RedisShake** if needed (first time only)
3. **Generates config** with Lua function for database prefixing
4. **Runs migration** and shows progress
5. **Logs everything** to a timestamped log file

## How It Handles Multiple Databases

Your source RDB might have data in multiple databases (db0, db1, db2, etc.).
ElastiCache Serverless only supports database 0.

The script automatically prefixes keys:

| Source | Target |
|--------|--------|
| db0: `user:123` | db0: `user:123` |
| db1: `user:123` | db0: `db1:user:123` |
| db2: `cache:xyz` | db0: `db2:cache:xyz` |

**No data loss, no collisions!**

## Example Output

```
==========================================
RDB to ElastiCache Serverless Migration
==========================================

Configuration:
  RDB File: /var/lib/redis/dump.rdb
  RDB Size: 2.3G
  Target: saif-serverlesss-eyty4q.serverless.use1.cache.amazonaws.com:6379
  Dry Run: false
  RedisShake: /path/to/rdb-elasticache-migrator/redisshake

Generating configuration...
Configuration created: configs/migration_20251016_134500.toml

==========================================
Starting Migration...
==========================================
Log file: logs/migration_20251016_134500.log

2025-10-16 13:45:00 INF create RDB reader
2025-10-16 13:45:00 INF * filepath: /var/lib/redis/dump.rdb
2025-10-16 13:45:00 INF create RedisClusterWriter
2025-10-16 13:45:00 INF start syncing...
2025-10-16 13:45:01 INF [rdb_reader] RDB version: 9
2025-10-16 13:45:15 INF [rdb_reader] rdb file parse done

==========================================
✓ Migration completed successfully!

Summary:
  - Log file: logs/migration_20251016_134500.log
  - Config file: configs/migration_20251016_134500.toml

Key transformation:
  - db0 keys: unchanged
  - db1 keys: prefixed with 'db1:'
  - db2 keys: prefixed with 'db2:'
  - etc.

To access migrated data:
  redis-cli -h saif-serverlesss-eyty4q.serverless.use1.cache.amazonaws.com -p 6379 --tls --askpass

Example commands:
  GET user:123        # Original db0 data
  GET db1:user:123    # Original db1 data
  KEYS db1:*          # All keys from original db1
==========================================
```

## Accessing Your Data After Migration

```bash
# Connect with redis-cli
redis-cli -h saif-serverlesss-eyty4q.serverless.use1.cache.amazonaws.com \
  -p 6379 \
  --tls \
  --askpass

# Get original db0 data (no prefix)
127.0.0.1:6379> GET user:123

# Get original db1 data (with prefix)
127.0.0.1:6379> GET db1:user:123

# Find all keys from original db1
127.0.0.1:6379> KEYS db1:*

# Count keys from original db2
127.0.0.1:6379> EVAL "return #redis.call('keys', 'db2:*')" 0
```

## Getting Your RDB File

If you don't have an RDB file yet:

```bash
# Method 1: From running Redis
redis-cli BGSAVE
redis-cli LASTSAVE  # Wait until this changes
# Find the file at /var/lib/redis/dump.rdb (or check your redis.conf)

# Method 2: Copy from backup
scp user@redis-server:/var/lib/redis/dump.rdb ./dump.rdb

# Method 3: Check Redis config for location
redis-cli CONFIG GET dir
redis-cli CONFIG GET dbfilename
```

## Troubleshooting

### "RDB file not found"
```bash
# Find your RDB file
sudo find / -name "dump.rdb" 2>/dev/null

# Or check Redis config
redis-cli CONFIG GET dir
```

### "Failed to build RedisShake"
Make sure you have Go installed:
```bash
# Install Go (if needed)
# Mac: brew install go
# Linux: sudo apt-get install golang  or  sudo yum install golang

# Then try again
./migrate.sh ...
```

### "Connection refused"
- Check ElastiCache security group allows your IP
- Verify the endpoint is correct
- Ensure TLS is enabled in ElastiCache

### Check Migration Progress
```bash
# Watch the log in real-time
tail -f logs/migration_*.log

# Check latest log
ls -lt logs/ | head -2
```

## Directory Structure After Running

```
rdb-elasticache-migrator/
├── migrate.sh
├── redisshake/
│   └── bin/redis-shake      # Built binary
├── configs/
│   └── migration_20251016_134500.toml
├── logs/
│   └── migration_20251016_134500.log
└── data/                     # RedisShake working dir
```

## Need Help?

```bash
# Show help
./migrate.sh --help

# Test with dry run first
./migrate.sh --dry-run -r /path/to/dump.rdb -e endpoint.com -p password
```

## That's It!

This is a complete, self-contained migration tool. Everything you need is included - just run `migrate.sh`!
