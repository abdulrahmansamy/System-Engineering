# Git Reference Guide

## Variables
Replace the following variables with your actual values:
- `<username>`: Your GitHub username
- `<repo_name>`: Your repository name

## Repository Setup

### Clone an existing repository
```bash
git clone https://github.com/<username>/<repo_name>.git
```

### Initialize a new repository and connect to remote
```bash
git init
git remote add origin https://github.com/<username>/<repo_name>.git
git branch -M main
git add .
git commit -m "Initial commit"
git push -u origin main
```

## Basic Operations

### Check repository status
```bash
git status
```

### Add files to staging area
```bash
git add .                    # Add all files
git add filename.txt         # Add specific file
git add *.js                 # Add files by pattern
```

### Commit changes
```bash
git commit -m "Commit message"
git commit -am "Add and commit in one step"
```

### Push and pull changes
```bash
git push origin main         # Push to remote
git pull origin main         # Pull from remote
git fetch                    # Fetch without merging
```

## Branching

### Branch operations
```bash
git branch                   # List branches
git branch feature-name      # Create new branch
git checkout feature-name    # Switch to branch
git checkout -b feature-name # Create and switch to branch
git branch -d feature-name   # Delete branch
```

### Merge branches
```bash
git checkout main
git merge feature-name
```

## Viewing History

### View commit history
```bash
git log                      # Full log
git log --oneline           # Condensed log
git log --graph             # Visual graph
```

### View changes
```bash
git diff                     # Unstaged changes
git diff --staged           # Staged changes
git show commit-hash        # Show specific commit
```

## Undoing Changes

### Unstage files
```bash
git reset filename.txt       # Unstage specific file
git reset                   # Unstage all files
```

### Revert commits
```bash
git revert commit-hash      # Create new commit that undoes changes
git reset --soft HEAD~1     # Undo last commit, keep changes staged
git reset --hard HEAD~1     # Undo last commit and all changes
```

## Remote Operations

### Manage remotes
```bash
git remote -v               # List remotes
git remote add name url     # Add remote
git remote remove name      # Remove remote
```

## Troubleshooting

### Remove cached files after adding to .gitignore
```bash
git rm --cached .DS_Store           # Remove specific file
git rm -r --cached directory/      # Remove directory
git rm --cached -r .               # Remove all cached files
```

### Reset to remote state
```bash
git fetch origin
git reset --hard origin/main
```

### Stash changes temporarily
```bash
git stash                   # Stash current changes
git stash pop              # Apply and remove latest stash
git stash list             # List all stashes
```

## Configuration

### Set up user information
```bash
git config --global user.name "Your Name"
git config --global user.email "your.email@example.com"
```

### Useful aliases
```bash
git config --global alias.st status
git config --global alias.co checkout
git config --global alias.br branch
git config --global alias.cm commit
```