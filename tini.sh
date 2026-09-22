#!/bin/sh
# Container entrypoint. Run under tini as PID 1:
#   ENTRYPOINT ["tini", "-s", "--", "/startup/tini.sh"]

log() { echo "[entrypoint] $*" >&2; }

if [ -f /app/.env.encrypted ]; then
    log "decrypting .env.encrypted"
    php artisan env:decrypt --key "${LARAVEL_ENV_ENCRYPTION_KEY}"
    unset LARAVEL_ENV_ENCRYPTION_KEY
else
    log "env decryption skipped (no .env.encrypted)"
fi

if [ "${ARTISAN_CACHE}" = true ]; then
    log "running php artisan optimize"
    php artisan optimize
    unset ARTISAN_CACHE
else
    log "artisan cache disabled (ARTISAN_CACHE != true)"
fi

if [ -f /app/entrypoint.sh ]; then
    log "running custom entrypoint (/app/entrypoint.sh)"
    sh /app/entrypoint.sh
else
    log "custom entrypoint skipped (no /app/entrypoint.sh)"
fi

set -u

CADDYFILE="${CADDYFILE:-/etc/caddy/Caddyfile}"
PIDFILE=/tmp/container-pids
SUPERVISORS=""

: > "$PIDFILE"

track_pid() { echo "$1" >> "$PIDFILE"; }

shutdown() {
    log "shutting down..."

    # Stop supervisor loops first so they don't restart services.
    for pid in $SUPERVISORS; do
        kill -TERM "$pid" 2>/dev/null
    done

    if [ -s "$PIDFILE" ]; then
        while read -r pid; do
            [ -n "$pid" ] && kill -TERM "$pid" 2>/dev/null
        done < "$PIDFILE"
    fi

    wait
    exit 0
}

trap shutdown TERM INT

# name, max_retries (0 = unlimited), stdout, stderr, command...
run_service() {
    name=$1
    max_retries=$2
    stdout=$3
    stderr=$4
    shift 4

    (
        trap 'exit 0' TERM INT

        count=0
        while true; do
            "$@" >"$stdout" 2>"$stderr" &
            pid=$!
            track_pid "$pid"
            wait "$pid"
            rc=$?
            count=$((count + 1))
            if [ "$max_retries" -gt 0 ] && [ "$count" -ge "$max_retries" ]; then
                log "$name exited (code $rc), retry limit ($max_retries) reached, giving up"
                break
            fi
            log "$name exited (code $rc), restarting (attempt $count)"
            sleep 1
        done
    ) &
    SUPERVISORS="$SUPERVISORS $!"
}

log "starting FrankenPHP with Caddyfile: $CADDYFILE"

run_service octane_00 20 /dev/stdout /dev/stderr \
    env /usr/local/bin/frankenphp run -c "$CADDYFILE"

if [ "${WITH_SCHEDULER:-false}" = "true" ]; then
    log "starting scheduler (supercronic)"
    run_service cron 0 /dev/stdout /dev/stderr \
        supercronic -overlapping -quiet -passthrough-logs /etc/crontabs/www-data
else
    log "scheduler disabled (WITH_SCHEDULER != true)"
fi

if [ "${WITH_QUEUE:-false}" = "true" ]; then
    n="${QUEUE_WORKER_NUMBER:-1}"
    i=0
    log "starting $n queue workers"
    while [ "$i" -lt "$n" ]; do
        run_service "queue_$(printf '%02d' "$i")" 0 /dev/null /dev/stderr \
            php artisan queue:work
        i=$((i + 1))
    done
else
    log "queue disabled (WITH_QUEUE != true)"
fi

# EXTRA_COMMANDS: one command per line, or semicolon-separated on a single line.
if [ -n "${EXTRA_COMMANDS:-}" ]; then
    case "$EXTRA_COMMANDS" in
        *'
'*) ;;
        *) EXTRA_COMMANDS=$(printf '%s' "$EXTRA_COMMANDS" | tr ';' '\n') ;;
    esac

    n=0
    while IFS= read -r cmd || [ -n "$cmd" ]; do
        [ -z "$cmd" ] && continue
        name="extra_$(printf '%02d' "$n")"
        log "starting $name: $cmd"
        run_service "$name" 0 /dev/stdout /dev/stderr sh -c "$cmd"
        n=$((n + 1))
    done <<EOF
${EXTRA_COMMANDS}
EOF
else
    log "extra services disabled (EXTRA_COMMANDS not set)"
fi

wait
