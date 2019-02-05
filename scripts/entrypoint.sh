#!/usr/bin/env bash

set -x

cat /ssl/key.pem > /etc/ssl/private/pure-ftpd.pem
echo '' >> /etc/ssl/private/pure-ftpd.pem
cat /ssl/cert.pem >> /etc/ssl/private/pure-ftpd.pem
echo '' >> /etc/ssl/private/pure-ftpd.pem
chmod 600 /etc/ssl/private/pure-ftpd.pem

if [ ! -f /etc/app_configured ]; then
    pure-pw list | grep ${FTP_USER} || (echo ${FTP_PASSWORD}; echo ${FTP_PASSWORD}) | pure-pw useradd ${FTP_USER} -f /etc/pure-ftpd/passwd/pureftpd.passwd -m -d /home/ftpusers/default -u 1000 -g 1000
    touch /etc/app_configured
    until [[ $(curl -i -H "Accept: application/json" -H "Content-Type:application/json" -X POST "https://api.cylo.io/v1/apps/installed/${INSTANCE_ID}" | grep '200') ]]
        do
        sleep 5
    done
fi

exec "$@"
