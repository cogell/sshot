#!/usr/bin/env bash
set -euo pipefail

# Build SSHot.app for release and package as .zip
# Usage: ./scripts/build-release.sh [version]
# Example: ./scripts/build-release.sh 1.0.0

VERSION="${1:-$(grep 'MARKETING_VERSION' project.yml | head -1 | sed 's/.*: *"\(.*\)"/\1/')}"
BUILD_DIR="build"
ARCHIVE_PATH="$BUILD_DIR/SSHot.xcarchive"
ZIP_NAME="SSHot-${VERSION}.zip"

echo "==> Building SSHot v${VERSION}"

# Generate Xcode project from project.yml
echo "==> Generating Xcode project..."
xcodegen generate

# Clean build directory
rm -rf "$BUILD_DIR"
mkdir -p "$BUILD_DIR"

# Archive
echo "==> Archiving..."
xcodebuild archive \
  -project SSHot.xcodeproj \
  -scheme SSHot \
  -configuration Release \
  -archivePath "$ARCHIVE_PATH" \
  -quiet

# Check for Developer ID certificate
HAS_DEVELOPER_ID=$(security find-identity -v -p codesigning | grep -c "Developer ID Application" || true)

if [ "$HAS_DEVELOPER_ID" -gt 0 ]; then
  echo "==> Exporting with Developer ID signing..."
  EXPORT_PATH="$BUILD_DIR/export"
  mkdir -p "$EXPORT_PATH"

  cat > "$BUILD_DIR/ExportOptions.plist" << 'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>method</key>
    <string>developer-id</string>
</dict>
</plist>
PLIST

  xcodebuild -exportArchive \
    -archivePath "$ARCHIVE_PATH" \
    -exportPath "$EXPORT_PATH" \
    -exportOptionsPlist "$BUILD_DIR/ExportOptions.plist" \
    -quiet

  APP_PATH="$EXPORT_PATH/SSHot.app"
else
  echo "==> No Developer ID certificate found — extracting from archive (unsigned for distribution)"
  echo "    To sign: create a 'Developer ID Application' cert at developer.apple.com"
  echo "    On other Macs: right-click → Open to bypass Gatekeeper, or run:"
  echo "      xattr -d com.apple.quarantine /Applications/SSHot.app"
  APP_PATH="$ARCHIVE_PATH/Products/Applications/SSHot.app"
fi

# Create zip
echo "==> Creating ${ZIP_NAME}..."
cd "$(dirname "$APP_PATH")"
zip -r -q "${OLDPWD}/${ZIP_NAME}" SSHot.app
cd "$OLDPWD"

# Compute SHA256
SHA256=$(shasum -a 256 "$ZIP_NAME" | awk '{print $1}')

echo ""
echo "==> Done!"
echo "    Artifact: ${ZIP_NAME}"
echo "    SHA256:   ${SHA256}"
echo ""
echo "Next steps:"
echo "  1. git tag v${VERSION} && git push origin v${VERSION}"
echo "  2. gh release create v${VERSION} ${ZIP_NAME} --title \"SSHot v${VERSION}\" --generate-notes"
echo "  3. Update homebrew tap SHA256 to: ${SHA256}"
