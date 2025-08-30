# Release Notes - sync_on_change

## Version 1.3.0 - 2025-08-27

### 🎯 Major Features
- **Directory Synchronization**: Added full support for monitoring and syncing entire directories
- **Intelligent Sync Methods**: Auto-detects rsync availability with tar+scp fallback
- **Recursive Monitoring**: Monitors all files within directories for changes
- **Smart Permissions**: Automatically sets executable permissions for shell scripts in synced directories
- **Binary Distribution**: Added Makefile and build script for creating compiled binaries using shc

### 🔧 Technical Improvements
- **Enhanced Checksum Calculation**: 
  - Files: SHA-256 checksum of file content
  - Directories: Combined SHA-256 checksum of all files within directory tree
- **Dual Sync Strategy**:
  - Primary: rsync with `--delete` flag for efficient directory sync
  - Fallback: tar+scp method when rsync unavailable on remote host
- **Unified Target Handling**: Single parameter accepts both files and directories
- **Backward Compatibility**: Maintains all v1.2 functionality for file sync
- **Binary Compilation**: Support for creating standalone executables with shc

### 🎨 User Experience
- **Automatic Type Detection**: Script detects file vs directory and adjusts behavior
- **Enhanced Monitoring Display**: Shows target type (file/directory) in progress messages
- **Improved Error Messages**: Clearer feedback for different sync methods and failures
- **Seamless Fallback**: Transparent switching between sync methods on failure
- **Easy Binary Creation**: Simple `make` or `./build.sh` commands to create binaries

### 🔒 Reliability
- **Robust Directory Sync**: Handles missing rsync gracefully with tar+scp fallback
- **Remote Cleanup**: Removes temporary archives after extraction
- **Atomic Directory Operations**: Removes old content before extracting new
- **Enhanced Error Detection**: Validates each step of fallback sync process

### 📋 Configuration
- **Unchanged Config Format**: All existing config files work without modification
- **Same Search Order**: Maintains v1.2 configuration file precedence
- **Backward Compatible**: v1.2 usage patterns continue to work

### 🚀 Usage Examples
```bash
# File sync (unchanged from v1.2)
./sync_on_change_v1.3.sh script.sh

# Directory sync (new in v1.3)
./sync_on_change_v1.3.sh my_project/

# With verbose output
./sync_on_change_v1.3.sh my_project/ -v

# With custom config
./sync_on_change_v1.3.sh my_project/ -c /path/to/config.conf

# Using compiled binary
./sync_on_change my_project/ -v
```

### 🔨 Binary Creation
Create standalone executable binaries using the included build tools:

```bash
# Install shc compiler (required)
sudo apt-get install shc  # Ubuntu/Debian
sudo yum install shc      # CentOS/RHEL

# Build all versions
make all

# Build latest version only
make binaries

# Create distribution package
make dist

# Install to system
make install

# Using build script for advanced options
./build.sh --latest --optimize --dist --install
```

The binary creation process:
- Compiles Bash scripts into standalone executables using shc
- Creates optimized binaries with stripped symbols
- Packages binaries with configuration templates and documentation
- Supports system-wide installation

### 🔄 Migration from v1.2
- **Zero Changes Required**: All v1.2 usage patterns work unchanged
- **New Capability**: Simply pass a directory path instead of file path
- **Same Config**: No configuration file updates needed
- **Binary Option**: Optionally compile to binary for faster execution and distribution

### 🐛 Bug Fixes
- Fixed directory sync when rsync not available on remote host
- Improved error handling for archive creation and transfer
- Enhanced permission setting for shell scripts in directories

---

## Version 1.2.0 - 2025-08-27

### 🎯 Major Features
- **Modular Architecture**: Complete refactoring into clean, maintainable functions
- **Verbose Mode**: Added `-v/--verbose` flag to control debug output visibility
- **Initial Sync**: Automatic first sync on startup to ensure remote is current
- **Enhanced Configuration**: Improved config loading with better source reporting

### 🔧 Technical Improvements
- **Function-based Design**: Split monolithic script into focused functions:
  - `parse_args()` - Command line argument parsing
  - `set_defaults()` - Default configuration values
  - `load_config()` - External configuration file loading
  - `validate_config()` - Configuration validation
  - `ssh_setup()` - SSH connection and remote directory setup
  - `sync_file()` - File synchronization logic
  - `main_loop()` - Main monitoring loop
  - `monitor_dots()` - Visual progress animation

- **Improved Sync Logic**: 
  - Fixed checksum corruption issue by redirecting log messages to stderr
  - Only sync when file content actually changes (not on every interval)
  - Proper first-run initialization to avoid unnecessary initial sync

- **Better Error Handling**:
  - Removed dependency on Bash 4.3+ nameref feature for broader compatibility
  - Global `fail_count` variable for cleaner error tracking
  - Enhanced validation for config parameters

### 🎨 User Experience
- **Cleaner Output**: Debug messages only shown with `-v` flag
- **Better Monitoring**: Animated dots show monitoring activity without spam
- **Comprehensive Logging**: Color-coded messages with timestamps
- **Configuration Transparency**: Clear reporting of config sources

### 🔒 Reliability
- **SSH Key Management**: Automatic setup of passwordless SSH if needed
- **Remote Directory Creation**: Ensures target directory exists
- **Failure Tracking**: Configurable failure threshold with graceful exit
- **File Validation**: Proper file existence checks

### 📋 Configuration
- **Flexible Config Loading**: Multiple config file locations supported
- **Source Reporting**: Shows which values come from defaults vs config files
- **Override Priority**: Clear precedence order for configuration sources

### 🚀 Usage Examples
```bash
# Basic usage
./sync_on_change_v1.2.sh script.sh

# With verbose output
./sync_on_change_v1.2.sh script.sh -v

# With custom config
./sync_on_change_v1.2.sh script.sh -c /path/to/config.conf

# With both verbose and custom config
./sync_on_change_v1.2.sh script.sh -v -c /path/to/config.conf
```

### 🔧 Configuration File
The script supports configuration files with the following variables:
- `remote_user` - SSH username
- `remote_host` - SSH host/IP address  
- `remote_path` - Destination directory (default: ~/scripts/)
- `interval` - Polling interval in seconds (default: 3)
- `max_failures` - Maximum consecutive failures before abort (default: 10)

### 🐛 Bug Fixes
- Fixed sync triggering on every interval instead of only on changes
- Resolved checksum corruption from log message interference
- Eliminated compatibility issues with older Bash versions
- Corrected config loading order and validation timing

### 📦 Dependencies
- Bash 3.2+ (improved compatibility)
- OpenSSL (for SHA-256 checksums)
- SSH/SCP (for remote operations)
- Standard Unix utilities (grep, awk, etc.)

### 🔄 Migration from v1.1
No breaking changes - existing config files and usage patterns remain compatible.
New verbose mode is opt-in via `-v` flag.

---
*v1.3: Major expansion with directory sync capabilities, intelligent fallback mechanisms, and binary compilation support.*  
*v1.2: Complete architectural overhaul focused on maintainability, reliability, and user experience.*
