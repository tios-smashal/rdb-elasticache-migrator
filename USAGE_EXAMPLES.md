# Usage Examples

## How RDB Reading Works

Both tools read the Redis RDB file format, which is the standard Redis persistence format:

### RDB File Format
- **Binary format** containing Redis data snapshots
- Contains all databases (db0, db1, db2, etc.)
- Includes key types, values, TTLs, and metadata
- Standard format used by Redis SAVE/BGSAVE commands

### How the Tools Parse RDB

#### RedisShake Approach (Built-in Parser)
```
RDB File (dump.rdb)
        ↓
RedisShake RDB Parser (Go)
  - Reads binary format
  - Extracts: database number, key, value, TTL
  - Detects key type (string, hash, list, etc.)
        ↓
Lua Function
  - Adds database prefix if DB != 0
  - Example: db1 + "user:123" → "db1:user:123"
        ↓
ElastiCache Serverless (db0 only)
  - All keys in database 0
  - No collisions due to prefixes
```

#### Python Tool Approach (rdbtools Library)
```
RDB File (dump.rdb)
        ↓
rdbtools Library (Python)
  - Parses binary format
  - Calls callbacks for each key
        ↓
ElastiCacheMigrator Class
  - Receives: database, key, value, type, TTL
  - Adds prefix if needed
  - Writes directly to ElastiCache
        ↓
ElastiCache Serverless (db0 only)
```

---

## Example 1: Using RedisShake Script (Recommended)

### Step 1: Get your RDB file

From a running Redis:
```bash
# Connect to source Redis
redis-cli -h localhost -p 6379

# Trigger save
127.0.0.1:6379> BGSAVE
Background saving started

# Wait and check
127.0.0.1:6379> LASTSAVE
(integer) 1697456789

# Find the file (common locations)
# - /var/lib/redis/dump.rdb (Linux)
# - /usr/local/var/db/redis/dump.rdb (Mac)
# - Check redis.conf for 'dir' and 'dbfilename'
```

Or copy from a backup:
```bash
scp user@redis-server:/var/lib/redis/dump.rdb ./my-dump.rdb
```

### Step 2: Run the migration

```bash
cd ~/dev/rdb-elasticache-migrator

./migrate-with-redisshake.sh \
  /path/to/dump.rdb \
  saif-serverlesss-eyty4q.serverless.use1.cache.amazonaws.com \
  YOUR_ELASTICACHE_AUTH_TOKEN
```

### Step 3: Monitor progress

The script shows real-time output:
```
==========================================
RDB to ElastiCache Serverless Migration
Using RedisShake
==========================================

Configuration:
  RDB File: /path/to/dump.rdb
  Target: saif-serverlesss-eyty4q.serverless.use1.cache.amazonaws.com
  RedisShake: /Users/smashal/dev/RedisShake

Starting migration...
Log file: /Users/smashal/dev/RedisShake/data/rdb-elasticache-migration.log
==========================================

2025-10-16 13:45:00 INF load config from file: /tmp/redisshake-rdb-migration.xxxxx.toml
2025-10-16 13:45:00 INF create RDB reader
2025-10-16 13:45:00 INF * filepath: /path/to/dump.rdb
2025-10-16 13:45:00 INF create RedisClusterWriter
2025-10-16 13:45:00 INF * address: saif-serverlesss-eyty4q.serverless.use1.cache.amazonaws.com:6379
2025-10-16 13:45:00 INF start syncing...
2025-10-16 13:45:01 INF [rdb_reader] RDB version: 9
2025-10-16 13:45:01 INF [rdb_reader] DB 1: Transforming 3 keys with prefix db1:
2025-10-16 13:45:01 INF [rdb_reader]   user:123 -> db1:user:123
2025-10-16 13:45:01 INF [rdb_reader]   cache:xyz -> db1:cache:xyz
...
2025-10-16 13:45:10 INF [rdb_reader] rdb file parse done

==========================================
Migration completed successfully!
==========================================
```

---

## Example 2: Using Python Tool

### Step 1: Setup
```bash
cd ~/dev/rdb-elasticache-migrator

# One-time setup
./setup.sh

# Activate environment
source venv/bin/activate
```

### Step 2: Configure
```bash
# Create config
cp config.example.json config.json

# Edit config.json
nano config.json
```

```json
{
  "source": {
    "rdb_file": "/path/to/dump.rdb"
  },
  "target": {
    "host": "saif-serverlesss-eyty4q.serverless.use1.cache.amazonaws.com",
    "port": 6379,
    "password": "YOUR_AUTH_TOKEN",
    "tls": true,
    "cluster": true
  },
  "dry_run": false,
  "prefix_dbs": true
}
```

