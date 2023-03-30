#!/bin/bash

if [[ $(grep -E '^(ID|NAME)="?' /etc/os-release | awk -F= '{print $2}' | tr -d '"') == "Ubuntu" ]]; then
    if [[ $(grep -E '^(VERSION_ID)="?' /etc/os-release | awk -F= '{print $2}' | tr -d '"') == "20.04" ]]; then
        echo "Running Ubuntu 20.04 LTS"
        # Run command for Ubuntu 20.04 LTS
    elif [[ $(grep -E '^(VERSION_ID)="?' /etc/os-release | awk -F= '{print $2}' | tr -d '"') == "18.04" ]]; then
        echo "Running Ubuntu 18.04 LTS"
        # Run command for Ubuntu 18.04 LTS
    else
        echo "Unsupported Ubuntu version"
    fi
elif [[ $(grep -E '^(ID|NAME)="?' /etc/os-release | awk -F= '{print $2}' | tr -d '"') == "CentOS Linux" ]]; then
    if [[ $(grep -E '^(VERSION_ID)="?' /etc/os-release | awk -F= '{print $2}' | tr -d '"' | cut -c1) == "7" ]]; then
        echo "Running CentOS 7"
        # Run command for CentOS 7
    elif [[ $(grep -E '^(VERSION_ID)="?' /etc/os-release | awk -F= '{print $2}' | tr -d '"' | cut -c1) == "8" ]]; then
        echo "Running CentOS 8"
        # Run command for CentOS 8
    else
        echo "Unsupported CentOS version"
    fi
elif [[ $(grep -E '^(NAME)="?' /etc/os-release | awk -F= '{print $2}' | tr -d '"') == "Fedora Linux" ]]; then
    if [[ $(grep -E '^(VERSION_ID)="?' /etc/os-release | awk -F= '{print $2}' | tr -d '"') == "36" ]]; then
        echo "Running Fedora 36"
        # Run command for CentOS 7
    elif [[ $(grep -E '^(VERSION_ID)="?' /etc/os-release | awk -F= '{print $2}' | tr -d '"') == "37" ]]; then
        echo "Running Fedora 37"
        # Run command for CentOS 8
    else
        echo "Unsupported CentOS version"
    fi
else
    echo "Unsupported Linux distribution"
fi
