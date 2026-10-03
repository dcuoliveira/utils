#!/usr/bin/env bash
#
# claude-tunnel.sh — work around the IME-USP path-MTU black hole that breaks
# Claude Code on the vision cluster.
#
# THE PROBLEM
#   Hosts on 192.168.231.0/24 cannot send full-size (~1500 byte) packets off
#   campus, and the ICMP "fragmentation needed" that would trigger path-MTU
#   discovery is filtered. Verified on hamilton:
#       ping -M do -s 1452 160.79.104.10   -> ok
#       ping -M do -s 1472 160.79.104.10   -> silently dropped
#   Result: any HTTPS request carrying more than ~1.2 KB of payload stalls for
#   ~15 s and resets. Claude Code's first API request is always larger than
#   that, so every session dies with ECONNRESET while SSH and small requests
#   keep working.
#
# THE WORKAROUND
#   Run an HTTP proxy on the Mac and expose it on each remote host through an
#   SSH reverse forward. The API traffic then travels inside the SSH
#   connection, which negotiated a workable segment size when it connected.
#
# USAGE
#   ./claude-tunnel.sh setup     one-time: install shell guard + settings.json on every host
#   ./claude-tunnel.sh up        per session: start the proxy and open the tunnels
#   ./claude-tunnel.sh status    show what is and isn't working
#   ./claude-tunnel.sh test      prove the direct path is broken and the tunnel fixes it
#   ./claude-tunnel.sh down      close the tunnels   (--proxy also stops the proxy)
#   ./claude-tunnel.sh remove    undo setup on every host
#   ./claude-tunnel.sh all       setup + up + status
#
# ENVIRONMENT OVERRIDES
#   HOSTS="hamilton hopper"      limit to specific hosts
#   CLAUDE_TUNNEL_PORT=8888      proxy port on both ends
#
# REQUIREMENTS (Mac)
#   An HTTP proxy: pip install proxy.py   — or —   brew install tinyproxy
#   ~/.ssh/config entries for each host. ControlMaster is strongly recommended
#   so that extra terminal windows share one tunnel instead of failing to bind.
#
set -uo pipefail

PORT="${CLAUDE_TUNNEL_PORT:-8888}"
SSH_TIMEOUT="${CLAUDE_TUNNEL_SSH_TIMEOUT:-20}"
PROXY_LOG="${CLAUDE_TUNNEL_LOG:-/tmp/claude-proxy.log}"
TINYPROXY_CONF="/tmp/claude-tinyproxy.conf"
GUARD_MARK="claude-tunnel guard"

DEFAULT_HOSTS="hamilton hopper lovelace curie puchkin dostoievski tolstoi \
deepzero deepone deeptwo deepthree deepfour deepfive deepsix"

read -r -a HOST_LIST <<< "${HOSTS:-$DEFAULT_HOSTS}"

# ---------------------------------------------------------------- output ----

if [ -t 1 ]; then
  C_OK=$'\033[32m'; C_BAD=$'\033[31m'; C_WARN=$'\033[33m'
  C_BOLD=$'\033[1m'; C_DIM=$'\033[2m'; C_OFF=$'\033[0m'
else
  C_OK=; C_BAD=; C_WARN=; C_BOLD=; C_DIM=; C_OFF=
fi

hdr()  { printf '\n%s%s%s\n' "$C_BOLD" "$*" "$C_OFF"; }
ok()   { printf '  %s+%s %s\n' "$C_OK"   "$C_OFF" "$*"; }
bad()  { printf '  %s-%s %s\n' "$C_BAD"  "$C_OFF" "$*"; }
warn() { printf '  %s!%s %s\n' "$C_WARN" "$C_OFF" "$*"; }
note() { printf '  %s.%s %s\n' "$C_DIM"  "$C_OFF" "$*"; }

die() { printf '%serror:%s %s\n' "$C_BAD" "$C_OFF" "$*" >&2; exit 1; }

SSH_OPTS=(-o ConnectTimeout="$SSH_TIMEOUT" -o BatchMode=no)

# ----------------------------------------------------------------- proxy ----

proxy_listening() {
  if command -v lsof >/dev/null 2>&1; then
    lsof -nP -iTCP:"$PORT" -sTCP:LISTEN >/dev/null 2>&1
  else
    nc -z 127.0.0.1 "$PORT" >/dev/null 2>&1
  fi
}