### Step 3: Test with dry run
```bash
# Edit config.json and set "dry_run": true
python migrate.py --config config.json
```

### Step 4: Run actual migration
```bash
# Edit config.json and set "dry_run": false
python migrate.py --config config.json
```

---

## Example 3: What Happens to Your Data

### Source Redis (Multiple Databases)

**Database 0:**
```
user:123 = "John"
product:456 = "Widget"
```

**Database 1:**
```
user:123 = "Jane"
cache:temp = "xyz"
```

**Database 2:**
```
session:abc = "active"
```

### After Migration to ElastiCache Serverless

**Database 0 (all data):**
```
user:123 = "John"           # From original db0
product:456 = "Widget"      # From original db0
db1:user:123 = "Jane"       # From original db1 (prefixed)
db1:cache:temp = "xyz"      # From original db1 (prefixed)
db2:session:abc = "active"  # From original db2 (prefixed)
```

**No collisions!** Keys with the same name from different databases are distinguished by prefixes.

---

## Example 4: Accessing Migrated Data

### Python
```python
import redis

# Connect
client = redis.Redis(
    host='saif-serverlesss-eyty4q.serverless.use1.cache.amazonaws.com',
    port=6379,
    password='YOUR_AUTH_TOKEN',
    ssl=True
)

# Original db0 data (no prefix)
john = client.get('user:123')  # "John"

# Original db1 data (with prefix)
jane = client.get('db1:user:123')  # "Jane"
temp = client.get('db1:cache:temp')  # "xyz"

# Original db2 data (with prefix)
session = client.get('db2:session:abc')  # "active"
```

### redis-cli
```bash
redis-cli -h saif-serverlesss-eyty4q.serverless.use1.cache.amazonaws.com \
  -p 6379 \
  --tls \
  --askpass

# Enter password when prompted

# Get original db0 data
127.0.0.1:6379> GET user:123
"John"

# Get original db1 data
127.0.0.1:6379> GET db1:user:123
"Jane"

# Get original db2 data
127.0.0.1:6379> GET db2:session:abc
"active"

# Find all keys from a specific original database
127.0.0.1:6379> KEYS db1:*
1) "db1:user:123"
2) "db1:cache:temp"
```

---

## Example 5: Real RDB File Structure

When RedisShake/Python reads the RDB file, it sees:

```
REDIS0009        # Magic string + version
...              # Metadata
SELECTDB 0       # Switch to database 0
  STRING user:123 = "John"
  STRING product:456 = "Widget"
SELECTDB 1       # Switch to database 1
  STRING user:123 = "Jane"
  STRING cache:temp = "xyz"
SELECTDB 2       # Switch to database 2
  STRING session:abc = "active"
EOF              # End of file
```

The parser:
1. Detects `SELECTDB` opcodes to track current database
2. Reads each key with its type, value, and TTL
3. Applies the prefix transformation
4. Writes to ElastiCache

---

## Comparison

| Feature | RedisShake Script | Python Tool |
|---------|------------------|-------------|
| Setup | None (uses existing RedisShake) | pip install required |
| Dependencies | None | rdbtools, python-lzf, redis |
| RDB Parser | Built-in (Go) | rdbtools library |
| Speed | Fast (compiled Go) | Moderate (Python) |
| Memory | Efficient | Moderate |
| Customization | Edit script/config | Edit Python code |
| Best For | Quick migrations | Custom processing |

---

## Troubleshooting

### RDB File Not Found
```bash
# Find Redis data directory
redis-cli CONFIG GET dir
1) "dir"
2) "/var/lib/redis"

# Find RDB filename
redis-cli CONFIG GET dbfilename
1) "dbfilename"
2) "dump.rdb"

# Full path
ls -lh /var/lib/redis/dump.rdb
```

### Empty or Old RDB
```bash
# Force a new save
redis-cli BGSAVE

# Check last save time
redis-cli LASTSAVE
(integer) 1697456789

# Or use SAVE (blocks Redis)
redis-cli SAVE
```

### Large RDB Files
For very large files (>10GB):
- Run migration on a machine with sufficient RAM
- Monitor the log file for progress
- Consider using RedisShake (more memory efficient than Python)

### Connection Issues
```bash
# Test ElastiCache connectivity
redis-cli -h your-cluster.serverless.use1.cache.amazonaws.com \
  -p 6379 \
  --tls \
  --askpass \
  PING
```
