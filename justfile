# Gitea stack — all config lives in .env (cp .env.example .env)

alias c := check
alias u := up
alias d := down
alias p := ps
alias l := logs
alias b := backup
alias r := restore

set dotenv-load := false

lib := "JUST='" + just_executable() + "'\nJF='" + justfile() + "'\nROOT='" + justfile_directory() + "'\n" + '''
set -euo pipefail
ENV_FILE="$ROOT/.env"

log(){ echo "[$(date '+%F %T')] $*"; }
warn(){ echo "''' + style("warning") + '''WARN''' + NORMAL + ''': $*" >&2; }
die(){ echo "''' + style("error") + '''error''' + NORMAL + ''': $*" >&2; exit 1; }

# Re-exec this recipe as root
as_root(){ [[ -r /var/run/docker.sock ]] || exec sudo "$JUST" -f "$JF" "$@"; }

# .env parser (values may contain spaces: APP_NAME, BACKUP_SCHEDULE)
load_env(){
  local f="${1:-$ENV_FILE}" line k v
  [ -f "$f" ] || die "$f not found (cp .env.example .env)"
  while IFS= read -r line || [ -n "$line" ]; do
    line="${line%$'\r'}"
    [[ "$line" =~ ^[[:space:]]*(#|$) ]] && continue
    [[ "$line" =~ ^[[:space:]]*([A-Za-z_][A-Za-z0-9_]*)=(.*)$ ]] || continue
    k="${BASH_REMATCH[1]}"; v="${BASH_REMATCH[2]}"
    if [[ "$v" =~ ^\"(.*)\"$ ]] || [[ "$v" =~ ^\'(.*)\'$ ]]; then v="${BASH_REMATCH[1]}"; fi
    export "$k=$v"
  done < "$f"
}
get_env(){ sed -n "s/^$2=//p" "$1" | tail -1 | sed -e 's/^"\(.*\)"$/\1/' -e "s/^'\(.*\)'$/\1/"; }
set_env(){ # <key> <value> [file]  (keeps owner/perms)
  local k=$1 v=$2 f="${3:-$ENV_FILE}" tmp; tmp="$(mktemp)"
  if grep -q "^$k=" "$f"; then
    awk -v k="$k" -v v="$v" 'index($0, k"=")==1 {print k"="v; next} {print}' "$f" > "$tmp"
  else
    cat "$f" > "$tmp"; printf '%s=%s\n' "$k" "$v" >> "$tmp"
  fi
  cat "$tmp" > "$f"; rm -f "$tmp"; export "$k=$v"
}
gen_secret(){ openssl rand -hex "${1:-32}"; }

dc(){ docker compose --project-directory "$ROOT" -f "$ROOT/compose.yaml" --env-file "$ENV_FILE" "$@"; }
service_exists(){ [ -f "/etc/systemd/system/${SERVICE_NAME}.service" ]; }
service_active(){ systemctl is-active --quiet "${SERVICE_NAME}.service" 2>/dev/null; }
running(){ [ -n "$(dc ps -q --status running "$1" 2>/dev/null)" ]; }

do_check(){
  load_env || die "failed to parse .env file. did you create it ?"
  local ERR=0 k name len v l labels
  err(){ echo "  x $*" >&2; ERR=1; }
  command -v openssl >/dev/null || die "openssl not installed"
  for k in GITEA_SECRET_KEY:32 GITEA_INTERNAL_TOKEN:32 RUNNER_REGISTRATION_TOKEN:24 POSTGRES_PASSWORD:16 ADMIN_PASSWORD:10; do
    name=${k%%:*}; len=${k##*:}
    if [ -z "${!name:-}" ]; then
      set_env "$name" "$(gen_secret "$len")"; echo "  + generated $name"
      [ "$name" = ADMIN_PASSWORD ] && echo "    admin password: $ADMIN_PASSWORD  (stored in .env)"
    fi
  done
  if [ "${RUNNER_ENABLED:-}" = true ]; then set_env COMPOSE_PROFILES runner; else set_env COMPOSE_PROFILES ""; fi

  for v in INSTALL_DIR DATA_DIR SERVICE_NAME GITEA_VERSION POSTGRES_VERSION RUNNER_VERSION APP_NAME DOMAIN \
           HTTP_PORT SSH_PORT ROOT_URL TZ USER_UID USER_GID ADMIN_USER ADMIN_EMAIL POSTGRES_DB POSTGRES_USER; do
    [ -n "${!v:-}" ] || err "$v is empty"
  done
  for v in DISABLE_REGISTRATION REQUIRE_SIGNIN_VIEW RUNNER_ENABLED; do
    [[ "${!v:-}" =~ ^(true|false)$ ]] || err "$v must be true or false (got '${!v:-}')"
  done
  for v in HTTP_PORT SSH_PORT USER_UID USER_GID RUNNER_CAPACITY BACKUP_KEEP; do
    [[ "${!v:-}" =~ ^[0-9]+$ ]] || err "$v must be a number (got '${!v:-}')"
  done
  for v in HTTP_PORT SSH_PORT; do
    if [[ "${!v:-}" =~ ^[0-9]+$ ]] && { [ "${!v}" -lt 1 ] || [ "${!v}" -gt 65535 ]; }; then err "$v out of range"; fi
  done
  [ "${HTTP_PORT:-}" != "${SSH_PORT:-}" ] || err "HTTP_PORT and SSH_PORT are identical"
  [[ "${INSTALL_DIR:-}" = /* ]] || err "INSTALL_DIR must be an absolute path"
  [[ "${DATA_DIR:-}" = /* ]] || err "DATA_DIR must be an absolute path"
  [[ "${SERVICE_NAME:-}" =~ ^[A-Za-z0-9_-]+$ ]] || err "SERVICE_NAME: letters, digits, - and _ only"
  [[ "${ROOT_URL:-}" =~ ^https?://[^/]+(/.*)?/$ ]] || err "ROOT_URL must look like http(s)://host[:port]/ (trailing slash)"
  [[ "${ROOT_URL:-}" == *"${DOMAIN:-}"* ]] || warn "ROOT_URL doesn't contain DOMAIN ($DOMAIN), intended?"
  [[ "${ADMIN_USER:-}" =~ ^[A-Za-z0-9_.-]+$ ]] || err "ADMIN_USER: letters, digits, _ . - only"
  [ "${ADMIN_USER,,}" != admin ] || err "ADMIN_USER 'admin' is reserved by Gitea, pick another name"
  [[ "${ADMIN_EMAIL:-}" =~ ^[^@[:space:]]+@[^@[:space:]]+$ ]] || err "ADMIN_EMAIL is not an email"
  [ ${#ADMIN_PASSWORD} -ge 8 ] || err "ADMIN_PASSWORD must be >= 8 chars"
  [ ${#POSTGRES_PASSWORD} -ge 8 ] || err "POSTGRES_PASSWORD must be >= 8 chars"
  if [ "${RUNNER_ENABLED:-}" = true ]; then
    [ "${RUNNER_CAPACITY:-0}" -ge 1 ] 2>/dev/null || err "RUNNER_CAPACITY must be >= 1"
    [ -n "${RUNNER_NAME:-}" ] || err "RUNNER_NAME is empty"
    IFS=',' read -ra labels <<< "${RUNNER_LABELS:-}"
    [ ${#labels[@]} -gt 0 ] || err "RUNNER_LABELS is empty"
    for l in "${labels[@]}"; do
      l="$(echo "$l" | xargs)"
      [[ "$l" =~ ^[A-Za-z0-9_.-]+(:(host|docker://.+))?$ ]] || err "bad runner label '$l' (name:docker://image or name:host)"
    done
  fi
  if [ -n "${BACKUP_SCHEDULE:-}" ] && [ "$(wc -w <<< "$BACKUP_SCHEDULE")" -ne 5 ]; then err "BACKUP_SCHEDULE must have 5 cron fields"; fi
  [ -e "/usr/share/zoneinfo/${TZ:-}" ] || warn "TZ '${TZ:-}' not found in /usr/share/zoneinfo"
  command -v docker >/dev/null || err "docker not installed"
  docker compose version >/dev/null 2>&1 || err "docker compose plugin not installed"
  [ $ERR = 0 ] || die "invalid configuration, fix $ENV_FILE"
  dc config -q || die "docker compose config invalid"
  echo "  ok config valid"
}

prepare_data(){
  mkdir -p "$DATA_DIR/gitea" "$DATA_DIR/postgres" "$DATA_DIR/runner"
  chown "$USER_UID:$USER_GID" "$DATA_DIR/gitea"
  [ "$RUNNER_ENABLED" = true ] || return 0
  local l
  {
    echo "# Generated from .env by just, do not edit"
    echo "log:"
    echo "  level: info"
    echo "runner:"
    echo "  file: .runner"
    echo "  capacity: $RUNNER_CAPACITY"
    echo "  timeout: 3h"
    echo "  labels:"
    IFS=',' read -ra labels <<< "$RUNNER_LABELS"
    for l in "${labels[@]}"; do
        echo "    - \"$(echo "$l" | xargs)\""
    done
    echo "cache:"
    echo "  enabled: true"
    echo "container:"
    echo "  network: gitea-net"
    echo "  privileged: false"
  } > "$DATA_DIR/runner/config.yaml"
}

wait_healthy(){ # <service> [timeout s]
  local svc=$1 t=${2:-300} cid st i
  for ((i=0; i<t; i+=3)); do
    cid="$(dc ps -q "$svc" 2>/dev/null || true)"
    if [ -n "$cid" ]; then
      st="$(docker inspect -f '{{if .State.Health}}{{.State.Health.Status}}{{else}}{{.State.Status}}{{end}}' "$cid" 2>/dev/null || true)"
      [ "$st" = healthy ] && return 0
    fi
    sleep 3
  done
  die "$svc not healthy after ${t}s (check: just logs $svc)"
}

ensure_admin(){
  wait_healthy gitea
  local users; users="$(dc exec -T -u git gitea gitea admin user list | awk 'NR>1{print $2}')"
  if grep -qxF "$ADMIN_USER" <<< "$users"; then
    log "Admin '$ADMIN_USER' already exists"
  else
    [ -n "${ADMIN_PASSWORD:-}" ] || die "ADMIN_PASSWORD empty and admin user doesn't exist yet"
    log "Creating admin '$ADMIN_USER'"
    dc exec -T -u git gitea gitea admin user create --admin \
      --username "$ADMIN_USER" --password "$ADMIN_PASSWORD" --email "$ADMIN_EMAIL" \
      --must-change-password=false >/dev/null
  fi
}
'''

