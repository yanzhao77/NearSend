#!/usr/bin/env bash
# Package a Flutter Linux release bundle as a relocatable tarball and a .deb.
# Usage: package_linux_deb.sh <version> <build-number> <bundle-dir> <output-dir>

set -euo pipefail

version="$1"
build_number="$2"
bundle_dir="$3"
output_dir="$4"

if [ ! -d "$bundle_dir" ]; then
  echo "Linux bundle not found: $bundle_dir" >&2
  exit 1
fi

mkdir -p "$output_dir"
tar -C "$bundle_dir" -czf "$output_dir/NearSend-${version}-linux-x64.tar.gz" .

staging="$(mktemp -d)"
trap 'rm -rf "$staging"' EXIT

mkdir -p \
  "$staging/DEBIAN" \
  "$staging/opt/nearsend" \
  "$staging/usr/bin" \
  "$staging/usr/share/applications"
cp -a "$bundle_dir/." "$staging/opt/nearsend/"

cat > "$staging/DEBIAN/control" <<EOF
Package: nearsend
Version: ${version}-${build_number}
Section: net
Priority: optional
Architecture: amd64
Maintainer: NearSend maintainers
Description: NearSend offline file transfer
 Secure, resumable file transfer over a local Wi-Fi network.
EOF

cat > "$staging/usr/bin/nearsend" <<'EOF'
#!/bin/sh
exec /opt/nearsend/nearsend "$@"
EOF
chmod 0755 "$staging/usr/bin/nearsend"

cat > "$staging/usr/share/applications/nearsend.desktop" <<EOF
[Desktop Entry]
Name=NearSend
Comment=Offline file transfer over local Wi-Fi
Exec=/usr/bin/nearsend
Terminal=false
Type=Application
Categories=Network;Utility;
EOF

dpkg-deb --build --root-owner-group "$staging" "$output_dir/NearSend-${version}-linux-amd64.deb" >/dev/null
