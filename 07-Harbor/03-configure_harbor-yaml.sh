#!/bin/bash

#export CERTIFICATE_DIR="/data/cert"
#export YOURDOMAIN=$(hostname)

source setup_vars.sh

cp ~/harbor/online-installer/harbor/harbor.yml.tmpl ~/harbor/online-installer/harbor/harbor.yml

echo 
echo -e "$Yellow[Stage 03]: Configure Harbor Yaml file$NOCOLOR"
echo -e "$Yellow======================================$NOCOLOR"

sed -i "s|reg.mydomain.com|$YOURDOMAIN|g" ~/harbor/online-installer/harbor/harbor.yml
#sed -i -e "s|\/your\/certificate\/path|$CERTIFICATE_DIR\/$YOURDOMAIN.crt|g" ~/harbor/online-installer/harbor/harbor.yml
#sed -i -e "s/\/your\/private\/key\/path/$CERTIFICATE_DIR\/$YOURDOMAIN.key/g" ~/harbor/online-installer/harbor/harbor.yml
sed -i "s|/your/certificate/path|$CERTIFICATE_DIR/$YOURDOMAIN.crt|g" ~/harbor/online-installer/harbor/harbor.yml
sed -i "s|/your/private/key/path|$CERTIFICATE_DIR/$YOURDOMAIN.key|g" ~/harbor/online-installer/harbor/harbor.yml