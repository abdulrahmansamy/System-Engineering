#!/bin/bash -e

COUNTRYNAME="SA"
COMMONNAME=$(hostname)
export YOURDOMAIN=$(hostname)
FQDN=$(hostname)
REGFQDN=$(hostname)
ORGANIZATION="SOLUTIONSBYSTC"
STATE="RIYADH"
LOCALITY="RIYADH"
ORGANIZATIONUNIT="CLOUDENGINEERING"
export CERTIFICATE_DIR="/data/cert"
DOCKER_CERT_DIRECTORY="/etc/docker"
PODMAN_CERT_DIRECTORY="/etc/containers/certs.d"


Black='\\033[0;30m'
Dark_Gray='\\033[1;30m'
RED='\\033[0;31m'
Light_Red='\\033[1;31m'
Green='\\033[0;32m'
Light_Green='\\033[1;32m'
Yellow='\\033[0;33m'
Light_Yellow='\\033[1;33m'
Blue='\\033[0;34m'
Light_Blue='\\033[1;34m'
Purple='\\033[0;35m'
Light_Purple='\\033[1;35m'
Cyan='\\033[0;36m'
Light_Cyan='\\033[1;36m'
White='\\033[1;37m'

NOCOLOR='\\033[0m'