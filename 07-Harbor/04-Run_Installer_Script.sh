#!/bin/bash -e

#REGFQDN=$(hostname)

source setup_vars.sh

echo
echo -e "$Yellow[Stage 04]: Running Harbor installation script$NOCOLOR"
echo -e "$Yellow=============================================$NOCOLOR"
cd ~/harbor/online-installer/harbor/
source ./install.sh 

echo
echo -e "$Light_Yellow Logging in to the new harbor registry$NOCOLOR"
echo -e "$Light_Yellow -------------------------------------$NOCOLOR"
docker login $REGFQDN -u admin -p Harbor12345
docker push $REGFQDN/myproject/myrepo:mytag