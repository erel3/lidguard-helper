app_name := "lidguard-helper"
build_dir := ".build/release"
install_dir := home_directory() + "/Library/Application Support/LidGuard"
plist_label := "com.lidguard.helper"
plist_src := "com.lidguard.helper.plist"
plist_dst := home_directory() + "/Library/LaunchAgents/" + plist_label + ".plist"
version_file := "VERSION"
bump := env("BUMP", "patch")
codesign_id := env("CODESIGN_ID", "Developer ID Application: Andrey Kim (73R36N2A46)")
installer_id := env("INSTALLER_ID", "Developer ID Installer: Andrey Kim (73R36N2A46)")
codesign_req := env("CODESIGN_REQ", 'designated => anchor apple generic and certificate leaf[subject.OU] = "73R36N2A46"')
notarize_profile := env("NOTARIZE_PROFILE", "Notarize")

version := `cat VERSION 2>/dev/null || echo "1.0.0"`

# Build release binary
build:
    swift build -c release

# Build debug binary and run directly
run-debug:
    swift build && .build/debug/{{app_name}}

# Build, install binary + LaunchAgent, load via launchctl
install: build
    #!/usr/bin/env bash
    set -euo pipefail
    echo "Installing {{app_name}} v{{version}}"
    mkdir -p "{{install_dir}}"
    cp {{build_dir}}/{{app_name}} "{{install_dir}}/"
    sed 's|INSTALL_PATH|{{install_dir}}|g' {{plist_src}} > "{{plist_dst}}"
    launchctl bootout gui/$(id -u) "{{plist_dst}}" 2>/dev/null || true
    launchctl bootstrap gui/$(id -u) "{{plist_dst}}"
    echo "Installed and loaded {{plist_label}}"

# Unload and remove
uninstall:
    #!/usr/bin/env bash
    set -euo pipefail
    launchctl bootout gui/$(id -u) "{{plist_dst}}" 2>/dev/null || true
    rm -f "{{plist_dst}}"
    rm -f "{{install_dir}}/{{app_name}}"
    echo "Uninstalled {{app_name}}"

# Release: bump version, build, codesign, notarize, commit, tag, push, create GH release
release:
    #!/usr/bin/env bash
    set -euo pipefail
    test -f RELEASE_NOTES.md || { echo "Error: RELEASE_NOTES.md is required. Write release notes first."; exit 1; }
    just _bump
    just build
    just _sign
    just _pkg
    just _notarize
    VERSION=$(cat {{version_file}})
    TITLE="${TITLE:-v$VERSION}"
    git add {{version_file}} Sources/main.swift
    git commit -m "chore: bump version to $VERSION"
    git tag "v$VERSION"
    git push origin main --tags
    gh release create "v$VERSION" "dist/{{app_name}}-$VERSION.pkg" \
        --title "$TITLE" --notes-file RELEASE_NOTES.md
    rm -f RELEASE_NOTES.md
    echo "Released v$VERSION"

# Run swiftlint --strict on Sources/
lint:
    #!/usr/bin/env bash
    set -euo pipefail
    TOOLCHAIN_DIR=$(dirname "$(dirname "$(xcrun --find swiftc)")")
    DYLD_FRAMEWORK_PATH="$TOOLCHAIN_DIR/lib" swiftlint lint --strict Sources/

# Remove .build and dist
clean:
    rm -rf .build dist

# Print current version
version:
    @cat {{version_file}}

[private]
_sign:
    #!/usr/bin/env bash
    set -euo pipefail
    echo "Signing {{app_name}}..."
    codesign --force --sign "{{codesign_id}}" \
        -o runtime --timestamp \
        -r='{{codesign_req}}' \
        {{build_dir}}/{{app_name}}
    echo "Signed"

[private]
_pkg:
    #!/usr/bin/env bash
    set -euo pipefail
    echo "Building PKG installer..."
    VERSION=$(cat {{version_file}})
    mkdir -p dist/pkg-root/payload
    cp {{build_dir}}/{{app_name}} dist/pkg-root/payload/
    cp {{plist_src}} dist/pkg-root/payload/
    pkgbuild --root dist/pkg-root/payload \
        --identifier {{plist_label}} \
        --version $VERSION \
        --install-location /tmp/lidguard-helper-pkg \
        --scripts scripts \
        --sign "{{installer_id}}" \
        dist/{{app_name}}-$VERSION.pkg
    rm -rf dist/pkg-root
    echo "Built: dist/{{app_name}}-$VERSION.pkg"

[private]
_notarize:
    #!/usr/bin/env bash
    set -euo pipefail
    echo "Notarizing PKG..."
    VERSION=$(cat {{version_file}})
    xcrun notarytool submit dist/{{app_name}}-$VERSION.pkg \
        --keychain-profile "{{notarize_profile}}" --wait
    xcrun stapler staple dist/{{app_name}}-$VERSION.pkg
    echo "Notarization complete"

[private]
_bump:
    #!/usr/bin/env bash
    set -euo pipefail
    VERSION=$(cat {{version_file}})
    MAJOR=$(echo $VERSION | cut -d. -f1)
    MINOR=$(echo $VERSION | cut -d. -f2)
    PATCH=$(echo $VERSION | cut -d. -f3)
    case "{{bump}}" in
        major) MAJOR=$((MAJOR + 1)); MINOR=0; PATCH=0;;
        minor) MINOR=$((MINOR + 1)); PATCH=0;;
        patch) PATCH=$((PATCH + 1));;
    esac
    NEW="$MAJOR.$MINOR.$PATCH"
    echo "$NEW" > {{version_file}}
    sed -i '' "s/let helperVersion = \".*\"/let helperVersion = \"$NEW\"/" Sources/main.swift
    echo "Version bumped to $NEW"
