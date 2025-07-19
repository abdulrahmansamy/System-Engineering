## MySQL Installation
## =====================

# 1- Install and Secure MySQL
# ---------------------------
# https://dev.mysql.com/doc/mysql-yum-repo-quick-guide/en/

curl -sLO https://dev.mysql.com/get/mysql80-community-release-fc37-1.noarch.rpm	## for fedora 37

curl -sLO https://dev.mysql.com/get/mysql80-community-release-el7-7.noarch.rpm	 ## for centos 7

sudo rpm -Uvh  mysql80-community-release-fc37-1.noarch.rpm 

yum repolist all | grep mysql

yum repolist enabled | grep mysql


sudo yum module -y disable mysql

sudo yum install -y mysql-community-server

systemctl enable mysqld --now

systemctl status mysqld

: << 'COMMENT'
/*
sudo grep 'temporary password' /var/log/mysqld.log
mysql -uroot -p
ALTER USER 'root'@'localhost' IDENTIFIED BY '1234@Pass';
*/
COMMENT

mysql -uroot --password=$(sudo grep 'temporary password' /var/log/mysqld.log | grep -o '[^ ]*$') -e 'ALTER USER "root"@"localhost" IDENTIFIED BY "1234@Pass";' --connect-expired-password
mysql -uroot -p1234@Pass -e 'SHOW DATABASES;'

mysql -uroot -p1234@Pass -e 'CREATE USER "root"@"%" IDENTIFIED BY "1234@Pass"';

cat << EOF > ~/.my.cnf
[client]
user = root
password = 1234@Pass
host = localhost
EOF

mysql_config_editor set --login-path=client --user=root --host=localhost --password

: << 'COMMENT'
/*
CREATE USER 'replica'@'172.16.42.145' IDENTIFIED BY '123@Pass';
CREATE USER 'replica'@'db01' IDENTIFIED BY '123@Pass';
CREATE USER 'replica'@'db01.mysql.cluster' IDENTIFIED BY '123@Pass';
select user,host from mysql.user;
CREATE USER 'replica'@'rm-l4v6j1kult1n8m0ft.mysql.me-central-1.rds.aliyuncs.com' IDENTIFIED BY '123@Pass';
CREATE USER 'replica'@'100.104.76.247' IDENTIFIED BY '123@Pass';
CREATE USER 'replica'@'100.104.76.246' IDENTIFIED BY '123@Pass';
GRANT ALL PRIVILEGES ON *.* TO 'replica'@'%' WITH GRANT OPTION;
CREATE USER 'replica'@'%' IDENTIFIED BY '123@Pass';
GRANT ALL PRIVILEGES ON *.* TO 'replica'@'%';
 WITH GRANT OPTION;
*/
COMMENT

2- Prepration For MySQL Clustering
----------------------------------

hostnamectl set-hostname db01.cluster02.mysql
hostnamectl set-hostname db02.cluster02.mysql

cat << EOF >> /etc/hosts

172.16.42.148	db01.cluster01.mysql	db01
172.16.42.149	db02.cluster01.mysql	db02
EOF



cat << EOF >> ~/.my.cnf

[db01]
user = root
password = 1234@Pass
host = db01

[db02]
user = root
password = 1234@Pass
host = db02
EOF


firewall-cmd --permanent --add-service=mysql 
firewall-cmd --reload 


3- Master Master Configuration
------------------------------

in both servers
---------------

cat << EOF >>  /etc/my.cnf
!includedir /etc/my.cnf.d/
EOF

mkdir -p /var/log/mysql/
chown mysql:mysql /var/log/mysql/
sed -i 's/log-error=\/var\/log\/mysqld.log/log-error=\/var\/log\/mysql\/mysqld.log/g' /etc/my.cnf



in master 01
------------



cat << EOF > /etc/my.cnf.d/mysql-server.cnf
[mysqld]
server-id=1
replicate-same-server-id=0
auto-increment-increment=2
auto-increment-offset=1

relay-log=/var/lib/mysql/node1-relay-bin 
relay-log-index=/var/lib/mysql/node1-relay-bin.index 
log-error=/var/log/mysql/mysql.error 
master-info-file=/var/lib/mysql/mysql-master.info
relay-log-info-file=/var/lib/mysql/node1-relay-log.info
log-bin=/var/lib/mysql/node1-bin

EOF


systemctl enable mysqld.service --now

systemctl restart mysqld.service
systemctl status mysqld.service 

ls /var/lib/mysql/node1-bin.*


mysql -uroot -p1234@Pass 

CREATE USER 'replica'@'db02.mysql.cluster' IDENTIFIED BY '123@Pass';
GRANT replication slave ON *.* TO 'replica'@'db02.mysql.cluster';
GRANT replication slave ON *.* TO 'replica'@'172.16.42.147';


