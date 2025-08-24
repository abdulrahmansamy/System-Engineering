#!/bin/bash

if [[ $(grep -E '^(ID|NAME)="?' /etc/os-release &> /dev/null | awk -F= '{print $2}' | tr -d '"') == "Ubuntu" ]]; then
    if [[ $(grep -E '^(VERSION_ID)="?' /etc/os-release | awk -F= '{print $2}' | tr -d '"') == "20.04" ]]; then
        echo "Running Ubuntu 20.04 LTS"
        # Run command for Ubuntu 20.04 LTS
    elif [[ $(grep -E '^(VERSION_ID)="?' /etc/os-release | awk -F= '{print $2}' | tr -d '"') == "18.04" ]]; then
        echo "Running Ubuntu 18.04 LTS"
        # Run command for Ubuntu 18.04 LTS
    else
        echo "Unsupported Ubuntu version"
    fi
elif [[ $(grep -E '^(ID|NAME)="?' /etc/os-release &> /dev/null | awk -F= '{print $2}' | tr -d '"') == "CentOS Linux" ]]; then
    if [[ $(grep -E '^(VERSION_ID)="?' /etc/os-release | awk -F= '{print $2}' | tr -d '"' | cut -c1) == "7" ]]; then
        echo "Running CentOS 7"
        # Run command for CentOS 7
    elif [[ $(grep -E '^(VERSION_ID)="?' /etc/os-release | awk -F= '{print $2}' | tr -d '"' | cut -c1) == "8" ]]; then
        echo "Running CentOS 8"
        # Run command for CentOS 8
    else
        echo "Unsupported CentOS version"
    fi
elif [[ $(grep -E '^(NAME)="?' /etc/os-release &> /dev/null | awk -F= '{print $2}' | tr -d '"') == "Fedora Linux" ]]; then
    if [[ $(grep -E '^(VERSION_ID)="?' /etc/os-release | awk -F= '{print $2}' | tr -d '"') == "36" ]]; then
        echo "Running Fedora 36"
        # Run command for Fedora 36
    elif [[ $(grep -E '^(VERSION_ID)="?' /etc/os-release | awk -F= '{print $2}' | tr -d '"') == "37" ]]; then
        echo "Running Fedora 37"
        # Run command for Fedora 37
    else
        echo "Unsupported Fedora version"
    fi
elif [[ $(system_profiler SPSoftwareDataType | grep -i 'system version' | awk -F' ' '{print $3}') == "macOS" ]]; then
    if [[ $(system_profiler SPSoftwareDataType | grep -i 'system version' | awk -F' ' '{print $4}') == "13.2.1" ]]; then
        echo "Running macOS 13.2.1"
        # Run command for macOS 13.2.1
    elif [[ $(system_profiler SPSoftwareDataType | grep -i 'system version' | awk -F' ' '{print $4}') == "13.2.2" ]]; then
        echo "Running macOS 13.2.2"
        # Run command for macOS 13.2.2
    
    else
        echo "Unsupported macOS version"
    fi
else
    echo "Unsupported Linux distribution"
fi

# you can use this to get the redhat version
# rpm -qa '(oraclelinux|sl|redhat|centos|fedora|rocky|alma)*release(|-server)' --queryformat '%{VERSION}'
