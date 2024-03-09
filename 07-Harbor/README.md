# Install Harbor

### 0. Install Git
```bash
sudo yum install -y git
```

### 1. Download Harbor installation scripts
```bash
mkdir -p ~/git && cd ~/git \
&& rm -fr ~/git/System-Engineering \
&& git clone https://github.com/abdulrahmansamy/System-Engineering.git \
&& cd System-Engineering/07-Harbor/
```

### 2. Set your Environment Variables
```bash
vim setup_vars.sh
```

### 3. Run the installation scripts
```bash
chmod +x *.sh

for script in *.sh; do
   sudo bash "$script" || break
done
```

