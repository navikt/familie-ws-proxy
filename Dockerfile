# =============================================================================
# familie-ws-proxy
#
# Bygger et OpenResty-image (nginx + innebygd LuaJIT). Nginx står for selve
# proxyingen, mens Lua brukes til å validere Azure AD-token før requesten
# slippes videre inn til FSS-tjenestene.
#
# Vi bruker "alpine-fat"-varianten fordi den inneholder byggeverktøy og
# `luarocks`, som vi trenger for å installere lua-resty-openidc.
# Finn ny tag her: https://hub.docker.com/r/openresty/openresty/tags
# =============================================================================
FROM openresty/openresty:1.31.1.1-2-alpine-fat

# Installer tilgjengelige sikkerhetsoppdateringer fra Alpine-repositoriene.
RUN apk upgrade --no-cache

# Nais krever at containeren kjører som en ikke-root-bruker.
# 101 er den vanlige uid/gid-en for nginx.
ARG UID=101
ARG GID=101

# Oppretter nginx-brukeren som prosessen skal kjøre som.
# -S = systembruker, -D = uten passord, -H = uten hjemmekatalog,
# -s /sbin/nologin = kan ikke logge inn interaktivt.
RUN set -x \
    && addgroup -g $GID -S nginx \
    && adduser -S -D -H -u $UID -h /var/cache/nginx -s /sbin/nologin -G nginx -g nginx nginx

# Containeren kjører som ikke-root, og standard-nginx.conf peker pid-fil og
# temp-kataloger til steder under /var/run som brukeren vår ikke får skrive til.
# Vi flytter derfor alt til /tmp. Første sed-linje avkommenterer `pid`-direktivet
# slik at den etterfølgende erstatningen av pid-stien faktisk får effekt.
#
# Til slutt gir vi uid-en vår eierskap (og gruppa skrivetilgang) til
# nginx-katalogene, slik at nginx kan skrive logger og laste konfigurasjon.
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

# lua-resty-openidc gir oss OIDC/JWT-støtte i Lua. Vi bruker den i jwt.lua til å
# hente Azure sine signeringsnøkler fra well-known-endepunktet og verifisere
# tokenet i innkommende requests.
RUN /usr/local/openresty/luajit/bin/luarocks install lua-resty-openidc

# Lua-kode kan kun lese miljøvariabler som er eksplisitt deklarert med
# `env`-direktivet i nginx.conf - ellers returnerer os.getenv() nil.
# Derfor må hver variabel vi bruker i jwt.lua og proxy.conf listes opp her.
#
#   AZURE_APP_WELL_KNOWN_URL / AZURE_APP_CLIENT_ID
#       Injiseres av nais når `azure.application.enabled: true`. Brukes til å
#       validere signatur og `aud` på innkommende token.
#   HTTP_PROXY / HTTPS_PROXY / NO_PROXY
#       FSS har ikke direkte internettilgang, så oppslag mot Azure sitt
#       well-known-endepunkt må gå via webproxy-nais.
#   STS_BASE_URL / CICS_BASE_URL
#       Hvilke on-prem-tjenester vi videresender til. Settes per miljø i
#       .nais/app-dev.yaml og .nais/app-prod.yaml.
RUN echo "env AZURE_APP_WELL_KNOWN_URL;" >> /usr/local/openresty/nginx/conf/nginx.conf \
    && echo "env AZURE_APP_CLIENT_ID;" >> /usr/local/openresty/nginx/conf/nginx.conf \
    && echo "env HTTP_PROXY;" >> /usr/local/openresty/nginx/conf/nginx.conf \
    && echo "env HTTPS_PROXY;" >> /usr/local/openresty/nginx/conf/nginx.conf \
    && echo "env NO_PROXY;" >> /usr/local/openresty/nginx/conf/nginx.conf \
    && echo "env STS_BASE_URL;" >> /usr/local/openresty/nginx/conf/nginx.conf \
    && echo "env CICS_BASE_URL;" >> /usr/local/openresty/nginx/conf/nginx.conf

# conf.d/default.conf lastes automatisk av standard-nginx.conf.
COPY proxy.conf /etc/nginx/conf.d/default.conf

# jwt.lua legges i nginx sin arbeidskatalog, slik at `access_by_lua_file jwt.lua`
# i proxy.conf finner den via relativ sti.
COPY jwt.lua /usr/local/openresty/nginx/

USER $UID