in master 02
------------



cat << EOF >> /etc/my.cnf.d/mysql-server.cnf
[mysqld]
server-id=2
replicate-same-server-id=0
auto-increment-increment=2
auto-increment-offset=2

relay-log=/var/lib/mysql/node2-relay-bin 
relay-log-index=/var/lib/mysql/node2-relay-bin.index 
log-error=/var/log/mysql/mysql.error 
master-info-file=/var/lib/mysql/mysql-master.info
relay-log-info-file=/var/lib/mysql/node2-relay-log.info
log-bin=/var/lib/mysql/node2-bin

EOF


systemctl enable mysqld.service --now

systemctl restart mysqld.service
systemctl status mysqld.service 

ls /var/lib/mysql/node2-bin.*



mysql -uroot -p1234@Pass 

CREATE USER 'replica'@'db01.mysql.cluster' IDENTIFIED BY '123@Pass';
GRANT replication slave ON *.* TO 'replica'@'db01.mysql.cluster';
GRANT replication slave ON *.* TO 'replica'@'172.16.42.145';



in both servers
---------------




cat << EOF >> /etc/hosts

172.16.42.145	db01.mysql.cluster	db01
172.16.42.147	db02.mysql.cluster	db02
EOF



mysql -uroot -p1234@Pass -e 'SELECT user,host FROM mysql.user;'

mysql -uroot -p1234@Pass -e 'SHOW MASTER STATUS;'


In server 01
------------

mysql -uroot -p1234@Pass

STOP SLAVE;

CHANGE MASTER TO MASTER_HOST='db02.mysql.cluster', MASTER_USER='replica', MASTER_PASSWORD='123@Pass', MASTER_LOG_FILE='node2-bin.000001', MASTER_LOG_POS=887;

START SLAVE;

SHOW SLAVE STATUS\G;

In server 02
------------

mysql -uroot -p1234@Pass

STOP SLAVE;

CHANGE MASTER TO MASTER_HOST='db01.mysql.cluster', MASTER_USER='replica', MASTER_PASSWORD='123@Pass', MASTER_LOG_FILE='node1-bin.000001', MASTER_LOG_POS=642;

START SLAVE;


SHOW SLAVE STATUS\G;



CREATE Loadbalancing
====================


CREATE USER 'dbadmin'@'%' IDENTIFIED BY '123@Pass';
GRANT ALL PRIVILEGES ON *.* to 'dbadmin';


mysql -udbadmin -p123@Pass -e 'SELECT user,host FROM mysql.user;'


yum install -y keepalived



server01
--------


cp /etc/keepalived/keepalived.conf /etc/keepalived/keepalived.conf.bak

cat << EOF > /etc/keepalived/keepalived.conf
! Configuration File for keepalived


vrrp_instance VI_1 {
    state MASTER
    interface ens160
    virtual_router_id 51
    priority 101
    advert_int 1
    authentication {
        auth_type dbadmin
        auth_pass 123@Pass
    }
    virtual_ipaddress {
        172.16.42.146/24 dev ens160 label ens160:1
    }

    track_interface {
        ens160 weight 5
    }
}
EOF





systemctl enable keepalived.service --now
systemctl restart keepalived.service
systemctl status keepalived.service


ip a



server02
--------


cp /etc/keepalived/keepalived.conf /etc/keepalived/keepalived.conf.bak

cat << EOF > /etc/keepalived/keepalived.conf
! Configuration File for keepalived


vrrp_instance VI_1 {
    state MASTER
    interface ens160
    virtual_router_id 51
    priority 101
    advert_int 1
    authentication {
        auth_type dbadmin
        auth_pass 123@Pass
    }
    virtual_ipaddress {
        172.16.42.146/24 dev ens160 label ens160:1
    }

    track_interface {
        ens160 weight 5
    }
}
EOF





systemctl enable keepalived.service --now
systemctl restart keepalived.service
systemctl status keepalived.service



ip a



both servers
------------

ping 172.16.42.146


Third machine (client mysql)
----------------------------

sudo yum install -y mysql

mysql -udbadmin -p123@Pass -h 172.16.42.146
show databases;




FailOver, Failback
------------------

SHOW VARIABLES LIKE 'server_id';
SHOW DATABASES;

stop node1
systemctl stop mysqld.service

CREATE DATABASE node1down;


start node1
systemctl start mysqld.service

stop node2
systemctl stop mysqld.service

CREATE DATABASE node2down;

start node2
systemctl start mysqld.service










Install HAPROXY
===============
in both servers
---------------
yum install -y haproxy



