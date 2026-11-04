#!/usr/bin/env bash
# Run as root from the Dockerfile (online): pre-fetch the few third-party tarballs that apt trixie
# cannot satisfy (too old) into a root-owned, $HOME-independent dir, pinned by arrow's own sha256s.
# build.sh then points arrow's cmake at them via ARROW_<DEP>_URL=file://..., so it is air-gapped.
set -euo pipefail
DEST=/opt/toolchains/arrow-deps
VERSIONS="${1:-/mayhem/cpp/thirdparty/versions.txt}"
source "$VERSIONS"
mkdir -p "$DEST"
for dep in SIMDJSON XSIMD; do
  ver_var="ARROW_${dep}_BUILD_VERSION"; sha_var="ARROW_${dep}_BUILD_SHA256_CHECKSUM"
  entry="$(printf '%s\n' "${DEPENDENCIES[@]}" | grep "^\"\?ARROW_${dep}_URL " | head -1 | tr -d '"')"
  file="$(echo "$entry" | cut -d' ' -f2)"; url="$(echo "$entry" | cut -d' ' -f3)"
  curl -fsSL --retry 5 -o "$DEST/$file" "$url"
  echo "${!sha_var}  $DEST/$file" | sha256sum -c -
done
chmod -R a+rX,go-w "$DEST"
