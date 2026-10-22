#!/usr/bin/env bash
# Lambda(arm64, Python 3.13) 배포 묶음을 만든다. 사용: alert-analyzer/build.sh <출력 zip 경로>
set -euo pipefail
cd "$(dirname "$0")"
out="${1:-dist/alert-analyzer.zip}"
mkdir -p "$(dirname "$out")"
out="$(cd "$(dirname "$out")" && pwd)/$(basename "$out")"
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
python3 -m pip install --quiet --target "$work" --platform manylinux2014_aarch64 --implementation cp \
  --python-version 3.13 --only-binary=:all: -r requirements.txt
cp handler.py diagnose.py tools.py prompt.md "$work/"
rm -f "$out"
(cd "$work" && zip -qr "$out" .)
