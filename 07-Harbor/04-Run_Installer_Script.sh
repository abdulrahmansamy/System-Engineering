#!/bin/bash -e

#REGFQDN=$(hostname)

source setup_vars.sh

echo
echo -e "$Yellow[Step 04]: Running installing script\033[0m"
echo -e "$Yellow====================================\033[0m"
cd ~/harbor/online-installer/harbor/
source ./install.sh 


docker login $REGFQDN -u admin -p Harbor12345
docker push $REGFQDN/myproject/myrepo:mytag