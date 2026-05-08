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
APP_ROOT="/opt/gitlab/embedded/service/gitlab-rails"

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
Replaces: gitlab-ce
Description: GitLab CE TUS/LFS overlay package
 Installs the GitLab Rails changes required for TUS-based Git LFS uploads
 on an existing Omnibus GitLab CE installation.
EOF

cat > "${DEBIAN_DIR}/preinst" <<EOF
#!/bin/sh
set -e

APP_ROOT="${APP_ROOT}"
EXPECTED_VERSION="${PKG_VERSION}"
BACKUP_ROOT="/var/opt/gitlab/tus-overlay-backups"

if [ ! -d "\$APP_ROOT" ]; then
  echo "GitLab Rails app path not found: \$APP_ROOT" >&2
  exit 1
fi

if [ ! -f "\$APP_ROOT/VERSION" ]; then
  echo "GitLab VERSION file not found under \$APP_ROOT" >&2
  exit 1
fi

INSTALLED_VERSION="\$(tr -d '\n' < "\$APP_ROOT/VERSION")"
if [ "\$INSTALLED_VERSION" != "\$EXPECTED_VERSION" ] && [ "\${GITLAB_TUS_OVERLAY_ALLOW_VERSION_MISMATCH:-}" != "1" ]; then
  echo "Refusing to install ${PKG_NAME}: installed GitLab is \$INSTALLED_VERSION, package was built for \$EXPECTED_VERSION." >&2
  echo "Set GITLAB_TUS_OVERLAY_ALLOW_VERSION_MISMATCH=1 only if you have validated this patch against that exact GitLab build." >&2
  exit 1
fi

STAMP="\$(date +%Y%m%d%H%M%S)"
BACKUP_DIR="\$BACKUP_ROOT/\$EXPECTED_VERSION-\$STAMP"
mkdir -p "\$BACKUP_DIR"

for rel in \\
  app/controllers/repositories/lfs_api_controller.rb \\
  app/controllers/repositories/lfs_storage_controller.rb \\
  app/services/lfs/tus_upload_service.rb \\
  config/routes/git_http.rb
do
  if [ -e "\$APP_ROOT/\$rel" ]; then
    mkdir -p "\$BACKUP_DIR/\$(dirname "\$rel")"
    cp -a "\$APP_ROOT/\$rel" "\$BACKUP_DIR/\$rel"
    echo "\$rel" >> "\$BACKUP_DIR/files"
  else
    echo "\$rel" >> "\$BACKUP_DIR/missing"
  fi
done

ln -sfn "\$BACKUP_DIR" "\$BACKUP_ROOT/latest"
printf '%s\n' "\$BACKUP_DIR" > "\$BACKUP_ROOT/last"

exit 0
EOF
chmod 0755 "${DEBIAN_DIR}/preinst"

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

cat > "${DEBIAN_DIR}/postrm" <<EOF
#!/bin/sh
set -e

APP_ROOT="${APP_ROOT}"
BACKUP_ROOT="/var/opt/gitlab/tus-overlay-backups"

case "\$1" in
  remove|purge)
    if [ "\${GITLAB_TUS_OVERLAY_RESTORE_ON_REMOVE:-1}" = "0" ]; then
      exit 0
    fi

    if [ -f "\$BACKUP_ROOT/last" ]; then
      BACKUP_DIR="\$(cat "\$BACKUP_ROOT/last")"
    elif [ -L "\$BACKUP_ROOT/latest" ]; then
      BACKUP_DIR="\$(readlink -f "\$BACKUP_ROOT/latest")"
    else
      BACKUP_DIR=""
    fi

    if [ -n "\$BACKUP_DIR" ] && [ -d "\$BACKUP_DIR" ]; then
      if [ -f "\$BACKUP_DIR/files" ]; then
        while IFS= read -r rel; do
          [ -n "\$rel" ] || continue
          mkdir -p "\$APP_ROOT/\$(dirname "\$rel")"
          cp -a "\$BACKUP_DIR/\$rel" "\$APP_ROOT/\$rel"
        done < "\$BACKUP_DIR/files"
      fi

      if [ -f "\$BACKUP_DIR/missing" ]; then
        while IFS= read -r rel; do
          [ -n "\$rel" ] || continue
          rm -f "\$APP_ROOT/\$rel"
        done < "\$BACKUP_DIR/missing"
      fi
    fi

    if command -v gitlab-ctl >/dev/null 2>&1; then
      gitlab-ctl hup puma || true
      gitlab-ctl hup sidekiq || true
    fi
    ;;
esac

exit 0
EOF
chmod 0755 "${DEBIAN_DIR}/postrm"

dpkg-deb --root-owner-group --build "${PKG_ROOT}" "${DEB_PATH}"
printf '%s\n' "${DEB_PATH}"
