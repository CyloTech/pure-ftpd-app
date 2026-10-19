#!/usr/bin/env bash
# Tests for the Appbox installed callback, run against a local mock API (needs
# bash, curl and python3; no Docker):
#   - appbox-installed-callback retries network errors, 408, 429 and 5xx,
#     stops after one try on any other status, sends CALLBACK_TOKEN in
#     X-Cylo-Callback-Token, passes an optional JSON body, and never logs the
#     callback token carried in INSTANCE_ID;
#   - the /entrypoint.sh embedded in the Dockerfile execs pure-ftpd straight
#     away even when the API rejects the callback, sends a pending callback
#     once in the background, clears the pending flag, and sends nothing
#     without INSTANCE_ID or on a plain restart.
#
# Usage: tests/test-installed-callback.sh
set -u

repo_root="$(cd "$(dirname "$0")/.." && pwd)"
helper="${repo_root}/appbox-installed-callback"
token_id='999?callback_token=querytoken0123456789'
header_token='headertoken0123456789'

# Answers GET with 200 (readiness) and each POST with the next status from a
# comma-separated list, logging what it received.
mock_server='
import http.server, json, os, sys
port, codes, log = int(sys.argv[1]), [int(c) for c in sys.argv[2].split(",")], sys.argv[3]
class Handler(http.server.BaseHTTPRequestHandler):
    def do_GET(self):
        self.send_response(200)
        self.end_headers()
    def do_POST(self):
        seen = sum(1 for _ in open(log)) if os.path.exists(log) else 0
        code = codes[min(seen, len(codes) - 1)]
        length = int(self.headers.get("Content-Length") or 0)
        body = self.rfile.read(length).decode() if length else ""
        with open(log, "a") as f:
            f.write(json.dumps({"path": self.path, "code": code, "body": body,
                                "token": self.headers.get("X-Cylo-Callback-Token", "")}) + "\n")
        self.send_response(code)
        self.end_headers()
    def log_message(self, *args):
        pass
http.server.HTTPServer(("127.0.0.1", port), Handler).serve_forever()
'

failures=0
work=""
server=""

pass() { echo "ok   $*"; }
fail() {
    echo "FAIL $*"
    [[ -f "${work}/output" ]] && sed 's/^/     /' "${work}/output"
    failures=$((failures + 1))
}

start_mock() {
    work="$(mktemp -d)"
    port=$((20000 + RANDOM % 20000))
    python3 -c "${mock_server}" "${port}" "$1" "${work}/requests" &
    server=$!
    for _ in $(seq 1 50); do
        curl -s -o /dev/null "http://127.0.0.1:${port}/" && return 0
        sleep 0.1
    done
    echo "mock API did not start" >&2
    exit 2
}

stop_mock() {
    kill "${server}" 2>/dev/null
    wait "${server}" 2>/dev/null
    rm -rf "${work}"
}

# Run a command, killing it (exit 124) if it is still running after $1 seconds,
# so a callback that never stops fails the test instead of hanging it.
run_limited() {
    local limit=$1 pid ticks=0
    shift
    "$@" &
    pid=$!
    while kill -0 "${pid}" 2>/dev/null && [[ "${ticks}" -lt $((limit * 10)) ]]; do
        sleep 0.1
        ticks=$((ticks + 1))
    done
    if kill -0 "${pid}" 2>/dev/null; then
        kill "${pid}" 2>/dev/null
        wait "${pid}" 2>/dev/null
        return 124
    fi
    wait "${pid}"
}

request_count() { cat "${work}/requests" 2>/dev/null | wc -l | tr -d ' '; }
token_logged() { grep -cE 'querytoken|headertoken' "${work}/output"; }

# --- helper ------------------------------------------------------------------

helper_case() {
    local codes=$1 want_exit=$2 want_requests=$3
    shift 3
    start_mock "${codes}"
    run_limited 20 env INSTANCE_ID="${token_id}" CALLBACK_TOKEN="${header_token}" \
        APPBOX_CALLBACK_BASE="http://127.0.0.1:${port}" \
        APPBOX_CALLBACK_RETRY_DELAY=1 \
        "$@" "${helper}" >"${work}/output" 2>&1
    local rc=$? requests leaked
    requests=$(request_count)
    leaked=$(token_logged)
    if [[ "${rc}" == "${want_exit}" && "${requests}" == "${want_requests}" && "${leaked}" == 0 ]]; then
        pass "helper codes=${codes} exit=${rc} requests=${requests}"
    else
        fail "helper codes=${codes} exit=${rc}/${want_exit} requests=${requests}/${want_requests} token_logged=${leaked}"
    fi
    stop_mock
}

