#!/bin/bash

REGFQDN=$(hostname)
source ~/harbor/online-installer/harbor/install.sh 


docker login $REGFQDN -u admin -p Harbor12345
docker push $REGFQDN/myproject/myrepo:mytag