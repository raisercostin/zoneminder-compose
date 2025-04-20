# syntax=docker/dockerfile:1.4
FROM ubuntu:22.04

ENV DEBIAN_FRONTEND=noninteractive \
    TZ=UTC

# 1) Add ZoneMinder PPA (rarely changes)
RUN apt-get update \
 && apt-get install -y software-properties-common \
 && add-apt-repository -y ppa:iconnor/zoneminder-1.36

# 2) Install standard deps (php‑fpm, MariaDB client)
RUN apt-get install -y --no-install-recommends php-fpm mariadb-client

# 3) Install ZoneMinder (last install step)
RUN apt-get install -y --no-install-recommends zoneminder

# Install additional tools
RUN apt-get install -y --no-install-recommends pv

# 3.1) Configure php‑fpm logging to stdout/stderr
RUN sed -i \
    -e 's|;error_log = .*|error_log = /proc/self/fd/2|' \
    -e 's|;access.log = .*|access.log = /proc/self/fd/1|' \
    /etc/php/8.1/fpm/php-fpm.conf

# 4) Configure PHP‑FPM to listen on TCP port 9000 instead of socket
RUN sed -i \
    -e 's|listen = /run/php/php8.1-fpm.sock|listen = 9000|' \
    -e 's|;listen.owner = www-data|listen.owner = www-data|' \
    -e 's|;listen.group = www-data|listen.group = www-data|' \
    /etc/php/8.1/fpm/pool.d/www.conf

# 5) Override DB connection in conf.d so zm.conf localhost is replaced. See also /etc/zm/zm.conf
RUN mkdir -p /etc/zm/conf.d
COPY <<EOF /etc/zm/conf.d/99-docker.conf
ZM_DB_HOST=${ZM_DB_HOST}
ZM_DB_PORT=3306
ZM_DB_SOCKET=
EOF
RUN ls -al /etc/zm/conf.d && cat /etc/zm/conf.d/99-docker.conf

# 6) Embed entrypoint via heredoc (BuildKit required)
COPY <<'EOF' /usr/local/bin/docker-entrypoint.sh
#!/bin/sh
set -e

: "${ZM_DB_ROOT_PASS:=rootpass}"
: "${ZM_DB_HOST:=db}"
: "${ZM_DB_NAME:=zm}"
: "${ZM_DB_USER:=zmuser}"
: "${ZM_DB_PASS:=zmpass}"

until mysqladmin --host="$ZM_DB_HOST" --user="$ZM_DB_USER" --password="$ZM_DB_PASS" ping --silent; do
  echo "⏳ waiting for DB at $ZM_DB_HOST…"
  sleep 2
done

# DEBUG block start
echo "DEBUG: checking if database '$ZM_DB_NAME' exists on '$ZM_DB_HOST' as '$ZM_DB_USER'"
mysqlshow --host="$ZM_DB_HOST" --user="$ZM_DB_USER" --password="$ZM_DB_PASS" "$ZM_DB_NAME" >/dev/null 2>&1
RC=$?
echo "DEBUG: mysqlshow exit code = $RC"
# DEBUG block end
# Check for a missing ZoneMinder table instead of the database itself
TABLE_CHECK=$(mysql --silent --skip-column-names \
  --host="$ZM_DB_HOST" --user="$ZM_DB_USER" --password="$ZM_DB_PASS" \
  -e "SELECT COUNT(*) FROM information_schema.tables \
      WHERE table_schema='$ZM_DB_NAME' AND table_name='Monitors';")

if [ "$TABLE_CHECK" -eq 0 ]; then
  echo "🛠 loading ZoneMinder schema (Monitor table missing)…"
  pv /usr/share/zoneminder/db/zm_create.sql \
    | mysql --force --host="$ZM_DB_HOST" --user="$ZM_DB_USER" --password="$ZM_DB_PASS" \
    "$ZM_DB_NAME"
  echo "🛠 loading ZoneMinder schema (Monitor table missing)… done."
  echo "🔐 granting ZoneMinder user privileges…"
  mysql --host="$ZM_DB_HOST" \
    -u root -p"$ZM_DB_ROOT_PASS" \
    -e "GRANT LOCK TABLES,ALTER,DROP,SELECT,INSERT,UPDATE,CREATE,INDEX,\
        ALTER ROUTINE,CREATE ROUTINE,TRIGGER,EXECUTE,REFERENCES \
        ON \`$ZM_DB_NAME\`.* TO '$ZM_DB_USER'@'%' IDENTIFIED BY '$ZM_DB_PASS';"
  echo "🔐 granting ZoneMinder user privileges… done."
fi

exec php-fpm8.1 --nodaemonize
EOF

RUN \
  chmod +x /usr/local/bin/docker-entrypoint.sh && \
  ls -al /usr/local/bin/docker-entrypoint.sh && \
  mkdir -p /run/php

# 6) Runtime ENV (override at docker run)
ENV TZ=UTC \
    ZM_DB_HOST=db \
    ZM_DB_NAME=zm \
    ZM_DB_USER=zmuser \
    ZM_DB_PASS=zmpass \
    ZM_DB_ROOT_PASS=rootpass

VOLUME ["/var/cache/zoneminder","/var/log/zoneminder","/etc/zm"]
EXPOSE 9000

ENTRYPOINT ["/usr/local/bin/docker-entrypoint.sh"]
CMD ["php-fpm8.1","--nodaemonize"]
