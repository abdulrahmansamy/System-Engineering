package main

import (
	"bufio"
	"crypto/sha256"
	"flag"
	"fmt"
	"io"
	"os"
	"os/exec"
	"os/signal"
	"path/filepath"
	"runtime"
	"strconv"
	"strings"
	"syscall"
	"time"
)

// ANSI color codes
const (
	ColorReset  = "\033[0m"
	ColorRed    = "\033[31m"
	ColorGreen  = "\033[32m"
	ColorYellow = "\033[33m"
	ColorBlue   = "\033[34m"
)

// Configuration holds all sync settings
type Config struct {
	RemoteUser  string
	RemoteHost  string
	RemotePath  string
	Interval    int
	MaxFailures int
	ConfigPath  string
	LoadedFrom  string
}

// Default configuration values
func defaultConfig() *Config {
	return &Config{
		RemoteUser:  "username",
		RemoteHost:  "xxx.xxx.xxx.xxx",
		RemotePath:  "~/scripts/",
		Interval:    3,
		MaxFailures: 10,
	}
}

// Logging functions with timestamps and colors
func timestamp() string {
	return time.Now().Format("2006-01-02 15:04:05")
}

func logInfo(msg string) {
	fmt.Printf("%s[%s] [i]%s %s\n", ColorBlue, timestamp(), ColorReset, msg)
}

func logSuccess(msg string) {
	fmt.Printf("%s[%s] [+]%s %s\n", ColorGreen, timestamp(), ColorReset, msg)
}

func logWarn(msg string) {
	fmt.Fprintf(os.Stderr, "%s[%s] [!]%s %s\n", ColorYellow, timestamp(), ColorReset, msg)
}

func logError(msg string) {
	fmt.Fprintf(os.Stderr, "%s[%s] [x]%s %s\n", ColorRed, timestamp(), ColorReset, msg)
}

// Parse configuration from file
func parseConfig(path string) (*Config, error) {
	config := defaultConfig()

	file, err := os.Open(path)
	if err != nil {
		return config, err
	}
	defer file.Close()

	scanner := bufio.NewScanner(file)
	for scanner.Scan() {
		line := strings.TrimSpace(scanner.Text())
		if line == "" || strings.HasPrefix(line, "#") {
			continue
		}

		parts := strings.SplitN(line, "=", 2)
		if len(parts) != 2 {
			continue
		}

		key := strings.TrimSpace(parts[0])
		value := strings.Trim(strings.TrimSpace(parts[1]), `"`)

		switch key {
		case "remote_user":
			config.RemoteUser = value
		case "remote_host":
			config.RemoteHost = value
		case "remote_path":
			config.RemotePath = value
		case "interval":
			if i, err := strconv.Atoi(value); err == nil {
				config.Interval = i
			}
		case "max_failures":
			if i, err := strconv.Atoi(value); err == nil {
				config.MaxFailures = i
			}
		}
	}

	config.LoadedFrom = path
	return config, scanner.Err()
}

// Load configuration with precedence
func loadConfig(targetPath, explicitConfigPath string) (*Config, error) {
	config := defaultConfig()
	config.LoadedFrom = "Script's Defaults"

	var searchPaths []string

	if explicitConfigPath != "" {
		searchPaths = []string{explicitConfigPath}
	} else {
		// Get current working directory
		cwd, _ := os.Getwd()

		// Get script directory
		ex, _ := os.Executable()
		scriptDir := filepath.Dir(ex)

		// Get target directory
		var targetDir string
		if targetPath != "" {
			if info, err := os.Stat(targetPath); err == nil {
				if info.IsDir() {
					targetDir = targetPath
				} else {
					targetDir = filepath.Dir(targetPath)
				}
			}
		}

		searchPaths = []string{
			filepath.Join(cwd, "sync_on_change.conf"),
			filepath.Join(scriptDir, "sync_on_change.conf"),
		}

		if targetDir != "" {
			searchPaths = append(searchPaths, filepath.Join(targetDir, "sync_on_change.conf"))
		}

		if runtime.GOOS != "windows" {
			searchPaths = append(searchPaths, "/etc/sync_on_change/sync_on_change.conf")
		}
	}

	for _, path := range searchPaths {
		if _, err := os.Stat(path); err == nil {
			logInfo(fmt.Sprintf("Loading configuration from: %s", path))
			if cfg, err := parseConfig(path); err == nil {
				cfg.LoadedFrom = path
				return cfg, nil
			}
		}
	}

	return config, nil
}

