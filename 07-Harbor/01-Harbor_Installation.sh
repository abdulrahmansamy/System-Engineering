#!/bin/bash -e


source setup_vars.sh

## Harbor Download packages

echo
echo -e "$Yellow[Step 01]: Download and Extract the Harbor Packages\033[0m"
echo -e "$Yellow===================================================\033[0m"


echo
echo -e "$Light_Yellow[Step 01.1]: Download Harbor Online Packages\033[0m"
echo -e "$Light_Yellow--------------------------------------------\033[0m"
mkdir -p ~/harbor/online-installer &&  cd ~/harbor/


wget -nv --quiet --show-progress -O ~/harbor/harbor-online-installer-v2.9.2.tgz https://github.com/goharbor/harbor/releases/download/v2.9.2/harbor-online-installer-v2.9.2.tgz 

wget -nv --quiet --show-progress  -O ~/harbor/harbor-online-installer-v2.9.2.tgz.asc https://github.com/goharbor/harbor/releases/download/v2.9.2/harbor-online-installer-v2.9.2.tgz.asc



echo
echo -e "$Light_Yellow[Step 01.2]: Verify the package is genuine\033[0m"
echo -e "$Light_Yellow------------------------------------------\033[0m"

gpg --keyserver hkps://keyserver.ubuntu.com --receive-keys 644FF454C0B4115C

gpg -v --keyserver hkps://keyserver.ubuntu.com --verify harbor-online-installer-v2.9.2.tgz.asc


echo
echo -e "$Light_Yellow[Step 01.3]: Extracting the Package\033[0m"
echo -e "$Light_Yellow-----------------------------------\033[0m"

tar xzvf  ~/harbor/harbor-online-installer-v2.9.2.tgz -C ~/harbor/online-installer
