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

    echo "+ signing"
    export CODESIGN_IDENTITY AGENT_TEMPDIRECTORY

    DEBUG="electron-osx-sign*" node vscode/build/darwin/sign.js "$( pwd )"
    # codesign --display --entitlements :- ""

    echo "+ notarize"

    cd "VSCode-darwin-${VSCODE_ARCH}"
    ZIP_FILE="./${APP_NAME}-darwin-${VSCODE_ARCH}-${RELEASE_VERSION}.zip"

    zip -r -X -y "${ZIP_FILE}" ./*.app

    xcrun notarytool store-credentials "${APP_NAME}" --apple-id "${CERTIFICATE_OSX_ID}" --team-id "${CERTIFICATE_OSX_TEAM_ID}" --password "${CERTIFICATE_OSX_APP_PASSWORD}" --keychain "${KEYCHAIN}"
    # xcrun notarytool history --keychain-profile "${APP_NAME}" --keychain "${KEYCHAIN}"
    xcrun notarytool submit "${ZIP_FILE}" --keychain-profile "${APP_NAME}" --wait --keychain "${KEYCHAIN}"

    echo "+ attach staple"
    xcrun stapler staple ./*.app
    # spctl --assess -vv --type install ./*.app

    rm "${ZIP_FILE}"

    cd ..
  fi

  if [[ "${SHOULD_BUILD_ZIP}" != "no" ]]; then
    echo "Building and moving ZIP"
    cd "VSCode-darwin-${VSCODE_ARCH}"
    zip -r -X -y "../assets/${APP_NAME}-darwin-${VSCODE_ARCH}-${RELEASE_VERSION}.zip" ./*.app
    cd ..
  fi

  if [[ "${SHOULD_BUILD_DMG}" != "no" ]]; then
    echo "Building and moving DMG"
    pushd "VSCode-darwin-${VSCODE_ARCH}"
    npx create-dmg --skip-codesign ./*.app .
    mv ./*.dmg "../assets/${APP_NAME}.${VSCODE_ARCH}.${RELEASE_VERSION}.dmg"
    popd
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

# #!/usr/bin/env bash
# # shellcheck disable=SC1091

# set -e

# APP_NAME_LC="$( echo "${APP_NAME}" | awk '{print tolower($0)}' )"

# mkdir -p assets

# if [[ "${OS_NAME}" == "osx" ]]; then
#   if [[ -n "${CERTIFICATE_OSX_P12_DATA}" ]]; then
#     if [[ "${CI_BUILD}" == "no" ]]; then
#       RUNNER_TEMP="${TMPDIR}"
#     fi

#     CERTIFICATE_P12="${APP_NAME}.p12"
#     KEYCHAIN="${RUNNER_TEMP}/buildagent.keychain"
#     AGENT_TEMPDIRECTORY="${RUNNER_TEMP}"
#     # shellcheck disable=SC2006
#     KEYCHAINS=`security list-keychains | xargs`

#     rm -f "${KEYCHAIN}"

#     echo "${CERTIFICATE_OSX_P12_DATA}" | base64 --decode > "${CERTIFICATE_P12}"

#     echo "+ create temporary keychain"
#     security create-keychain -p pwd "${KEYCHAIN}"
#     security set-keychain-settings -lut 21600 "${KEYCHAIN}"
#     security unlock-keychain -p pwd "${KEYCHAIN}"
#     # shellcheck disable=SC2086
#     security list-keychains -s $KEYCHAINS "${KEYCHAIN}"
#     # security show-keychain-info "${KEYCHAIN}"

#     echo "+ import certificate to keychain"
#     security import "${CERTIFICATE_P12}" -k "${KEYCHAIN}" -P "${CERTIFICATE_OSX_P12_PASSWORD}" -T /usr/bin/codesign
#     security set-key-partition-list -S apple-tool:,apple:,codesign: -s -k pwd "${KEYCHAIN}" > /dev/null
#     # security find-identity "${KEYCHAIN}"

#     CODESIGN_IDENTITY="$( security find-identity -v -p codesigning "${KEYCHAIN}" | grep -oEi "([0-9A-F]{40})" | head -n 1 )"

#     echo "+ signing"
#     export CODESIGN_IDENTITY AGENT_TEMPDIRECTORY

#     DEBUG="electron-osx-sign*" node vscode/build/darwin/sign.js "$( pwd )"
#     # codesign --display --entitlements :- ""

#     echo "+ notarize (DMG via API key, custom poll)"

#     cd "VSCode-darwin-${VSCODE_ARCH}"

#     # 1) Ensure we have a DMG (stapling is supported on DMG, not ZIP)
#     APP_FILE="$(find . -maxdepth 1 -name '*.app' -print -quit)"
#     if [ -z "$APP_FILE" ]; then
#       echo "[NOTARIZE] ERROR: .app not found"
#       exit 1
#     fi
#     echo "[NOTARIZE] Found app: $APP_FILE"

#     DMG_FILE="./${APP_NAME}-darwin-${VSCODE_ARCH}-${RELEASE_VERSION}.dmg"
#     if [ ! -f "$DMG_FILE" ]; then
#       echo "[NOTARIZE] Creating DMG ${DMG_FILE}..."
#       hdiutil create -volname "${APP_NAME}" -srcfolder "$APP_FILE" -ov -format UDZO "$DMG_FILE"
#     fi
#     echo "[NOTARIZE] DMG ready: $DMG_FILE ($(du -h "$DMG_FILE" | cut -f1))"

#     # 2) Write API key, protect, and auto-clean
#     P8="${RUNNER_TEMP}/AuthKey.p8"
#     echo "[NOTARIZE] Writing App Store Connect API key to temporary file..."
#     echo "${ASC_KEY_P8}" | base64 --decode > "$P8"
#     chmod 600 "$P8"
#     cleanup_notary_key() { rm -f "$P8"; }
#     trap cleanup_notary_key EXIT

#     echo "[NOTARIZE] Using App Store Connect credentials:"
#     echo "  - Issuer ID: ${ASC_ISSUER_ID:0:8}... (${#ASC_ISSUER_ID} chars)"
#     echo "  - Key ID: ${ASC_KEY_ID}"
#     echo "  - Key file: $P8"

#     # 3) Submit WITHOUT --wait, capture submission id
#     echo "[NOTARIZE] ======================================"
#     echo "[NOTARIZE] Submitting DMG to Apple notary service..."
#     echo "[NOTARIZE] ======================================"
#     START_TIME=$(date +%s)

#     SUBMIT_JSON=$(xcrun notarytool submit "$DMG_FILE" \
#       --issuer "$ASC_ISSUER_ID" --key-id "$ASC_KEY_ID" --key "$P8" \
#       --output-format json 2>&1) || true

#     # Extract submission ID - handle both with and without --progress output
#     SUBMISSION_ID=$(echo "$SUBMIT_JSON" | grep -o '"id":"[^"]*"' | head -1 | cut -d'"' -f4)

#     if [ -z "$SUBMISSION_ID" ]; then
#       echo "[NOTARIZE] ERROR: no submission id returned:"
#       echo "$SUBMIT_JSON"
#       exit 1
#     fi
#     echo "[NOTARIZE] Submission ID: $SUBMISSION_ID"

#     # 4) Poll with exponential backoff (max ~60 minutes)
#     ATTEMPTS=0
#     MAX_ATTEMPTS=20          # 20 polls
#     SLEEP=15                 # start at 15s → doubles each loop; caps below
#     MAX_SLEEP=180            # cap at 3 minutes
#     STATUS=""

#     echo "[NOTARIZE] Polling for status (timeout: ~60 minutes, exponential backoff)..."

#     while [ $ATTEMPTS -lt $MAX_ATTEMPTS ]; do
#       sleep "$SLEEP"
#       ATTEMPTS=$((ATTEMPTS + 1))

#       INFO_JSON=$(xcrun notarytool info "$SUBMISSION_ID" \
#         --issuer "$ASC_ISSUER_ID" --key-id "$ASC_KEY_ID" --key "$P8" \
#         --output-format json 2>&1) || true

#       # Extract status using grep (more reliable than python JSON parsing)
#       STATUS=$(echo "$INFO_JSON" | grep -o '"status":"[^"]*"' | head -1 | cut -d'"' -f4)

#       ELAPSED=$(($(date +%s) - START_TIME))
#       echo "[NOTARIZE] Status: ${STATUS:-unknown} (attempt ${ATTEMPTS}/${MAX_ATTEMPTS}, ${ELAPSED}s elapsed, next check in ${SLEEP}s)"

#       if [ "$STATUS" = "Accepted" ]; then
#         break
#       elif [ "$STATUS" = "Invalid" ]; then
#         echo "[NOTARIZE] ======================================"
#         echo "[NOTARIZE] ERROR: Notarization INVALID"
#         echo "[NOTARIZE] ======================================"
#         echo "[NOTARIZE] Fetching notary log..."
#         xcrun notarytool log "$SUBMISSION_ID" \
#           --issuer "$ASC_ISSUER_ID" --key-id "$ASC_KEY_ID" --key "$P8" > notary.log || true
#         echo "[NOTARIZE] --- Last 200 lines of notary.log ---"
#         tail -200 notary.log || true
#         exit 1
#       fi

#       # Exponential backoff with cap
#       SLEEP=$((SLEEP * 2))
#       if [ $SLEEP -gt $MAX_SLEEP ]; then
#         SLEEP=$MAX_SLEEP
#       fi
#     done

#     if [ "$STATUS" != "Accepted" ]; then
#       END_TIME=$(date +%s)
#       DURATION=$((END_TIME - START_TIME))
#       echo "[NOTARIZE] ======================================"
#       echo "[NOTARIZE] ERROR: Timed out waiting for notarization"
#       echo "[NOTARIZE] Duration: ${DURATION} seconds"
#       echo "[NOTARIZE] Last status: ${STATUS:-unknown}"
#       echo "[NOTARIZE] ======================================"
#       echo "[NOTARIZE] Fetching notary log..."
#       xcrun notarytool log "$SUBMISSION_ID" \
#         --issuer "$ASC_ISSUER_ID" --key-id "$ASC_KEY_ID" --key "$P8" > notary.log || true
#       echo "[NOTARIZE] --- Last 200 lines of notary.log ---"
#       tail -200 notary.log || true
#       exit 1
#     fi

#     END_TIME=$(date +%s)
#     DURATION=$((END_TIME - START_TIME))
#     echo "[NOTARIZE] ======================================"
#     echo "[NOTARIZE] SUCCESS: Notarization accepted!"
#     echo "[NOTARIZE] Duration: ${DURATION} seconds"
#     echo "[NOTARIZE] ======================================"

#     echo "[NOTARIZE] Stapling DMG..."
#     xcrun stapler staple "$DMG_FILE" || true
#     echo "[NOTARIZE] Stapling .app..."
#     xcrun stapler staple "$APP_FILE" || true

#     echo "[NOTARIZE] Saving notarization log (success)..."
#     xcrun notarytool log "$SUBMISSION_ID" \
#       --issuer "$ASC_ISSUER_ID" --key-id "$ASC_KEY_ID" --key "$P8" > notary.log || true

#     cd ..
#   fi

#   if [[ "${SHOULD_BUILD_ZIP}" != "no" ]]; then
#     echo "Building and moving ZIP"
#     cd "VSCode-darwin-${VSCODE_ARCH}"
#     zip -r -X -y "../assets/${APP_NAME}-darwin-${VSCODE_ARCH}-${RELEASE_VERSION}.zip" ./*.app
#     cd ..
#   fi

#   if [[ "${SHOULD_BUILD_DMG}" != "no" ]]; then
#     echo "Moving stapled DMG to assets"
#     # DMG was already created, notarized, and stapled in the notarization step
#     # Just move it to the assets directory
#     mv "VSCode-darwin-${VSCODE_ARCH}/${APP_NAME}-darwin-${VSCODE_ARCH}-${RELEASE_VERSION}.dmg" \
#        "assets/${APP_NAME}.${VSCODE_ARCH}.${RELEASE_VERSION}.dmg"
#   fi

#   if [[ "${SHOULD_BUILD_SRC}" == "yes" ]]; then
#     git archive --format tar.gz --output="./assets/${APP_NAME}-${RELEASE_VERSION}-src.tar.gz" HEAD
#     git archive --format zip --output="./assets/${APP_NAME}-${RELEASE_VERSION}-src.zip" HEAD
#   fi

#   if [[ -n "${CERTIFICATE_OSX_P12_DATA}" ]]; then
#     echo "+ clean"
#     security delete-keychain "${KEYCHAIN}"
#     # shellcheck disable=SC2086
#     security list-keychains -s $KEYCHAINS
#   fi

#   VSCODE_PLATFORM="darwin"
# elif [[ "${OS_NAME}" == "windows" ]]; then
#   cd vscode || { echo "'vscode' dir not found"; exit 1; }

#   npm run gulp "vscode-win32-${VSCODE_ARCH}-inno-updater"

#   if [[ "${SHOULD_BUILD_ZIP}" != "no" ]]; then
#     7z.exe a -tzip "../assets/${APP_NAME}-win32-${VSCODE_ARCH}-${RELEASE_VERSION}.zip" -x!CodeSignSummary*.md -x!tools "../VSCode-win32-${VSCODE_ARCH}/*" -r
#   fi

#   if [[ "${SHOULD_BUILD_EXE_SYS}" != "no" ]]; then
#     npm run gulp "vscode-win32-${VSCODE_ARCH}-system-setup"
#   fi

#   if [[ "${SHOULD_BUILD_EXE_USR}" != "no" ]]; then
#     npm run gulp "vscode-win32-${VSCODE_ARCH}-user-setup"
#   fi

#   if [[ "${VSCODE_ARCH}" == "ia32" || "${VSCODE_ARCH}" == "x64" ]]; then
#     if [[ "${SHOULD_BUILD_MSI}" != "no" ]]; then
#       . ../build/windows/msi/build.sh
#     fi

#     if [[ "${SHOULD_BUILD_MSI_NOUP}" != "no" ]]; then
#       . ../build/windows/msi/build-updates-disabled.sh
#     fi
#   fi

#   cd ..

#   if [[ "${SHOULD_BUILD_EXE_SYS}" != "no" ]]; then
#     echo "Moving System EXE"
#     mv "vscode\\.build\\win32-${VSCODE_ARCH}\\system-setup\\VSCodeSetup.exe" "assets\\${APP_NAME}Setup-${VSCODE_ARCH}-${RELEASE_VERSION}.exe"
#   fi

#   if [[ "${SHOULD_BUILD_EXE_USR}" != "no" ]]; then
#     echo "Moving User EXE"
#     mv "vscode\\.build\\win32-${VSCODE_ARCH}\\user-setup\\VSCodeSetup.exe" "assets\\${APP_NAME}UserSetup-${VSCODE_ARCH}-${RELEASE_VERSION}.exe"
#   fi

#   if [[ "${VSCODE_ARCH}" == "ia32" || "${VSCODE_ARCH}" == "x64" ]]; then
#     if [[ "${SHOULD_BUILD_MSI}" != "no" ]]; then
#       echo "Moving MSI"
#       mv "build\\windows\\msi\\releasedir\\${APP_NAME}-${VSCODE_ARCH}-${RELEASE_VERSION}.msi" assets/
#     fi

#     if [[ "${SHOULD_BUILD_MSI_NOUP}" != "no" ]]; then
#       echo "Moving MSI with disabled updates"
#       mv "build\\windows\\msi\\releasedir\\${APP_NAME}-${VSCODE_ARCH}-updates-disabled-${RELEASE_VERSION}.msi" assets/
#     fi
#   fi

#   VSCODE_PLATFORM="win32"
# else
#   cd vscode || { echo "'vscode' dir not found"; exit 1; }

#   if [[ "${SHOULD_BUILD_APPIMAGE}" != "no" && "${VSCODE_ARCH}" != "x64" ]]; then
#     SHOULD_BUILD_APPIMAGE="no"
#   fi

#   if [[ "${SHOULD_BUILD_DEB}" != "no" || "${SHOULD_BUILD_APPIMAGE}" != "no" ]]; then
#     npm run gulp "vscode-linux-${VSCODE_ARCH}-prepare-deb"
#     npm run gulp "vscode-linux-${VSCODE_ARCH}-build-deb"
#   fi

#   if [[ "${SHOULD_BUILD_RPM}" != "no" ]]; then
#     npm run gulp "vscode-linux-${VSCODE_ARCH}-prepare-rpm"
#     npm run gulp "vscode-linux-${VSCODE_ARCH}-build-rpm"
#   fi

#   if [[ "${SHOULD_BUILD_APPIMAGE}" != "no" ]]; then
#     . ../build/linux/appimage/build.sh
#   fi

#   cd ..

#   if [[ "${CI_BUILD}" == "no" ]]; then
#     . ./stores/snapcraft/build.sh

#     if [[ "${SKIP_ASSETS}" == "no" ]]; then
#       mv stores/snapcraft/build/*.snap assets/
#     fi
#   fi

#   if [[ "${SHOULD_BUILD_TAR}" != "no" ]]; then
#     echo "Building and moving TAR"
#     cd "VSCode-linux-${VSCODE_ARCH}"
#     tar czf "../assets/${APP_NAME}-linux-${VSCODE_ARCH}-${RELEASE_VERSION}.tar.gz" .
#     cd ..
#   fi

#   if [[ "${SHOULD_BUILD_DEB}" != "no" ]]; then
#     echo "Moving DEB"
#     mv vscode/.build/linux/deb/*/deb/*.deb assets/
#   fi

#   if [[ "${SHOULD_BUILD_RPM}" != "no" ]]; then
#     echo "Moving RPM"
#     mv vscode/.build/linux/rpm/*/*.rpm assets/
#   fi