[doc("list recipes")]
default:
    @"{{ just_executable() }}" -f "{{ justfile() }}" --list

[doc("validate .env (generates missing secrets into it)")]
check:
    #!/usr/bin/env bash
    {{ lib }}
    as_root {{ recipe_name() }}
    do_check

[doc("run the stack from this folder, no install (testing)")]
up:
    #!/usr/bin/env bash
    {{ lib }}
    as_root {{ recipe_name() }}
    do_check
    service_active && die "service ${SERVICE_NAME} is running, stop it first (systemctl stop ${SERVICE_NAME})"
    prepare_data
    dc up -d --remove-orphans
    ensure_admin
    log "Up: $ROOT_URL  (admin: $ADMIN_USER)"

[doc("stop the stack started with `just up`")]
down:
    #!/usr/bin/env bash
    {{ lib }}
    as_root {{ recipe_name() }}
    load_env
    service_active && die "stack is managed by systemd: systemctl stop ${SERVICE_NAME}"
    dc down

[doc("container status")]
ps:
    #!/usr/bin/env bash
    {{ lib }}
    as_root {{ recipe_name() }}
    load_env
    dc ps

[doc("follow logs (optionally one service: just logs gitea)")]
logs *svc:
    #!/usr/bin/env bash
    {{ lib }}
    as_root {{ recipe_name() }} {{ svc }}
    load_env
    dc logs -f --tail 100 {{ svc }}

