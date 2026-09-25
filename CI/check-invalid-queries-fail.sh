#!/usr/bin/env bash
# Asserts that queries Postgres rejects do not compile.
#
# Hangar's claim is that a broken query is a build error rather than a failed
# request. A claim like that rots quietly: widen one overload and the invalid
# form starts compiling again, every test still passes, and nobody learns until
# a query reaches a server. So this compiles a package of deliberately invalid
# queries and fails if the build SUCCEEDS.
#
# It also checks the message. An error that says "binary operator cannot be
# applied" is technically a caught mistake and practically a dead end; these
# errors name the Postgres rule and the fix, and that is worth pinning too.
set -uo pipefail
cd "$(dirname "$0")/invalid-queries"

output=$(swift build 2>&1)
status=$?

if [ $status -eq 0 ]; then
  echo "::error::invalid queries compiled — the compile-time guarantee has regressed"
  exit 1
fi

missing=0
while IFS= read -r phrase; do
  if ! grep -qF "$phrase" <<< "$output"; then
    echo "::error::the build failed, but no diagnostic mentioned: $phrase"
    missing=1
  fi
done <<'PHRASES'
Aggregate functions are not allowed in WHERE
Window functions are not allowed in WHERE or HAVING
.groupBy { $0.someColumn }.having { ... }
A grouped query has no whole rows to fetch
A frame cannot start at UNBOUNDED FOLLOWING
A frame cannot end at UNBOUNDED PRECEDING
PHRASES

# Every diagnostic code Hangar declares must be produced by this build and
# have a page, and every page must belong to a code that exists — a code
# nothing proves, or a page for a code nothing emits, is a promise nothing
# checks. The page is where the message's link points.
cd ../..
declared=$(grep -rhoE '\[HGR-QUERY-[0-9]{4}\]' Sources | tr -d '[]' | sort -u)
# Codes reported when a query runs rather than when it compiles — held as a
# quoted constant, since the message interpolates it. Proven by a test
# asserting the code, not by this build.
runtime=$(grep -rhoE '"HGR-QUERY-[0-9]{4}"' Sources | tr -d '"' | sort -u)
pages=$(ls Diagnostics | sed -n 's/\.md$//p' | sort -u)
for code in $runtime; do
  [ -f "Diagnostics/$code.md" ] || { echo "::error::$code has no page in Diagnostics/"; missing=1; }
  grep -rqF "$code" Tests || { echo "::error::$code is reported at runtime but no test asserts it"; missing=1; }
done
for code in $declared; do
  grep -qF "[$code]" <<< "$output" || { echo "::error::$code is declared but the invalid-queries build never produced it"; missing=1; }
  [ -f "Diagnostics/$code.md" ] || { echo "::error::$code has no page in Diagnostics/"; missing=1; }
done
for page in $pages; do
  grep -qx "$page" <<< "$declared"$'\n'"$runtime" || { echo "::error::Diagnostics/$page.md is for a code no source declares"; missing=1; }
done
covered=$(printf '%s\n%s\n' "$declared" "$runtime" | grep -c . || true)

if [ $missing -ne 0 ]; then
  echo "--- build output ---"
  echo "$output"
  exit 1
fi

echo "invalid queries are compile errors, and each names its fix ($covered/$covered diagnostic codes proven)"
