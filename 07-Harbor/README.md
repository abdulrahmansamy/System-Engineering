# Install Harbor

```bash
mkdir -p ~/git && cd ~/git \
&& rm -fr ~/git/System-Engineering \
&& git clone https://github.com/abdulrahmansamy/System-Engineering.git \
&& cd System-Engineering/07-Harbor/
```

```bash
chmod +x *.sh

for script in *.sh; do
   sudo bash "$script" || break
done
```

