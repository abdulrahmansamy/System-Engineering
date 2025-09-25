package main

import (
	"os"
	"path/filepath"
	"testing"
)

func TestParseConfig(t *testing.T) {
	// Create a temporary config file
	tmpDir := t.TempDir()
	configFile := filepath.Join(tmpDir, "test.conf")

	configContent := `remote_user=testuser
remote_host=server.example.com
remote_path=/remote/path
interval=5
max_failures=15`

	err := os.WriteFile(configFile, []byte(configContent), 0644)
	if err != nil {
		t.Fatalf("Failed to create test config file: %v", err)
	}

	config, err := parseConfig(configFile)
	if err != nil {
		t.Fatalf("Failed to parse config: %v", err)
	}

	// Test config values
	if config.RemoteUser != "testuser" {
		t.Errorf("Expected RemoteUser = testuser, got %s", config.RemoteUser)
	}
	if config.RemoteHost != "server.example.com" {
		t.Errorf("Expected RemoteHost = server.example.com, got %s", config.RemoteHost)
	}
	if config.RemotePath != "/remote/path" {
		t.Errorf("Expected RemotePath = /remote/path, got %s", config.RemotePath)
	}
	if config.Interval != 5 {
		t.Errorf("Expected Interval = 5, got %d", config.Interval)
	}
	if config.MaxFailures != 15 {
		t.Errorf("Expected MaxFailures = 15, got %d", config.MaxFailures)
	}
}

func TestCalculateChecksum(t *testing.T) {
	// Create a temporary file
	tmpDir := t.TempDir()
	testFile := filepath.Join(tmpDir, "test.txt")

	content := "Hello, World!"
	err := os.WriteFile(testFile, []byte(content), 0644)
	if err != nil {
		t.Fatalf("Failed to create test file: %v", err)
	}

	checksum1, err := calculateChecksum(testFile)
	if err != nil {
		t.Fatalf("Failed to calculate checksum: %v", err)
	}

	// Calculate again - should be the same
	checksum2, err := calculateChecksum(testFile)
	if err != nil {
		t.Fatalf("Failed to calculate checksum: %v", err)
	}

	if checksum1 != checksum2 {
		t.Errorf("Checksums should be identical: %s != %s", checksum1, checksum2)
	}

	// Modify file and check checksum changes
	err = os.WriteFile(testFile, []byte("Modified content"), 0644)
	if err != nil {
		t.Fatalf("Failed to modify test file: %v", err)
	}

	checksum3, err := calculateChecksum(testFile)
	if err != nil {
		t.Fatalf("Failed to calculate checksum: %v", err)
	}

	if checksum1 == checksum3 {
		t.Error("Checksums should be different after file modification")
	}
}

func TestDefaultConfig(t *testing.T) {
	config := defaultConfig()

	// Test default values
	if config.RemoteUser != "username" {
		t.Errorf("Expected default RemoteUser = username, got %s", config.RemoteUser)
	}
	if config.RemoteHost != "xxx.xxx.xxx.xxx" {
		t.Errorf("Expected default RemoteHost = xxx.xxx.xxx.xxx, got %s", config.RemoteHost)
	}
	if config.RemotePath != "~/scripts/" {
		t.Errorf("Expected default RemotePath = ~/scripts/, got %s", config.RemotePath)
	}
	if config.Interval != 3 {
		t.Errorf("Expected default Interval = 3, got %d", config.Interval)
	}
	if config.MaxFailures != 10 {
		t.Errorf("Expected default MaxFailures = 10, got %d", config.MaxFailures)
	}
}

func TestConfigParsing(t *testing.T) {
	// Test config parsing with comments and empty lines
	tmpDir := t.TempDir()
	configFile := filepath.Join(tmpDir, "test.conf")

	configContent := `# This is a comment
remote_user=testuser
# Another comment

remote_host=server.example.com
remote_path="/home/user/scripts"
interval=7
max_failures=20
`

	err := os.WriteFile(configFile, []byte(configContent), 0644)
	if err != nil {
		t.Fatalf("Failed to create test config file: %v", err)
	}

	config, err := parseConfig(configFile)
	if err != nil {
		t.Fatalf("Failed to parse config: %v", err)
	}

	// Test that quoted values are handled correctly
	if config.RemotePath != "/home/user/scripts" {
		t.Errorf("Expected RemotePath = /home/user/scripts, got %s", config.RemotePath)
	}

	// Test that numeric values are parsed correctly
	if config.Interval != 7 {
		t.Errorf("Expected Interval = 7, got %d", config.Interval)
	}

	if config.MaxFailures != 20 {
		t.Errorf("Expected MaxFailures = 20, got %d", config.MaxFailures)
	}
}

func TestHashFile(t *testing.T) {
	// Create a temporary file with known content
	tmpDir := t.TempDir()
	testFile := filepath.Join(tmpDir, "test.txt")

	content := "Hello, World!"
	err := os.WriteFile(testFile, []byte(content), 0644)
	if err != nil {
		t.Fatalf("Failed to create test file: %v", err)
	}

	hash1, err := hashFile(testFile)
	if err != nil {
		t.Fatalf("Failed to hash file: %v", err)
	}

	// Hash the same file again - should be identical
	hash2, err := hashFile(testFile)
	if err != nil {
		t.Fatalf("Failed to hash file: %v", err)
	}

	if hash1 != hash2 {
		t.Errorf("Hashes should be identical: %s != %s", hash1, hash2)
	}

	// Verify hash is not empty
	if hash1 == "" {
		t.Error("Hash should not be empty")
	}
}
