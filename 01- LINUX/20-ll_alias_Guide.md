# `ll` Alias Guide  
A quick reference for enabling the `ll` command on Linux and macOS, with support for both Bash and Zsh.

---

## 🧭 Check Your Current Shell

Before adding the alias, confirm which shell you're using:

```bash
echo $SHELL
```

Common results:
- `/bin/bash` → Bash
- `/bin/zsh` → Zsh (default on macOS)

---

## 🐧 Linux (Bash)

Add the alias to your `~/.bashrc`:

```bash
echo "alias ll='ls -alrhS'" >> ~/.bashrc
source ~/.bashrc
```

This creates an `ll` command that lists files:
- all files (`-a`)
- long format (`-l`)
- human‑readable sizes (`-h`)
- reverse order (`-r`)
- sorted by size (`-S`)

---

## 🍏 macOS

macOS uses **Zsh by default**, but Bash is still available.  
Choose the section that matches your preferred shell.

---

### ▶️ macOS — Zsh Users

Add the alias to your `~/.zshrc`:

```bash
echo "alias ll='ls -alrhS'" >> ~/.zshrc
source ~/.zshrc
ll
```

---

### ▶️ macOS — Bash Users

macOS Terminal launches Bash as a **login shell**, which means it loads `~/.bash_profile` instead of `~/.bashrc`.

Add the alias to `~/.bash_profile`:

```bash
echo "alias ll='ls -alrhS'" >> ~/.bash_profile
source ~/.bash_profile
ll
```

---

### 🔄 Make Bash Load `.bashrc` Automatically (macOS)

If you prefer keeping aliases in `~/.bashrc`, add this snippet to `~/.bash_profile`:

```bash
if [ -f ~/.bashrc ]; then
    source ~/.bashrc
fi
```

This ensures your Bash environment behaves consistently across Linux and macOS.

---

If you want, I can help you turn this into a full README with badges, screenshots, or a more polished structure for your GitHub repo.