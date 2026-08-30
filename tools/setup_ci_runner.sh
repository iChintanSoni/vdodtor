#!/usr/bin/env bash
#
# setup_ci_runner.sh — register this Mac as the self-hosted CI runner.
#
# Run once. Everything it needs that is secret comes from you:
#
#   1. Open  https://github.com/iChintanSoni/vdodtor/settings/actions/runners/new
#   2. Copy the registration token (it expires after an hour).
#   3. tools/setup_ci_runner.sh <TOKEN>
#
# Afterwards the runner runs as a launchd service and survives reboots.
#   Status:  tools/setup_ci_runner.sh --status
#   Stop:    cd ~/actions-runner && ./svc.sh stop
#   Remove:  cd ~/actions-runner && ./svc.sh uninstall && ./config.sh remove --token <TOKEN>
#
set -euo pipefail

REPO_URL="https://github.com/iChintanSoni/vdodtor"
RUNNER_DIR="$HOME/actions-runner"
RUNNER_NAME="${RUNNER_NAME:-$(scutil --get ComputerName | tr ' ' '-')}"
LABELS="self-hosted,macOS,ARM64"

if [[ "${1:-}" == "--status" ]]; then
  if [[ -d "$RUNNER_DIR" ]]; then
    cd "$RUNNER_DIR" && ./svc.sh status
  else
    echo "no runner installed at $RUNNER_DIR"
    exit 1
  fi
  exit 0
fi

TOKEN="${1:-}"
if [[ -z "$TOKEN" ]]; then
  echo "usage: $0 <registration-token>   (get one at $REPO_URL/settings/actions/runners/new)" >&2
  echo "       $0 --status" >&2
  exit 1
fi

# The workflow refuses to install anything itself, so check here instead —
# this is the one place that is allowed to talk about the machine's setup.
echo "==> checking the toolchain the workflow expects"
missing=()
for tool in cmake nasm flutter dart xcodebuild rsync; do
  command -v "$tool" >/dev/null || missing+=("$tool")
done
if (( ${#missing[@]} )); then
  echo "missing: ${missing[*]}" >&2
  echo "install them first (brew install cmake nasm; Flutter and Xcode by hand)" >&2
  exit 1
fi

if [[ "$(uname -m)" != "arm64" ]]; then
  echo "warning: this Mac is $(uname -m), but the workflow asks for the ARM64 label" >&2
fi

mkdir -p "$RUNNER_DIR"
cd "$RUNNER_DIR"

if [[ ! -x ./config.sh ]]; then
  echo "==> downloading the latest runner for macOS arm64"
  url="$(curl -fsSL https://api.github.com/repos/actions/runner/releases/latest \
    | grep -o 'https://[^"]*osx-arm64-[0-9.]*\.tar\.gz' | head -1)"
  [[ -n "$url" ]] || { echo "could not find a runner download url" >&2; exit 1; }
  echo "    $url"
  curl -fL --retry 3 -o runner.tar.gz "$url"
  tar xzf runner.tar.gz
  rm -f runner.tar.gz
fi

if [[ -f .runner ]]; then
  echo "==> runner already configured as '$(grep -o '"agentName": *"[^"]*"' .runner | cut -d'"' -f4)'"
else
  echo "==> registering as '$RUNNER_NAME' with labels $LABELS"
  ./config.sh --unattended \
    --url "$REPO_URL" \
    --token "$TOKEN" \
    --name "$RUNNER_NAME" \
    --labels "$LABELS" \
    --work _work \
    --replace
fi

echo "==> installing the launchd service"
./svc.sh install
./svc.sh start
./svc.sh status

cat <<'DONE'

Runner is up. Two things worth knowing:

  * It builds with *your* Xcode, Flutter and signing identity, so a green run
    means the same thing a local build does — that is the point of self-hosting
    this one.
  * The workspace persists between runs. The workflow cleans build output
    itself and keeps third_party/ffmpeg, which is why a run after the first
    takes minutes rather than a quarter of an hour.
DONE
