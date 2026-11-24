#!/usr/bin/env bash
# The clock-skew swarm: three Durable nodes in containers, one with the right
# clock, one ahead and one behind by each skew in SKEWS (seconds), against the
# test Postgres. See README.md.
set -euo pipefail

here="$(cd "$(dirname "$0")" && pwd)"
root="$(cd "$here/../../.." && pwd)"
image=durable-skew
skews=${SKEWS:-"0 1 4 40"}
out=${SKEW_OUT:-/tmp/durable-skew}
mkdir -p "$out"
log="$out/results.txt"
: >"$log"

# The source is mounted read-only, and mix.exs writes this copy if it's missing.
[ -f "$root/durable/shared.exs" ] || cp "$root/shared.exs" "$root/durable/shared.exs"

common=(
  --network "${SKEW_NETWORK:-durable_default}"
  -v "$root:/src:ro" -v durable-skew-build:/build -w /src/durable
  -e MIX_ENV=prod -e MIX_DEPS_PATH=/build/deps -e MIX_BUILD_PATH=/build/_build
  -e HEX_HOME=/build/hex -e DATABASE_URL=ecto://unused/unused
  -e SKEW_DB_HOST="${SKEW_DB_HOST:-durable-postgres-1}" -e SKEW_DB_PORT="${SKEW_DB_PORT:-5432}"
  -e ROUND_SECONDS="${ROUND_SECONDS:-130}"
)
run=(mix run --no-compile --no-deps-check test/skew/swarm.exs)

docker build -q -t "$image" "$here" >/dev/null
docker run --rm "${common[@]}" "$image" sh -c 'mix deps.get --only prod >/dev/null 2>&1 && mix compile'

stop_nodes() {
  for n in zero ahead behind; do docker rm -f "skew-$n" >/dev/null 2>&1 || true; done
}
trap stop_nodes EXIT

start_node() { # name, offset in seconds
  local faked=()
  if [ "$2" != "+0" ] && [ "$2" != "-0" ]; then
    faked=(-e LD_PRELOAD=/usr/local/lib/libfaketimeMT.so.1 -e FAKETIME="$2"
      -e FAKETIME_DONT_FAKE_MONOTONIC=1 -e DONT_FAKE_MONOTONIC=1)
  fi
  docker run -d --name "skew-$1" --hostname "skew-$1" "${common[@]}" ${faked[@]+"${faked[@]}"} -e ROLE=node \
    "$image" elixir --sname "$1" --cookie skew -S "${run[@]}" >/dev/null
}

for s in $skews; do
  echo "== skew ${s}s: zero +0, ahead +${s}, behind -${s}"
  stop_nodes
  docker run --rm "${common[@]}" -e ROLE=setup "$image" "${run[@]}"
  start_node zero +0
  start_node ahead "+$s"
  start_node behind "-$s"
  docker run --rm --name skew-orch --hostname skew-orch "${common[@]}" -e ROLE=orch -e SKEW="$s" \
    "$image" elixir --sname orch --cookie skew -S "${run[@]}" | tee -a "$log"
  for n in zero ahead behind; do docker logs "skew-$n" >"$out/node-$n-${s}s.log" 2>&1 || true; done
done

echo
echo "== Passed / checked, per skew (full results in $log)"
grep '^SUMMARY' "$log" | sort -k3,3 -k2,2V | awk '{print $3, $2, $4}' | column -t
! grep -q '^RESULT .* FAIL' "$log"
