# Technical Deep Dive: RDB to ElastiCache Migration

This document explains in detail what this tool does, how it works, and the technical architecture behind it.

## Table of Contents

1. [Overview](#overview)
2. [The Problem We're Solving](#the-problem-were-solving)
3. [Architecture](#architecture)
4. [How RDB Files Work](#how-rdb-files-work)
5. [Migration Process Step-by-Step](#migration-process-step-by-step)
6. [Database Prefixing Strategy](#database-prefixing-strategy)
7. [RedisShake Internals](#redisshake-internals)
8. [Lua Filter Function](#lua-filter-function)
9. [Network Communication](#network-communication)
10. [Performance Considerations](#performance-considerations)
11. [Error Handling](#error-handling)
12. [Code Structure](#code-structure)

---

## Overview

This tool migrates Redis data from an RDB file to AWS ElastiCache Serverless. The key challenge is that:
- **Source**: Traditional Redis with multiple databases (db0, db1, db2, ... db15)
- **Target**: ElastiCache Serverless (cluster mode) which **only supports database 0**

**Solution**: Prefix keys from non-zero databases so all data can coexist in database 0 without collisions.

---

## The Problem We're Solving

### Redis Database Model

Traditional Redis supports 16 databases (0-15) accessed via the `SELECT` command:

```redis
SELECT 0
SET user:123 "John"

SELECT 1
SET user:123 "Jane"  # Different database, different value

SELECT 2
SET cache:temp "xyz"
```

### ElastiCache Serverless Limitation

ElastiCache Serverless runs in **cluster mode** where:
- Data is distributed across multiple shards
- Each shard handles a portion of the key space (hash slots)
- The `SELECT` command is **not available**
- **Only database 0 exists**

This means if you try to use standard migration tools:
```bash
# This fails!
redis-cli --rdb dump.rdb | redis-cli -h elasticache

# Error: ERR SELECT is not allowed in cluster mode
```

### Our Solution

Transform keys during migration:
- `db0:user:123` → `user:123` (unchanged)
- `db1:user:123` → `db1:user:123` (prefixed)
- `db2:cache:temp` → `db2:cache:temp` (prefixed)

All data goes to database 0, no collisions, no data loss!

---

## Architecture

```
┌─────────────────────────────────────────────────────────────────┐
│                        migrate.sh                                │
│                   (Orchestration Script)                         │
│                                                                   │
│  • Validates RDB file exists                                     │
│  • Checks/builds RedisShake binary                               │
│  • Generates TOML configuration                                  │
│  • Launches RedisShake process                                   │
│  • Monitors and reports results                                  │
└────────────────────┬────────────────────────────────────────────┘
                     │
                     │ executes
                     ▼
┌─────────────────────────────────────────────────────────────────┐
│                      RedisShake                                  │
│              (Go Binary - RDB Processor)                         │
│                                                                   │
│  ┌─────────────────────────────────────────────────────┐        │
│  │              RDB Reader                              │        │
│  │  • Opens dump.rdb file                               │        │
│  │  • Parses binary format                              │        │
│  │  • Extracts keys, values, types, TTLs                │        │
│  │  • Tracks current database number                    │        │
│  └──────────────────┬──────────────────────────────────┘        │
│                     │                                             │
│                     │ stream of entries                           │
│                     ▼                                             │
│  ┌─────────────────────────────────────────────────────┐        │
│  │              Lua Filter                              │        │
│  │  • Receives each key with DB number                  │        │
│  │  • IF DB != 0: prefix = "db" + DB + ":"             │        │
│  │  • Transform key: key → prefix + key                │        │
│  │  • Call shake.call(0, ARGV) to emit                 │        │
│  └──────────────────┬──────────────────────────────────┘        │
│                     │                                             │
│                     │ transformed entries                         │
│                     ▼                                             │
│  ┌─────────────────────────────────────────────────────┐        │
│  │         Redis Cluster Writer                         │        │
│  │  • Connects to ElastiCache (TLS)                     │        │
│  │  • Batches commands (pipeline)                       │        │
│  │  • Routes to correct shard (hash slot)              │        │
│  │  • Handles retries and errors                        │        │
│  │  • Rate limits (QPS control)                         │        │
│  └──────────────────┬──────────────────────────────────┘        │
│                     │                                             │
└─────────────────────┼─────────────────────────────────────────────┘
                      │
                      │ TLS connection
                      ▼
┌─────────────────────────────────────────────────────────────────┐
│              AWS ElastiCache Serverless                          │
│                    (Cluster Mode)                                │
│                                                                   │
│  ┌──────────┐  ┌──────────┐  ┌──────────┐  ┌──────────┐       │
│  │ Shard 0  │  │ Shard 1  │  │ Shard 2  │  │ Shard N  │       │
│  │ Slots    │  │ Slots    │  │ Slots    │  │ Slots    │       │
│  │ 0-4095   │  │ 4096-    │  │ 8192-    │  │ 12288-   │       │
│  │          │  │ 8191     │  │ 12287    │  │ 16383    │       │
│  └──────────┘  └──────────┘  └──────────┘  └──────────┘       │
│                                                                   │
│  All data in Database 0 only                                     │
└─────────────────────────────────────────────────────────────────┘
```

---

## How RDB Files Work

### Binary Format Structure

RDB (Redis Database) files are binary snapshots of Redis data. Here's the structure:

```
┌────────────────────────────────────────────────────────────┐
│ MAGIC STRING: "REDIS" (5 bytes)                            │
├────────────────────────────────────────────────────────────┤
│ VERSION: "0009" (4 bytes ASCII)                            │
├────────────────────────────────────────────────────────────┤
│ AUXILIARY FIELDS (metadata)                                │
│   - redis-ver: 7.0.9                                       │
│   - redis-bits: 64                                         │
│   - ctime: 1697456789                                      │
│   - used-mem: 1073741824                                   │
│   - repl-stream-db: 0                                      │
├────────────────────────────────────────────────────────────┤
│ DATABASE SECTION 0                                         │
│ ┌────────────────────────────────────────────────────────┐ │
│ │ SELECTDB opcode: 0xFE (254)                            │ │
│ │ DB number: 0 (length-encoded)                          │ │
│ │ RESIZEDB opcode: 0xFB (251)                            │ │
│ │   - db_size: 10000                                     │ │
│ │   - expires_size: 5000                                 │ │
│ │                                                         │ │
│ │ KEY-VALUE PAIRS:                                       │ │
│ │ ┌──────────────────────────────────────────┐          │ │
│ │ │ [OPTIONAL] EXPIRE opcode: 0xFD or 0xFC   │          │ │
│ │ │   - Expiry time in seconds or milliseconds│          │ │
│ │ │                                            │          │ │
│ │ │ VALUE TYPE: 0 (string)                     │          │ │
│ │ │ KEY: "user:123" (length-encoded string)    │          │ │
│ │ │ VALUE: "John" (length-encoded string)      │          │ │
│ │ └──────────────────────────────────────────┘          │ │
│ │ ┌──────────────────────────────────────────┐          │ │
│ │ │ VALUE TYPE: 4 (hash)                       │          │ │
│ │ │ KEY: "product:456"                         │          │ │
│ │ │ HASH SIZE: 3                               │          │ │
│ │ │   field1: "name" → "Widget"                │          │ │
│ │ │   field2: "price" → "29.99"                │          │ │
│ │ │   field3: "stock" → "100"                  │          │ │
│ │ └──────────────────────────────────────────┘          │ │
│ └────────────────────────────────────────────────────────┘ │
├────────────────────────────────────────────────────────────┤
│ DATABASE SECTION 1                                         │
│ ┌────────────────────────────────────────────────────────┐ │
│ │ SELECTDB opcode: 0xFE                                  │ │
│ │ DB number: 1                                           │ │
│ │ RESIZEDB opcode: 0xFB                                  │ │
│ │   - db_size: 5000                                      │ │
│ │   - expires_size: 2000                                 │ │
│ │                                                         │ │
│ │ KEY-VALUE PAIRS:                                       │ │
│ │   - cache:abc = "xyz"                                  │ │
│ │   - session:def = {...}                                │ │
│ └────────────────────────────────────────────────────────┘ │
├────────────────────────────────────────────────────────────┤
│ DATABASE SECTION 2                                         │
│   - temp:foo = [...]                                       │
├────────────────────────────────────────────────────────────┤
│ EOF opcode: 0xFF (255)                                     │
├────────────────────────────────────────────────────────────┤
│ CRC64 CHECKSUM (8 bytes)                                   │
└────────────────────────────────────────────────────────────┘
```

### RDB Opcodes

| Opcode | Hex  | Meaning |
|--------|------|---------|
| String | 0x00 | Simple string value |
| List | 0x01 | List data structure |
| Set | 0x02 | Set data structure |
| ZSet | 0x03 | Sorted set |
| Hash | 0x04 | Hash data structure |
| ZSet 2 | 0x05 | Sorted set with scores as strings |
| Module | 0x06 | Module-specific data type |
| ... | ... | Many more type codes |
| EXPIRETIME | 0xFD | Expiry in seconds (4 bytes) |
| EXPIRETIME_MS | 0xFC | Expiry in milliseconds (8 bytes) |
| RESIZEDB | 0xFB | DB size hint |
| AUX | 0xFA | Auxiliary field |
| SELECTDB | 0xFE | Select database |
| EOF | 0xFF | End of file |

### Length Encoding

RDB uses a compact length encoding scheme:

```
┌──────────────────────────────────────────────────────┐
│ First byte determines encoding:                       │
│                                                        │
│ 00XXXXXX → 6-bit length (0-63)                       │
│ 01XXXXXX XXXXXXXX → 14-bit length (0-16,383)        │
│ 10XXXXXX [4 bytes] → 32-bit length                   │
│ 11XXXXXX → Special encoding (integer, compressed)    │
└──────────────────────────────────────────────────────┘
```

**Example:**
- Length 42: `00101010` (1 byte)
- Length 5000: `01010011 11101000` (2 bytes)
- Length 100000: `10000000 00000001 10000110 10100000` (5 bytes)

---

## Migration Process Step-by-Step

### Phase 1: Initialization

```bash
./migrate.sh /var/lib/redis/dump.rdb endpoint.com password
```

**Script Actions:**

1. **Parse Arguments**
   ```bash
   RDB_FILE="/var/lib/redis/dump.rdb"
   ELASTICACHE_ENDPOINT="endpoint.com"
   ELASTICACHE_PASSWORD="password"
   ```

2. **Validate RDB File**
   ```bash
   [ -f "$RDB_FILE" ] || exit 1
   RDB_FILE=$(cd "$(dirname "$RDB_FILE")" && pwd)/$(basename "$RDB_FILE")
   # Now: /var/lib/redis/dump.rdb (absolute path)
   ```

3. **Check RedisShake Binary**
   ```bash
   if [ ! -f "$REDISSHAKE_BIN" ]; then
       cd redisshake
       ./build.sh  # Compiles Go code
       cd ..
   fi
   ```

### Phase 2: Configuration Generation

**Generated TOML:**

```toml
[rdb_reader]
filepath = "/var/lib/redis/dump.rdb"

[redis_writer]
cluster = true
address = "endpoint.com:6379"
password = "password"
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
log_file = "logs/migration_20251016_134500.log"
log_level = "info"
rdb_restore_command_behavior = "rewrite"
pipeline_count_limit = 512
target_redis_max_qps = 50000
```

### Phase 3: RedisShake Execution

**What RedisShake Does:**

```go
// 1. Open RDB file
rdbFile, _ := os.Open("/var/lib/redis/dump.rdb")
reader := bufio.NewReader(rdbFile)

// 2. Read magic and version
magic := make([]byte, 5)  // "REDIS"
version := make([]byte, 4) // "0009"

// 3. Parse databases
currentDB := 0
for {
    opcode := readByte(reader)

    switch opcode {
    case 0xFE: // SELECTDB
        currentDB = readLength(reader)

    case 0xFC: // EXPIRETIME_MS
        expiryMs = readUint64(reader)

    case 0x00: // String type
        key := readString(reader)
        value := readString(reader)

        // Create entry
        entry := Entry{
            DbId: currentDB,
            Argv: []string{"SET", key, value}
        }

        // Send to filter
        filteredEntry := luaFilter(entry)

        // Send to writer
        writer.Write(filteredEntry)

    case 0xFF: // EOF
        return
    }
}
```

### Phase 4: Lua Filtering

**For each entry, Lua function runs:**

```lua
-- Input entry from DB 1:
-- DB = 1
-- CMD = "SET"
-- KEYS = {"user:123"}
-- KEY_INDEXES = {2}
-- ARGV = {"SET", "user:123", "Jane"}

if DB ~= 0 then  -- DB is 1, so true
    local prefix = "db" .. DB .. ":"  -- prefix = "db1:"

    for _, index in ipairs(KEY_INDEXES) do  -- index = 2
        local key = ARGV[index]  -- key = "user:123"
        if key then
            ARGV[index] = prefix .. key  -- ARGV[2] = "db1:user:123"
        end
    end
end

-- Now ARGV = {"SET", "db1:user:123", "Jane"}

shake.call(0, ARGV)  -- Send to database 0
```

### Phase 5: ElastiCache Writing

**RedisShake Cluster Writer:**

```go
// 1. Calculate hash slot
key := "db1:user:123"
slot := crc16(key) % 16384  // Example: slot 9527

// 2. Find shard for slot
shard := clusterNodes[slot]  // Get shard handling slot 9527

// 3. Pipeline commands
pipeline := []Command{
    {"SET", "db1:user:123", "Jane"},
    {"HSET", "db1:product:456", "name", "Widget"},
    // ... up to 512 commands
}

// 4. Send batch over TLS
conn, _ := tls.Dial("tcp", "endpoint.com:6379", tlsConfig)
conn.Write(encodeRESP(pipeline))

// 5. Read replies
for _, cmd := range pipeline {
    reply := readReply(conn)
    if reply.IsError {
        handleError(cmd, reply)
    }
}

// 6. Rate limit
if qps > 50000 {
    time.Sleep(waitTime)
}
```

---

## Database Prefixing Strategy

### Why Prefixing?

**Problem:** Keys with same name in different databases must not collide:

```
DB0: user:123 = "John"
DB1: user:123 = "Jane"
DB2: user:123 = "Bob"
```

Without prefixing, we'd lose data (only one value would remain).

### Prefix Format

```
Original: db{N}:key
Target:   db{N}:key

Examples:
- db0: user:123  →  user:123       (no prefix)
- db1: user:123  →  db1:user:123
- db2: cache:xyz →  db2:cache:xyz
- db15:temp:foo  →  db15:temp:foo
```

### Key Space Distribution

After migration, keys are distributed:

```
ElastiCache Cluster (Database 0):
┌─────────────────────────────────────────────┐
│ Slot Range: 0 - 16383                       │
│                                              │
│ Keys:                                        │
│   user:123        → Slot 5798  → Shard 1    │
│   product:456     → Slot 12001 → Shard 3    │
│   db1:user:123    → Slot 9527  → Shard 2    │
│   db1:cache:abc   → Slot 15234 → Shard 4    │
│   db2:temp:foo    → Slot 3421  → Shard 1    │
│   db2:session:bar → Slot 8765  → Shard 2    │
└─────────────────────────────────────────────┘

Hash slot calculation:
  slot = CRC16(key) % 16384
```

### Accessing Prefixed Data

**Application code changes:**

```python
# Before migration (multi-database)
redis0 = Redis(db=0)
redis1 = Redis(db=1)

john = redis0.get('user:123')  # db0
jane = redis1.get('user:123')  # db1

# After migration (single database with prefixes)
redis = Redis(db=0, host='elasticache-endpoint', ssl=True)

john = redis.get('user:123')        # Original db0 data
jane = redis.get('db1:user:123')    # Original db1 data

# Helper function
def get_from_db(db_num, key):
    if db_num == 0:
        return redis.get(key)
    else:
        return redis.get(f'db{db_num}:{key}')

john = get_from_db(0, 'user:123')
jane = get_from_db(1, 'user:123')
```

---

## RedisShake Internals

### Core Components

#### 1. RDB Reader (`internal/reader/rdb_reader.go`)

```go
type rdbReader struct {
    ch chan *entry.Entry  // Output channel
    stat struct {
        FileSizeBytes int64
        FileSentBytes int64
        Percent       string
    }
}

func (r *rdbReader) StartRead(ctx context.Context) []chan *entry.Entry {
    rdbLoader := rdb.NewLoader(r.filepath, r.ch)

    go func() {
        rdbLoader.ParseRDB(ctx)  // Parse in background
        close(r.ch)              // Signal completion
    }()

    return []chan *entry.Entry{r.ch}
}
```

#### 2. RDB Parser (`internal/rdb/rdb.go`)

```go
type Loader struct {
    nowDBId  int     // Current database
    expireMs int64   // Pending expiry
    filPath  string  // RDB file path
    ch       chan *entry.Entry
}

func (ld *Loader) ParseRDB(ctx context.Context) {
    // Read magic + version
    buf := make([]byte, 9)
    io.ReadFull(rd, buf)

    // Parse entries
    for {
        typeByte := readByte(rd)

        switch typeByte {
        case kFlagSelect:  // 0xFE
            ld.nowDBId = readLength(rd)

        case kFlagExpireMs:  // 0xFC
            ld.expireMs = readUint64(rd)

        case typeString:  // 0x00
            key := readString(rd)
            value := readString(rd)

            entry := &entry.Entry{
                DbId: ld.nowDBId,
                Argv: []string{"SET", key, value}
            }
            ld.ch <- entry

            if ld.expireMs != 0 {
                expireEntry := &entry.Entry{
                    DbId: ld.nowDBId,
                    Argv: []string{"PEXPIRE", key, strconv.FormatInt(ld.expireMs, 10)}
                }
                ld.ch <- expireEntry
                ld.expireMs = 0
            }

        case kEOF:  // 0xFF
            return
        }
    }
}
```

#### 3. Filter (`internal/filter/function.go`)

```go
type luaRuntime struct {
    luaState *lua.LState
    pool     *sync.Pool  // Reuse Lua VMs
}

func (l *luaRuntime) Filter(entry *entry.Entry) []*entry.Entry {
    L := l.pool.Get().(*lua.LState)
    defer l.pool.Put(L)

    // Set global variables
    L.SetGlobal("DB", lua.LNumber(entry.DbId))
    L.SetGlobal("CMD", lua.LString(entry.Argv[0]))

    keysTable := L.NewTable()
    for i, key := range entry.Keys {
        keysTable.RawSetInt(i+1, lua.LString(key))
    }
    L.SetGlobal("KEYS", keysTable)

    argvTable := L.NewTable()
    for i, arg := range entry.Argv {
        argvTable.RawSetInt(i+1, lua.LString(arg))
    }
    L.SetGlobal("ARGV", argvTable)

    // Execute Lua function
    if err := L.DoString(l.function); err != nil {
        log.Panicf("lua error: %v", err)
    }

    // Collect results from shake.call()
    return l.collectedEntries
}
```

#### 4. Cluster Writer (`internal/writer/redis_cluster_writer.go`)

```go
type redisClusterWriter struct {
    clients  map[int]*redis.Client  // Client per shard
    slots    []int                  // Slot to shard mapping
    pipeline chan *entry.Entry
    limiter  *rate.Limiter           // QPS control
}

func (w *redisClusterWriter) Write(entry *entry.Entry) error {
    // Calculate slot
    key := entry.Argv[1]  // First key argument
    slot := crc16([]byte(key)) % 16384

    // Get client for slot
    shardId := w.slots[slot]
    client := w.clients[shardId]

    // Rate limit
    w.limiter.Wait(context.Background())

    // Send command
    cmd := redis.NewCmd(context.Background(), entry.Argv...)
    err := client.Process(context.Background(), cmd)

    if err != nil {
        // Retry logic
        return w.handleError(entry, err)
    }

    return nil
}
```

---

## Lua Filter Function

### Complete Function Breakdown

```lua
-- ============================================
-- 1. CHECK DATABASE NUMBER
-- ============================================
if DB ~= 0 then
    -- This entry is from a non-zero database
    -- We need to prefix the keys

    -- ========================================
    -- 2. BUILD PREFIX STRING
    -- ========================================
    local prefix = "db" .. DB .. ":"
    -- Examples:
    --   DB=1  → prefix="db1:"
    --   DB=2  → prefix="db2:"
    --   DB=15 → prefix="db15:"

    -- ========================================
    -- 3. ITERATE OVER KEY POSITIONS
    -- ========================================
    -- KEY_INDEXES tells us which arguments are keys
    -- For "SET key value": KEY_INDEXES={2}
    -- For "MSET k1 v1 k2 v2": KEY_INDEXES={2,4}

    for _, index in ipairs(KEY_INDEXES) do
        local key = ARGV[index]

        if key then
            -- ================================
            -- 4. PREFIX THE KEY
            -- ================================
            ARGV[index] = prefix .. key

            -- Before: ARGV = {"SET", "user:123", "John"}
            -- After:  ARGV = {"SET", "db1:user:123", "John"}
        end
    end

    -- ========================================
    -- 5. LOG TRANSFORMATION (optional)
    -- ========================================
    if KEYS[1] then
        shake.log("DB" .. DB .. ": " .. KEYS[1] .. " -> " .. prefix .. KEYS[1])
        -- Output: "DB1: user:123 -> db1:user:123"
    end
end

-- ============================================
-- 6. EMIT TO TARGET
-- ============================================
-- Always write to database 0 (cluster mode requirement)
shake.call(0, ARGV)
```

### Example Transformations

**Example 1: Simple String**
```lua
-- Input
DB = 1
ARGV = {"SET", "user:123", "Jane"}
KEY_INDEXES = {2}

-- Processing
prefix = "db1:"
ARGV[2] = "db1:" .. "user:123"  -- "db1:user:123"

-- Output
shake.call(0, {"SET", "db1:user:123", "Jane"})
```

**Example 2: Hash**
```lua
-- Input
DB = 2
ARGV = {"HSET", "product:456", "name", "Widget"}
KEY_INDEXES = {2}

-- Processing
prefix = "db2:"
ARGV[2] = "db2:" .. "product:456"  -- "db2:product:456"

-- Output
shake.call(0, {"HSET", "db2:product:456", "name", "Widget"})
```

**Example 3: Multiple Keys (MSET)**
```lua
-- Input
DB = 1
ARGV = {"MSET", "k1", "v1", "k2", "v2", "k3", "v3"}
KEY_INDEXES = {2, 4, 6}

-- Processing
prefix = "db1:"
ARGV[2] = "db1:k1"
ARGV[4] = "db1:k2"
ARGV[6] = "db1:k3"

-- Output
shake.call(0, {"MSET", "db1:k1", "v1", "db1:k2", "v2", "db1:k3", "v3"})
```

**Example 4: Database 0 (No Change)**
```lua
-- Input
DB = 0
ARGV = {"SET", "user:123", "John"}

-- Processing
-- if DB ~= 0 → false, skip prefixing

-- Output
shake.call(0, {"SET", "user:123", "John"})
```

---

## Network Communication

### TLS Handshake

```
Client (RedisShake)                    ElastiCache
       │                                     │
       ├─────── TCP SYN ────────────────────>│
       │<──────── SYN-ACK ───────────────────┤
       ├─────── ACK ─────────────────────────>│
       │                                     │
       ├─────── ClientHello ────────────────>│
       │         (TLS 1.2/1.3)               │
       │<──────── ServerHello ───────────────┤
       │<──────── Certificate ───────────────┤
       │<──────── ServerHelloDone ───────────┤
       │                                     │
       ├─────── ClientKeyExchange ──────────>│
       ├─────── ChangeCipherSpec ───────────>│
       ├─────── Finished ───────────────────>│
       │<──────── ChangeCipherSpec ──────────┤
       │<──────── Finished ──────────────────┤
       │                                     │
       │      TLS Connection Established     │
       │                                     │
       ├─────── AUTH password ──────────────>│
       │<──────── +OK ───────────────────────┤
       │                                     │
       │   Ready for Commands                │
```

### Redis Protocol (RESP)

**Request Encoding:**

```
Command: SET db1:user:123 Jane

RESP Format:
*3\r\n           ← Array with 3 elements
$3\r\n           ← Bulk string, 3 bytes
SET\r\n          ← Command
$13\r\n          ← Bulk string, 13 bytes
db1:user:123\r\n ← Key
$4\r\n           ← Bulk string, 4 bytes
Jane\r\n         ← Value
```

**Response Parsing:**

```
Success:
+OK\r\n          ← Simple string

Error:
-ERR message\r\n ← Error string

Integer:
:1234\r\n        ← Integer

Bulk String:
$5\r\n           ← String of 5 bytes
hello\r\n        ← Data

Null:
$-1\r\n          ← Null bulk string

Array:
*2\r\n           ← Array of 2 elements
$3\r\n
foo\r\n
$3\r\n
bar\r\n
```

### Pipelining

```go
// Without pipeline (slow)
for _, entry := range entries {
    client.Do(entry.Argv...)  // Network roundtrip per command
}
// Time: N commands × latency

// With pipeline (fast)
pipeline := client.Pipeline()
for _, entry := range entries {
    pipeline.Do(entry.Argv...)
}
pipeline.Exec()  // Single network roundtrip
// Time: 1 × latency
```

**Example Pipeline:**

```
Client sends (batch of 3):
───────────────────────────>
*3\r\n$3\r\nSET\r\n$13\r\ndb1:user:123\r\n$4\r\nJane\r\n
*4\r\n$4\r\nHSET\r\n$16\r\ndb1:product:456\r\n$4\r\nname\r\n$6\r\nWidget\r\n
*3\r\n$4\r\nSADD\r\n$10\r\ndb2:tags\r\n$3\r\nfoo\r\n

Server replies (batch of 3):
<───────────────────────────
+OK\r\n
:1\r\n
:1\r\n
```

---

## Performance Considerations

### Bottlenecks

1. **RDB Parsing**: CPU-bound
   - Binary parsing
   - String decoding
   - Type detection

2. **Lua Filtering**: CPU-bound
   - String concatenation
   - Table operations
   - Function calls

3. **Network I/O**: Latency-bound
   - TLS encryption overhead
   - Network roundtrips
   - ElastiCache processing

### Optimizations

**1. Pipeline Batching**
```toml
pipeline_count_limit = 512  # Commands per batch
```

More commands = fewer network roundtrips, but:
- Too high: Memory usage, timeout risk
- Too low: Poor throughput
- Sweet spot: 256-1024

**2. QPS Rate Limiting**
```toml
target_redis_max_qps = 50000  # Max queries per second
```

Protects ElastiCache from overload:
- ElastiCache Serverless auto-scales
- But scaling takes time
- Rate limit prevents throttling

**3. Concurrent Processing**
```toml
ncpu = 0  # Use all CPU cores
```

RedisShake uses goroutines:
- RDB reader: 1 goroutine
- Lua filter: 1 goroutine per entry (pool)
- Cluster writer: 1 goroutine per shard

**4. Connection Pooling**
```go
// One connection per shard
clients := make(map[int]*redis.Client)
for shardId, addr := range shards {
    clients[shardId] = redis.NewClient(&redis.Options{
        Addr:         addr,
        PoolSize:     10,    // Connection pool
        MinIdleConns: 5,     // Keep connections warm
    })
}
```

### Performance Metrics

**Example: 1.5GB RDB File**

```
File Size: 1.5GB
Total Keys: ~2 million
Databases: 3 (db0, db1, db2)

Performance:
- Parse Rate: ~100MB/s (CPU-bound)
- Write Rate: ~50,000 QPS (rate-limited)
- Duration: ~15 minutes

Breakdown:
- RDB Parsing: ~15 seconds
- Lua Filtering: ~30 seconds
- Network Writing: ~14 minutes (rate-limited)
- Overhead: ~15 seconds

Throughput: ~2,222 keys/second
```

**Factors Affecting Speed:**

| Factor | Impact | Notes |
|--------|--------|-------|
| RDB Size | Linear | Larger files take longer |
| Key Count | Linear | More keys = more operations |
| Value Size | Moderate | Large values slow parsing |
| Network Latency | High | Cross-region = slower |
| ElastiCache Size | Moderate | Larger clusters handle more QPS |
| Rate Limit | High | Lower QPS = longer migration |

---

## Error Handling

### Error Categories

**1. File Errors**
```bash
# RDB file not found
Error: RDB file not found: /var/lib/redis/dump.rdb

# Solution: Check path, permissions
ls -lh /var/lib/redis/dump.rdb
```

**2. Build Errors**
```bash
# Go not installed
Error: build.sh not found in RedisShake directory

# Solution: Install Go
brew install go  # Mac
apt-get install golang  # Ubuntu
```

**3. Connection Errors**
```bash
# Network/firewall issue
ERR dial tcp: i/o timeout

# Solution: Check security group, network
telnet endpoint.com 6379
```

**4. Authentication Errors**
```bash
# Wrong password
ERR invalid password

# Solution: Check auth token
redis-cli -h endpoint.com --tls --askpass
```

**5. Cluster Errors**
```bash
# Not cluster mode
ERR This instance has cluster support disabled

# Solution: Set cluster=true in config
[redis_writer]
cluster = true
```

**6. Rate Limiting**
```bash
# ElastiCache throttling
BUSY Redis is busy running a script

# Solution: Lower QPS
target_redis_max_qps = 10000
```

### Retry Logic

**RedisShake implements automatic retries:**

```go
func (w *writer) Write(entry *entry.Entry) error {
    maxRetries := 3
    backoff := time.Second

    for attempt := 0; attempt < maxRetries; attempt++ {
        err := w.doWrite(entry)

        if err == nil {
            return nil  // Success
        }

        if isRetryable(err) {
            log.Warnf("Retry %d/%d: %v", attempt+1, maxRetries, err)
            time.Sleep(backoff)
            backoff *= 2  // Exponential backoff
            continue
        }

        // Non-retryable error
        return err
    }

    return fmt.Errorf("max retries exceeded")
}

func isRetryable(err error) bool {
    // Network errors: yes
    if isNetworkError(err) {
        return true
    }

    // BUSY, LOADING: yes
    if strings.Contains(err.Error(), "BUSY") ||
       strings.Contains(err.Error(), "LOADING") {
        return true
    }

    // AUTH, SYNTAX errors: no
    return false
}
```

### Recovery

**Checkpoint Support:**

RedisShake doesn't have built-in checkpointing for RDB files (since they're read sequentially), but you can:

1. **Split large RDB files:**
```bash
# Use redis-cli with SCAN to create smaller RDBs
redis-cli --rdb partial-db0.rdb << EOF
SELECT 0
SCAN 0 MATCH * COUNT 10000
SAVE
EOF
```

2. **Verify migration:**
```bash
# Count keys in source
redis-cli -h source DBSIZE

# Count keys in target (with prefixes)
redis-cli -h target --tls KEYS 'db1:*' | wc -l
redis-cli -h target --tls KEYS 'db2:*' | wc -l
```

3. **Incremental sync after RDB:**
```toml
# Use scan_reader for live updates
[scan_reader]
address = "source:6379"
ksn = true  # Enable keyspace notifications
```

---

## Code Structure

### Project Layout

```
rdb-elasticache-migrator/
│
├── migrate.sh                          [Main orchestrator script]
│
├── redisshake/                         [Complete RedisShake source]
│   │
│   ├── cmd/
│   │   └── redis-shake/
│   │       └── main.go                 [Entry point]
│   │
│   ├── internal/
│   │   │
│   │   ├── rdb/                        [RDB parsing]
│   │   │   ├── rdb.go                  [Main parser logic]
│   │   │   ├── structure/              [Binary structure readers]
│   │   │   │   ├── byte.go
│   │   │   │   ├── length.go
│   │   │   │   ├── string.go
│   │   │   │   └── ziplist.go
│   │   │   └── types/                  [Redis data types]
│   │   │       ├── string.go
│   │   │       ├── hash.go
│   │   │       ├── list.go
│   │   │       ├── set.go
│   │   │       ├── zset.go
│   │   │       └── stream.go
│   │   │
│   │   ├── reader/                     [Data source readers]
│   │   │   ├── rdb_reader.go          [RDB file reader]
│   │   │   ├── sync_standalone_reader.go
│   │   │   └── scan_cluster_reader.go
│   │   │
│   │   ├── filter/                     [Data transformation]
│   │   │   ├── filter.go              [Base filter]
│   │   │   └── function.go            [Lua function filter]
│   │   │
│   │   ├── writer/                     [Data destination writers]
│   │   │   ├── redis_cluster_writer.go [Cluster mode writer]
│   │   │   └── redis_standalone_writer.go
│   │   │
│   │   ├── client/                     [Redis protocol]
│   │   │   ├── redis.go
│   │   │   ├── reply.go
│   │   │   └── proto/                  [RESP parser]
│   │   │
│   │   ├── entry/                      [Data entry structure]
│   │   │   └── entry.go
│   │   │
│   │   └── utils/                      [Helper utilities]
│   │       ├── crc16.go               [Hash slot calculation]
│   │       ├── file.go
│   │       └── parse.go
│   │
│   ├── build.sh                        [Build script]
│   ├── go.mod                          [Go dependencies]
│   └── go.sum                          [Dependency checksums]
│
├── configs/                            [Generated configs]
│   └── migration_*.toml
│
├── logs/                               [Migration logs]
│   └── migration_*.log
│
└── data/                               [Working directory]
    └── [RedisShake runtime files]
```

### Key Files Explained

**1. migrate.sh (622 lines)**
- Argument parsing
- Validation logic
- Config generation
- Process management
- Result reporting

**2. redisshake/internal/rdb/rdb.go (242 lines)**
- Binary RDB parsing
- Opcode handling
- Database tracking
- Entry generation

**3. redisshake/internal/filter/function.go (280 lines)**
- Lua VM initialization
- Context injection
- Function execution
- Result collection

**4. redisshake/internal/writer/redis_cluster_writer.go (350 lines)**
- Cluster topology discovery
- Slot calculation
- Connection management
- Pipeline batching
- Error handling

---

## Summary

This migration tool solves the multi-database to cluster-mode problem through:

1. **RDB Parsing**: Reads binary Redis snapshots
2. **Key Transformation**: Prefixes keys from non-zero databases
3. **Cluster Writing**: Routes keys to correct shards
4. **Performance**: Pipelines, rate limiting, parallelism
5. **Reliability**: Retries, error handling, logging

The result: Complete data migration from traditional Redis to ElastiCache Serverless with zero data loss and minimal downtime.

---

## Additional Resources

- **RedisShake Docs**: https://tair-opensource.github.io/RedisShake/
- **RDB Format**: https://github.com/sripathikrishnan/redis-rdb-tools/wiki/Redis-RDB-Dump-File-Format
- **Redis Cluster**: https://redis.io/docs/reference/cluster-spec/
- **RESP Protocol**: https://redis.io/docs/reference/protocol-spec/
- **ElastiCache**: https://docs.aws.amazon.com/elasticache/

---

**Questions? Issues?**
- Check logs: `tail -100 logs/migration_*.log`
- GitHub Issues: https://github.com/tios-smashal/rdb-elasticache-migrator/issues
