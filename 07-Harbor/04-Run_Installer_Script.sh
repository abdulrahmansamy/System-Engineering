#!/bin/bash -e

#REGFQDN=$(hostname)

source setup_vars.sh

echo
echo -e "$Yellow[Step 04]: Running installing script$NOCOLOR"
echo -e "$Yellow====================================$NOCOLOR"
cd ~/harbor/online-installer/harbor/
source ./install.sh 

echo
echo -e "$Yellow Logging in harbor registry$NOCOLOR"
echo -e "$Yellow --------------------------$NOCOLOR"
docker login $REGFQDN -u admin -p Harbor12345
docker push $REGFQDN/myproject/myrepo:mytag