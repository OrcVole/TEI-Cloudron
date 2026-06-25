#!/bin/bash
#
# Secret-scan and anonymity sweep. Run before any push (docs/RELEASING.md gate 6).
#
# Scans tracked files for secrets and personal or internal identifiers that must never appear in the
# public package. Exits non-zero if anything is found.
#
# This tracked script contains NO private identifiers itself. The maintainer-specific list of hosts,
# paths, and emails to forbid lives in a gitignored file `.anonymize-list` (one extended-regex per
# line), so publishing this script never leaks them.

set -uo pipefail
cd "$(dirname "$0")/.." || exit 2

# Generic secret shapes, safe to hardcode.
patterns=(
  'BEGIN [A-Z ]*PRIVATE KEY'
  'ghp_[A-Za-z0-9]{30,}'
  'github_pat_[A-Za-z0-9_]{20,}'
  'glpat-[A-Za-z0-9_-]{20,}'
)

# Maintainer-specific private identifiers, read from the gitignored list if present.
extra=()
if [ -f .anonymize-list ]; then
  while IFS= read -r line; do
    [ -z "$line" ] && continue
    case "$line" in \#*) continue ;; esac
    extra+=("$line")
  done < .anonymize-list
fi

# Files to scan: tracked files when in git (gitignored files are excluded automatically); otherwise
# every file except the .git dir, the scratchpad, the local-only list, and the editor settings.
if git rev-parse --git-dir >/dev/null 2>&1; then
  mapfile -t files < <(git ls-files)
else
  mapfile -t files < <(find . -type f \
    -not -path './.git/*' -not -path './scratchpad/*' \
    -not -path './.claude/*' -not -name .anonymize-list \
    -not -name STATUS.md -not -name RECON.md)
fi

hits=0
scan() {
  local label="$1"; shift
  for p in "$@"; do
    [ -z "$p" ] && continue
    local m
    m="$(printf '%s\0' "${files[@]}" | xargs -0 grep -InE -- "$p" 2>/dev/null)"
    if [ -n "$m" ]; then echo "LEAK [${label}] /${p}/:"; printf '%s\n' "$m"; hits=1; fi
  done
}
scan secret "${patterns[@]}"
[ "${#extra[@]}" -gt 0 ] && scan private "${extra[@]}"

for tok in githubtoken.txt forgejotoken.txt orcvole-token.txt; do
  if printf '%s\n' "${files[@]}" | grep -qx "$tok"; then echo "LEAK: ${tok} is tracked"; hits=1; fi
done

if [ "$hits" -eq 0 ]; then echo "secret-scan: clean"; else echo "secret-scan: FOUND issues (see above)"; fi
exit "$hits"