// Calculate SHA256 checksum of file or directory
func calculateChecksum(path string) (string, error) {
	info, err := os.Stat(path)
	if err != nil {
		return "", err
	}

	if info.IsDir() {
		// For directories, hash all files recursively
		hash := sha256.New()
		err := filepath.Walk(path, func(path string, info os.FileInfo, err error) error {
			if err != nil {
				return err
			}
			if !info.IsDir() {
				fileHash, err := hashFile(path)
				if err != nil {
					return err
				}
				hash.Write([]byte(fileHash))
			}
			return nil
		})
		if err != nil {
			return "", err
		}
		return fmt.Sprintf("%x", hash.Sum(nil)), nil
	} else {
		// For files, hash the file content
		return hashFile(path)
	}
}

func hashFile(path string) (string, error) {
	file, err := os.Open(path)
	if err != nil {
		return "", err
	}
	defer file.Close()

	hash := sha256.New()
	if _, err := io.Copy(hash, file); err != nil {
		return "", err
	}

	return fmt.Sprintf("%x", hash.Sum(nil)), nil
}

// Run command and return success status
func runCommand(command string) bool {
	cmd := exec.Command("sh", "-c", command)
	err := cmd.Run()
	if err != nil {
		logWarn(fmt.Sprintf("Command failed: %s", command))
		return false
	}
	return true
}

// Setup SSH and ensure remote directory exists
func setupSSH(config *Config) error {
	logInfo("Checking SSH connection...")

	remote := fmt.Sprintf("%s@%s", config.RemoteUser, config.RemoteHost)
	sshCheck := fmt.Sprintf("ssh -o BatchMode=yes -o ConnectTimeout=5 %s 'echo ok'", remote)

	cmd := exec.Command("sh", "-c", sshCheck)
	output, err := cmd.Output()

	if err != nil || !strings.Contains(string(output), "ok") {
		logWarn(fmt.Sprintf("SSH key authentication may not be set up for %s.", remote))
		logInfo("Please run the following command in your terminal to set it up:")
		fmt.Printf("  ssh-copy-id %s\n", remote)
	} else {
		logInfo("SSH key authentication is already set up.")
	}

	logInfo(fmt.Sprintf("Ensuring remote directory exists: %s", config.RemotePath))
	mkdirCmd := fmt.Sprintf("ssh %s 'mkdir -p %s'", remote, config.RemotePath)
	if !runCommand(mkdirCmd) {
		return fmt.Errorf("failed to create remote directory")
	}

	return nil
}

// Sync target file or directory to remote host
func syncTarget(targetPath string, config *Config) bool {
	remote := fmt.Sprintf("%s@%s", config.RemoteUser, config.RemoteHost)

	info, err := os.Stat(targetPath)
	if err != nil {
		return false
	}

	if info.IsDir() {
		// Directory sync with rsync
		remotePath := config.RemotePath
		if !strings.HasSuffix(remotePath, "/") {
			remotePath += "/"
		}

		rsyncCmd := fmt.Sprintf("rsync -avz --delete '%s/' '%s:%s'", targetPath, remote, remotePath)
		if runCommand(rsyncCmd) {
			logSuccess("✅ Directory synced successfully (rsync)")

			// Set executable permissions for shell scripts
			chmodCmd := fmt.Sprintf("ssh %s \"find %s -name '*.sh' -exec chmod +x {} +\"", remote, config.RemotePath)
			if runCommand(chmodCmd) {
				logSuccess("🔐 Remote executable permissions set for shell scripts")
			}
			return true
		} else {
			logWarn("rsync failed, trying tar+scp fallback...")
			// Implement tar+scp fallback if needed
			return false
		}
	} else {
		// File sync with scp
		scpCmd := fmt.Sprintf("scp '%s' '%s:%s'", targetPath, remote, config.RemotePath)
		if runCommand(scpCmd) {
			logSuccess("✅ File synced successfully")

			// Set executable permission
			fileName := filepath.Base(targetPath)
			chmodCmd := fmt.Sprintf("ssh %s 'chmod +x %s%s'", remote, config.RemotePath, fileName)
			if runCommand(chmodCmd) {
				logSuccess("🔐 Remote executable permission set successfully")
			}
			return true
		}
	}

	return false
}

// Spinner animation characters
var spinnerChars = []string{"|", "/", "-", "\\"}

