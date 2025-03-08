# Security Hardening for Bastion Host


1. Create Access users: 
   - Access Users in bastion host should not have root privilages
     ```bash
     sudo groupadd dev
     sudo useradd <username> -G dev
     sudo usermod <username> -G dev 
     ```
2. Limit active services and ports that run on the OS
   - services
      ```
      systemctl list-units --type=service --state=running
      ```
   - ports
      ```
      lsof -i -P -n | grep LISTEN
      ```
2. Change the default ssh port
3. sshd_config :
   ```sh
   sudo vim /etc/ssh/sshd_config
   ```
   - PermitRootLogin no
   - PasswordAuthentication no
   - ClientAliveInterval 300
   - allowGroups dev
4. Regenerate server host keys with harder algorithms
   ```bash
   ssh-keygen -t rsa -b 4096 -f ~/ssh_gcp_rsa_key -N ""
   ssh-keygen -t ed25519 -f ~/ssh_gcp_ed25519_key -N ""
   ```
5. firewall GeoIP filtering