[doc("install to INSTALL_DIR as a systemd service (rerun after editing .env)")]
install:
    #!/usr/bin/env bash
    {{ lib }}
    as_root {{ recipe_name() }}
    command -v systemctl >/dev/null || die "systemd required"
    do_check

    log "Installing to $INSTALL_DIR"
    mkdir -p "$INSTALL_DIR"
    if [ "$ROOT" != "$(cd "$INSTALL_DIR" && pwd)" ]; then
      install -m 644 "$ROOT/compose.yaml" "$ROOT/justfile" "$INSTALL_DIR/"
      [ -f "$ROOT/.env.example" ] && install -m 644 "$ROOT/.env.example" "$INSTALL_DIR/"
      install -m 600 "$ROOT/.env" "$INSTALL_DIR/.env"
      ROOT="$INSTALL_DIR"; ENV_FILE="$ROOT/.env"
    fi
    chmod 600 "$ENV_FILE"
    prepare_data

    log "Pulling images (can take a while on a Pi)"
    dc pull --quiet

    DOCKER="$(command -v docker)"
    UNIT="/etc/systemd/system/${SERVICE_NAME}.service"
    log "Writing $UNIT"
    cat > "$UNIT" <<EOF
    [Unit]
    Description=Gitea stack (gitea + postgres + runner) via docker compose
    Requires=docker.service
    After=docker.service network-online.target
    Wants=network-online.target

    [Service]
    Type=simple
    WorkingDirectory=$INSTALL_DIR
    ExecStart=$DOCKER compose up --remove-orphans
    ExecStop=$DOCKER compose down -t3
    Restart=on-failure
    RestartSec=10
    TimeoutStartSec=0
    TimeoutStopSec=120

    [Install]
    WantedBy=multi-user.target
    EOF

    systemctl daemon-reload
    systemctl enable "${SERVICE_NAME}.service" >/dev/null
    dc down >/dev/null 2>&1 || true
    systemctl restart "${SERVICE_NAME}.service"
    ensure_admin
    log "Installed: $ROOT_URL  admin: $ADMIN_USER"
    log "Manage: systemctl status|restart ${SERVICE_NAME}, logs: journalctl -u ${SERVICE_NAME} -f"
    log "Live config is now $INSTALL_DIR/.env"

