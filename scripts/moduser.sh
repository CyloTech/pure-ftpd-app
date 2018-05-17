#!/usr/bin/env bash

EXPECTED_ARGS=4
E_BADARGS=65

if [ $# -ne $EXPECTED_ARGS ]
    then
    echo "Usage: `basename $0` <username> <password> <restricted folder> <read only>"
    exit $E_BADARGS
fi

if [ "$(id -u)" != "0" ]; then
   echo "This script must be run as root" 1>&2
   exit 1
fi

USERNAME=${1}
PASSWORD=${2}
RESTRICTED_FOLDER=${3}
READ_ONLY=${4}

if [[ ${READ_ONLY} == '1' ]]
    then
    pure-pw userdel ${USERNAME} -f /etc/pure-ftpd/passwd/pureftpd.passwd
    (echo ${PASSWORD}; echo ${PASSWORD}) | pure-pw useradd ${USERNAME} -f /etc/pure-ftpd/passwd/pureftpd.passwd -m -d /home/ftpusers/default/${RESTRICTED_FOLDER} -u 1001 -g 1001
else
    pure-pw userdel ${USERNAME} -f /etc/pure-ftpd/passwd/pureftpd.passwd
    (echo ${PASSWORD}; echo ${PASSWORD}) | pure-pw useradd ${USERNAME} -f /etc/pure-ftpd/passwd/pureftpd.passwd -m -d /home/ftpusers/default/${RESTRICTED_FOLDER} -u 1000 -g 1000
fi

pure-pw mkdb /etc/pure-ftpd/pureftpd.pdb -f /etc/pure-ftpd/passwd/pureftpd.passwd