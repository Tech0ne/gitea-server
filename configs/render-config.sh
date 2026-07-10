#!/bin/sh
# Rendered by the `config-init` service. Turns instance.ini.tmpl into the real
# /etc/gitea/app.ini, filling @@PLACEHOLDER@@ tokens from settings.env values
# (passed as env) and from generated, persisted secret keys.
#
# Substitution is done with awk using ENVIRON (literal replacement) so that
# arbitrary values — passwords with & | \ etc. — are inserted byte-for-byte.
set -eu

SEC=/etc/gitea/secrets
OUT=/etc/gitea/app.ini
TMPL=/tmpl/instance.ini.tmpl

mkdir -p "$SEC"

# Generate each secret once, then reuse it forever (persisted in gitea_config).
# Losing SECRET_KEY would make encrypted data unreadable — never regenerate one.
gen() {  # gen <file> <gitea-secret-kind>
    if [ ! -s "$SEC/$1" ]; then
        gitea generate secret "$2" > "$SEC/$1"
    fi
}
gen SECRET_KEY        SECRET_KEY
gen INTERNAL_TOKEN    INTERNAL_TOKEN
gen OAUTH2_JWT_SECRET JWT_SECRET
gen LFS_JWT_SECRET    JWT_SECRET

cp "$TMPL" "$OUT"

# Values to inject, exported so awk can read them literally via ENVIRON.
export V_APP_NAME="${APP_NAME}"
export V_DB_NAME="${POSTGRES_DB}"
export V_DB_USER="${POSTGRES_USER}"
export V_DB_PASSWD="${POSTGRES_PASSWORD}"
export V_DOMAIN="${GITEA_DOMAIN}"
export V_ROOT_URL="${GITEA_ROOT_URL}"
export V_DISABLE_REGISTER="${GITEA_DISABLE_REGISTER}"
export V_SSH_PORT="${SSH_PORT}"
export V_SECRET_KEY="$(cat "$SEC/SECRET_KEY")"
export V_INTERNAL_TOKEN="$(cat "$SEC/INTERNAL_TOKEN")"
export V_OAUTH2_JWT_SECRET="$(cat "$SEC/OAUTH2_JWT_SECRET")"
export V_LFS_JWT_SECRET="$(cat "$SEC/LFS_JWT_SECRET")"

subst() {  # subst <PLACEHOLDER> <ENV_VAR_NAME>   (literal, no regex interpretation)
    awk -v ph="@@$1@@" -v envkey="$2" '
        BEGIN { val = ENVIRON[envkey] }
        {
            s = $0; out = ""
            while ((p = index(s, ph)) > 0) {
                out = out substr(s, 1, p - 1) val
                s = substr(s, p + length(ph))
            }
            print out s
        }
    ' "$OUT" > "$OUT.tmp" && mv "$OUT.tmp" "$OUT"
}

for name in APP_NAME DB_NAME DB_USER DB_PASSWD DOMAIN ROOT_URL DISABLE_REGISTER SSH_PORT \
            SECRET_KEY INTERNAL_TOKEN OAUTH2_JWT_SECRET LFS_JWT_SECRET; do
    subst "$name" "V_$name"
done

# Fail loudly if any real placeholder was left behind (ignore ; comment lines).
LEFT=$(grep -n '@@' "$OUT" | grep -vE '^[0-9]+:[[:space:]]*;' || true)
if [ -n "$LEFT" ]; then
    echo "config-init: ERROR — unrendered placeholders remain:" >&2
    printf '%s\n' "$LEFT" >&2
    exit 1
fi

# rootless Gitea runs as uid 1000 and must read/write these files
chown -R 1000:1000 /etc/gitea
echo "config-init: rendered /etc/gitea/app.ini"
