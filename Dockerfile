FROM stilliard/pure-ftpd

ADD scripts /scripts
RUN chmod -R +x /scripts

ENTRYPOINT ["/scripts/entrypoint.sh"]

CMD /run.sh -l puredb:/etc/pure-ftpd/pureftpd.pdb -P ${PUBLICHOST} -p ${FIRST_PORT}:${LAST_PORT} -s -A -j -Z -H -4 -E -w -D -L 40000:5 -b

EXPOSE 21