================================================================================
  RDB to ElastiCache Serverless Migration Tool
  Complete Self-Contained Package
================================================================================

WHAT YOU HAVE:
  A complete, ready-to-use migration tool with:
  ✓ RedisShake source code (built-in RDB parser)
  ✓ Migration script with automatic configuration
  ✓ Database prefixing (handles multiple databases)
  ✓ Full logging and error handling
  ✓ No external dependencies needed

PROJECT SIZE: 30MB (includes complete RedisShake source)

================================================================================
QUICK START
================================================================================

ONE COMMAND:
  
  ./migrate.sh /path/to/dump.rdb your-endpoint.amazonaws.com your-password

THAT'S IT!

================================================================================
WHAT IT DOES
================================================================================

1. Reads your Redis RDB file (all databases: db0, db1, db2, etc.)
2. Prefixes keys from non-zero databases
   - db0: user:123  →  user:123       (unchanged)
   - db1: user:123  →  db1:user:123   (prefixed)
   - db2: cache:xyz →  db2:cache:xyz  (prefixed)
3. Writes everything to ElastiCache database 0
4. No data loss, no key collisions!

================================================================================
FILES
================================================================================

MAIN FILES:
  migrate.sh          - Main migration script (USE THIS!)
  QUICKSTART.md       - 1-page quick start guide
  README_SIMPLE.md    - Simple documentation
  
OPTIONAL:
  migrate.py          - Python alternative (more dependencies)
  README.md           - Full documentation
  USAGE_EXAMPLES.md   - Detailed examples
  
INCLUDED:
  redisshake/         - Complete RedisShake source with RDB parser
  
AUTO-GENERATED:
  configs/            - Generated configs (timestamped)
  logs/               - Migration logs (timestamped)
  data/               - Working directory

================================================================================
REQUIREMENTS
================================================================================

MINIMAL:
  ✓ Bash shell
  ✓ Go compiler (for first-time build only)
  ✓ Your RDB file
  ✓ ElastiCache endpoint and password

NO NEED TO INSTALL:
  ✗ Redis
  ✗ Python packages
  ✗ External tools

================================================================================
EXAMPLES
================================================================================

Basic:
  ./migrate.sh /var/lib/redis/dump.rdb my-cluster.amazonaws.com mypass

With options:
  ./migrate.sh --rdb-file dump.rdb --endpoint my-cluster.com --password mypass

Dry run first (test):
  ./migrate.sh --dry-run -r dump.rdb -e my-cluster.com -p mypass

Help:
  ./migrate.sh --help

================================================================================
PORTABLE
================================================================================

This entire directory is self-contained!

Copy to any machine:
  scp -r rdb-elasticache-migrator/ user@server:~/
  
Then run:
  cd ~/rdb-elasticache-migrator
  ./migrate.sh /path/to/dump.rdb endpoint password

================================================================================
DOCUMENTATION
================================================================================

Quick Start:     QUICKSTART.md (1 page)
Simple Guide:    README_SIMPLE.md (user-friendly)
Full Docs:       README.md (comprehensive)
Examples:        USAGE_EXAMPLES.md (detailed examples)

================================================================================
SUPPORT
================================================================================

Check logs:
  tail -f logs/migration_*.log

Show help:
  ./migrate.sh --help

View latest config:
  cat configs/migration_*.toml

================================================================================

Ready to migrate? Run: ./migrate.sh --help

================================================================================
