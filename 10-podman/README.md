# Podman Clean

A comprehensive Bash script for cleaning up Podman images with advanced filtering, logging, and safety features.

## Overview

`podman-clean.sh` is a powerful utility that helps you manage and clean up Podman images by repository, tag, or dangling images. It includes safety features like dry-run mode, interactive confirmations, and detailed logging.

## Features

- **Multiple cleanup modes**: Repository, tag, or dangling images
- **Dry-run mode**: Preview changes without executing deletions
- **Interactive confirmations**: Safe deletion with user prompts
- **Comprehensive logging**: Configurable log levels with optional file output
- **Shell completion**: Auto-completion support for bash and zsh
- **Size calculation**: Shows total size of images to be deleted
- **Container handling**: Automatically handles containers using dangling images

## Installation

1. Clone or download the script and its dependencies:
   ```bash
   git clone <repository>
   cd 10-podman
   ```

2. Ensure the script is executable:
   ```bash
   chmod +x podman-clean.sh
   ```

3. Install shell completion (optional):
   ```bash
   # For bash
   source <(./podman-clean.sh completion bash)
   
   # For zsh
   source <(./podman-clean.sh completion zsh)
   ```

## Dependencies

- **Podman**: The script requires Podman to be installed and accessible
- **Bash**: Requires Bash 4.0 or higher
- **Library files**: The following library files must be present in the `lib/` directory:
  - `lib/logging.sh` - Logging functionality
  - `lib/spinner.sh` - Progress indicators
  - `lib/podman-utils.sh` - Podman utility functions

## Usage

### Basic Syntax

```bash
./podman-clean.sh <subcommand> [options]
```

### Subcommands

#### Clean by Repository
```bash
./podman-clean.sh repo <REPOSITORY> [options]
```

#### Clean by Tag
```bash
./podman-clean.sh tag <TAG> [options]
```

#### Clean Dangling Images
```bash
./podman-clean.sh dangling [options]
```

#### Shell Completion
```bash
./podman-clean.sh completion [bash|zsh]
```

### Options

- `--dry-run`: Preview changes without executing deletions
- `--silent`: Reduce output to warnings and errors only
- `--verbose`: Enable detailed debug output
- `--log-file FILE`: Write logs to specified file
- `-h, --help`: Show help information

### Legacy Syntax (Deprecated)

```bash
./podman-clean.sh --repo REPOSITORY [options]
./podman-clean.sh --tag TAG [options]
```

## Examples

### Clean all images from a specific repository
```bash
# Preview deletion
./podman-clean.sh repo nginx --dry-run

# Actually delete (with confirmation)
./podman-clean.sh repo nginx

# Delete with verbose logging
./podman-clean.sh repo nginx --verbose --log-file cleanup.log
```

### Clean images by tag
```bash
# Clean all images with 'latest' tag
./podman-clean.sh tag latest

# Clean with dry-run and silent mode
./podman-clean.sh tag v1.0 --dry-run --silent
```

### Clean dangling images
```bash
# Clean dangling images (most common use case)
./podman-clean.sh dangling

# Preview dangling cleanup with verbose output
./podman-clean.sh dangling --dry-run --verbose
```

### Advanced usage with logging
```bash
# Clean with comprehensive logging
./podman-clean.sh repo myapp --verbose --log-file /var/log/podman-clean.log

# Silent cleanup (only errors shown)
./podman-clean.sh dangling --silent
```

## Exit Codes

The script uses specific exit codes to indicate different outcomes:

- `0`: Success - Images were deleted successfully
- `1`: No images found - No images matched the specified criteria
- `2`: User aborted - User chose not to proceed with deletion
- `3`: Deletion failed - An error occurred during the deletion process

## Safety Features

### Dry Run Mode
Use `--dry-run` to preview what would be deleted without actually removing anything:
```bash
./podman-clean.sh repo nginx --dry-run
```

### Interactive Confirmation
The script always asks for confirmation before deleting images (unless in dry-run mode).

### Container Handling
When cleaning dangling images, the script:
1. Identifies containers using dangling images
2. Provides options to stop/remove conflicting containers
3. Ensures safe cleanup without breaking running services

## Logging

### Log Levels
- **Silent** (`--silent`): Only warnings and errors
- **Normal** (default): Standard informational messages
- **Verbose** (`--verbose`): Detailed debug information

### Log File Output
Optionally write logs to a file while maintaining console output:
```bash
./podman-clean.sh dangling --log-file cleanup-$(date +%Y%m%d).log
```

## Troubleshooting

### Common Issues

1. **Permission denied**: Ensure you have proper Podman permissions
   ```bash
   # Check Podman access
   podman images
   ```

2. **Library files not found**: Ensure lib/ directory exists with required files
   ```bash
   ls -la lib/
   ```

3. **No images found**: Verify the repository/tag names are correct
   ```bash
   podman images | grep <repository-or-tag>
   ```

### Debug Mode
Use verbose logging to troubleshoot issues:
```bash
./podman-clean.sh dangling --verbose --log-file debug.log
```

## Contributing

When contributing to this script:
1. Follow the existing code style
2. Update this README for new features
3. Test with various Podman image configurations
4. Ensure compatibility with both bash and zsh completion

## License

Licensed under the Apache License, Version 2.0 (the "License");
you may not use this file except in compliance with the License.
You may obtain a copy of the License at

    http://www.apache.org/licenses/LICENSE-2.0

Unless required by applicable law or agreed to in writing, software
distributed under the License is distributed on an "AS IS" BASIS,
WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
See the License for the specific language governing permissions and
limitations under the License.