proxy_start() {
  if proxy_listening; then
    ok "proxy already listening on 127.0.0.1:$PORT"
    return 0
  fi

  if command -v proxy >/dev/null 2>&1; then
    note "starting proxy.py on 127.0.0.1:$PORT"
    nohup proxy --hostname 127.0.0.1 --port "$PORT" >"$PROXY_LOG" 2>&1 &
    disown 2>/dev/null || true
  elif command -v tinyproxy >/dev/null 2>&1; then
    note "starting tinyproxy on 127.0.0.1:$PORT"
    cat >"$TINYPROXY_CONF" <<EOF
Port $PORT
Listen 127.0.0.1
Timeout 600
Allow 127.0.0.1
EOF
    nohup tinyproxy -d -c "$TINYPROXY_CONF" >"$PROXY_LOG" 2>&1 &
    disown 2>/dev/null || true
  else
    bad "no HTTP proxy installed"
    note "install one:  pip install proxy.py    or    brew install tinyproxy"
    return 1
  fi

  for _ in $(seq 40); do
    proxy_listening && { ok "proxy up (log: $PROXY_LOG)"; return 0; }
    sleep 0.25
  done

  bad "proxy failed to bind $PORT — see $PROXY_LOG"
  return 1
}

proxy_stop() {
  if ! proxy_listening; then
    note "proxy not running"
    return 0
  fi
  pkill -f "proxy --hostname 127.0.0.1 --port $PORT" 2>/dev/null
  pkill -f "tinyproxy -d -c $TINYPROXY_CONF" 2>/dev/null
  sleep 0.5
  proxy_listening && bad "proxy still listening — stop it by hand" || ok "proxy stopped"
}

# ---------------------------------------------------------------- tunnels ----

# Does the user's ssh config already declare the reverse forward for this host?
host_config_has_forward() {
  ssh -G "$1" 2>/dev/null | grep -qiE "^remoteforward .*[^0-9]$PORT([^0-9]|$)"
}

host_config_has_controlpath() {
  local cp
  cp="$(ssh -G "$1" 2>/dev/null | awk '$1=="controlpath"{print $2}')"
  [ -n "$cp" ] && [ "$cp" != "none" ]
}

master_alive() { ssh -O check "$1" >/dev/null 2>&1; }

remote_port_bound() {
  ssh "${SSH_OPTS[@]}" "$1" "timeout 2 bash -c '</dev/tcp/127.0.0.1/$PORT'" >/dev/null 2>&1
}

tunnel_up() {
  local host="$1"

  if master_alive "$host" && remote_port_bound "$host"; then
    ok "$host: tunnel already up"
    return 0
  fi

  if master_alive "$host"; then
    note "$host: master exists but port $PORT is not bound — restarting it"
    ssh -O exit "$host" >/dev/null 2>&1
    sleep 0.5
  fi

  local args=("${SSH_OPTS[@]}" -f -N -o ExitOnForwardFailure=yes)
  host_config_has_controlpath "$host" && args+=(-M)
  host_config_has_forward "$host" || args+=(-R "$PORT:localhost:$PORT")

  if ssh "${args[@]}" "$host" 2>/tmp/claude-tunnel-"$host".err; then
    if remote_port_bound "$host"; then
      ok "$host: tunnel up"
    else
      bad "$host: connected but port $PORT not reachable remotely"
    fi
  else
    bad "$host: could not open tunnel"
    sed 's/^/      /' /tmp/claude-tunnel-"$host".err 2>/dev/null | head -5
  fi
}

tunnel_down() {
  local host="$1"
  if master_alive "$host"; then
    ssh -O exit "$host" >/dev/null 2>&1 && ok "$host: tunnel closed" || bad "$host: close failed"
  else
    note "$host: no tunnel"
  fi
}

# ------------------------------------------------------------ remote setup ----

