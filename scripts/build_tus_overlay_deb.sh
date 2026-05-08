#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PKG_NAME="gitlab-ce-tus-overlay"
PKG_VERSION="$(tr -d '\n' < "${ROOT_DIR}/VERSION")"
ARCH="all"
BUILD_DIR="${ROOT_DIR}/tmp/tus-overlay-deb"
PKG_ROOT="${BUILD_DIR}/${PKG_NAME}_${PKG_VERSION}_${ARCH}"
DEBIAN_DIR="${PKG_ROOT}/DEBIAN"
PAYLOAD_ROOT="${PKG_ROOT}/opt/gitlab/embedded/service/gitlab-rails"
OUT_DIR="${ROOT_DIR}/pkg"
DEB_PATH="${OUT_DIR}/${PKG_NAME}_${PKG_VERSION}_${ARCH}.deb"

rm -rf "${BUILD_DIR}"
mkdir -p "${DEBIAN_DIR}" "${PAYLOAD_ROOT}" "${OUT_DIR}"

install -D -m 0644 "${ROOT_DIR}/app/controllers/repositories/lfs_api_controller.rb" \
  "${PAYLOAD_ROOT}/app/controllers/repositories/lfs_api_controller.rb"
install -D -m 0644 "${ROOT_DIR}/app/controllers/repositories/lfs_storage_controller.rb" \
  "${PAYLOAD_ROOT}/app/controllers/repositories/lfs_storage_controller.rb"
install -D -m 0644 "${ROOT_DIR}/app/services/lfs/tus_upload_service.rb" \
  "${PAYLOAD_ROOT}/app/services/lfs/tus_upload_service.rb"
install -D -m 0644 "${ROOT_DIR}/config/routes/git_http.rb" \
  "${PAYLOAD_ROOT}/config/routes/git_http.rb"

cat > "${DEBIAN_DIR}/control" <<EOF
Package: ${PKG_NAME}
Version: ${PKG_VERSION}
Section: misc
Priority: optional
Architecture: ${ARCH}
Maintainer: Codex <codex@example.com>
Depends: gitlab-ce
Description: GitLab CE TUS/LFS overlay package
 Installs the GitLab Rails changes required for TUS-based Git LFS uploads
 on an existing Omnibus GitLab CE installation.
EOF

cat > "${DEBIAN_DIR}/postinst" <<'EOF'
#!/bin/sh
set -e

if command -v gitlab-ctl >/dev/null 2>&1; then
  gitlab-ctl hup puma || true
  gitlab-ctl hup sidekiq || true
fi

exit 0
EOF
chmod 0755 "${DEBIAN_DIR}/postinst"

dpkg-deb --build "${PKG_ROOT}" "${DEB_PATH}"
printf '%s\n' "${DEB_PATH}"
