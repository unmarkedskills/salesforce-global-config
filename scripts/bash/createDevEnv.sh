#!/bin/sh
# create development enviornment for developer for current repo

# usage
# set $SCRIPT_PATH variable to the config/scripts/bash folder of config submodule 
source "$SCRIPT_PATH""utility.sh"
source "$SCRIPT_PATH""decorator.sh"

readParams "$@"
if [ -n "$PACKAGE" ]
then
    createScratchOrg # create scratch org
    preInstallDeploy # pre deploy components from demo for scratch org
    source "$SCRIPT_PATH""dependencies.sh" --package $PACKAGE -v $TARGETDEVHUBUSERNAME -u $TARGETUSERNAME # install dependencies from devhub
    deploySource # deploy source
    for i in "${PERMISSION_SETS[@]}"
    do
        echo "Assign permission set : ${i}"
        assignPermissionSet $i $TARGETUSERNAME
    done
    echo "${GREY_BOLD}Opening scratch org..${NO_COLOUR}"
    echo "${GREY_BOLD}Alias: ${GREEN}$SETALIAS${NO_COLOUR}"
    echo "${GREY_BOLD}Username: ${GREEN}$TARGETUSERNAME${NO_COLOUR}"
    sfdx force:org:open -u $TARGETUSERNAME
else
    errorExit "1" "${RED}Package name empty, cannot proceed without package name${NO_COLOUR}"
fi