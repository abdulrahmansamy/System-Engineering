#!/bin/bash

###################################################
#Define cluster Hosts
#in hosts file

more /etc/hosts
#127.0.0.1   localhost localhost.localdomain localhost4 localhost4.localdomain4
#::1         localhost localhost.localdomain localhost6 localhost6.localdomain6

#192.168.2.3	jumbhost02	jh				jumbhost	
#192.168.2.4	master01	m1	master01.cluster.local	
#192.168.2.5	master02	m2	master02.cluster.local
#192.168.2.6	master03	m3	master03.cluster.local
#192.168.2.7	worker01	w1	worker01.cluster.local
#192.168.2.8	worker02	w2	worker02.cluster.local
#192.168.2.9	worker03	w3	worker03.cluster.local


#destributing ssh pub keys
#=========================
echo -e "\n\nGenerating a ssh key pair\n=========================\n"
ssh-keygen -t rsa -b 2048 -f ~/.ssh/id_rsa -N '' <<< n
echo 
echo


echo -e "\n\ndestributing ssh Public keys\n============================\n"
for X in `egrep -i 'master|worker' /etc/hosts | cut -f 2`
do
echo -e "\nNode: $X\n==============\n"
cat ~/.ssh/id_rsa.pub | ssh $X -i ~/.ssh/RKE-CLUSTER 'umask 077; test -d ~/.ssh || mkdir ~/.ssh ; cat >> ~/.ssh/authorized_keys'
ssh $X umask 0002
done


#Check the connectivity to the hosts


echo -e "\n\nChecking the connectivity to the Nodes\n======================================\n"
for x in `egrep -i 'master|worker' /etc/hosts | cut -f 2` ; do ssh $x hostname ; done
=======================



#Update sysctl settings for Kubernetes networking

echo -e "\n\nUpdating sysctl settings for Kubernetes networking\n==================================================\n"

for x in `egrep -i 'master|worker' /etc/hosts | cut -f 2`
do
echo -e "\nNode: $x\n==============\n"
ssh $x sudo tee /etc/sysctl.d/kubernetes.conf >/dev/null <<EOF
net.bridge.bridge-nf-call-ip6tables = 1
net.bridge.bridge-nf-call-iptables = 1
EOF
ssh $x sudo sysctl --system
done


#escale user privilages

echo -e "\n\nUser: $(whoami) Privilege Escalation\n=================================\n"

for x in `egrep -i 'master|worker' /etc/hosts | cut -f 2`
do
echo -e "\nNode: $x\n==============\n"
ssh $x sudo tee /etc/sudoers.d/$(whoami) >/dev/null <<EOF  
$(whoami)    ALL=(ALL)       NOPASSWD: ALL
EOF
done
