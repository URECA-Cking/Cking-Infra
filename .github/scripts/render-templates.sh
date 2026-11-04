#!/usr/bin/env bash
# Terraform templatefile로 만드는 서버 부팅 스크립트를 shellcheck할 수 있게 펼쳐 <출력 폴더>에 같은 경로로 쓴다.
# Terraform 변수 ${이름}은 tfvar_이름으로, 이스케이프 $${…}는 셸의 ${…}로 바꾸고,
# ${server_base} 한 줄에는 Terraform과 같이 펼친 server-base.sh를 넣는다.
# 사용: .github/scripts/render-templates.sh <출력 폴더> <템플릿>...
set -euo pipefail

render() {
  sed -E 's/(^|[^$])\$\{([a-z0-9_]+)\}/\1tfvar_\2/g; s/\$\$\{/${/g' "$1"
}

out=$1
shift
mkdir -p "$out"
base="$out/.server-base.sh"
render envs/prod/templates/server-base.sh > "$base"
for f in "$@"; do
  mkdir -p "$out/$(dirname "$f")"
  render "$f" | awk -v base="$base" '
    $0 == "tfvar_server_base" { while ((getline line < base) > 0) print line; close(base); next }
    { print }' > "$out/$f"
done
