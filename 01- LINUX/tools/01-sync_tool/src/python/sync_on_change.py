"""
sync_on_change.py - File and Directory Synchronization Tool in Python

A Python rewrite of the sync_on_change Bash script, designed for cross-platform
compilation into a single binary using PyInstaller.

Copyright (c) 2025 Abdulrahman Samy
Licensed under the MIT License. See LICENSE file for details.
Repository: https://github.com/abdulrahmansamy/system_engineering
"""

import argparse
import hashlib
import os
import platform
import shlex
import signal
import subprocess
import sys
import time
from pathlib import Path

# --- Color Codes & Logging ---
class Colors:
    """ANSI color codes"""
    RED = '\033[0;31m'
    GREEN = '\033[0;32m'
    YELLOW = '\033[1;33m'
    BLUE = '\033[0;34m'
    NC = '\033[0m'

def get_timestamp():
    """Returns a formatted timestamp."""
    return time.strftime('%Y-%m-%d %H:%M:%S')

def log(message):
    """Log a success message."""
    print(f"{Colors.GREEN}[{get_timestamp()}] [+]{Colors.NC} {message}")

def warn(message):
    """Log a warning message to stderr."""
    print(f"{Colors.YELLOW}[{get_timestamp()}] [!]{Colors.NC} {message}", file=sys.stderr)

def die(message):
    """Log an error message to stderr and exit."""
    print(f"{Colors.RED}[{get_timestamp()}] [x]{Colors.NC} {message}", file=sys.stderr)
    sys.exit(1)

def info(message):
    """Log an informational message."""
    print(f"{Colors.BLUE}[{get_timestamp()}] [i]{Colors.NC} {message}")

# --- Configuration ---
DEFAULTS = {
    "remote_user": "username",
    "remote_host": "xxx.xxx.xxx.xxx",
    "remote_path": "~/scripts/",
    "interval": 3,
    "max_failures": 10,
}

def parse_config(file_path):
    """Parses a simple key="value" config file."""
    config = {}
    try:
        with open(file_path, 'r') as f:
            for line in f:
                line = line.strip()
                if not line or line.startswith('#'):
                    continue
                try:
                    key, value = line.split('=', 1)
                    key = key.strip()
                    value = shlex.split(value)[0] # Handles quoted values
                    config[key] = value
                except ValueError:
                    warn(f"Skipping malformed line in {file_path}: {line}")
    except FileNotFoundError:
        return {}
    return config

def load_config(target_path, explicit_config_path=None):
    """Loads configuration with the specified precedence."""
    config = DEFAULTS.copy()
    config_loaded_from = "Script's Defaults"

    script_dir = Path(__file__).parent.resolve()
    
    # Note: target_path might not exist on first run, handle gracefully.
    target_dir = Path(target_path).parent.resolve() if Path(target_path).exists() else None

    search_paths = []
    if explicit_config_path:
        if not Path(explicit_config_path).is_file():
            die(f"Explicit config file not found: {explicit_config_path}")
        search_paths = [Path(explicit_config_path)]
    else:
        search_paths = [
            Path.cwd() / "sync_on_change.conf",
            script_dir / "sync_on_change.conf",
        ]
        if target_dir:
            search_paths.append(target_dir / "sync_on_change.conf")
        
        if platform.system() != "Windows":
             search_paths.append(Path("/etc/sync_on_change/sync_on_change.conf"))

    for path in search_paths:
        if path.is_file():
            info(f"Loading configuration from: {path}")
            config.update(parse_config(path))
            config_loaded_from = str(path)
            break # First one found wins

    # Apply integer conversion for specific keys
    try:
        config["interval"] = int(config["interval"])
        config["max_failures"] = int(config["max_failures"])
    except (ValueError, TypeError):
        die("Config values 'interval' and 'max_failures' must be integers.")

    info(f"Configuration loaded from: {config_loaded_from}")
    return config