[doc("remove the systemd service (keeps data and INSTALL_DIR)")]
uninstall:
    #!/usr/bin/env bash
    {{ lib }}
    as_root {{ recipe_name() }}
    load_env
    systemctl disable --now "${SERVICE_NAME}.service" 2>/dev/null || true
    rm -f "/etc/systemd/system/${SERVICE_NAME}.service"
    systemctl daemon-reload
    log "Service removed. Data kept in $DATA_DIR, files in $INSTALL_DIR"

[doc("add the scheduled backup cron job (needs `just install` first)")]
install-backup:
    #!/usr/bin/env bash
    {{ lib }}
    as_root {{ recipe_name() }}
    load_env
    [ -f "$INSTALL_DIR/justfile" ] || die "stack not installed in $INSTALL_DIR, run 'just install' first"
    [ -n "${BACKUP_SCHEDULE:-}" ] && [ -n "${BACKUP_DIR:-}" ] || die "BACKUP_SCHEDULE / BACKUP_DIR empty in .env"
    [ -d /etc/cron.d ] || die "/etc/cron.d missing, install cron (apt install cron)"
    [ "$ROOT" != "$INSTALL_DIR" ] && install -m 600 "$ENV_FILE" "$INSTALL_DIR/.env"
    CRON="/etc/cron.d/${SERVICE_NAME}-backup"
    cat > "$CRON" <<EOF
    SHELL=/bin/bash
    PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
    $BACKUP_SCHEDULE root $JUST -f $INSTALL_DIR/justfile backup >> /var/log/${SERVICE_NAME}-backup.log 2>&1
    EOF
    chmod 644 "$CRON"
    cat > "/etc/logrotate.d/${SERVICE_NAME}-backup" <<EOF
    /var/log/${SERVICE_NAME}-backup.log {
      monthly
      rotate 6
      compress
      missingok
      notifempty
    }
    EOF
    log "Cron installed: '$BACKUP_SCHEDULE' -> $BACKUP_DIR (keep $BACKUP_KEEP). Log: /var/log/${SERVICE_NAME}-backup.log"
    if [ -n "${BACKUP_MOUNTPOINT:-}" ] && ! mountpoint -q "$BACKUP_MOUNTPOINT"; then warn "$BACKUP_MOUNTPOINT is not mounted right now"; fi

