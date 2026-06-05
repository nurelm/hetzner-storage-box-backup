ARG PG_VERSION
FROM postgres:${PG_VERSION}-alpine

RUN apk add --no-cache \
    restic \
    openssh-client \
    bash

COPY hpb.sh /usr/local/bin/hpb.sh
RUN chmod +x /usr/local/bin/hpb.sh

ENTRYPOINT ["/usr/local/bin/hpb.sh"]
