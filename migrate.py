#!/usr/bin/env python3
"""
RDB to ElastiCache Serverless Migration Tool

This tool reads a Redis dump.rdb file and migrates all databases to ElastiCache Serverless.
Since ElastiCache Serverless (cluster mode) only supports database 0, keys from other
databases are prefixed with "db{N}:" to avoid collisions.

Requirements:
    pip install redis rdbtools python-lzf

Usage:
    python migrate.py --config config.json
"""

import argparse
import json
import logging
import sys
from typing import Dict, Any, Optional
import redis
from redis.cluster import RedisCluster
import rdbtools
import io

# Configure logging
logging.basicConfig(
    level=logging.INFO,
    format='%(asctime)s - %(levelname)s - %(message)s',
    handlers=[
        logging.FileHandler('migration.log'),
        logging.StreamHandler(sys.stdout)
    ]
)
logger = logging.getLogger(__name__)


class ElastiCacheMigrator(rdbtools.RdbCallback):
    """
    RDB parser callback that writes to ElastiCache Serverless
    """

    def __init__(self, redis_client, dry_run=False, prefix_dbs=True):
        """
        Initialize the migrator

        Args:
            redis_client: Redis client instance
            dry_run: If True, only log operations without writing
            prefix_dbs: If True, prefix keys from non-zero databases
        """
        super().__init__()
        self.client = redis_client
        self.dry_run = dry_run
        self.prefix_dbs = prefix_dbs
        self.current_db = 0
        self.stats = {
            'total_keys': 0,
            'by_type': {},
            'by_db': {},
            'errors': 0
        }

    def start_rdb(self):
        logger.info("Starting RDB parse...")

    def start_database(self, db_number):
        """Called when RDB switches to a new database"""
        self.current_db = db_number
        logger.info(f"Processing database {db_number}")
        if db_number not in self.stats['by_db']:
            self.stats['by_db'][db_number] = 0

    def end_database(self, db_number):
        """Called when database processing is complete"""
        logger.info(f"Completed database {db_number}: {self.stats['by_db'][db_number]} keys")

    def end_rdb(self):
        """Called when RDB parsing is complete"""
        logger.info("RDB parse complete!")
        logger.info(f"Total keys processed: {self.stats['total_keys']}")
        logger.info(f"Errors: {self.stats['errors']}")
        logger.info(f"By database: {self.stats['by_db']}")
        logger.info(f"By type: {self.stats['by_type']}")

    def _get_key_name(self, key):
        """
        Get the target key name, adding database prefix if needed

        Args:
            key: Original key name (bytes)

        Returns:
            str: Target key name
        """
        key_str = key.decode('utf-8') if isinstance(key, bytes) else key

        # Add database prefix for non-zero databases
        if self.prefix_dbs and self.current_db != 0:
            return f"db{self.current_db}:{key_str}"
        return key_str

    def _set_key(self, key, value, expiry=None):
        """
        Set a key in the target Redis

        Args:
            key: Key name
            value: Key value
            expiry: Optional expiry in milliseconds
        """
        target_key = self._get_key_name(key)

        if self.dry_run:
            logger.info(f"[DRY RUN] SET {target_key} (db={self.current_db})")
            return

        try:
            if expiry and expiry > 0:
                self.client.set(target_key, value, px=expiry)
            else:
                self.client.set(target_key, value)

            self.stats['total_keys'] += 1
            self.stats['by_db'][self.current_db] += 1

        except Exception as e:
            logger.error(f"Error setting key {target_key}: {e}")
            self.stats['errors'] += 1

    def set(self, key, value, expiry, info):
        """Handle string keys"""
        self._track_type('string')
        self._set_key(key, value, expiry)

    def _track_type(self, key_type):
        """Track key type statistics"""
        if key_type not in self.stats['by_type']:
            self.stats['by_type'][key_type] = 0
        self.stats['by_type'][key_type] += 1

    def hset(self, key, field, value):
        """Handle hash fields"""
        self._track_type('hash')
        target_key = self._get_key_name(key)

        if self.dry_run:
            logger.info(f"[DRY RUN] HSET {target_key} {field}")
            return

        try:
            self.client.hset(target_key, field, value)
        except Exception as e:
            logger.error(f"Error setting hash field {target_key}.{field}: {e}")
            self.stats['errors'] += 1

    def sadd(self, key, member):
        """Handle set members"""
        self._track_type('set')
        target_key = self._get_key_name(key)

        if self.dry_run:
            logger.info(f"[DRY RUN] SADD {target_key} {member}")
            return

        try:
            self.client.sadd(target_key, member)
        except Exception as e:
            logger.error(f"Error adding set member to {target_key}: {e}")
            self.stats['errors'] += 1

    def rpush(self, key, value):
        """Handle list elements"""
        self._track_type('list')
        target_key = self._get_key_name(key)

        if self.dry_run:
            logger.info(f"[DRY RUN] RPUSH {target_key}")
            return

        try:
            self.client.rpush(target_key, value)
        except Exception as e:
            logger.error(f"Error pushing to list {target_key}: {e}")
            self.stats['errors'] += 1

    def zadd(self, key, score, member):
        """Handle sorted set members"""
        self._track_type('zset')
        target_key = self._get_key_name(key)

        if self.dry_run:
            logger.info(f"[DRY RUN] ZADD {target_key} {score} {member}")
            return

        try:
            self.client.zadd(target_key, {member: score})
        except Exception as e:
            logger.error(f"Error adding to sorted set {target_key}: {e}")
            self.stats['errors'] += 1


