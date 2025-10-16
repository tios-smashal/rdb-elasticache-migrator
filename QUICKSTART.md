# Quick Start - RDB to ElastiCache Migration

## One Command Migration

```bash
cd ~/dev/rdb-elasticache-migrator

./migrate.sh /var/lib/redis/dump.rdb saif-serverlesss-eyty4q.serverless.use1.cache.amazonaws.com YOUR_PASSWORD
```

Done! That's literally it.

## What Just Happened?

The script:
1. ✓ Found your RDB file
2. ✓ Built RedisShake (if needed)
3. ✓ Generated config with database prefixing
4. ✓ Migrated all databases to ElastiCache db0
5. ✓ Logged everything

## What About Multiple Databases?

Your RDB file might have:
- db0: 10,000 keys
- db1: 5,000 keys
- db2: 2,000 keys

After migration, ElastiCache db0 has:
- 10,000 keys (unchanged from db0)
- 5,000 keys prefixed with `db1:`
- 2,000 keys prefixed with `db2:`

**Total: 17,000 keys, all in db0, no collisions!**

## Check Your Data

```bash
redis-cli -h saif-serverlesss-eyty4q.serverless.use1.cache.amazonaws.com \
  -p 6379 --tls --askpass

# Original db0
GET user:123

# Original db1
GET db1:user:123

# All keys from original db1
KEYS db1:*
```

## Everything is Self-Contained

```
~/dev/rdb-elasticache-migrator/
├── migrate.sh          ← THE ONLY FILE YOU NEED
├── redisshake/         ← Complete RedisShake source
├── configs/            ← Auto-generated configs
├── logs/               ← Migration logs
└── README_SIMPLE.md    ← Full documentation
```

Copy this whole directory to any machine and it works!

## Help

```bash
./migrate.sh --help
```

## That's It!

No dependencies, no setup, no complexity. Just one command.
