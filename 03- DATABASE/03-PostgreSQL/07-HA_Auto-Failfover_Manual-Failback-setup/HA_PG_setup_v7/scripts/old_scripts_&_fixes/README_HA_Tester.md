# PostgreSQL HA Automated Testing Suite v2.0.0

## 🎯 Overview

This is a completely new, clean, and fully automated PostgreSQL High Availability failover/failback testing suite built on proven solutions from successful troubleshooting sessions. It handles complete failover/failback scenarios with automatic resolution of common issues like replication slot problems.

## ✨ Key Features

### 🔄 **Fully Automated Testing**
- Complete failover testing with automatic promotion
- Comprehensive failback with cluster restoration
- Full cycle testing (failover → failback)
- Automatic error detection and recovery

### 🛠️ **Proven Solutions Integration**
- Enhanced pg_basebackup with WAL streaming
- Complete directory cleanup methods
- Automatic replication slot management
- pg_hba.conf authentication fixes
- Multiple promotion fallback methods

### 📊 **Advanced Monitoring**
- Real-time connectivity monitoring
- Comprehensive cluster validation
- Detailed test reporting
- Performance metrics collection

### 🔧 **Production-Safe Operations**
- Comprehensive pre-flight checks
- Automatic rollback on failures
- Load balancer integration
- DNS-aware testing

## 🚀 Quick Start

### Setup
```bash
cd /Users/abdulrahmansamy/git-repos/system_engineering/03-\ DATABASE/03-PostgreSQL/07-HA_Auto-Failfover_Manual-Failback-setup/HA_PG_setup_v7/scripts/
./setup_ha_tester.sh
```

### Run the Suite
```bash
./automated_ha_failover_tester.sh
```

## 📋 Menu Options

### 1. 🔍 **Initial Cluster Validation**
- Tests connectivity to both nodes
- Verifies current roles (PRIMARY/STANDBY)  
- Checks replication status and lag
- Validates data synchronization

### 2. 🔧 **Apply Proven Configuration Fixes**
- Updates pg_hba.conf with proven replication entries
- Applies authentication fixes
- Configures optimal settings for HA

### 3. ⚡ **Run Complete Failover Test**
- **Pre-failover validation**
- **Stops primary PostgreSQL service**
- **Promotes standby to primary**
- **Updates load balancer configuration**
- **Validates new primary functionality**

### 4. 🔄 **Run Complete Failback Test**  
- **Validates cluster state for safe failback**
- **Promotes original primary back to PRIMARY**
- **Re-creates standby using enhanced pg_basebackup**
- **Re-establishes replication**
- **Restores original configuration**

### 5. 🔁 **Run Full Cycle Test**
- **Complete failover → failback testing**
- **Validates cluster at each step**
- **Comprehensive end-to-end validation**

### 6. 📊 **Monitor Cluster Status**
- Real-time connectivity monitoring
- CSV output for analysis
- Performance metrics collection

### 7. 🛠️ **Fix Replication Slots**
- Automatic detection and cleanup of problematic slots
- Creates missing replication slots
- Resolves slot-related errors

### 8. 📋 **Generate Status Report**
- Comprehensive cluster health report
- Replication status details
- Configuration analysis

### 9. 🧹 **Cleanup Test Artifacts**
- Removes test tables and temporary data
- Cleans up monitoring files
- Ensures clean environment

## 🔧 Technical Implementation

### Proven Solutions Integrated

#### **Enhanced pg_basebackup Method**
```bash
# Complete directory cleanup + enhanced backup
sudo rm -rf /var/lib/postgresql/17/main
sudo mkdir -p /var/lib/postgresql/17/main
sudo chown postgres:postgres /var/lib/postgresql/17/main

# Enhanced pg_basebackup with proven options
pg_basebackup -h $source_host -p 5432 -U postgres \
  -D /var/lib/postgresql/17/main \
  --no-password -X stream --checkpoint=fast \
  --write-recovery-conf
```

#### **Automatic Replication Slot Management**
```sql
-- Drop inactive slots causing issues
SELECT pg_drop_replication_slot(slot_name) 
FROM pg_replication_slots 
WHERE NOT active AND slot_name LIKE 'repmgr_slot_%';

-- Create missing slots
SELECT pg_create_physical_replication_slot('repmgr_slot_2') 
WHERE NOT EXISTS (
    SELECT 1 FROM pg_replication_slots 
    WHERE slot_name = 'repmgr_slot_2'
);
```

