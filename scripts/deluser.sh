#!/usr/bin/env bash

EXPECTED_ARGS=1
E_BADARGS=65

if [ $# -ne $EXPECTED_ARGS ]
    then
    echo "Usage: `basename $0` <username>"
    exit $E_BADARGS
fi

if [ "$(id -u)" != "0" ]; then
   echo "This script must be run as root" 1>&2
   exit 1
fi

USERNAME=${1}

pure-pw userdel ${USERNAME} -f /etc/pure-ftpd/passwd/pureftpd.passwd