# --- Core Logic ---
def calculate_checksum(path: Path):
    """Calculates the SHA-256 checksum for a file or directory."""
    if not path.exists():
        return None

    if path.is_file():
        sha256 = hashlib.sha256()
        try:
            with open(path, 'rb') as f:
                while chunk := f.read(8192):
                    sha256.update(chunk)
            return sha256.hexdigest()
        except IOError:
            return None

    if path.is_dir():
        # Combine hashes of all files in the directory
        dir_hash = hashlib.sha256()
        files = sorted(p for p in path.rglob('*') if p.is_file())
        for file_path in files:
            file_hash = calculate_checksum(file_path)
            if file_hash:
                dir_hash.update(file_hash.encode())
        return dir_hash.hexdigest()
    
    return None

def run_command(command, show_output=False, stdin_input=None):
    """Runs a shell command and returns its success status."""
    try:
        result = subprocess.run(
            command,
            shell=True,
            check=True,
            capture_output=not show_output,
            text=True,
            input=stdin_input
        )
        if not show_output and result.stdout:
            print(result.stdout)
        if not show_output and result.stderr:
            print(result.stderr, file=sys.stderr)
        return True
    except subprocess.CalledProcessError as e:
        if not show_output:
            warn(f"Command failed: {command}")
            if e.stdout:
                print(e.stdout, file=sys.stderr)
            if e.stderr:
                print(e.stderr, file=sys.stderr)
        return False

def ssh_setup(config):
    """Checks SSH connection and ensures remote directory exists."""
    info("Checking SSH connection...")
    remote = f"{config['remote_user']}@{config['remote_host']}"
    ssh_check_cmd = f"ssh -o BatchMode=yes -o ConnectTimeout=5 {remote} 'echo ok'"
    
    try:
        result = subprocess.run(ssh_check_cmd, shell=True, check=True, capture_output=True, text=True)
        if "ok" not in result.stdout:
            raise subprocess.CalledProcessError(1, ssh_check_cmd)
        info("SSH key authentication is already set up.")
    except subprocess.CalledProcessError:
        warn(f"SSH key authentication may not be set up for {remote}.")
        info("Please run the following command in your terminal to set it up:")
        print(f"  ssh-copy-id {remote}")

    info(f"Ensuring remote directory exists: {config['remote_path']}")
    mkdir_cmd = f"ssh {remote} 'mkdir -p {config['remote_path']}'"
    if not run_command(mkdir_cmd):
        die("Failed to create remote directory.")

def sync_target(target_path: Path, config: dict):
    """Syncs the target file or directory to the remote host."""
    remote_user = config['remote_user']
    remote_host = config['remote_host']
    remote_path_str = config['remote_path']
    remote_base = f"{remote_user}@{remote_host}"
    
    if target_path.is_file():
        # --- File Sync ---
        scp_cmd = f"scp {shlex.quote(str(target_path))} {remote_base}:{shlex.quote(remote_path_str)}"
        if run_command(scp_cmd):
            log("✅ File synced successfully")
            chmod_cmd = f"ssh {remote_base} 'chmod +x {remote_path_str}/{target_path.name}'"
            if run_command(chmod_cmd):
                log("🔐 Remote executable permission set successfully")
                return True
        return False
    
    elif target_path.is_dir():
        # --- Directory Sync ---
        # Ensure remote path ends with a slash for rsync
        rsync_remote_path = remote_path_str
        if not rsync_remote_path.endswith('/'):
            rsync_remote_path += '/'
            
        rsync_cmd = f"rsync -avz --delete {shlex.quote(str(target_path) + '/')} {remote_base}:{shlex.quote(rsync_remote_path)}"
        if run_command(rsync_cmd):
            log("✅ Directory synced successfully (rsync)")
            # Pass the command via stdin to avoid complex quoting issues with ssh
            chmod_script = f"find {remote_path_str} -name '*.sh' -exec chmod +x {{}} +"
            chmod_cmd = f"ssh {remote_base} bash"
            if run_command(chmod_cmd, stdin_input=chmod_script):
                log("🔐 Remote executable permissions set for shell scripts")
            else:
                warn("Failed to set remote executable permissions.")
            return True
        else:
            warn("rsync failed, trying tar+scp fallback...")
            # Fallback to tar + scp
            archive_name = f"sync_{target_path.name}_{int(time.time())}.tar.gz"
            local_archive = Path("/tmp") / archive_name
            
            tar_cmd = f"tar -czf {shlex.quote(str(local_archive))} -C {shlex.quote(str(target_path.parent))} {shlex.quote(target_path.name)}"
            if not run_command(tar_cmd):
                warn("❌ Archive creation failed.")
                return False

            scp_cmd = f"scp {shlex.quote(str(local_archive))} {remote_base}:/tmp/"
            if not run_command(scp_cmd):
                warn("❌ Archive transfer failed.")
                os.remove(local_archive)
                return False

            extract_cmd = f"""
            ssh {remote_base} '
                cd {shlex.quote(remote_path_str)} &&
                rm -rf {shlex.quote(target_path.name)} &&
                tar -xzf /tmp/{archive_name} &&
                rm -f /tmp/{archive_name} &&
                find . -name "*.sh" -exec chmod +x {{}} +
            '
            """
            if run_command(extract_cmd):
                log("✅ Directory synced successfully (tar+scp)")
                os.remove(local_archive)
                return True
            else:
                warn("❌ Remote extraction failed.")
                os.remove(local_archive)
                return False
    return False

