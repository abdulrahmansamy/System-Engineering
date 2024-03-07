#!/bin/bash

export CERTIFICATE_DIR="/data/cert/"
export YOURDOMAIN=$(hostname)

cp ~/harbor/online-installer/harbor/harbor.yml.tmpl ~/harbor/online-installer/harbor/harbor.yml

echo 
echo -e "\033[1mConfigure Harbor Yaml file\033[0m"
echo -e "\033[1m==========================\033[0m"

sed -i "s|reg.mydomain.com|$YOURDOMAIN|g" ~/harbor/online-installer/harbor/harbor.yml
#sed -i -e "s|\/your\/certificate\/path|$CERTIFICATE_DIR\/$YOURDOMAIN.crt|g" ~/harbor/online-installer/harbor/harbor.yml
#sed -i -e "s/\/your\/private\/key\/path/$CERTIFICATE_DIR\/$YOURDOMAIN.key/g" ~/harbor/online-installer/harbor/harbor.yml
sed -i "s|/your/certificate/path|$CERTIFICATE_DIR/$YOURDOMAIN.crt|g" ~/harbor/online-installer/harbor/harbor.yml
sed -i "s|/your/private/key/path|$CERTIFICATE_DIR/$YOURDOMAIN.key|g" ~/harbor/online-installer/harbor/harbor.yml