[doc("remove the scheduled backup cron job (existing backups untouched)")]
uninstall-backup:
    #!/usr/bin/env bash
    {{ lib }}
    as_root {{ recipe_name() }}
    load_env
    rm -f "/etc/cron.d/${SERVICE_NAME}-backup" "/etc/logrotate.d/${SERVICE_NAME}-backup"
    log "Backup cron removed"

[doc("backup now into DEST/<timestamp>. No DEST = scheduled mode (BACKUP_DIR, mount check, pruning, ping)")]
backup dest="":
    #!/usr/bin/env bash
    {{ lib }}
    as_root {{ recipe_name() }} "{{ dest }}"
    load_env
    DEST="{{ dest }}"; SCHEDULED=0
    [ -z "$DEST" ] && { SCHEDULED=1; DEST="$BACKUP_DIR"; }

    TO_RESTART=""; DB_STARTED=0
    on_exit(){
      local rc=$?
      [ "$DB_STARTED" = 1 ] && { dc stop db >/dev/null 2>&1 || true; }
      [ -n "$TO_RESTART" ] && { log "Restarting $TO_RESTART"; dc start $TO_RESTART || true; }
      if [ $SCHEDULED = 1 ] && [ -n "${BACKUP_HC_URL:-}" ]; then
        if [ $rc = 0 ]; then curl -fsS -m 10 "$BACKUP_HC_URL" >/dev/null || true
        else curl -fsS -m 10 "$BACKUP_HC_URL/fail" >/dev/null || true; fi
      fi
      [ $rc = 0 ] || log "Backup FAILED (exit $rc)"
    }
    trap on_exit EXIT

    if [ $SCHEDULED = 1 ] && [ -n "${BACKUP_MOUNTPOINT:-}" ]; then
      mountpoint -q "$BACKUP_MOUNTPOINT" || die "$BACKUP_MOUNTPOINT not mounted (USB stick plugged in?)"
    fi

    TS="$(date +%Y-%m-%d_%H%M%S)"
    mkdir -p "$DEST"; DEST="$(cd "$DEST" && pwd)"
    rm -rf "$DEST"/*.partial
    TMP="$DEST/$TS.partial"; mkdir -p "$TMP"
    cp "$ENV_FILE" "$TMP/dot.env"; chmod 600 "$TMP/dot.env"
    cp "$ROOT/compose.yaml" "$TMP/"

    for s in gitea runner; do running "$s" && TO_RESTART="$TO_RESTART $s"; done
    TO_RESTART="$(echo $TO_RESTART)"
    [ -n "$TO_RESTART" ] && { log "Stopping $TO_RESTART"; dc stop $TO_RESTART; }
    if ! running db; then log "Starting db for dump"; dc up -d db; DB_STARTED=1; fi
    wait_healthy db 120

    log "Dumping database"
    dc exec -T db sh -c 'pg_dump -U "$POSTGRES_USER" -d "$POSTGRES_DB" -Fc' > "$TMP/gitea-db.dump"
    [ -s "$TMP/gitea-db.dump" ] || die "empty database dump"
    log "Archiving gitea data"
    tar --numeric-owner -czf "$TMP/gitea-data.tar.gz" -C "$DATA_DIR" gitea
    if [ -d "$DATA_DIR/runner" ]; then
      log "Archiving runner data"
      tar --numeric-owner -czf "$TMP/runner-data.tar.gz" -C "$DATA_DIR" runner
    fi

    [ "$DB_STARTED" = 1 ] && { dc stop db >/dev/null; DB_STARTED=0; }
    [ -n "$TO_RESTART" ] && { log "Restarting $TO_RESTART"; dc start $TO_RESTART; TO_RESTART=""; }

    (cd "$TMP" && sha256sum -- * > SHA256SUMS)
    mv "$TMP" "$DEST/$TS"; sync
    if [ $SCHEDULED = 1 ]; then
      log "Pruning, keeping last $BACKUP_KEEP"
      ls -1d "$DEST"/20*/ 2>/dev/null | sort | head -n -"$BACKUP_KEEP" | xargs -r rm -rf
    fi
    log "Done: $DEST/$TS ($(du -sh "$DEST/$TS" | cut -f1)), free: $(df -h --output=avail "$DEST" | tail -1 | xargs)"

