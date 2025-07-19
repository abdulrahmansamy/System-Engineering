#!/bin/bash

ALIAS_CMD="alias rmDS='find . -name \".DS_Store\" -print -delete'"
FILES=("$HOME/.zshrc" "$HOME/.bash_profile" "$HOME/.bashrc")

for FILE in "${FILES[@]}"; do
    if [ -f "$FILE" ]; then
        if ! grep -Fxq "$ALIAS_CMD" "$FILE"; then
            echo "$ALIAS_CMD" >> "$FILE"
            echo "Added alias to $FILE"
        else
            echo "️Alias already exists in $FILE"
        fi
    else
        echo "$FILE not found — skipping"
    fi
done

# Reload shell configs if they exist
[ -f "$HOME/.zshrc" ] && source "$HOME/.zshrc" 2>/dev/null
[ -f "$HOME/.bash_profile" ] && source "$HOME/.bash_profile" 2>/dev/null
[ -f "$HOME/.bashrc" ] && source "$HOME/.bashrc" 2>/dev/null

echo "You're all set. Try running 'rmDS' from your terminal to wipe out those .DS_Store files!"
