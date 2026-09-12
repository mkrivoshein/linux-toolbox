#!/usr/bin/env bash
set -euo pipefail

check_agent() {
  if gpg-connect-agent --no-autostart 'NOP' '/bye' >/dev/null 2>&1; then
    echo "gpg-agent: running"
    return 0
  else
    echo "gpg-agent: NOT running"
    return 1
  fi
}

restart_agent() {
  echo "Restarting gpg-agent..."
  gpgconf --kill gpg-agent 2>/dev/null || true
  gpg-agent --daemon >/dev/null 2>&1 || true
  gpgconf --reload gpg-agent 2>/dev/null || true
  if check_agent; then
    echo "gpg-agent restarted successfully."
  else
    echo "Failed to start gpg-agent."
    return 1
  fi
}

echo "=== GPG Health Check ==="

if ! command -v gpg >/dev/null 2>&1; then
  echo "ERROR: gpg not found in PATH"
  exit 1
fi

echo "gpg version: $(gpg --version | head -1)"

if ! check_agent; then
  echo "Attempting to start gpg-agent..."
  gpg-agent --daemon >/dev/null 2>&1 || true
  check_agent || { echo "Could not start gpg-agent. Try manually:"; echo "  gpg-agent --daemon"; exit 1; }
fi

echo ""
echo "=== GPG Signing Test ==="
echo "Running: echo \"test\" | gpg --clearsign"
echo "(You may be prompted for your key passphrase)"
echo ""

if echo "test" | gpg --clearsign > /dev/null 2>&1; then
  echo "SUCCESS: GPG signing works."
else
  rc=$?
  echo "FAILED: GPG signing failed (exit code $rc)"
  echo ""
  echo "Troubleshooting:"
  echo "  Kill agent:    gpgconf --kill gpg-agent"
  echo "  Start agent:   gpg-agent --daemon"
  echo "  Restart agent: gpgconf --reload gpg-agent"
  echo ""
  read -rp "Attempt to restart gpg-agent and retry? [y/N] " ans
  if [[ "$ans" =~ ^[Yy]$ ]]; then
    restart_agent
    echo ""
    if echo "test" | gpg --clearsign > /dev/null 2>&1; then
      echo "SUCCESS: GPG signing works after agent restart."
    else
      echo "FAILED: GPG signing still fails after agent restart."
      exit 1
    fi
  else
    exit 1
  fi
fi
