ARG FRANKENPHP_VERSION="latest"
FROM dunglas/frankenphp:${FRANKENPHP_VERSION} AS builder

ARG SUPERCRONIC_VERSION="v0.2.49"
ARG PHP_EXTENSIONS="@composer gd pdo_pgsql pdo_mysql opcache apcu redis zip ftp simplexml pcntl excimer"
RUN <<-EOF
    install-php-extensions ${PHP_EXTENSIONS} && \
    rm -f /usr/local/etc/php/conf.d/docker-php-ext-excimer.ini && \
    apt-get update && \
    apt-get install -yqq --no-install-recommends libtree tini curl
    curl -fsSL "https://github.com/aptible/supercronic/releases/download/${SUPERCRONIC_VERSION}/supercronic-linux-amd64" -o /usr/bin/supercronic && \
    chmod +x /usr/bin/supercronic && \
    mkdir -p /etc/supercronic /etc/crontabs/ /tmp/libs && \
    echo "*/1 * * * * php /app/artisan schedule:run --no-interaction" > /etc/crontabs/www-data && \
	for target in $(which frankenphp) \
		$(find "$(php -r 'echo ini_get("extension_dir");')" -maxdepth 2 -name "*.so"); do
		libtree -pv "$target" 2>/dev/null | grep -oP '(?:── )\K/\S+(?= \[)' | while IFS= read -r lib; do
			[ -f "$lib" ] && cp -n "$lib" /tmp/libs/
		done
	done
EOF

RUN usermod -u 1000 www-data

COPY ./example.Caddyfile /etc/caddy/Caddyfile
RUN chown -R www-data:www-data /data/caddy /config/caddy

# runtime image based on debian-slim
FROM debian:trixie-slim

ENV WITH_QUEUE=false
ENV WITH_SCHEDULER=false
ENV ARTISAN_CACHE=false
ENV OCTANE_SERVER=frankenphp
ENV CADDYFILE='/etc/caddy/Caddyfile'
ENV QUEUE_WORKER_NUMBER=3
ENV XDG_CONFIG_HOME=/config
ENV XDG_DATA_HOME=/data
ENV GODEBUG=cgocheck=0
ENV APP_BASE_PATH=/app
ENV APP_PUBLIC_PATH=/app/public
ENV LARAVEL_OCTANE=1

RUN usermod -u 1000 www-data \
    && mkdir -p /startup /config/caddy /data/caddy \
    && chown -R www-data:www-data /startup /config/caddy /data/caddy \
    && apt-get update \
    && apt-get install -yqq --no-install-recommends ca-certificates \
    && apt-get purge -y --allow-remove-essential perl-base \
    && apt-get autoremove -y \
    && apt-get clean \
    && rm -rf /var/lib/apt/lists/* /tmp/* /var/tmp/*

COPY --from=builder /usr/local/bin/frankenphp /usr/local/bin/frankenphp
COPY --from=builder /usr/local/bin/php /usr/local/bin/php
COPY --from=builder /usr/local/lib/php/extensions /usr/local/lib/php/extensions
COPY --from=builder /usr/local/bin/compose[r] /usr/local/bin/composer
COPY --from=builder /tmp/libs /usr/lib
COPY --from=builder /usr/local/etc/php/conf.d /usr/local/etc/php/conf.d
COPY --from=builder /usr/local/etc/php/php.ini-production /usr/local/etc/php/php.ini
COPY --from=builder /usr/bin/supercronic /usr/bin/supercronic
COPY --from=builder /etc/crontabs/www-data /etc/crontabs/www-data
COPY --from=builder /etc/caddy/Caddyfile /etc/caddy/Caddyfile
COPY --from=builder /usr/bin/tini /usr/bin/tini
COPY --from=builder /usr/bin/curl /usr/bin/curl

COPY --chown=www-data:www-data ./tini.sh /startup/tini.sh
RUN chmod +x /startup/tini.sh

RUN mkdir -p /app && chown -R www-data:www-data /app /etc/crontabs/www-data

USER www-data

WORKDIR /app

ENTRYPOINT ["tini", "-s", "--", "/startup/tini.sh"]