#   if [[ "${SHOULD_BUILD_APPIMAGE}" != "no" ]]; then
#     echo "Moving AppImage"
#     mv build/linux/appimage/out/*.AppImage* assets/

#     find assets -name '*.AppImage*' -exec bash -c 'mv $0 ${0/_-_/-}' {} \;
#   fi

#   VSCODE_PLATFORM="linux"
# fi

# if [[ "${SHOULD_BUILD_REH}" != "no" ]]; then
#   echo "Building and moving REH"
#   cd "vscode-reh-${VSCODE_PLATFORM}-${VSCODE_ARCH}"
#   tar czf "../assets/${APP_NAME_LC}-reh-${VSCODE_PLATFORM}-${VSCODE_ARCH}-${RELEASE_VERSION}.tar.gz" .
#   cd ..
# fi

# if [[ "${SHOULD_BUILD_REH_WEB}" != "no" ]]; then
#   echo "Building and moving REH-web"
#   cd "vscode-reh-web-${VSCODE_PLATFORM}-${VSCODE_ARCH}"
#   tar czf "../assets/${APP_NAME_LC}-reh-web-${VSCODE_PLATFORM}-${VSCODE_ARCH}-${RELEASE_VERSION}.tar.gz" .
#   cd ..
# fi

# if [[ "${OS_NAME}" != "windows" ]]; then
#   ./prepare_checksums.sh
# fi
