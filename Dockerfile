# syntax=docker/dockerfile:1.4
FROM ubuntu:22.04

ENV DEBIAN_FRONTEND=noninteractive \
    TZ=UTC

# 1) Add ZoneMinder PPA (rarely changes)
RUN apt-get update \
 && apt-get install -y software-properties-common \
 && add-apt-repository -y ppa:iconnor/zoneminder-1.36

# 2) Install standard deps (php‑fpm, MariaDB client, mysql-client)
RUN apt-get install -y --no-install-recommends \
      php-fpm \
      mariadb-client

# 3) Install ZoneMinder (last install step)
RUN apt-get install -y --no-install-recommends zoneminder

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

# 5) Embed entrypoint via heredoc (BuildKit required)
COPY <<EOF /usr/local/bin/docker-entrypoint.sh
#!/bin/sh
set -e

: "\${ZM_DB_HOST:=db}"
: "\${ZM_DB_NAME:=zm}"
: "\${ZM_DB_USER:=zmuser}"
: "\${ZM_DB_PASS:=zmpass}"

until mysqladmin -h"\$ZM_DB_HOST" -u"\$ZM_DB_USER" -p"\$ZM_DB_PASS" ping; do
  echo "waiting for DB at \$ZM_DB_HOST…"
  sleep 2
done

if ! mysqlshow -h"\$ZM_DB_HOST" -u"\$ZM_DB_USER" -p"\$ZM_DB_PASS" "\$ZM_DB_NAME" ; then
  echo "🛠 initializing ZoneMinder schema…"
  mysql -h"\$ZM_DB_HOST" -u"\$ZM_DB_USER" -p"\$ZM_DB_PASS" \
    -e "CREATE DATABASE IF NOT EXISTS \`\$ZM_DB_NAME\`;"
  mysql -h"\$ZM_DB_HOST" -u"\$ZM_DB_USER" -p"\$ZM_DB_PASS" \
    "\$ZM_DB_NAME" < /usr/share/zoneminder/db/zm_create.sql
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
    ZM_DB_PASS=zmpass

VOLUME ["/var/cache/zoneminder","/var/log/zoneminder","/etc/zm"]
EXPOSE 9000

ENTRYPOINT ["/usr/local/bin/docker-entrypoint.sh"]
CMD ["php-fpm8.1","--nodaemonize"]
