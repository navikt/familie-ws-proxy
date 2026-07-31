# finn ny tag her: https://hub.docker.com/r/openresty/openresty/tags
FROM openresty/openresty:1.31.1.1-2-alpine-fat

ARG UID=101
ARG GID=101

RUN set -x \
    && addgroup -g $GID -S nginx \
    && adduser -S -D -H -u $UID -h /var/cache/nginx -s /sbin/nologin -G nginx -g nginx nginx

# nginx-brukeren må eie cache- og etc-katalogen for å kunne skrive cache og justere nginx-konfigurasjonen
RUN set -x \
    && sed -i 's,#pid,pid,' /usr/local/openresty/nginx/conf/nginx.conf \
    && sed -i 's,logs/nginx.pid,/tmp/nginx.pid,' /usr/local/openresty/nginx/conf/nginx.conf \
    && sed -i 's,/var/run/openresty/nginx-client-body,/tmp/client_temp,' /usr/local/openresty/nginx/conf/nginx.conf \
    && sed -i 's,/var/run/openresty/nginx-proxy,/tmp/proxy_temp,' /usr/local/openresty/nginx/conf/nginx.conf \
    && sed -i 's,/var/run/openresty/nginx-fastcgi,/tmp/fastcgi_temp,' /usr/local/openresty/nginx/conf/nginx.conf \
    && sed -i 's,/var/run/openresty/nginx-uwsgi,/tmp/uwsgi_temp,' /usr/local/openresty/nginx/conf/nginx.conf \
    && sed -i 's,/var/run/openresty/nginx-scgi,/tmp/scgi_temp,' /usr/local/openresty/nginx/conf/nginx.conf \
    && chown -R $UID:0 /usr/local/openresty/nginx \
    && chmod -R g+w /usr/local/openresty/nginx \
    && chown -R $UID:0 /etc/nginx \
    && chmod -R g+w /etc/nginx

RUN /usr/local/openresty/luajit/bin/luarocks install lua-resty-openidc

# for å tillate lua-script å få tak i spesifikke miljøvariabler
RUN echo "env AZURE_APP_WELL_KNOWN_URL;" >> /usr/local/openresty/nginx/conf/nginx.conf \
    && echo "env AZURE_APP_CLIENT_ID;" >> /usr/local/openresty/nginx/conf/nginx.conf \
    && echo "env HTTP_PROXY;" >> /usr/local/openresty/nginx/conf/nginx.conf \
    && echo "env HTTPS_PROXY;" >> /usr/local/openresty/nginx/conf/nginx.conf \
    && echo "env NO_PROXY;" >> /usr/local/openresty/nginx/conf/nginx.conf \
    && echo "env STS_BASE_URL;" >> /usr/local/openresty/nginx/conf/nginx.conf \
    && echo "env CICS_BASE_URL;" >> /usr/local/openresty/nginx/conf/nginx.conf

COPY proxy.conf /etc/nginx/conf.d/default.conf
COPY jwt.lua /usr/local/openresty/nginx/

USER $UID
