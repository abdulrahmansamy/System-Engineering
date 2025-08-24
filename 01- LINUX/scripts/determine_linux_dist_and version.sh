#!/bin/bash

if [ -f /etc/os-release ]; then
    # freedesktop.org and systemd
    . /etc/os-release
    echo "The Linux distribution is: $NAME"
    echo "The version is: $VERSION_ID"
elif type lsb_release >/dev/null 2>&1; then
    # linuxbase.org
    echo "The Linux distribution is: $(lsb_release -si)"
    echo "The version is: $(lsb_release -sr)"
elif [ -f /etc/lsb-release ]; then
    # For some versions of Debian/Ubuntu without lsb_release command
    . /etc/lsb-release
    echo "The Linux distribution is: $DISTRIB_ID"
    echo "The version is: $DISTRIB_RELEASE"
elif [ -f /etc/debian_version ]; then
    # Older Debian/Ubuntu/etc.
    echo "The Linux distribution is: Debian"
    echo "The version is: $(cat /etc/debian_version)"
elif [ -f /etc/SuSe-release ]; then
    # Older SuSE/etc.
    echo "The Linux distribution is: SuSE"
    echo "The version is: $(cat /etc/SuSe-release)"
elif [ -f /etc/redhat-release ]; then
    # Older Red Hat, CentOS, etc.
    echo "The Linux distribution is: Red Hat"
    echo "The version is: $(cat /etc/redhat-release)"
else
    # Fall back to uname, e.g. "Linux <version>", also works for BSD, etc.
    echo "The Linux distribution is: $(uname -s)"
    echo "The version is: $(uname -r)"
fi