remote_setup() {
  local host="$1"
  ssh "${SSH_OPTS[@]}" "$host" "PORT=$PORT GUARD_MARK='$GUARD_MARK' bash -s" <<'REMOTE'
set -u
status=0

# --- 1. interactive-shell guard in ~/.bashrc -------------------------------
if grep -qF "$GUARD_MARK" "$HOME/.bashrc" 2>/dev/null; then
  echo "bashrc|skip|guard already present"
else
  cp "$HOME/.bashrc" "$HOME/.bashrc.bak.claude-tunnel" 2>/dev/null
  cat >> "$HOME/.bashrc" <<EOF

# >>> $GUARD_MARK >>>
# Route API traffic through the SSH reverse tunnel when it is present.
# Guarded so that pip/conda/git still work when the tunnel is down.
if timeout 0.3 bash -c "</dev/tcp/127.0.0.1/$PORT" 2>/dev/null; then
  export HTTP_PROXY=http://localhost:$PORT
  export HTTPS_PROXY=http://localhost:$PORT
  export NO_PROXY=localhost,127.0.0.1,.ime.usp.br,192.168.0.0/16
fi
# <<< $GUARD_MARK <<<
EOF
  echo "bashrc|ok|guard appended (backup: ~/.bashrc.bak.claude-tunnel)"
fi

# --- 2. ~/.claude/settings.json env block ----------------------------------
# The desktop app's remote session is non-interactive, so Ubuntu's early
# return in .bashrc means the guard above never runs for it. Claude Code
# reads its own env block regardless of shell, which covers that case.
python3 - "$PORT" <<'PY'
import json, pathlib, shutil, sys

port = sys.argv[1]
p = pathlib.Path.home() / ".claude" / "settings.json"
p.parent.mkdir(parents=True, exist_ok=True)

data = {}
if p.exists():
    try:
        data = json.loads(p.read_text() or "{}")
    except json.JSONDecodeError as e:
        print(f"settings|fail|existing file is not valid JSON ({e}); left untouched")
        sys.exit(1)
    shutil.copy(p, str(p) + ".bak.claude-tunnel")

env = data.setdefault("env", {})
before = dict(env)
env["HTTP_PROXY"] = f"http://localhost:{port}"
env["HTTPS_PROXY"] = f"http://localhost:{port}"

if before == env and p.exists():
    print("settings|skip|env block already correct")
else:
    p.write_text(json.dumps(data, indent=2) + "\n")
    print("settings|ok|env block written")
PY
[ $? -ne 0 ] && status=1

exit $status
REMOTE
}

remote_remove() {
  local host="$1"
  ssh "${SSH_OPTS[@]}" "$host" "GUARD_MARK='$GUARD_MARK' bash -s" <<'REMOTE'
set -u

if grep -qF "$GUARD_MARK" "$HOME/.bashrc" 2>/dev/null; then
  python3 - "$GUARD_MARK" <<'PY'
import pathlib, sys
mark = sys.argv[1]
p = pathlib.Path.home() / ".bashrc"
lines = p.read_text().splitlines(keepends=True)
out, skipping = [], False
for line in lines:
    if f">>> {mark} >>>" in line:
        skipping = True
        continue
    if f"<<< {mark} <<<" in line:
        skipping = False
        continue
    if not skipping:
        out.append(line)
p.write_text("".join(out))
print("bashrc|ok|guard removed")
PY
else
  echo "bashrc|skip|no guard found"
fi

python3 - <<'PY'
import json, pathlib
p = pathlib.Path.home() / ".claude" / "settings.json"
if not p.exists():
    print("settings|skip|no settings.json")
else:
    data = json.loads(p.read_text() or "{}")
    env = data.get("env", {})
    for k in ("HTTP_PROXY", "HTTPS_PROXY"):
        env.pop(k, None)
    if not env:
        data.pop("env", None)
    p.write_text(json.dumps(data, indent=2) + "\n")
    print("settings|ok|proxy vars removed")
PY
REMOTE
}

print_remote_result() {
  local host="$1" line
  while IFS='|' read -r what state msg; do
    [ -z "${what:-}" ] && continue
    case "${state:-}" in
      ok)   ok   "$host: $what — $msg" ;;
      skip) note "$host: $what — $msg" ;;
      fail) bad  "$host: $what — $msg" ;;
      *)    note "$host: ${what}${state:+ $state}${msg:+ $msg}" ;;
    esac
  done
}

# ------------------------------------------------------------------ tests ----

