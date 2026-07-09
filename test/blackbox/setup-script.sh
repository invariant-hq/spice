export HOME="$PWD/home"
export XDG_CONFIG_HOME="$PWD/xdg-config"
export XDG_DATA_HOME="$PWD/xdg-data"
export XDG_STATE_HOME="$PWD/xdg-state"
export SPICE_TEST_DATA_HOME="$XDG_DATA_HOME/spice"
export SHELL=/bin/sh

unset APPDATA
unset COMSPEC
unset SPICE_ANTHROPIC_BASE_URL
unset SPICE_CONFIG
unset SPICE_CONFIG_HOME
unset SPICE_DATA_HOME
unset SPICE_MAX_STEPS
unset SPICE_MODEL
unset SPICE_OPENAI_AUTH_BASE_URL
unset SPICE_OPENAI_BASE_URL
unset SPICE_OLLAMA_BASE_URL
unset SPICE_PERMISSION_MODE
unset SPICE_SANDBOX_BACKEND
unset SPICE_SANDBOX_REQUIRE
unset SPICE_SHELL
unset SPICE_SMALL_MODEL
unset SPICE_STATE_HOME
unset SPICE_WEB_BRAVE_API_KEY
export SPICE_AUTO_TITLE=0

# Deterministic cross-platform sandbox posture for fixtures that are not
# about sandboxing: explicit unconfined execution, so no fixture depends on
# workspace trust or on a platform sandbox backend. Sandbox test cases
# override this per invocation.
export SPICE_SANDBOX_MODE=danger-full-access

# Deterministic local-model surfaces: fit verdicts judge against a fixed
# 24 GiB budget instead of this machine's memory, and the engine binary is a
# name that never resolves, so doctor and models output do not depend on the
# host's RAM or on llama.cpp being installed. Local test cases override per
# invocation.
export SPICE_LOCAL_MEMORY_BUDGET=25769803776
export SPICE_LOCAL_SERVER_BINARY=spice-test-llama-server

mkdir -p "$HOME" "$XDG_CONFIG_HOME" "$XDG_DATA_HOME" "$XDG_STATE_HOME"

find_up () {
  local path="$1"
  local dir="$PWD"

  while [ "$dir" != "/" ]
  do
    if [ -e "$dir/$path" ]
    then
      printf '%s\n' "$dir/$path"
      return 0
    fi
    dir="$(dirname "$dir")"
  done

  return 1
}

wait_for_file () {
  local path="$1"
  local tries="${2:-200}"

  while [ "$tries" -gt 0 ]
  do
    if [ -s "$path" ]
    then
      return 0
    fi
    tries=$((tries - 1))
    sleep 0.05
  done

  echo "timed out waiting for $path"
  return 1
}

wait_for_output () {
  local pattern="$1"
  local path="$2"
  local tries="${3:-200}"

  while [ "$tries" -gt 0 ]
  do
    if grep -q "$pattern" "$path" 2>/dev/null
    then
      return 0
    fi
    tries=$((tries - 1))
    sleep 0.05
  done

  echo "timed out waiting for $pattern in $path"
  return 1
}

# One-shot loopback HTTP GET printing the status code: the "browser" of OAuth
# browser-login fixtures, hitting the CLI's local callback listener.
fake_browser_get () {
  "$(find_up bin/spice_fake_provider_server.exe)" --get "$1"
}

cleanup_fake_server () {
  if [ -n "${SPICE_FAKE_PROVIDER_PID:-}" ]
  then
    kill "$SPICE_FAKE_PROVIDER_PID" 2>/dev/null || true
    wait "$SPICE_FAKE_PROVIDER_PID" 2>/dev/null || true
    unset SPICE_FAKE_PROVIDER_PID
  fi
}

start_fake_server () {
  local script="$1"
  local capture="${2:-capture}"
  local port_file="${3:-port}"
  local server

  server="$(find_up bin/spice_fake_provider_server.exe)"
  mkdir -p "$capture"
  rm -f "$port_file"

  # SPICE_FAKE_PROVIDER_UNORDERED=1 matches each request against the first
  # pending script item instead of strict sequence -- required when detached
  # subagents make parent and child requests race.
  "$server" --script "$script" --capture "$capture" --port-file "$port_file" \
    --accept-timeout "${SPICE_FAKE_PROVIDER_ACCEPT_TIMEOUT:-3}" \
    ${SPICE_FAKE_PROVIDER_UNORDERED:+--unordered} &
  SPICE_FAKE_PROVIDER_PID=$!
  export SPICE_FAKE_PROVIDER_PID

  wait_for_file "$port_file"
}

wait_fake_server () {
  wait "$SPICE_FAKE_PROVIDER_PID"
  unset SPICE_FAKE_PROVIDER_PID
}

start_fake_openai () {
  local script="$1"
  local capture="${2:-capture}"
  local port_file="${3:-openai-port}"

  start_fake_server "$script" "$capture" "$port_file"
  export OPENAI_API_KEY=test-key
  export SPICE_MODEL=openai/gpt-5.5
  export SPICE_OPENAI_BASE_URL="http://127.0.0.1:$(cat "$port_file")/v1"
}

# Point the Ollama provider (Spice's OpenAI-compatible chat-completions client)
# at a local chat-completions fixture. Sets an arbitrary model id -- the daemon
# owns the model set, so any id resolves. Auth stays the caller's choice: the
# bare daemon needs none, a key-protected one takes OLLAMA_API_KEY. The base URL
# is the daemon root; the provider appends /v1/chat/completions.
start_fake_ollama () {
  local reply="${1:-ollama compat reply}"
  local capture="${2:-capture}"
  local port_file="${3:-ollama-port}"
  local model="${4:-ollama/my-llama-model}"
  local server

  server="$(find_up bin/spice_fake_chat_server.exe)"
  mkdir -p "$capture"
  rm -f "$port_file"

  "$server" --capture "$capture" --port-file "$port_file" --reply "$reply" \
    --accept-timeout "${SPICE_FAKE_PROVIDER_ACCEPT_TIMEOUT:-3}" &
  SPICE_FAKE_PROVIDER_PID=$!
  export SPICE_FAKE_PROVIDER_PID

  wait_for_file "$port_file"
  export SPICE_MODEL="$model"
  export SPICE_OLLAMA_BASE_URL="http://127.0.0.1:$(cat "$port_file")"
}

trap cleanup_fake_server EXIT