def main():
    """Main script entry point."""
    parser = argparse.ArgumentParser(
        description="A Python tool to watch a file or directory and sync changes to a remote host.",
        formatter_class=argparse.RawTextHelpFormatter
    )
    parser.add_argument("target", help="Local file or directory to watch.")
    parser.add_argument("-c", "--config", help="Explicit config file path.", dest="config_path")
    parser.add_argument("-v", "--verbose", action="store_true", help="Enable verbose output.")
    
    args = parser.parse_args()

    target_path = Path(args.target)
    if not target_path.exists():
        die(f"Target not found: {target_path}")

    config = load_config(target_path, args.config_path)
    
    info(f"Watching {'directory' if target_path.is_dir() else 'file'}: {target_path}")
    info(f"Remote: {config['remote_user']}@{config['remote_host']}:{config['remote_path']}")
    info(f"Interval: {config['interval']}s | Max failures: {config['max_failures']}")

    ssh_setup(config)

    fail_count = 0
    last_checksum = None

    # --- Initial Sync ---
    info("Performing initial sync...")
    current_checksum = calculate_checksum(target_path)
    if sync_target(target_path, config):
        last_checksum = current_checksum
    else:
        die("Initial sync failed. Exiting.")

    # --- Main Loop ---
    spinner_chars = ['|', '/', '-', '\\']
    spinner_index = 0
    
    while True:
        # Check for changes
        current_checksum = calculate_checksum(target_path)
        if current_checksum != last_checksum:
            print() # Newline to move off the spinner line
            info("Change detected. Syncing...")
            if sync_target(target_path, config):
                last_checksum = current_checksum
                fail_count = 0
            else:
                fail_count += 1
                warn(f"Sync failed (failures: {fail_count}/{config['max_failures']})")
                if fail_count >= config['max_failures']:
                    die("Too many consecutive failures. Exiting.")
        
        # Animate spinner for the duration of the interval
        animation_sleep = 0.2 # seconds per frame
        for _ in range(int(config["interval"] / animation_sleep)):
            if not target_path.exists():
                warn(f"Target not found: {target_path}")
                break # Exit inner loop to re-evaluate in outer loop
            
            spinner_char = spinner_chars[spinner_index]
            print(f"\r[{get_timestamp()}] [{spinner_char}] Monitoring changes...", end="")
            spinner_index = (spinner_index + 1) % len(spinner_chars)
            time.sleep(animation_sleep)

def signal_handler(sig, frame):
    """Handle SIGINT (Ctrl+C) gracefully."""
    print("\nExiting.")
    os._exit(0)

if __name__ == "__main__":
    # Set up signal handler for clean exit
    signal.signal(signal.SIGINT, signal_handler)
    main()
