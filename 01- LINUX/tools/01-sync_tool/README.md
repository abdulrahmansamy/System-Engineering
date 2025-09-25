# Sync On Change Tool

A cross-platform file and directory synchronization tool that watches for changes and automatically syncs to remote hosts via SSH.

## Project Structure

```
01-sync_tool/
├── src/                    # Source code for all implementations
│   ├── bash/              # Shell script versions (legacy)
│   │   ├── sync_on_change_v1.1.sh
│   │   ├── sync_on_change_v1.2.sh
│   │   ├── sync_on_change_v1.3.sh
│   │   └── sync_on_change_v1.4.sh
│   ├── python/            # Python implementation
│   │   ├── sync_on_change.py
│   │   ├── requirements.txt
│   │   └── .venv/         # Python virtual environment
│   └── go/                # Go implementation (recommended)
│       ├── go.mod
│       └── main.go
├── bin/                   # Compiled binaries
│   ├── sync_on_change-darwin-amd64    # macOS Intel
│   ├── sync_on_change-darwin-arm64    # macOS Apple Silicon
│   ├── sync_on_change-linux-amd64     # Linux x64
│   ├── sync_on_change-linux-arm64     # Linux ARM64
│   ├── sync_on_change-windows-amd64.exe # Windows x64
│   └── sync_on_change-freebsd-amd64   # FreeBSD x64
├── config/                # Configuration files
│   ├── sync_on_change.conf         # Main config
│   └── sync_on_change.conf.example # Example config
├── scripts/               # Build and utility scripts
│   └── build-all.sh      # Cross-platform build script
├── docs/                  # Documentation
│   └── RELEASE_NOTES.md
└── LICENSE
```

## Features

- **Cross-platform binaries** - Single binary runs on Linux, macOS, Windows, FreeBSD
- **Real-time monitoring** - Watches files/directories for changes using checksums
- **Automatic sync** - Uses `rsync` for directories, `scp` for files
- **Fallback sync** - Automatic tar+scp fallback if rsync fails
- **SSH integration** - Seamless SSH key authentication
- **Executable permissions** - Automatically sets +x on shell scripts
- **Spinner animation** - Visual feedback during monitoring
- **Graceful exit** - Clean Ctrl+C handling
- **Configuration precedence** - Multiple config file locations
- **Colored logging** - Timestamped, colored output

## Quick Start

### Using Go Binary (Recommended)

1. **Download the appropriate binary** for your platform from the `bin/` directory
2. **Make it executable** (Linux/macOS): `chmod +x sync_on_change-*`
3. **Create a config file** (optional):
   ```bash
   cp config/sync_on_change.conf.example config/sync_on_change.conf
   # Edit with your settings
   ```
4. **Run the tool**:
   ```bash
   ./bin/sync_on_change-linux-amd64 /path/to/file-or-directory
   ```

### Building from Source

#### Go Implementation (Recommended)
```bash
# Build for current platform
cd src/go
go build -o ../../bin/sync_on_change .

# Build for all platforms
./scripts/build-all.sh
```

#### Python Implementation
```bash
cd src/python
# Activate virtual environment
source .venv/bin/activate
# Install dependencies
pip install -r requirements.txt
# Build binary with PyInstaller
pyinstaller --onefile --name sync_on_change sync_on_change.py
```

## Configuration

The tool searches for configuration files in this order:
1. Explicit config file (via `-c` flag)
2. `./sync_on_change.conf` (current directory)
3. `<script-dir>/sync_on_change.conf` (same directory as binary)
4. `<target-dir>/sync_on_change.conf` (target file/directory location)
5. `/etc/sync_on_change/sync_on_change.conf` (system-wide, Linux/macOS only)

Example configuration:
```ini
remote_user="myuser"
remote_host="192.168.1.100"
remote_path="~/scripts/"
interval=3
max_failures=10
```

## Usage Examples

```bash
# Watch a single file
./sync_on_change script.sh

# Watch a directory
./sync_on_change /path/to/project/

# Use specific config file
./sync_on_change -c custom.conf /path/to/watch

# Show help
./sync_on_change -h
```

## Platform Support

| Platform | Architecture | Binary Name |
|----------|-------------|-------------|
| Linux | x86_64 | `sync_on_change-linux-amd64` |
| Linux | ARM64 | `sync_on_change-linux-arm64` |
| macOS | Intel | `sync_on_change-darwin-amd64` |
| macOS | Apple Silicon | `sync_on_change-darwin-arm64` |
| Windows | x86_64 | `sync_on_change-windows-amd64.exe` |
| FreeBSD | x86_64 | `sync_on_change-freebsd-amd64` |

## Implementation Comparison

| Feature | Bash | Python | Go |
|---------|------|--------|-----|
| Cross-compilation | ❌ | ❌ | ✅ |
| Binary size | N/A | ~25MB | ~8MB |
| Startup time | Fast | 1-2s | Instant |
| Dependencies | System tools | Python + libs | None |
| Maintenance | High | Medium | Low |
| Performance | Good | Good | Excellent |

## Development

### Go Implementation
- **Language**: Go 1.21+
- **Dependencies**: Standard library only
- **Build**: `go build`
- **Cross-compile**: `GOOS=linux GOARCH=amd64 go build`

### Python Implementation
- **Language**: Python 3.12+
- **Dependencies**: `paramiko`, `watchdog`, `pyinstaller`
- **Build**: PyInstaller
- **Limitations**: Platform-specific builds required

### Bash Implementation
- **Language**: Bash 4+
- **Dependencies**: `rsync`, `ssh`, `tar`, `scp`
- **Status**: Legacy, maintenance mode

## License

MIT License - see LICENSE file for details.
