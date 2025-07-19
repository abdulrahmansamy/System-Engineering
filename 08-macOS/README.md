# macOS System Engineering Scripts

This directory contains system engineering scripts specifically designed for macOS environments.

## Scripts Overview

### 01-delete_ds_store_files.sh

A utility script that creates a convenient alias for removing `.DS_Store` files from your system.

#### What it does:
- Creates an alias `rmDS` that finds and deletes all `.DS_Store` files in the current directory and subdirectories
- Automatically adds the alias to your shell configuration files (`.zshrc`, `.bash_profile`, `.bashrc`)
- Reloads shell configurations to make the alias immediately available
- Prevents duplicate aliases by checking if the alias already exists

#### Usage:
1. Make the script executable:
   ```bash
   chmod +x 01-delete_ds_store_files.sh
   ```

2. Run the script:
   ```bash
   ./01-delete_ds_store_files.sh
   ```

3. Use the new alias anywhere in your terminal:
   ```bash
   rmDS
   ```

#### What are .DS_Store files?
`.DS_Store` files are hidden system files created by macOS Finder to store custom attributes of folders (like icon positions, background images, etc.). They can clutter your directories, especially when sharing files with non-Mac users or committing to version control systems.

#### Features:
- ✅ Cross-shell compatibility (bash, zsh)
- ✅ Duplicate prevention
- ✅ Automatic configuration reload
- ✅ Safe file checking before modification
- ✅ User-friendly feedback messages

#### Example Output:
```
Added alias to /Users/username/.zshrc
/Users/username/.bash_profile not found — skipping
/Users/username/.bashrc not found — skipping
You're all set. Try running 'rmDS' from your terminal to wipe out those .DS_Store files!
```

## Remove Cached `.DS_Store` Files from Git

If you've already committed `.DS_Store` files to your Git repository before adding them to `.gitignore`, you'll need to remove them from Git's tracking while keeping them locally.

### Why Remove Cached Files?
- `.DS_Store` files are macOS-specific and irrelevant to other users
- They can cause merge conflicts and clutter your repository
- They should be ignored but may already be tracked by Git

### Commands:

**Remove a specific `.DS_Store` file:**
```bash
git rm --cached .DS_Store
```

**Remove all `.DS_Store` files recursively:**
```bash
find . -name .DS_Store -print0 | xargs -0 git rm --cached --ignore-unmatch
```

**Alternative recursive removal:**
```bash
git rm -r --cached **/.DS_Store
```

### Complete Workflow:
1. Add `.DS_Store` to your `.gitignore` file:
   ```bash
   echo ".DS_Store" >> .gitignore
   ```

2. Remove cached `.DS_Store` files from Git:
   ```bash
   find . -name .DS_Store -print0 | xargs -0 git rm --cached --ignore-unmatch
   ```

3. Commit the changes:
   ```bash
   git add .gitignore
   git commit -m "Remove .DS_Store files and add to .gitignore"
   ```

4. Use the `rmDS` alias (from the script above) to clean up local files:
   ```bash
   rmDS
   ```

### Pro Tips:
- Always add `.DS_Store` to your global `.gitignore` to prevent future issues
- Use `--ignore-unmatch` flag to avoid errors if files don't exist
- Consider adding other macOS-specific files like `._*` and `.Spotlight-V100` to your `.gitignore`

## Contributing

When adding new macOS system scripts to this directory, please:
1. Follow the naming convention: `##-descriptive_name.sh`
2. Include proper documentation and comments
3. Update this README with script descriptions
4. Test on multiple macOS versions when possible

## Requirements

- macOS (any recent version)
- Bash or Zsh shell
- Basic terminal access
