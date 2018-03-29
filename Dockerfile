FROM stilliard/pure-ftpd

ADD scripts /scripts
RUN chmod -R +x /scripts

ENTRYPOINT ["/scripts/entrypoint.sh"]

CMD /run.sh -c 5 -C 50 -l puredb:/etc/pure-ftpd/pureftpd.pdb -E -P ${PUBLICHOST} -p ${FIRST_PORT}:${LAST_PORT} -s -A -j -Z -H -4 -E -X -x

EXPOSE 21