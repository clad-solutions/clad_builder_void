#!/usr/bin/env bash
# shellcheck disable=SC1091

set -e

APP_NAME_LC="$( echo "${APP_NAME}" | awk '{print tolower($0)}' )"

mkdir -p assets

if [[ "${OS_NAME}" == "osx" ]]; then
  if [[ -n "${CERTIFICATE_OSX_P12_DATA}" ]]; then
    if [[ "${CI_BUILD}" == "no" ]]; then
      RUNNER_TEMP="${TMPDIR}"
    fi

    CERTIFICATE_P12="${APP_NAME}.p12"
    KEYCHAIN="${RUNNER_TEMP}/buildagent.keychain"
    AGENT_TEMPDIRECTORY="${RUNNER_TEMP}"
    # shellcheck disable=SC2006
    KEYCHAINS=`security list-keychains | xargs`

    rm -f "${KEYCHAIN}"

    echo "${CERTIFICATE_OSX_P12_DATA}" | base64 --decode > "${CERTIFICATE_P12}"

    echo "+ create temporary keychain"
    security create-keychain -p pwd "${KEYCHAIN}"
    security set-keychain-settings -lut 21600 "${KEYCHAIN}"
    security unlock-keychain -p pwd "${KEYCHAIN}"
    # shellcheck disable=SC2086
    security list-keychains -s $KEYCHAINS "${KEYCHAIN}"
    # security show-keychain-info "${KEYCHAIN}"

    echo "+ import certificate to keychain"
    security import "${CERTIFICATE_P12}" -k "${KEYCHAIN}" -P "${CERTIFICATE_OSX_P12_PASSWORD}" -T /usr/bin/codesign
    security set-key-partition-list -S apple-tool:,apple:,codesign: -s -k pwd "${KEYCHAIN}" > /dev/null
    # security find-identity "${KEYCHAIN}"

    CODESIGN_IDENTITY="$( security find-identity -v -p codesigning "${KEYCHAIN}" | grep -oEi "([0-9A-F]{40})" | head -n 1 )"

    echo "+ fixing file permissions before signing"
    cd "VSCode-darwin-${VSCODE_ARCH}"
    APP_FILE_TEMP="$(find . -maxdepth 1 -name '*.app' -print -quit)"

    if [ -n "$APP_FILE_TEMP" ]; then
      # Remove execute permissions from scripts, WASM, and text files
      # These don't need +x and Apple treats them as executables requiring signatures
      FIXED_COUNT=$(find "$APP_FILE_TEMP/Contents/Resources/app" -type f \( \
        -name "*.sh" -o \
        -name "*.js" -o \
        -name "*.wasm" -o \
        -name "LICENSE" -o \
        -name "bower.json" -o \
        -name "*.json" -o \
        -name "*.md" \
      \) -perm +111 -exec chmod -x {} \; -print 2>/dev/null | wc -l | tr -d ' ')

      # Also remove execute from CLI scripts in bin/ directories
      # These are Node.js/shell scripts that don't need to be signed
      BIN_COUNT=$(find "$APP_FILE_TEMP/Contents/Resources/app" -type f -path "*/bin/*" -perm +111 ! -name "*.dylib" ! -name "*.node" ! -name "*.so" -exec chmod -x {} \; -print 2>/dev/null | wc -l | tr -d ' ')

      # Remove execute from ALL files in node_modules that aren't native binaries
      # This catches edge cases like xdg-open (no extension, not in bin/)
      NODE_MODULES_COUNT=$(find "$APP_FILE_TEMP/Contents/Resources/app/node_modules" -type f -perm +111 ! -name "*.dylib" ! -name "*.node" ! -name "*.so" -exec chmod -x {} \; -print 2>/dev/null | wc -l | tr -d ' ')

      TOTAL_FIXED=$((FIXED_COUNT + BIN_COUNT + NODE_MODULES_COUNT))
      echo "  Removed execute permissions from ${TOTAL_FIXED} script/data files (${FIXED_COUNT} general + ${BIN_COUNT} bin/ + ${NODE_MODULES_COUNT} node_modules)"
    fi
    cd ..

    echo "+ signing"
    export CODESIGN_IDENTITY AGENT_TEMPDIRECTORY

    DEBUG="electron-osx-sign*" node vscode/build/darwin/sign.js "$( pwd )"
    # codesign --display --entitlements :- ""

    echo "=========================================="
    echo "COMPREHENSIVE POST-SIGNING DIAGNOSTICS"
    echo "=========================================="

    cd "VSCode-darwin-${VSCODE_ARCH}"

    APP_FILE="$(find . -maxdepth 1 -name '*.app' -print -quit)"
    if [ -z "$APP_FILE" ]; then
      echo "[DIAGNOSTIC] ERROR: .app not found"
      exit 1
    fi
    echo "[DIAGNOSTIC] Found app: $APP_FILE"

    # DIAGNOSTIC 1: Full codesign verbose output (first 120 lines)
    echo ""
    echo "[DIAGNOSTIC] === Full codesign output (first 120 lines) ==="
    codesign -dv --verbose=4 "$APP_FILE" 2>&1 | head -120
    echo ""

    # DIAGNOSTIC 2: Deep strict verification
    echo "[DIAGNOSTIC] === Deep strict code signature verification ==="
    if codesign --verify --deep --strict --verbose=2 "$APP_FILE" 2>&1; then
      echo "[DIAGNOSTIC] ✅ Deep code signature verification: PASSED"
    else
      echo "[DIAGNOSTIC] ❌ Deep code signature verification: FAILED"
      echo "[DIAGNOSTIC] This will likely cause notarization to fail or timeout"
    fi
    echo ""

    # DIAGNOSTIC 3: Check for hardened runtime
    echo "[DIAGNOSTIC] === Hardened runtime check ==="
    CODESIGN_INFO=$(codesign -dv --verbose=4 "$APP_FILE" 2>&1)
    if echo "$CODESIGN_INFO" | grep -q "runtime"; then
      echo "[DIAGNOSTIC] ✅ Hardened runtime: ENABLED"
      echo "[DIAGNOSTIC] Runtime flags: $(echo "$CODESIGN_INFO" | grep -i "runtime" | head -3)"
    else
      echo "[DIAGNOSTIC] ❌ Hardened runtime: NOT DETECTED"
      echo "[DIAGNOSTIC] Notarization will fail without hardened runtime"
      echo "[DIAGNOSTIC] Codesign info (first 30 lines):"
      echo "$CODESIGN_INFO" | head -30
    fi
    echo ""

    # DIAGNOSTIC 4: Scan for unsigned binaries inside the app bundle
    echo "[DIAGNOSTIC] === Scanning for unsigned binaries (this may take 1-2 minutes) ==="
    UNSIGNED_COUNT=0
    TOTAL_SCANNED=0

    # Find all executable files, dylibs, and frameworks
    while IFS= read -r -d '' file; do
      TOTAL_SCANNED=$((TOTAL_SCANNED + 1))
      # Check if file is signed
      if ! codesign -v "$file" 2>/dev/null; then
        echo "[DIAGNOSTIC] ⚠️  UNSIGNED: $file"
        UNSIGNED_COUNT=$((UNSIGNED_COUNT + 1))
        # Limit output to first 20 unsigned files
        if [ $UNSIGNED_COUNT -ge 20 ]; then
          echo "[DIAGNOSTIC] ... (stopping after 20 unsigned files, more may exist)"
          break
        fi
      fi
    done < <(find "$APP_FILE" -type f \( -name "*.dylib" -o -name "*.framework" -o -name "*.so" -o -perm +111 \) -print0 2>/dev/null)

    echo "[DIAGNOSTIC] Scanned $TOTAL_SCANNED binaries, found $UNSIGNED_COUNT unsigned"
    if [ $UNSIGNED_COUNT -eq 0 ]; then
      echo "[DIAGNOSTIC] ✅ All binaries are signed"
    else
      echo "[DIAGNOSTIC] ❌ Found unsigned binaries - Apple will likely timeout during processing"
      echo "[DIAGNOSTIC] These binaries must be signed before notarization will work"
    fi
    echo ""

    # DIAGNOSTIC 5: Bundle structure validation
    echo "[DIAGNOSTIC] === Bundle structure validation ==="
    INFO_PLIST="$APP_FILE/Contents/Info.plist"
    if [ ! -f "$INFO_PLIST" ]; then
      echo "[DIAGNOSTIC] ❌ Missing Info.plist at: $INFO_PLIST"
    else
      echo "[DIAGNOSTIC] ✅ Info.plist exists"

      BUNDLE_ID=$(/usr/libexec/PlistBuddy -c "Print CFBundleIdentifier" "$INFO_PLIST" 2>/dev/null || echo "NOT_FOUND")
      BUNDLE_EXE=$(/usr/libexec/PlistBuddy -c "Print CFBundleExecutable" "$INFO_PLIST" 2>/dev/null || echo "NOT_FOUND")
      BUNDLE_VERSION=$(/usr/libexec/PlistBuddy -c "Print CFBundleVersion" "$INFO_PLIST" 2>/dev/null || echo "NOT_FOUND")

      echo "[DIAGNOSTIC]   - CFBundleIdentifier: $BUNDLE_ID"
      echo "[DIAGNOSTIC]   - CFBundleExecutable: $BUNDLE_EXE"
      echo "[DIAGNOSTIC]   - CFBundleVersion: $BUNDLE_VERSION"

      # Check if executable exists
      if [ "$BUNDLE_EXE" != "NOT_FOUND" ]; then
        EXE_PATH="$APP_FILE/Contents/MacOS/$BUNDLE_EXE"
        if [ -f "$EXE_PATH" ]; then
          echo "[DIAGNOSTIC] ✅ Main executable exists: $EXE_PATH"
        else
          echo "[DIAGNOSTIC] ❌ Main executable not found: $EXE_PATH"
        fi
      fi
    fi
    echo ""

    # DIAGNOSTIC 6: Check helper apps
    echo "[DIAGNOSTIC] === Helper apps verification ==="
    HELPER_COUNT=0
    for helper in "$APP_FILE/Contents/Frameworks"/*.app; do
      if [ -d "$helper" ]; then
        HELPER_COUNT=$((HELPER_COUNT + 1))
        HELPER_NAME=$(basename "$helper")
        if codesign -v "$helper" 2>/dev/null; then
          echo "[DIAGNOSTIC] ✅ $HELPER_NAME: signed"
        else
          echo "[DIAGNOSTIC] ❌ $HELPER_NAME: unsigned or invalid signature"
        fi
      fi
    done
    echo "[DIAGNOSTIC] Found $HELPER_COUNT helper apps"
    echo ""

    echo "=========================================="
    echo "END DIAGNOSTICS - Starting notarization"
    echo "=========================================="
    echo ""

    echo "+ notarize (DMG via API key, custom poll)"

    # 1) Create DMG from the signed .app
    DMG_FILE="./${APP_NAME}-darwin-${VSCODE_ARCH}-${RELEASE_VERSION}.dmg"
    if [ ! -f "$DMG_FILE" ]; then
      echo "[NOTARIZE] Creating DMG ${DMG_FILE}..."
      hdiutil create -volname "${APP_NAME}" -srcfolder "$APP_FILE" -ov -format UDZO "$DMG_FILE"
    fi
    echo "[NOTARIZE] DMG ready: $DMG_FILE ($(du -h "$DMG_FILE" | cut -f1))"

    # 2) Write API key, protect, and auto-clean
    P8="${RUNNER_TEMP}/AuthKey.p8"
    echo "[NOTARIZE] Writing App Store Connect API key to temporary file..."
    echo "${ASC_KEY_P8}" | base64 --decode > "$P8"
    chmod 600 "$P8"
    cleanup_notary_key() { rm -f "$P8"; }
    trap cleanup_notary_key EXIT

    echo "[NOTARIZE] Using App Store Connect credentials:"
    echo "  - Issuer ID: ${ASC_ISSUER_ID:0:8}... (${#ASC_ISSUER_ID} chars)"
    echo "  - Key ID: ${ASC_KEY_ID}"
    echo "  - Key file: $P8"

    # 3) Submit WITHOUT --wait, capture submission id
    echo "[NOTARIZE] ======================================"
    echo "[NOTARIZE] Submitting DMG to Apple notary service..."
    echo "[NOTARIZE] ======================================"
    START_TIME=$(date +%s)

    SUBMIT_JSON=$(xcrun notarytool submit "$DMG_FILE" \
      --issuer "$ASC_ISSUER_ID" --key-id "$ASC_KEY_ID" --key "$P8" \
      --output-format json 2>&1) || true

    # Extract submission ID - handle both with and without --progress output
    SUBMISSION_ID=$(echo "$SUBMIT_JSON" | grep -o '"id":"[^"]*"' | head -1 | cut -d'"' -f4)

    if [ -z "$SUBMISSION_ID" ]; then
      echo "[NOTARIZE] ERROR: no submission id returned:"
      echo "$SUBMIT_JSON"
      exit 1
    fi
    echo "[NOTARIZE] Submission ID: $SUBMISSION_ID"

    # 4) Poll with exponential backoff (max ~120 minutes for large binaries)
    ATTEMPTS=0
    MAX_ATTEMPTS=40          # 40 polls (increased from 20) = ~120 minutes
    SLEEP=15                 # start at 15s → doubles each loop; caps below
    MAX_SLEEP=180            # cap at 3 minutes
    STATUS=""
    CONSECUTIVE_FAILURES=0
    MAX_CONSECUTIVE_FAILURES=5

    echo "[NOTARIZE] Polling for status (timeout: ~120 minutes, exponential backoff)..."
    echo "[NOTARIZE] Binary size: $(du -h "$DMG_FILE" | cut -f1) - large binaries take longer"

    while [ $ATTEMPTS -lt $MAX_ATTEMPTS ]; do
      sleep "$SLEEP"
      ATTEMPTS=$((ATTEMPTS + 1))

      INFO_JSON=$(xcrun notarytool info "$SUBMISSION_ID" \
        --issuer "$ASC_ISSUER_ID" --key-id "$ASC_KEY_ID" --key "$P8" \
        --output-format json 2>&1) || true

      # Extract status using grep (more reliable than python JSON parsing)
      STATUS=$(echo "$INFO_JSON" | grep -o '"status":"[^"]*"' | head -1 | cut -d'"' -f4)

      # Detect if we're getting no status (API/network issue)
      if [ -z "$STATUS" ]; then
        CONSECUTIVE_FAILURES=$((CONSECUTIVE_FAILURES + 1))
        echo "[NOTARIZE] WARNING: Could not extract status (failure ${CONSECUTIVE_FAILURES}/${MAX_CONSECUTIVE_FAILURES})"
        echo "[NOTARIZE] Raw response: ${INFO_JSON:0:200}..."

        if [ $CONSECUTIVE_FAILURES -ge $MAX_CONSECUTIVE_FAILURES ]; then
          echo "[NOTARIZE] ERROR: Too many consecutive failures to get status - possible API/network issue"
          exit 1
        fi
      else
        CONSECUTIVE_FAILURES=0  # Reset on success
      fi

      ELAPSED=$(($(date +%s) - START_TIME))
      MINUTES=$((ELAPSED / 60))
      SECONDS=$((ELAPSED % 60))
      echo "[NOTARIZE] Status: ${STATUS:-unknown} (attempt ${ATTEMPTS}/${MAX_ATTEMPTS}, ${MINUTES}m ${SECONDS}s elapsed, next check in ${SLEEP}s)"

      if [ "$STATUS" = "Accepted" ]; then
        break
      elif [ "$STATUS" = "Invalid" ] || [ "$STATUS" = "Rejected" ]; then
        echo "[NOTARIZE] ======================================"
        echo "[NOTARIZE] ERROR: Notarization ${STATUS}"
        echo "[NOTARIZE] ======================================"
        echo "[NOTARIZE] Fetching notary log..."
        xcrun notarytool log "$SUBMISSION_ID" \
          --issuer "$ASC_ISSUER_ID" --key-id "$ASC_KEY_ID" --key "$P8" > notary.log || true
        echo "[NOTARIZE] --- Last 200 lines of notary.log ---"
        tail -200 notary.log || true
        exit 1
      elif [ "$STATUS" = "In Progress" ]; then
        # Log every 10 attempts to show we're still trying
        if [ $((ATTEMPTS % 10)) -eq 0 ]; then
          echo "[NOTARIZE] Still in progress after ${MINUTES} minutes - this is normal for large binaries"
        fi
      fi

      # Exponential backoff with cap
      SLEEP=$((SLEEP * 2))
      if [ $SLEEP -gt $MAX_SLEEP ]; then
        SLEEP=$MAX_SLEEP
      fi
    done

    if [ "$STATUS" != "Accepted" ]; then
      END_TIME=$(date +%s)
      DURATION=$((END_TIME - START_TIME))
      echo "[NOTARIZE] ======================================"
      echo "[NOTARIZE] ERROR: Timed out waiting for notarization"
      echo "[NOTARIZE] Duration: ${DURATION} seconds"
      echo "[NOTARIZE] Last status: ${STATUS:-unknown}"
      echo "[NOTARIZE] ======================================"
      echo "[NOTARIZE] Fetching notary log..."
      xcrun notarytool log "$SUBMISSION_ID" \
        --issuer "$ASC_ISSUER_ID" --key-id "$ASC_KEY_ID" --key "$P8" > notary.log || true
      echo "[NOTARIZE] --- Last 200 lines of notary.log ---"
      tail -200 notary.log || true
      exit 1
    fi

    END_TIME=$(date +%s)
    DURATION=$((END_TIME - START_TIME))
    echo "[NOTARIZE] ======================================"
    echo "[NOTARIZE] SUCCESS: Notarization accepted!"
    echo "[NOTARIZE] Duration: ${DURATION} seconds"
    echo "[NOTARIZE] ======================================"

    echo "[NOTARIZE] Stapling DMG..."
    if xcrun stapler staple "$DMG_FILE" 2>&1; then
      echo "[NOTARIZE] ✅ DMG stapling: SUCCESS"
    else
      echo "[NOTARIZE] ⚠️  DMG stapling: FAILED (ticket may not be available yet)"
    fi

    echo "[NOTARIZE] Stapling .app..."
    if xcrun stapler staple "$APP_FILE" 2>&1; then
      echo "[NOTARIZE] ✅ .app stapling: SUCCESS"
    else
      echo "[NOTARIZE] ⚠️  .app stapling: FAILED (ticket may not be available yet)"
    fi

    echo ""
    echo "=========================================="
    echo "POST-STAPLING VERIFICATION"
    echo "=========================================="

    # Verify stapled DMG with spctl (Gatekeeper)
    echo "[VERIFY] Testing DMG with Gatekeeper (spctl)..."
    SPCTL_DMG_OUTPUT=$(spctl -a -t open --context context:primary-signature -vv "$DMG_FILE" 2>&1 || true)
    if echo "$SPCTL_DMG_OUTPUT" | grep -q "accepted"; then
      echo "[VERIFY] ✅ DMG Gatekeeper check: PASSED"
      echo "[VERIFY] Users will be able to open this DMG without warnings"
    else
      echo "[VERIFY] ⚠️  DMG Gatekeeper check: FAILED or UNCERTAIN"
      echo "[VERIFY] Output: $SPCTL_DMG_OUTPUT"
    fi

    # Verify stapled .app with spctl
    echo "[VERIFY] Testing .app with Gatekeeper (spctl)..."
    SPCTL_APP_OUTPUT=$(spctl -a -vv "$APP_FILE" 2>&1 || true)
    if echo "$SPCTL_APP_OUTPUT" | grep -q "accepted"; then
      echo "[VERIFY] ✅ .app Gatekeeper check: PASSED (source: $(echo "$SPCTL_APP_OUTPUT" | grep -o 'source=[^)]*' || echo 'unknown'))"
      echo "[VERIFY] Users will be able to run this app without warnings"
    elif echo "$SPCTL_APP_OUTPUT" | grep -qi "notarized"; then
      echo "[VERIFY] ✅ .app is notarized (Gatekeeper may show it as accepted after distribution)"
    else
      echo "[VERIFY] ⚠️  .app Gatekeeper check: FAILED"
      echo "[VERIFY] Output: $SPCTL_APP_OUTPUT"
      echo "[VERIFY] NOTE: This may still work after users download it (Gatekeeper caches change)"
    fi

    # Verify staple ticket is actually attached
    echo "[VERIFY] Checking if notarization ticket is attached to DMG..."
    if xcrun stapler validate "$DMG_FILE" 2>&1 | grep -q "validated"; then
      echo "[VERIFY] ✅ DMG notarization ticket: ATTACHED"
    else
      echo "[VERIFY] ⚠️  DMG notarization ticket: NOT FOUND or validation failed"
    fi

    echo "=========================================="
    echo "END VERIFICATION"
    echo "=========================================="
    echo ""

    echo "[NOTARIZE] Saving notarization log (success)..."
    xcrun notarytool log "$SUBMISSION_ID" \
      --issuer "$ASC_ISSUER_ID" --key-id "$ASC_KEY_ID" --key "$P8" > notary.log || true

    cd ..
  fi

  if [[ "${SHOULD_BUILD_ZIP}" != "no" ]]; then
    echo "Building and moving ZIP"
    cd "VSCode-darwin-${VSCODE_ARCH}"
    zip -r -X -y "../assets/${APP_NAME}-darwin-${VSCODE_ARCH}-${RELEASE_VERSION}.zip" ./*.app
    cd ..
  fi

  if [[ "${SHOULD_BUILD_DMG}" != "no" ]]; then
    echo "Moving stapled DMG to assets"
    # DMG was already created, notarized, and stapled in the notarization step
    # Just move it to the assets directory
    mv "VSCode-darwin-${VSCODE_ARCH}/${APP_NAME}-darwin-${VSCODE_ARCH}-${RELEASE_VERSION}.dmg" \
       "assets/${APP_NAME}.${VSCODE_ARCH}.${RELEASE_VERSION}.dmg"
  fi

  if [[ "${SHOULD_BUILD_SRC}" == "yes" ]]; then
    git archive --format tar.gz --output="./assets/${APP_NAME}-${RELEASE_VERSION}-src.tar.gz" HEAD
    git archive --format zip --output="./assets/${APP_NAME}-${RELEASE_VERSION}-src.zip" HEAD
  fi

  if [[ -n "${CERTIFICATE_OSX_P12_DATA}" ]]; then
    echo "+ clean"
    security delete-keychain "${KEYCHAIN}"
    # shellcheck disable=SC2086
    security list-keychains -s $KEYCHAINS
  fi

  VSCODE_PLATFORM="darwin"
elif [[ "${OS_NAME}" == "windows" ]]; then
  cd vscode || { echo "'vscode' dir not found"; exit 1; }

  npm run gulp "vscode-win32-${VSCODE_ARCH}-inno-updater"

  if [[ "${SHOULD_BUILD_ZIP}" != "no" ]]; then
    7z.exe a -tzip "../assets/${APP_NAME}-win32-${VSCODE_ARCH}-${RELEASE_VERSION}.zip" -x!CodeSignSummary*.md -x!tools "../VSCode-win32-${VSCODE_ARCH}/*" -r
  fi

  if [[ "${SHOULD_BUILD_EXE_SYS}" != "no" ]]; then
    npm run gulp "vscode-win32-${VSCODE_ARCH}-system-setup"
  fi

  if [[ "${SHOULD_BUILD_EXE_USR}" != "no" ]]; then
    npm run gulp "vscode-win32-${VSCODE_ARCH}-user-setup"
  fi

  if [[ "${VSCODE_ARCH}" == "ia32" || "${VSCODE_ARCH}" == "x64" ]]; then
    if [[ "${SHOULD_BUILD_MSI}" != "no" ]]; then
      . ../build/windows/msi/build.sh
    fi

    if [[ "${SHOULD_BUILD_MSI_NOUP}" != "no" ]]; then
      . ../build/windows/msi/build-updates-disabled.sh
    fi
  fi

  cd ..

  if [[ "${SHOULD_BUILD_EXE_SYS}" != "no" ]]; then
    echo "Moving System EXE"
    mv "vscode\\.build\\win32-${VSCODE_ARCH}\\system-setup\\VSCodeSetup.exe" "assets\\${APP_NAME}Setup-${VSCODE_ARCH}-${RELEASE_VERSION}.exe"
  fi

  if [[ "${SHOULD_BUILD_EXE_USR}" != "no" ]]; then
    echo "Moving User EXE"
    mv "vscode\\.build\\win32-${VSCODE_ARCH}\\user-setup\\VSCodeSetup.exe" "assets\\${APP_NAME}UserSetup-${VSCODE_ARCH}-${RELEASE_VERSION}.exe"
  fi

  if [[ "${VSCODE_ARCH}" == "ia32" || "${VSCODE_ARCH}" == "x64" ]]; then
    if [[ "${SHOULD_BUILD_MSI}" != "no" ]]; then
      echo "Moving MSI"
      mv "build\\windows\\msi\\releasedir\\${APP_NAME}-${VSCODE_ARCH}-${RELEASE_VERSION}.msi" assets/
    fi

    if [[ "${SHOULD_BUILD_MSI_NOUP}" != "no" ]]; then
      echo "Moving MSI with disabled updates"
      mv "build\\windows\\msi\\releasedir\\${APP_NAME}-${VSCODE_ARCH}-updates-disabled-${RELEASE_VERSION}.msi" assets/
    fi
  fi

  VSCODE_PLATFORM="win32"
else
  cd vscode || { echo "'vscode' dir not found"; exit 1; }

  if [[ "${SHOULD_BUILD_APPIMAGE}" != "no" && "${VSCODE_ARCH}" != "x64" ]]; then
    SHOULD_BUILD_APPIMAGE="no"
  fi

  if [[ "${SHOULD_BUILD_DEB}" != "no" || "${SHOULD_BUILD_APPIMAGE}" != "no" ]]; then
    npm run gulp "vscode-linux-${VSCODE_ARCH}-prepare-deb"
    npm run gulp "vscode-linux-${VSCODE_ARCH}-build-deb"
  fi

  if [[ "${SHOULD_BUILD_RPM}" != "no" ]]; then
    npm run gulp "vscode-linux-${VSCODE_ARCH}-prepare-rpm"
    npm run gulp "vscode-linux-${VSCODE_ARCH}-build-rpm"
  fi

  if [[ "${SHOULD_BUILD_APPIMAGE}" != "no" ]]; then
    . ../build/linux/appimage/build.sh
  fi

  cd ..

  if [[ "${CI_BUILD}" == "no" ]]; then
    . ./stores/snapcraft/build.sh

    if [[ "${SKIP_ASSETS}" == "no" ]]; then
      mv stores/snapcraft/build/*.snap assets/
    fi
  fi

  if [[ "${SHOULD_BUILD_TAR}" != "no" ]]; then
    echo "Building and moving TAR"
    cd "VSCode-linux-${VSCODE_ARCH}"
    tar czf "../assets/${APP_NAME}-linux-${VSCODE_ARCH}-${RELEASE_VERSION}.tar.gz" .
    cd ..
  fi

  if [[ "${SHOULD_BUILD_DEB}" != "no" ]]; then
    echo "Moving DEB"
    mv vscode/.build/linux/deb/*/deb/*.deb assets/
  fi

  if [[ "${SHOULD_BUILD_RPM}" != "no" ]]; then
    echo "Moving RPM"
    mv vscode/.build/linux/rpm/*/*.rpm assets/
  fi

  if [[ "${SHOULD_BUILD_APPIMAGE}" != "no" ]]; then
    echo "Moving AppImage"
    mv build/linux/appimage/out/*.AppImage* assets/

    find assets -name '*.AppImage*' -exec bash -c 'mv $0 ${0/_-_/-}' {} \;
  fi

  VSCODE_PLATFORM="linux"
fi

if [[ "${SHOULD_BUILD_REH}" != "no" ]]; then
  echo "Building and moving REH"
  cd "vscode-reh-${VSCODE_PLATFORM}-${VSCODE_ARCH}"
  tar czf "../assets/${APP_NAME_LC}-reh-${VSCODE_PLATFORM}-${VSCODE_ARCH}-${RELEASE_VERSION}.tar.gz" .
  cd ..
fi

if [[ "${SHOULD_BUILD_REH_WEB}" != "no" ]]; then
  echo "Building and moving REH-web"
  cd "vscode-reh-web-${VSCODE_PLATFORM}-${VSCODE_ARCH}"
  tar czf "../assets/${APP_NAME_LC}-reh-web-${VSCODE_PLATFORM}-${VSCODE_ARCH}-${RELEASE_VERSION}.tar.gz" .
  cd ..
fi

if [[ "${OS_NAME}" != "windows" ]]; then
  ./prepare_checksums.sh
fi