[doc("restore a backup dir (current data kept aside in DATA_DIR/.pre-restore-*). Add `-y` to skip the prompt")]
restore src yes="":
    #!/usr/bin/env bash
    {{ lib }}
    as_root {{ recipe_name() }} "{{ src }}" "{{ yes }}"
    load_env
    SRC="{{ src }}"; [ -d "$SRC" ] || die "$SRC is not a directory"
    SRC="$(cd "$SRC" && pwd)"
    for f in gitea-db.dump gitea-data.tar.gz SHA256SUMS dot.env; do [ -f "$SRC/$f" ] || die "$SRC/$f missing, not a backup dir"; done

    log "Verifying checksums"
    (cd "$SRC" && sha256sum -c --quiet SHA256SUMS) || die "checksum mismatch, backup corrupted"
    if [ "{{ yes }}" != -y ]; then
      read -rp "Replace ALL data in $DATA_DIR with $SRC ? [y/N] " a
      [[ "$a" =~ ^[yY]$ ]] || die "aborted"
    fi

    TS="$(date +%Y%m%d%H%M%S)"
    for envf in "$ENV_FILE" "$INSTALL_DIR/.env"; do
      [ -f "$envf" ] || continue
      changed=0
      for k in GITEA_SECRET_KEY GITEA_INTERNAL_TOKEN RUNNER_REGISTRATION_TOKEN; do
        v="$(get_env "$SRC/dot.env" "$k")"
        [ -n "$v" ] && [ "$v" != "$(get_env "$envf" "$k")" ] || continue
        [ $changed = 0 ] && cp -p "$envf" "$envf.bak-$TS"
        set_env "$k" "$v" "$envf"; changed=1
      done
      [ $changed = 1 ] && log "Updated secrets in $envf from backup (old: $envf.bak-$TS)"
    done
    load_env

    BV="$(get_env "$SRC/dot.env" GITEA_VERSION)"
    if [ -n "$BV" ] && [ "$BV" != "$GITEA_VERSION" ]; then warn "backup made with Gitea $BV, current is $GITEA_VERSION (newer is fine, older is NOT)"; fi

    WAS_SERVICE=0
    if service_active; then WAS_SERVICE=1; log "Stopping service $SERVICE_NAME"; systemctl stop "$SERVICE_NAME"; fi
    dc down >/dev/null 2>&1 || true

    OLD="$DATA_DIR/.pre-restore-$TS"
    log "Moving current data to $OLD"
    mkdir -p "$OLD"
    for d in gitea postgres runner; do [ -e "$DATA_DIR/$d" ] && mv "$DATA_DIR/$d" "$OLD/"; done

    log "Extracting files"
    tar --numeric-owner -xzpf "$SRC/gitea-data.tar.gz" -C "$DATA_DIR"
    [ -f "$SRC/runner-data.tar.gz" ] && tar --numeric-owner -xzpf "$SRC/runner-data.tar.gz" -C "$DATA_DIR"
    prepare_data

    log "Restoring database"
    dc up -d db
    wait_healthy db 180
    dc exec -T db sh -c 'pg_restore -U "$POSTGRES_USER" -d "$POSTGRES_DB" --clean --if-exists --no-owner --no-acl' < "$SRC/gitea-db.dump"
    dc stop db >/dev/null

    log "Starting stack"
    if [ $WAS_SERVICE = 1 ] || service_exists; then systemctl start "$SERVICE_NAME"; else dc up -d; fi
    wait_healthy gitea
    log "Restore done. If repos act weird: Site Administration > Dashboard > 'Resynchronize hooks'."
    log "Once happy: rm -rf $OLD"

