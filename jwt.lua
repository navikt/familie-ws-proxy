-- =============================================================================
-- Autentisering for familie-ws-proxy.
--
-- Kjøres av `access_by_lua_file jwt.lua` i proxy.conf for hver innkommende
-- request som når access-fasen. Formålet er å slippe gjennom kun kall fra
-- applikasjoner som har et gyldig Azure AD-token utstedt for denne proxyen.
--
-- Proxyen står i FSS og eksponeres på et *-fss-pub.nais.io-ingress, som er
-- åpent utenfor klusteret. Nais sin accessPolicy alene er derfor ikke nok -
-- token-validering her er den faktiske sikkerhetsmekanismen.
-- =============================================================================

local opts = {
    -- Azure sitt well-known-endepunkt. Herfra hentes issuer og de offentlige
    -- nøklene som brukes til å verifisere signaturen. Resultatet caches av
    -- lua-resty-openidc, så dette gjøres ikke ved hvert kall.
    discovery = os.getenv("AZURE_APP_WELL_KNOWN_URL"),

    -- Vi godtar kun RS256, som er det Azure AD signerer med.
    token_signing_alg_values_expected = { "RS256" },

    -- Avviser usignerte token ("alg": "none"). Uten dette kunne hvem som helst
    -- laget et token vi ville stolt på.
    accept_none_alg = false,

    -- Tokenet leses fra X-Proxy-Authorization i stedet for standard
    -- Authorization-header. To grunner:
    --   1) Java sin HttpClient fjerner Proxy-Authorization automatisk på alle
    --      HTTPS-tilkoblinger, så den kan ikke brukes.
    --   2) Authorization-headeren må holdes fri, fordi klienten bruker den til
    --      basic auth mot STS - den skal videresendes uendret.
    auth_accept_token_as_header_name = "X-Proxy-Authorization",

    -- FSS har ikke direkte internettilgang, så oppslaget mot Azure sitt
    -- well-known-endepunkt må gå via webproxy-nais.
    proxy_opts = {
        http_proxy  = os.getenv("HTTP_PROXY"),
        https_proxy = os.getenv("HTTPS_PROXY"),
        no_proxy = os.getenv("NO_PROXY")
    }
}

-- Verifiserer signatur, utløpstid (exp) og issuer. Returnerer innholdet
-- (claims) i tokenet ved suksess.
local res, err = require("resty.openidc").bearer_jwt_verify(opts)

if err or not res then
    ngx.status = 403
    ngx.say(err and err or "ingen access_token oppgitt")
    ngx.exit(ngx.HTTP_FORBIDDEN)
end

-- Logger hvilken applikasjon som kaller (sub er client-id-en til kalleren).
-- Krever error_log-nivå `notice`, som er satt i proxy.conf.
ngx.log(ngx.NOTICE, "tilkobling fra " .. res.sub)

-- bearer_jwt_verify sjekker signaturen, men ikke at tokenet faktisk er utstedt
-- *for oss*. Uten denne sjekken ville et hvilket som helst gyldig Azure-token
-- fra en annen applikasjon i samme tenant blitt godtatt.
if res.aud ~= os.getenv("AZURE_APP_CLIENT_ID") then
    ngx.status = 403
    ngx.say("token har feil aud ", res.aud)
    ngx.exit(ngx.HTTP_FORBIDDEN)
end

-- Videresender hvem kalleren er til nedstrøms tjeneste og til access-loggen.
-- Selve tokenet sendes ikke videre.
ngx.req.set_header("X-Azure-Client-Id", res.sub)
ngx.req.set_header("X-Azure-Azp-Name", res.azp_name)
