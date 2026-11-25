# PostgreSQL 18 and 19 side by side, so pg_upgrade can see both binaries.
# Base image pinned by digest; every PostgreSQL and extension package pinned by version.
# Helper tools (curl, jq, ...) float with the Debian trixie archive. The PGDG signing key is
# checked against its fingerprint before apt trusts it.
FROM debian:trixie-slim@sha256:8aa5a7bf5a1955bddbe7d74fcdd0b91ab30e74362a8b73af672b0481b35b44a0

ARG PG18=18.7-1.pgdg13+5
ARG PG19=19.0-2.pgdg13+1
ARG PGVECTOR=0.8.7-1.pgdg13+2
ARG POSTGIS=3.7.0+dfsg-1.pgdg13+2
ARG PGCRON=1.6.8-1.pgdg13+3
ARG TIMESCALE18=2.32.0+dfsg-2.pgdg13+1

RUN set -eux; \
    apt-get update; \
    apt-get install -y --no-install-recommends curl ca-certificates gnupg procps time jq bc locales; \
    install -d /usr/share/postgresql-common/pgdg; \
    curl -fsS --proto '=https' --tlsv1.2 --retry 3 -o /usr/share/postgresql-common/pgdg/apt.postgresql.org.asc https://www.postgresql.org/media/keys/ACCC4CF8.asc; \
    gpg --with-colons --show-keys /usr/share/postgresql-common/pgdg/apt.postgresql.org.asc | grep -q '^fpr:::::::::B97B0AFCAA1A47F044F244A07FCC7D46ACCC4CF8:' || { echo 'PGDG key fingerprint mismatch' >&2; exit 1; }; \
    echo "deb [signed-by=/usr/share/postgresql-common/pgdg/apt.postgresql.org.asc] https://apt.postgresql.org/pub/repos/apt trixie-pgdg main" > /etc/apt/sources.list.d/pgdg.list; \
    apt-get update; \
    # Stop the Debian wrapper from creating a default cluster on install.
    mkdir -p /etc/postgresql-common; echo "create_main_cluster = false" > /etc/postgresql-common/createcluster.conf; \
    apt-get install -y --no-install-recommends \
      postgresql-18=$PG18 postgresql-client-18=$PG18 \
      postgresql-19=$PG19 postgresql-client-19=$PG19 \
      postgresql-18-jit=$PG18 postgresql-19-jit=$PG19 \
      postgresql-18-pgvector=$PGVECTOR postgresql-19-pgvector=$PGVECTOR \
      postgresql-18-postgis-3=$POSTGIS postgresql-19-postgis-3=$POSTGIS \
      postgresql-18-cron=$PGCRON postgresql-19-cron=$PGCRON \
      postgresql-18-timescaledb=$TIMESCALE18; \
    rm -rf /var/lib/apt/lists/*; \
    sed -i 's/# en_US.UTF-8/en_US.UTF-8/' /etc/locale.gen && locale-gen

ENV LANG=en_US.UTF-8 PGHOST=/tmp
USER postgres
WORKDIR /data
CMD ["sleep", "infinity"]
