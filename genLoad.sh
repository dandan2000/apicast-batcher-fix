#!/usr/bin/env bash

# Default configuration
TOTAL_REQUESTS=100000
CONCURRENCY=25   # Number of concurrent requests (tune based on CPU/Network)

# 1. Read URL from the first positional argument ($1) if provided
URL="${1}"

# 2. Prompt interactively if no argument was passed
if [[ -z "$URL" ]]; then
  read -r -p "Enter target URL: " URL
fi

# Validate that the URL is not empty
if [[ -z "$URL" ]]; then
  echo "Error: Target URL cannot be empty." >&2
  exit 1
fi

send_request() {
  local req_num="$1"

  # In-memory generation without spawning external subprocesses
  # app_id: 8 hex characters
  local id=$(printf "%04x%04x" $RANDOM $RANDOM)

  # app_key: 32 hex characters
  local key=$(printf "%04x%04x%04x%04x%04x%04x%04x%04x" \
    $RANDOM $RANDOM $RANDOM $RANDOM $RANDOM $RANDOM $RANDOM $RANDOM)

  # -s: silent, -o /dev/null: discard payload, -w: print HTTP response code
  curl -k -s -o /dev/null -w "#${req_num} - %{http_code}\n" "$URL" \
    -H "app_id: ${id}" \
    -H "app_key: ${key}"
}

# Export function and URL variable for xargs child processes
export -f send_request
export URL

echo "Starting $TOTAL_REQUESTS requests against $URL with concurrency $CONCURRENCY..."

# seq feeds indices and xargs dispatches requests in parallel
seq 1 "$TOTAL_REQUESTS" | xargs -n 1 -P "$CONCURRENCY" -I {} bash -c 'send_request "{}"'