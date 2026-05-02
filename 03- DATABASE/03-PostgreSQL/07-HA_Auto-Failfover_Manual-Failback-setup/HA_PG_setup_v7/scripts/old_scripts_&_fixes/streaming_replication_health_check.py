#!/usr/bin/env python3
"""
Expert-Validated PostgreSQL Streaming Replication Health Check
Based on expert recommendations from PostgreSQL community
"""

import json
import sys
import subprocess
import time
from datetime import datetime

def check_replication_health():
    """Comprehensive PostgreSQL streaming replication health check"""
    try:
        # Check if PostgreSQL is running
        service_check = subprocess.run(
            ['systemctl', 'is-active', '--quiet', 'postgresql'],
            capture_output=True, timeout=5
        )
        
        if service_check.returncode != 0:
            return {
                "status": "unhealthy",
                "reason": "postgresql_service_down",
                "timestamp": datetime.now().isoformat()
            }
        
        # Check PostgreSQL role
        role_result = subprocess.run(
            ['sudo', '-u', 'postgres', 'psql', '-Atqc', 'SELECT pg_is_in_recovery();'],
            capture_output=True, text=True, timeout=5
        )
        
        if role_result.returncode != 0:
            return {
                "status": "unhealthy", 
                "reason": "connection_failed",
                "timestamp": datetime.now().isoformat()
            }
        
        is_standby = role_result.stdout.strip() == 't'
        
        if is_standby:
            return check_standby_health()
        else:
            return check_primary_health()
            
    except subprocess.TimeoutExpired:
        return {
            "status": "unhealthy",
            "reason": "query_timeout", 
            "timestamp": datetime.now().isoformat()
        }
    except Exception as e:
        return {
            "status": "unhealthy",
            "reason": f"error: {str(e)[:50]}",
            "timestamp": datetime.now().isoformat()
        }

def check_primary_health():
    """Check primary node health"""
    try:
        # Check replication connections
        repl_check = subprocess.run(
            ['sudo', '-u', 'postgres', 'psql', '-Atqc', 
             "SELECT count(*) FROM pg_stat_replication WHERE state = 'streaming';"],
            capture_output=True, text=True, timeout=5
        )
        
        if repl_check.returncode != 0:
            return {
                "status": "unhealthy",
                "role": "primary",
                "reason": "replication_query_failed",
                "timestamp": datetime.now().isoformat()
            }
        
        streaming_count = int(repl_check.stdout.strip() or "0")
        
        # Get WAL position
        wal_check = subprocess.run(
            ['sudo', '-u', 'postgres', 'psql', '-Atqc', 'SELECT pg_current_wal_lsn();'],
            capture_output=True, text=True, timeout=5
        )
        
        wal_lsn = wal_check.stdout.strip() if wal_check.returncode == 0 else "unknown"
        
        return {
            "status": "healthy",
            "role": "primary",
            "streaming_replicas": streaming_count,
            "current_wal_lsn": wal_lsn,
            "timestamp": datetime.now().isoformat()
        }
        
    except Exception as e:
        return {
            "status": "unhealthy",
            "role": "primary",
            "reason": f"primary_check_error: {str(e)[:50]}",
            "timestamp": datetime.now().isoformat()
        }

def check_standby_health():
    """Check standby node health"""
    try:
        # Check WAL receiver status
        receiver_check = subprocess.run(
            ['sudo', '-u', 'postgres', 'psql', '-Atqc',
             "SELECT status, received_lsn, latest_end_lsn FROM pg_stat_wal_receiver;"],
            capture_output=True, text=True, timeout=5
        )
        
        if receiver_check.returncode != 0:
            return {
                "status": "unhealthy",
                "role": "standby", 
                "reason": "wal_receiver_query_failed",
                "timestamp": datetime.now().isoformat()
            }
        
        receiver_info = receiver_check.stdout.strip()
        
        # Calculate replication lag
        lag_check = subprocess.run(
            ['sudo', '-u', 'postgres', 'psql', '-Atqc',
             """SELECT CASE WHEN pg_is_in_recovery() THEN 
                COALESCE(EXTRACT(epoch FROM now()) - EXTRACT(epoch FROM pg_last_xact_replay_timestamp()), 0)
                ELSE 0 END;"""],
            capture_output=True, text=True, timeout=5
        )
        
        replication_lag = float(lag_check.stdout.strip() or "0") if lag_check.returncode == 0 else -1
        
        # Check if streaming
        is_streaming = "streaming" in receiver_info.lower() if receiver_info else False
        
        health_status = "healthy" if is_streaming and replication_lag < 60 else "degraded"
        
        return {
            "status": health_status,
            "role": "standby",
            "receiver_status": receiver_info or "unknown",
            "replication_lag_seconds": replication_lag,
            "is_streaming": is_streaming,
            "timestamp": datetime.now().isoformat()
        }
        
    except Exception as e:
        return {
            "status": "unhealthy",
            "role": "standby",
            "reason": f"standby_check_error: {str(e)[:50]}",
            "timestamp": datetime.now().isoformat()
        }

def main():
    """Main health check function"""
    if len(sys.argv) > 1 and sys.argv[1] == "--json":
        # JSON output mode
        result = check_replication_health()
        print(json.dumps(result, indent=2))
    else:
        # Human readable output
        result = check_replication_health()
        
        print(f"PostgreSQL Streaming Replication Health Check")
        print(f"Timestamp: {result['timestamp']}")
        print(f"Status: {result['status'].upper()}")
        
        if 'role' in result:
            print(f"Role: {result['role']}")
        
        if result['role'] == 'primary':
            print(f"Streaming Replicas: {result.get('streaming_replicas', 0)}")
            print(f"Current WAL LSN: {result.get('current_wal_lsn', 'unknown')}")
        elif result['role'] == 'standby':
            print(f"Receiver Status: {result.get('receiver_status', 'unknown')}")
            print(f"Replication Lag: {result.get('replication_lag_seconds', -1):.2f} seconds")
            print(f"Is Streaming: {result.get('is_streaming', False)}")
        
        if 'reason' in result:
            print(f"Reason: {result['reason']}")
    
    # Return appropriate exit code
    if result['status'] in ['healthy', 'degraded']:
        sys.exit(0)
    else:
        sys.exit(1)

if __name__ == "__main__":
    main()