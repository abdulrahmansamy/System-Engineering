#!/bin/bash -e

# Configure HTTPS Access to Harbor


COUNTRYNAME="SA"
COMMONNAME=$(hostname)
YOURDOMAIN=$(hostname)
FQDN=$(hostname)
ORGANIZATION="SOLUTIONSBYSTC"
STATE="RIYADH"
LOCALITY="RIYADH"
ORGANIZATIONUNIT="CLOUDENGINEERING"

DOCKER_CERT_DIRECTORY="/etc/docker/certs.d/"
PODMAN_CERT_DIRECTORY="/etc/containers/certs.d/"

echo 
echo -e "Varifying docker and podman installation"
echo -e "========================================"


rpm -q podman &> /dev/null
if [ $? -eq 0 ]; then
    echo "Podman is installed!" | grep -iE "podman|docker"
else
    echo "Podman is not installed!" | grep -iE "podman|docker"
fi

rpm -q docker &> /dev/null
if [ $? -eq 0 ]; then
    echo "Docker is installed!" | grep -iE "podman|docker"
else
    echo "Docker is not installed!" | grep -iE "podman|docker"
fi


mkdir -p ~/certs/


echo
echo -e "Generate a Certificate Authority Certificate"
echo -e "============================================"
openssl genrsa -out ~/certs/ca.key 4096

# openssl rsa -noout -text -in ~/certs/ca.key


openssl req -x509 -new -nodes -sha512 -days 3650 \
 -subj "/C=$COUNTRYNAME/ST=$STATE/L=$LOCALITY/O=$ORGANIZATION/OU=$ORGANIZATIONUNIT/CN=$COMMONNAME" \
 -key ~/certs/ca.key \
 -out ~/certs/ca.crt

openssl x509 -noout -text -in ~/certs/ca.crt | grep -i issuer


echo
echo -e "Generate a Server Certificate"
echo -e "============================="

openssl genrsa -out ~/certs/$YOURDOMAIN.key 4096

openssl req -sha512 -new \
    -subj "/C=$COUNTRYNAME/ST=$STATE/L=$LOCALITY/O=$ORGANIZATION/OU=$ORGANIZATIONUNIT/CN=$COMMONNAME" \
    -key ~/certs/$YOURDOMAIN.key \
    -out ~/certs/$YOURDOMAIN.csr


cat > ~/certs/v3.ext <<-EOF
authorityKeyIdentifier=keyid,issuer
basicConstraints=CA:FALSE
keyUsage = digitalSignature, nonRepudiation, keyEncipherment, dataEncipherment
extendedKeyUsage = serverAuth
subjectAltName = @alt_names

[alt_names]
DNS.1=$FQDN
DNS.2=$(echo $FQDN | awk -F'.' '{print $1}')
DNS.3=$(hostname)
EOF


openssl x509 -req -sha512 -days 3650 \
    -extfile ~/certs/v3.ext \
    -CA ~/certs/ca.crt -CAkey ~/certs/ca.key -CAcreateserial \
    -in ~/certs/$YOURDOMAIN.csr \
    -out ~/certs/$YOURDOMAIN.crt


echo
echo -e "Provide the Certificates to Harbor and the Contianer Engine"
echo -e "==========================================================="

sudo mkdir -p /data/cert/
sudo cp ~/certs/$YOURDOMAIN.crt /data/cert/
sudo cp ~/certs/$YOURDOMAIN.key /data/cert/
tree /data/cert/


openssl x509 -inform PEM -in ~/certs/$YOURDOMAIN.crt -out ~/certs/$YOURDOMAIN.cert

if [ -d "$DOCKER_CERT_DIRECTORY" ]; then
    echo "Copying Certificate files to $DOCKER_CERT_DIRECTORY"

    sudo mkdir -p /etc/docker/certs.d/$YOURDOMAIN/
    sudo cp ~/certs/$YOURDOMAIN.cert /etc/docker/certs.d/$YOURDOMAIN/
    sudo cp ~/certs/$YOURDOMAIN.key /etc/docker/certs.d/$YOURDOMAIN/
    sudo cp ~/certs/ca.crt /etc/docker/certs.d/$YOURDOMAIN/

    tree $DOCKER_CERT_DIRECTORY
    sudo systemctl restart docker
    if [ $? -eq 0 ]; then echo "Docker Engine is Restarted!" | grep -iE "podman|docker"; fi


elif [ -d "$PODMAN_CERT_DIRECTORY" ]; then
    echo "Copying Certificate files to $PODMAN_CERT_DIRECTORY"

    sudo mkdir -p $PODMAN_CERT_DIRECTORY/$YOURDOMAIN/
    sudo cp ~/certs/$YOURDOMAIN.cert $PODMAN_CERT_DIRECTORY/$YOURDOMAIN/
    sudo cp ~/certs/$YOURDOMAIN.key $PODMAN_CERT_DIRECTORY/$YOURDOMAIN/
    sudo cp ~/certs/ca.crt $PODMAN_CERT_DIRECTORY/$YOURDOMAIN/

    tree $PODMAN_CERT_DIRECTORY
    sudo systemctl restart podman
    if [ $? -eq 0 ]; then echo "Podman Engine is Restarted!" | grep -iE "podman|docker"; fi
fi