def create_redis_client(config: Dict[str, Any]) -> redis.Redis:
    """
    Create Redis client based on configuration

    Args:
        config: Configuration dictionary

    Returns:
        Redis client instance
    """
    target = config['target']

    # Determine if it's a cluster
    if target.get('cluster', True):
        client = RedisCluster(
            host=target['host'],
            port=target.get('port', 6379),
            password=target.get('password'),
            ssl=target.get('tls', True),
            ssl_cert_reqs='required' if target.get('tls', True) else None,
            decode_responses=False,
            skip_full_coverage_check=True
        )
    else:
        client = redis.Redis(
            host=target['host'],
            port=target.get('port', 6379),
            password=target.get('password'),
            ssl=target.get('tls', True),
            ssl_cert_reqs='required' if target.get('tls', True) else None,
            decode_responses=False
        )

    # Test connection
    try:
        client.ping()
        logger.info(f"Successfully connected to {target['host']}:{target.get('port', 6379)}")
    except Exception as e:
        logger.error(f"Failed to connect to Redis: {e}")
        raise

    return client


def migrate_rdb(config_path: str):
    """
    Main migration function

    Args:
        config_path: Path to configuration file
    """
    # Load configuration
    with open(config_path, 'r') as f:
        config = json.load(f)

    logger.info("=" * 60)
    logger.info("RDB to ElastiCache Serverless Migration")
    logger.info("=" * 60)
    logger.info(f"Source RDB: {config['source']['rdb_file']}")
    logger.info(f"Target: {config['target']['host']}")
    logger.info(f"Dry run: {config.get('dry_run', False)}")
    logger.info(f"Prefix databases: {config.get('prefix_dbs', True)}")
    logger.info("=" * 60)

    # Create Redis client
    redis_client = create_redis_client(config)

    # Create migrator
    migrator = ElastiCacheMigrator(
        redis_client,
        dry_run=config.get('dry_run', False),
        prefix_dbs=config.get('prefix_dbs', True)
    )

    # Parse RDB file
    rdb_file = config['source']['rdb_file']
    logger.info(f"Parsing RDB file: {rdb_file}")

    try:
        parser = rdbtools.RdbParser(migrator)
        parser.parse(rdb_file)
    except Exception as e:
        logger.error(f"Error parsing RDB file: {e}")
        raise

    logger.info("=" * 60)
    logger.info("Migration completed!")
    logger.info("=" * 60)


def main():
    parser = argparse.ArgumentParser(
        description='Migrate Redis RDB file to ElastiCache Serverless'
    )
    parser.add_argument(
        '--config',
        required=True,
        help='Path to configuration JSON file'
    )

    args = parser.parse_args()

    try:
        migrate_rdb(args.config)
    except Exception as e:
        logger.error(f"Migration failed: {e}")
        sys.exit(1)


if __name__ == '__main__':
    main()
