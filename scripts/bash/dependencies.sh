#!/bin/sh
# find dependencies of the package
# usage
# set $SCRIPT_PATH variable to the config/scripts/bash folder of config submodule 
# pass param --package [PACKAGE_NAME_OR_ID] -v [DEV_HUB_ORG] -u [ORG_TO_INSTALL]
# example command 
source "$SCRIPT_PATH""dependenciesutil.sh"
source "$SCRIPT_PATH""utility.sh"
source "$SCRIPT_PATH""decorator.sh"

readParams "$@"
getPacakgeIdFromName
getLatestPackageVersion
installDependencies