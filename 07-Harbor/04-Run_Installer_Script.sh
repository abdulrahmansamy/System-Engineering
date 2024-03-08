#!/bin/bash -e

REGFQDN=$(hostname)

echo
echo -e "Running installing script"
echo -e "========================="
cd ~/harbor/online-installer/harbor/
source ./install.sh 


docker login $REGFQDN -u admin -p Harbor12345
docker push $REGFQDN/myproject/myrepo:mytag