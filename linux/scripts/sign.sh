#!/bin/zsh
# Signs a Linux release archive with Sparkle's EdDSA key, which the Linux updater checks against
# SUPublicEDKey in macos/Config/Info.plist, so both apps trust one publisher. Runs on the Mac, where
# the key lives in the login keychain.
# Usage: linux/scripts/sign.sh <archive>   prints the base64 signature
#        linux/scripts/sign.sh --check     fails unless the keychain has the matching key
set -euo pipefail
cd "${0:A:h:h:h}"

sparkle=macos/Scripts/sparkle.sh
if [[ "${1:?Usage: linux/scripts/sign.sh <archive> | --check}" == --check ]]; then
  [[ "$($sparkle generate_keys -p)" == "$(plutil -extract SUPublicEDKey raw macos/Config/Info.plist)" ]]
else
  $sparkle sign_update -p "$1"
fi