# Sends the same ~4 KB POST twice: once direct, once through the tunnel.
# A 401 is success — no API key is sent, so the auth error proves the request
# completed a full round trip.
test_host() {
  local host="$1" out direct proxied
  out="$(ssh "${SSH_OPTS[@]}" "$host" "PORT=$PORT bash -s" <<'REMOTE' 2>/dev/null
python3 -c "import json;print(json.dumps({'model':'claude-sonnet-4-6','max_tokens':16,'messages':[{'role':'user','content':'x'*4000}]}))" > /tmp/cc-mtu-probe.json

run() {
  curl -sS -o /dev/null --max-time 20 -w '%{http_code} %{time_total}' \
    -X POST https://api.anthropic.com/v1/messages \
    -H 'content-type: application/json' -H 'anthropic-version: 2023-06-01' \
    --data-binary @/tmp/cc-mtu-probe.json 2>/dev/null || printf '000 timeout'
}

printf 'direct '
env -u HTTP_PROXY -u HTTPS_PROXY bash -c "$(declare -f run); run"
printf '\nproxied '
HTTP_PROXY="http://localhost:$PORT" HTTPS_PROXY="http://localhost:$PORT" \
  bash -c "$(declare -f run); run"
printf '\n'
REMOTE
)"

  direct="$(printf '%s\n' "$out" | awk '$1=="direct"{print $2" in "$3"s"}')"
  proxied="$(printf '%s\n' "$out" | awk '$1=="proxied"{print $2" in "$3"s"}')"

  case "$direct" in
    401*) ok   "$host: direct  $direct  (this host is NOT affected)" ;;
    *)    warn "$host: direct  ${direct:-no result}  (path MTU broken)" ;;
  esac
  case "$proxied" in
    401*) ok   "$host: tunnel  $proxied" ;;
    *)    bad  "$host: tunnel  ${proxied:-no result}" ;;
  esac
}

status_host() {
  local host="$1" bits=()

  master_alive "$host"      && bits+=("master") || bits+=("no-master")
  if remote_port_bound "$host"; then
    bits+=("port-bound")
  else
    bits+=("port-DOWN")
  fi

  local remote
  remote="$(ssh "${SSH_OPTS[@]}" "$host" "bash -lic 'echo GUARD=\${HTTPS_PROXY:-unset}' 2>/dev/null | tail -1; \
    python3 -c \"import json,pathlib;p=pathlib.Path.home()/'.claude'/'settings.json';d=json.loads(p.read_text()) if p.exists() else {};print('SETTINGS='+('ok' if 'HTTPS_PROXY' in d.get('env',{}) else 'missing'))\" 2>/dev/null")"

  local guard settings
  guard="$(printf '%s\n' "$remote" | sed -n 's/^GUARD=//p' | tail -1)"
  settings="$(printf '%s\n' "$remote" | sed -n 's/^SETTINGS=//p' | tail -1)"

  bits+=("guard=${guard:-?}" "settings=${settings:-?}")

  if [[ "${bits[*]}" == *port-DOWN* || "${settings:-}" != "ok" ]]; then
    bad "$host: ${bits[*]}"
  else
    ok "$host: ${bits[*]}"
  fi
}

# ------------------------------------------------------------------- main ----

cmd_setup() {
  hdr "Installing on ${#HOST_LIST[@]} host(s)"
  note "homes may be NFS-shared; 'already present' on later hosts is expected"
  for h in "${HOST_LIST[@]}"; do
    remote_setup "$h" | print_remote_result "$h"
  done
}

cmd_up() {
  hdr "Proxy (local)"
  proxy_start || die "cannot continue without a proxy"

  hdr "Tunnels"
  for h in "${HOST_LIST[@]}"; do
    host_config_has_controlpath "$h" || warn "$h: no ControlPath in ssh config — extra windows may lose the tunnel"
    tunnel_up "$h"
  done
}

cmd_status() {
  hdr "Proxy (local)"
  proxy_listening && ok "listening on 127.0.0.1:$PORT" || bad "not running — run: $0 up"

  hdr "Hosts"
  for h in "${HOST_LIST[@]}"; do status_host "$h"; done
}

cmd_test() {
  hdr "Round-trip test (401 = success, no API key is sent)"
  for h in "${HOST_LIST[@]}"; do test_host "$h"; done
}

cmd_down() {
  hdr "Tunnels"
  for h in "${HOST_LIST[@]}"; do tunnel_down "$h"; done
  if [ "${1:-}" = "--proxy" ]; then
    hdr "Proxy (local)"
    proxy_stop
  fi
}

cmd_remove() {
  hdr "Removing from ${#HOST_LIST[@]} host(s)"
  for h in "${HOST_LIST[@]}"; do
    remote_remove "$h" | print_remote_result "$h"
  done
}

usage() {
  sed -n '3,40p' "$0" | sed 's/^# \{0,1\}//'
  exit 1
}

command -v ssh >/dev/null 2>&1 || die "ssh not found"

case "${1:-}" in
  setup)  cmd_setup ;;
  up)     cmd_up ;;
  status) cmd_status ;;
  test)   cmd_test ;;
  down)   shift; cmd_down "${1:-}" ;;
  remove) cmd_remove ;;
  all)    cmd_setup; cmd_up; cmd_status ;;
  *)      usage ;;
esac

printf '\n'
