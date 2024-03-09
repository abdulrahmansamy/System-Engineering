#!/bin/bash -e


source setup_vars.sh

## Harbor Download packages

echo
echo -e "$Yellow[Step 01]: Download and Extract the Harbor Packages$NOCOLOR"
echo -e "$Yellow===================================================$NOCOLOR"


echo
echo -e "$Light_Yellow[Step 01.1]: Download Harbor Online Packages$NOCOLOR"
echo -e "$Light_Yellow--------------------------------------------$NOCOLOR"
mkdir -p ~/harbor/online-installer &&  cd ~/harbor/


wget -nv --quiet --show-progress -O ~/harbor/harbor-online-installer-v2.9.2.tgz https://github.com/goharbor/harbor/releases/download/v2.9.2/harbor-online-installer-v2.9.2.tgz 

wget -nv --quiet --show-progress  -O ~/harbor/harbor-online-installer-v2.9.2.tgz.asc https://github.com/goharbor/harbor/releases/download/v2.9.2/harbor-online-installer-v2.9.2.tgz.asc



echo
echo -e "$Light_Yellow[Step 01.2]: Verify the package is genuine$NOCOLOR"
echo -e "$Light_Yellow------------------------------------------$NOCOLOR"

gpg --keyserver hkps://keyserver.ubuntu.com --receive-keys 644FF454C0B4115C

gpg -v --keyserver hkps://keyserver.ubuntu.com --verify harbor-online-installer-v2.9.2.tgz.asc


echo
echo -e "$Light_Yellow[Step 01.3]: Extracting the Package$NOCOLOR"
echo -e "$Light_Yellow-----------------------------------$NOCOLOR"

tar xzvf  ~/harbor/harbor-online-installer-v2.9.2.tgz -C ~/harbor/online-installer
