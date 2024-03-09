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