#### **Multiple Promotion Methods**
```bash
# Method 1: repmgr promotion
repmgr -f /etc/repmgr/repmgr.conf standby promote --force

# Method 2: Direct PostgreSQL promotion (fallback)
psql -c "SELECT pg_promote();"
```

### Error Handling & Recovery
- **Automatic retry logic** with exponential backoff
- **Comprehensive validation** at each step
- **Automatic rollback** on critical failures
- **Production-safe** operations with confirmations

### Load Balancer Integration
- Automatic load balancer updates during failover/failback
- DNS-aware testing and validation
- GCP Cloud Load Balancer support

## ⚠️ Prerequisites

### Required Access
- **SSH key access** to both PostgreSQL nodes
- **gcloud authentication** for Secret Manager access
- **Network connectivity** to cluster nodes and DNS endpoints
- **sudo privileges** on target nodes (via SSH)

### Dependencies
- `gcloud` CLI tool
- `psql` client
- `ssh` with key-based authentication
- `dig` for DNS resolution testing

## 📊 Monitoring & Reporting

### Real-Time Monitoring
- Connectivity status every 5 seconds during tests
- CSV output for post-analysis
- Performance metrics collection

### Comprehensive Reports
- Test duration and results
- Cluster configuration details
- Final cluster state validation
- Replication status analysis

### Example Report Output
```
PostgreSQL HA Test Report
========================
Test Type: FULL_CYCLE
Result: SUCCESS
Duration: 245 seconds
Start Time: 2025-01-18 15:30:45
End Time: 2025-01-18 15:34:50

Final Cluster State:
- Node 192.168.14.21 Role: PRIMARY
- Node 192.168.14.22 Role: STANDBY

Replication Status:
client_addr | application_name | state | lag_bytes
192.168.14.22 | standby | streaming | 0
```

## 🎯 Success Criteria

### Failover Test Success
✅ Primary node stops gracefully  
✅ Standby promotes to primary within 60 seconds  
✅ New primary accepts write operations  
✅ Load balancer routes traffic correctly  
✅ No data loss during transition  

### Failback Test Success  
✅ Original primary returns to PRIMARY role  
✅ Original standby returns to STANDBY role  
✅ Replication re-establishes successfully  
✅ Data synchronization verified  
✅ Cluster returns to original state  

### Full Cycle Test Success
✅ Complete failover → failback → validation cycle  
✅ All intermediate states validated  
✅ No manual intervention required  
✅ Cluster fully functional after test  

## 🔒 Production Safety

### Safety Measures
- **Comprehensive pre-flight checks** before destructive operations
- **User confirmation** required for disruptive tests
- **Automatic rollback** on critical failures
- **Validation at each step** to prevent data loss

### Best Practices
- Run tests during maintenance windows
- Monitor cluster performance during tests
- Have rollback procedures ready
- Test in staging environment first

## 🆚 Differences from Original Script

### What's New in v2.0.0
- **100% automated** operations vs manual interventions
- **Proven solutions** integrated from successful troubleshooting  
- **Automatic error recovery** vs manual fixes
- **Comprehensive validation** at each step
- **Production-safe** error handling
- **Load balancer integration** 
- **Enhanced monitoring** and reporting
- **Clean artifact management**

### Removed Complexities
- ❌ Manual troubleshooting options
- ❌ Complex menu navigation
- ❌ Trial-and-error approaches  
- ❌ Inconsistent error handling
- ❌ Manual cleanup requirements

## 🚀 Usage Examples

### Quick Validation
```bash
./automated_ha_failover_tester.sh
# Choose option 1: Initial cluster validation
```

### Complete Failover Test
```bash  
./automated_ha_failover_tester.sh
# Choose option 3: Run complete failover test
# Confirm with 'yes'
```

### Full Cycle Testing
```bash
./automated_ha_failover_tester.sh  
# Choose option 5: Run full cycle test
# Confirm with 'yes' 
# Wait for completion (~5-10 minutes)
```

## 📞 Support

This script implements battle-tested solutions from successful PostgreSQL HA troubleshooting sessions. All operations are based on proven methods that have been validated in production-like environments.

For issues or questions, refer to the comprehensive logging output and generated test reports.

---

**🎉 Ready for Enterprise PostgreSQL HA Testing!**