#!/usr/bin/env bash
# shellcheck disable=SC1091

set -ex

. version.sh

if [[ "${SHOULD_BUILD}" == "yes" ]]; then
  echo "MS_COMMIT=\"${MS_COMMIT}\""

  . prepare_vscode.sh

  cd vscode || { echo "'vscode' dir not found"; exit 1; }

  export NODE_OPTIONS="--max-old-space-size=8192"

  # Skip monaco-compile-check as it's failing due to searchUrl property
  # Skip valid-layers-check as well since it might depend on monaco
  # Void commented these out
  # npm run monaco-compile-check
  # npm run valid-layers-check

  npm run buildreact
npm run gulp compile-build-without-mangling
npm run gulp compile-extension-media
npm run gulp compile-extensions-build
npm run gulp minify-vscode

set_final_product_version() {
  if [[ -z "${ENGINE_VERSION}" ]]; then
    return
  fi

  local root="$1"
  if [[ ! -d "${root}" ]]; then
    return
  fi

  local target
  target=$(find "${root}" -path "*/Contents/Resources/app/product.json" -o -path "*/resources/app/product.json" | head -n 1)
  if [[ -n "${target}" && -f "${target}" ]]; then
    local tmp_product
    tmp_product=$(mktemp)
    jq --arg v "${ENGINE_VERSION}" '.version = $v' "${target}" > "${tmp_product}" && mv "${tmp_product}" "${target}"
    echo "Set product.version=${ENGINE_VERSION} in ${target}"
  fi
}

  if [[ "${OS_NAME}" == "osx" ]]; then
    # generate Group Policy definitions
    # node build/lib/policies darwin # Void commented this out

  npm run gulp "vscode-darwin-${VSCODE_ARCH}-min-ci"

  set_final_product_version "../VSCode-darwin-${VSCODE_ARCH}"

  find "../VSCode-darwin-${VSCODE_ARCH}" -print0 | xargs -0 touch -c

  . ../build_cli.sh

    VSCODE_PLATFORM="darwin"
  elif [[ "${OS_NAME}" == "windows" ]]; then
    # generate Group Policy definitions
    # node build/lib/policies win32 # Void commented this out

    # in CI, packaging will be done by a different job
    if [[ "${CI_BUILD}" == "no" ]]; then
      . ../build/windows/rtf/make.sh

      npm run gulp "vscode-win32-${VSCODE_ARCH}-min-ci"

      set_final_product_version "../VSCode-win32-${VSCODE_ARCH}"

      if [[ "${VSCODE_ARCH}" != "x64" ]]; then
        SHOULD_BUILD_REH="no"
        SHOULD_BUILD_REH_WEB="no"
      fi

      . ../build_cli.sh
    fi

    VSCODE_PLATFORM="win32"
  else # linux
    # in CI, packaging will be done by a different job
    if [[ "${CI_BUILD}" == "no" ]]; then
      npm run gulp "vscode-linux-${VSCODE_ARCH}-min-ci"

      set_final_product_version "../VSCode-linux-${VSCODE_ARCH}"

      find "../VSCode-linux-${VSCODE_ARCH}" -print0 | xargs -0 touch -c

      . ../build_cli.sh
    fi

    VSCODE_PLATFORM="linux"
  fi

  if [[ "${SHOULD_BUILD_REH}" != "no" ]]; then
    npm run gulp minify-vscode-reh
    npm run gulp "vscode-reh-${VSCODE_PLATFORM}-${VSCODE_ARCH}-min-ci"
  fi

  if [[ "${SHOULD_BUILD_REH_WEB}" != "no" ]]; then
    npm run gulp minify-vscode-reh-web
    npm run gulp "vscode-reh-web-${VSCODE_PLATFORM}-${VSCODE_ARCH}-min-ci"
  fi

  cd ..
fi