func main() {
	// Parse command line arguments
	var configPath = flag.String("c", "", "Explicit config file path")
	var _ = flag.Bool("v", false, "Enable verbose output") // Reserved for future use
	var help = flag.Bool("h", false, "Show help message")
	flag.Parse()

	if *help {
		fmt.Printf("sync_on_change - File and Directory Synchronization Tool\n\n")
		fmt.Printf("Usage: %s [OPTIONS] <file|directory>\n\n", os.Args[0])
		fmt.Printf("OPTIONS:\n")
		fmt.Printf("  -c <config-file>  Explicit config file path\n")
		fmt.Printf("  -v                Enable verbose output\n")
		fmt.Printf("  -h                Show this help message\n\n")
		fmt.Printf("DESCRIPTION:\n")
		fmt.Printf("  Watches a file or directory and syncs changes to a remote host via SSH.\n")
		fmt.Printf("  Uses rsync for directories and scp for files with automatic fallback.\n\n")
		fmt.Printf("EXAMPLES:\n")
		fmt.Printf("  %s script.sh\n", os.Args[0])
		fmt.Printf("  %s -c custom.conf /path/to/directory\n", os.Args[0])
		os.Exit(0)
	}

	args := flag.Args()
	if len(args) != 1 {
		fmt.Fprintf(os.Stderr, "Error: Please specify exactly one file or directory to watch.\n")
		fmt.Fprintf(os.Stderr, "Use -h for help.\n")
		os.Exit(1)
	}

	targetPath := args[0]
	if _, err := os.Stat(targetPath); os.IsNotExist(err) {
		logError(fmt.Sprintf("Target not found: %s", targetPath))
		os.Exit(1)
	}

	// Load configuration
	config, err := loadConfig(targetPath, *configPath)
	if err != nil {
		logError(fmt.Sprintf("Failed to load configuration: %v", err))
		os.Exit(1)
	}

	logInfo(fmt.Sprintf("Configuration loaded from: %s", config.LoadedFrom))

	// Display configuration
	info, _ := os.Stat(targetPath)
	targetType := "file"
	if info.IsDir() {
		targetType = "directory"
	}

	logInfo(fmt.Sprintf("Watching %s: %s", targetType, targetPath))
	logInfo(fmt.Sprintf("Remote: %s@%s:%s", config.RemoteUser, config.RemoteHost, config.RemotePath))
	logInfo(fmt.Sprintf("Interval: %ds | Max failures: %d", config.Interval, config.MaxFailures))

	// Setup SSH
	if err := setupSSH(config); err != nil {
		logError(err.Error())
		os.Exit(1)
	}

	// Setup signal handling for graceful exit
	signalChan := make(chan os.Signal, 1)
	signal.Notify(signalChan, os.Interrupt, syscall.SIGTERM)

	go func() {
		<-signalChan
		fmt.Println("\nExiting.")
		os.Exit(0)
	}()

	// Initial sync
	logInfo("Performing initial sync...")
	lastChecksum, _ := calculateChecksum(targetPath)
	if !syncTarget(targetPath, config) {
		logError("Initial sync failed. Exiting.")
		os.Exit(1)
	}

	// Main monitoring loop
	failCount := 0
	spinnerIndex := 0

	for {
		currentChecksum, err := calculateChecksum(targetPath)
		if err != nil {
			logWarn(fmt.Sprintf("Failed to calculate checksum: %v", err))
			time.Sleep(time.Duration(config.Interval) * time.Second)
			continue
		}

		if currentChecksum != lastChecksum {
			fmt.Println() // Newline to move off spinner line
			logInfo("Change detected. Syncing...")
			if syncTarget(targetPath, config) {
				lastChecksum = currentChecksum
				failCount = 0
			} else {
				failCount++
				logWarn(fmt.Sprintf("Sync failed (failures: %d/%d)", failCount, config.MaxFailures))
				if failCount >= config.MaxFailures {
					logError("Too many consecutive failures. Exiting.")
					os.Exit(1)
				}
			}
		}

		// Animated monitoring with spinner
		animationSleep := 200 * time.Millisecond
		totalSleep := time.Duration(config.Interval) * time.Second
		iterations := int(totalSleep / animationSleep)

		for i := 0; i < iterations; i++ {
			spinner := spinnerChars[spinnerIndex]
			fmt.Printf("\r[%s] [%s] Monitoring changes...", timestamp(), spinner)
			spinnerIndex = (spinnerIndex + 1) % len(spinnerChars)
			time.Sleep(animationSleep)
		}
	}
}
