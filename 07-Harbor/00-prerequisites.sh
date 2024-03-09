#!/bin/bash -e

source setup_vars.sh

# 00-prerequisites.sh

echo
echo -e "$Yellow[Stage 00]: Preparing the prerequisites$NOCOLOR"
echo -e "$Yellow=======================================$NOCOLOR"

echo
echo -e "$Light_Yellow[Stage 00.1]: Updating the package repos$NOCOLOR"
echo -e "$Light_Yellow----------------------------------------$NOCOLOR"
sudo dnf -yv update
sudo dnf install -y openssl

#echo
#echo -e "$Light_YellowInstalling python package system$NOCOLOR"
#echo -e "$Light_Yellow================================$NOCOLOR"
# sudo dnf install --assumeyes python3-pip

#echo
#echo -e "$Light_YellowThe pip version is:$NOCOLOR"
#echo -e "$Light_Yellow===================$NOCOLOR"
# pip3 --version


#echo
#echo -e "$Light_YellowRemoving podman$NOCOLOR"
#echo -e "$Light_Yellow=================$NOCOLOR"
#sudo dnf -y install podman
#sudo dnf -y remove podman


#echo
#echo -e "$Light_YellowUninstalling podman-compose$NOCOLOR"
#echo -e "$Light_Yellow=========================$NOCOLOR"
# sudo dnf install podman-compose
# pip3 uninstall -y podman-compose

# podman-compose --version

echo 
echo -e "$Light_Yellow[Stage 00.2]: Removing old versions of docker$NOCOLOR"
echo -e "$Light_Yellow---------------------------------------------$NOCOLOR"

sudo dnf remove  docker \
                  docker-client \
                  docker-client-latest \
                  docker-common \
                  docker-latest \
                  docker-latest-logrotate \
                  docker-logrotate \
                  docker-selinux \
                  docker-engine-selinux \
                  docker-engine \
                  docker-compose

echo 
echo -e "$Light_Yellow[Stage 00.3]: Installing docker$NOCOLOR"
echo -e "$Light_Yellow-------------------------------$NOCOLOR"

sudo dnf -y install dnf-plugins-core
sudo dnf config-manager --add-repo https://download.docker.com/linux/fedora/docker-ce.repo

sudo dnf install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin


#sudo usermod -aG docker $(id -un) && newgrp docker
sudo chmod 666 /var/run/docker.sock


echo 
echo -e "$Light_Yellow[Stage 00.4]: Installing docker compose$NOCOLOR"
echo -e "$Light_Yellow---------------------------------------$NOCOLOR"
sudo dnf install -qy docker-compose

sudo systemctl start docker

docker --version
docker-compose --version

echo
docker run --rm hello-world
docker pull goharbor/prepare:v2.9.2

echo
echo -e "$Light_Yellow[Stage 00.5]: Allowing 443, 4443 and 80 ports and HTTPS,HTTPS protocols$NOCOLOR"
echo -e "$Light_Yellow-----------------------------------------------------------------------$NOCOLOR"

sudo firewall-cmd --add-port={443/tcp,4443/tcp,80/tcp}
sudo firewall-cmd --add-service={https,http}
sudo firewall-cmd --runtime-to-permanent

echo
echo -e "$Light_Yellow Ports and Services Allowed:$NOCOLOR"

sudo firewall-cmd --list-all | grep -iE "https|http|443|4443|80"