helper_case 200 0 1
helper_case 401 1 1
helper_case 404 1 1
helper_case 409 1 1
helper_case 422 1 1
helper_case 503,502,200 0 3
helper_case 429,408,204 0 3
helper_case 500,401 1 2
helper_case 200 0 0 SKIP_APPBOX_CALLBACK=1

# Network errors are retried: nothing listens on the port for the first try.
work="$(mktemp -d)"
port=$((20000 + RANDOM % 20000))
(
    sleep 1.5
    exec python3 -c "${mock_server}" "${port}" 200 "${work}/requests"
) &
server=$!
run_limited 20 env INSTANCE_ID="${token_id}" APPBOX_CALLBACK_BASE="http://127.0.0.1:${port}" \
    APPBOX_CALLBACK_RETRY_DELAY=1 "${helper}" >"${work}/output" 2>&1
rc=$?
if [[ "${rc}" == 0 ]] && grep -q 'HTTP 000, retrying' "${work}/output" && [[ "$(request_count)" == 1 ]]; then
    pass "helper retries a network error"
else
    fail "helper network error exit=${rc} requests=$(request_count)"
fi
stop_mock

# An invalid APPBOX_CALLBACK_RETRY_DELAY falls back to the 5s default.
start_mock 503,200
run_limited 20 env INSTANCE_ID="${token_id}" APPBOX_CALLBACK_BASE="http://127.0.0.1:${port}" \
    APPBOX_CALLBACK_RETRY_DELAY='1;x' "${helper}" >"${work}/output" 2>&1
rc=$?
if [[ "${rc}" == 0 ]] && grep -q 'retrying in 5s' "${work}/output" && [[ "$(request_count)" == 2 ]]; then
    pass "helper ignores an invalid retry delay"
else
    fail "helper invalid retry delay exit=${rc} requests=$(request_count)"
fi
stop_mock

# Token header, query string and optional body reach the API.
start_mock 200
run_limited 20 env INSTANCE_ID="${token_id}" CALLBACK_TOKEN="${header_token}" \
    APPBOX_CALLBACK_BASE="http://127.0.0.1:${port}" \
    "${helper}" '{"custom_fields":[{"key":"ADMIN_PANEL","value":"https://example.test/"}]}' \
    >"${work}/output" 2>&1
if python3 - "${work}/requests" "${header_token}" <<'PY'
import json, sys
req = json.loads(open(sys.argv[1]).readline())
assert req["path"] == "/v1/apps/installed/999?callback_token=querytoken0123456789", req
assert req["token"] == sys.argv[2], req
assert json.loads(req["body"])["custom_fields"][0]["key"] == "ADMIN_PANEL", req
PY
then
    pass "helper sends path, X-Cylo-Callback-Token and body"
else
    fail "helper request contents"
fi
stop_mock

# --- entrypoint (embedded in the Dockerfile) -----------------------------------

