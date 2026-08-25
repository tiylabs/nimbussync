#!/bin/sh
set -eu

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/../.." && pwd)
echo "Prepare uninstall is a user-confirmed workflow. It preserves dirty data, removes domains through the Store service, unregisters the login item, and only then deletes Keychain references."
echo "No Cloudreve delete API is called by this script."
printf '%s\n' "See the application removal service before clearing App Group data."