[doc("convert a backup from the OLD rootless instance (old backup.sh) into this stack's format, in OUT")]
import-old src out:
    #!/usr/bin/env bash
    {{ lib }}
    as_root import-old "{{ src }}" "{{ out }}"
    load_env
    SRC="$(cd "{{ src }}" && pwd)"; OUT="{{ out }}"
    for f in gitea-db.dump gitea-data.tar.gz; do [ -f "$SRC/$f" ] || die "$SRC/$f missing"; done
    [ -e "$OUT" ] && die "$OUT already exists"
    W="$(mktemp -d)"; trap 'rm -rf "$W"' EXIT

    log "Extracting old data"
    tar --numeric-owner -xzpf "$SRC/gitea-data.tar.gz" -C "$W"
    INI="$W/etc/gitea/app.ini"
    [ -f "$INI" ] || die "no etc/gitea/app.ini in the archive (old backup must include /etc/gitea)"
    ini(){ awk -v s="[$1]" -v k="$2" '
      /^[ \t]*\[/ { f = ($0 == s) ; next }
      f { split($0, a, "="); gsub(/[ \t]/, "", a[1]); if (a[1] == k) { sub(/^[^=]*=[ \t]*/, ""); print; exit } }' "$INI"; }

    REPOS="$(ini repository ROOT)";  REPOS="${REPOS:-/var/lib/gitea/git/repositories}"
    LFS="$(ini lfs PATH)";           LFS="${LFS:-/var/lib/gitea/git/lfs}"
    APPDATA="$(ini server APP_DATA_PATH)"; APPDATA="${APPDATA:-/var/lib/gitea}"
    log "Old paths: repos=$REPOS lfs=$LFS app_data=$APPDATA"
    [ -d "$W$REPOS" ] || die "repositories not found at $REPOS in archive"

    N="$W/new/gitea"; mkdir -p "$N/git" "$N/gitea"
    mv "$W$REPOS" "$N/git/repositories"
    [ -d "$W$LFS" ] && mv "$W$LFS" "$N/git/lfs"
    for e in "$W$APPDATA"/*; do
      [ -e "$e" ] || continue
      case "$(basename "$e")" in git|custom|log|conf|tmp) ;; *) cp -a "$e" "$N/gitea/" ;; esac
    done
    if [ -d "$W/var/lib/gitea/custom" ]; then
      for e in "$W/var/lib/gitea/custom"/*; do
        [ -e "$e" ] || continue
        [ "$(basename "$e")" = conf ] || cp -a "$e" "$N/gitea/"
      done
    fi
    chown -R "$USER_UID:$USER_GID" "$N"

    mkdir -p "$OUT"; OUT="$(cd "$OUT" && pwd)"
    tar --numeric-owner -czf "$OUT/gitea-data.tar.gz" -C "$W/new" gitea
    cp "$SRC/gitea-db.dump" "$OUT/"
    cp "$ENV_FILE" "$OUT/dot.env"; chmod 600 "$OUT/dot.env"
    for p in "security SECRET_KEY GITEA_SECRET_KEY" "security INTERNAL_TOKEN GITEA_INTERNAL_TOKEN"; do
      set -- $p; v="$(ini "$1" "$2")"
      if [ -n "$v" ]; then set_env "$3" "$v" "$OUT/dot.env"; else warn "$2 not found in old app.ini"; fi
    done
    (cd "$OUT" && sha256sum -- * > SHA256SUMS)
    log "Converted backup in $OUT. Next: just restore $OUT"
    log "After restore, in Site Administration > Dashboard run: 'Resynchronize hooks' and 'Update .ssh/authorized_keys'. Delete the old offline runner in Admin > Actions > Runners."
