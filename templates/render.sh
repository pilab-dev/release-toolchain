#!/usr/bin/env bash
# Render templates/goreleaser.yaml into a ready-to-use .goreleaser.yaml.
#
# Called by:
#   .github/workflows/release.yml  (toolchain checked out into .toolchain)
#   .github/workflows/lint.yml     (this repository, keeping both in step)
#
# Inputs (environment):
#   BINARY       binary + archive name                (default: repo name)
#   PACKAGE      deb/rpm package name                  (default: BINARY)
#   MAIN         main package path                     (default: .)
#   DESCRIPTION  package description                   (default: none)
#   ARCHES       space separated GOARCH list           (default: amd64 arm64 386)
#   LDPKG        package holding version/commit/date vars, or "none"
#   REPO         owner/name used for the homepage      (default: none)
#   TEMPLATE     template path                         (default: ./goreleaser.yaml)
#   OUT          output path                           (default: $PWD/.goreleaser.yaml)
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TEMPLATE=${TEMPLATE:-$HERE/goreleaser.yaml}
OUT=${OUT:-$(pwd)/.goreleaser.yaml}

BINARY=${BINARY:?BINARY is required}
PACKAGE=${PACKAGE:-$BINARY}
MAIN=${MAIN:-.}
DESCRIPTION=${DESCRIPTION:-}
ARCHES=${ARCHES:-amd64 arm64 386}
LDPKG=${LDPKG:-main}
REPO=${REPO:-}

# The rendered file becomes a URL and a filename, so refuse anything that
# could break out of them rather than trusting the caller.
[[ $BINARY =~ ^[a-z0-9][a-z0-9._+-]*$ ]] || { echo "::error::invalid binary name '$BINARY'" >&2; exit 1; }
[[ $PACKAGE =~ ^[a-z0-9][a-z0-9._+-]*$ ]] || { echo "::error::invalid package name '$PACKAGE'" >&2; exit 1; }
[[ $MAIN =~ ^[A-Za-z0-9_./-]*$ ]]         || { echo "::error::invalid main path '$MAIN'" >&2; exit 1; }
for a in $ARCHES; do
    [[ $a =~ ^(amd64|arm64|arm|386|ppc64le|s390x|riscv64|loong64)$ ]] \
        || { echo "::error::unsupported arch '$a'" >&2; exit 1; }
done

# YAML flow list: "amd64","arm64","386"
arches=$(printf '%s' "$ARCHES" | tr -s ' ' ',' | sed -E 's/([^,]+)/"\1"/g' | sed 's/,$//')
if [ "$LDPKG" = none ]; then
    ldflags="'-s -w'"
else
    [[ $LDPKG =~ ^[A-Za-z0-9_./-]*$ ]] || { echo "::error::invalid ldflags package '$LDPKG'" >&2; exit 1; }
    ldflags="'-s -w', '-X ${LDPKG}.version={{ .Version }}', '-X ${LDPKG}.commit={{ .Commit }}', '-X ${LDPKG}.date={{ .Date }}'"
fi
# A double quote or backslash would end the quoted YAML scalar early.
desc=$(printf '%s' "$DESCRIPTION" | sed 's/["\\]//g' | cut -c1-200)

sed -e "s|__BINARY__|$BINARY|g" \
    -e "s|__PACKAGE__|$PACKAGE|g" \
    -e "s|__MAIN__|$MAIN|g" \
    -e "s|__DESCRIPTION__|$desc|g" \
    -e "s|__ARCHES__|$arches|g" \
    -e "s|__LDFLAGS__|$ldflags|g" \
    -e "s|__REPO__|$REPO|g" \
    "$TEMPLATE" > "$OUT"

# A template edit that forgets a placeholder must fail the build, not ship.
# Comments may mention the placeholder pattern, so ignore commented lines.
leftovers=$(grep -n '__[A-Z][A-Z_]*__' "$OUT" | grep -v '^[0-9]*:[[:space:]]*#' || true)
if [ -n "$leftovers" ]; then
    echo "::error::unrendered placeholder in $OUT:" >&2
    echo "$leftovers" >&2
    exit 1
fi

echo "rendered $OUT"
cat "$OUT"