# Extract the /entrypoint.sh heredoc from the Dockerfile, point its paths into
# a scratch directory and replace `exec pure-ftpd ...` with a fake app that
# records when it started.
#   state: fresh (no app_configured), restart-pending (app_configured and the
#   pending flag present) or restart (app_configured only).
entrypoint_case() {
    local state=$1 codes=$2 want_requests=$3 instance=${4-${token_id}}
    start_mock "${codes}"
    local sandbox="${work}/entrypoint.sh"
    mkdir -p "${work}/pure-ftpd/passwd"
    sed -n "/^RUN cat > \/entrypoint.sh <<'EOF'$/,/^EOF$/p" "${repo_root}/Dockerfile" \
        | sed -e '1d' -e '$d' \
            -e "s|/etc/app_configured|${work}/app_configured|g" \
            -e "s|/etc/appbox_callback_pending|${work}/callback_pending|g" \
            -e "s|/usr/local/bin/appbox-installed-callback|${helper}|g" \
            -e "s|/etc/ssl/private/|${work}/ssl/|g" \
            -e "s|/etc/pure-ftpd|${work}/pure-ftpd|g" \
            -e "s|/data/pureftpd.pem|${work}/pureftpd.pem|g" \
            -e "s|/ssl/|${work}/no-ssl/|g" \
            -e 's|^exec pure-ftpd $FTPD_ARGS$|exec "$@"|' \
        >"${sandbox}"
    chmod +x "${sandbox}"
    if ! grep -q '^exec "\$@"$' "${sandbox}" || ! grep -q '^#!/bin/bash$' "${sandbox}"; then
        fail "entrypoint ${state}: could not extract and sandbox /entrypoint.sh"
        stop_mock
        return
    fi

    case "${state}" in
        restart-pending) touch "${work}/app_configured" "${work}/callback_pending" ;;
        restart) touch "${work}/app_configured" ;;
    esac

    local started_at app_at entrypoint_pid waited=0
    started_at=$(date +%s)
    env INSTANCE_ID="${instance}" CALLBACK_TOKEN="${header_token}" \
        APPBOX_CALLBACK_BASE="http://127.0.0.1:${port}" \
        APPBOX_CALLBACK_RETRY_DELAY=1 \
        "${sandbox}" bash -c "date +%s >'${work}/app_started'; sleep 1" \
        >"${work}/output" 2>&1 &
    entrypoint_pid=$!

    while [[ ! -f "${work}/app_started" && "${waited}" -lt 10 ]]; do
        sleep 1
        waited=$((waited + 1))
    done
    if [[ ! -f "${work}/app_started" ]]; then
        pkill -P "${entrypoint_pid}" 2>/dev/null
        kill "${entrypoint_pid}" 2>/dev/null
    fi
    wait "${entrypoint_pid}" 2>/dev/null

    waited=0
    while [[ -f "${work}/callback_pending" && "${waited}" -lt 20 ]]; do
        sleep 1
        waited=$((waited + 1))
    done
    sleep 0.5

    app_at=$(cat "${work}/app_started" 2>/dev/null || echo 0)
    local requests leaked
    requests=$(request_count)
    leaked=$(token_logged)
    if [[ "${app_at}" -gt 0 && $((app_at - started_at)) -le 2 && ! -f "${work}/callback_pending" \
        && -f "${work}/app_configured" && "${requests}" == "${want_requests}" && "${leaked}" == 0 ]]; then
        pass "entrypoint ${state} codes=${codes}: app started after $((app_at - started_at))s, requests=${requests}"
    else
        fail "entrypoint ${state} codes=${codes}: app_started=${app_at} start=${started_at} pending=$([[ -f "${work}/callback_pending" ]] && echo yes || echo no) requests=${requests}/${want_requests} token_logged=${leaked}"
    fi
    stop_mock
}

entrypoint_case fresh 200 1
entrypoint_case fresh 401 1
entrypoint_case fresh 200 0 ''
entrypoint_case restart-pending 503,200 2
entrypoint_case restart 200 0

entry=$(sed -n "/^RUN cat > \/entrypoint.sh <<'EOF'$/,/^EOF$/p" "${repo_root}/Dockerfile")
if grep -q 'apps/installed' <<<"${entry}" || grep -q 'until curl' <<<"${entry}"; then
    fail "/entrypoint.sh still calls the installed callback itself"
else
    pass "/entrypoint.sh only marks the callback pending and hands it to the helper"
fi

# First boot sets the pending flag before the configured marker, so a crash
# between the two cannot lose the callback.
# Usage: flag_before_marker <label> <marker path> < script
flag_before_marker() {
    local label=$1 marker=$2 text flag_line marker_line
    text=$(cat)
    flag_line=$(grep -n 'touch [^ ]*appbox_callback_pending' <<<"${text}" | head -1 | cut -d: -f1)
    marker_line=$(grep -n "touch ${marker}\$" <<<"${text}" | head -1 | cut -d: -f1)
    if [[ -n "${flag_line}" && -n "${marker_line}" && "${flag_line}" -lt "${marker_line}" ]]; then
        pass "${label} sets the pending flag before ${marker}"
    else
        fail "${label}: pending flag line ${flag_line:-none}, ${marker} line ${marker_line:-none}"
    fi
}
flag_before_marker "/entrypoint.sh" /etc/app_configured <<<"${entry}"

exit "${failures}"
