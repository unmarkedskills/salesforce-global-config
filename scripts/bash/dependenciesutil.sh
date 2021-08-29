#!/bin/sh
# utility script to resoleve and installe dependencies
# get package's latest package version id
function getLatestPackageVersion {
    case $PACKAGE in
        0Ho*)
            echo "${GREY_BOLD}Getting latest package version Id for package ${GREEN}$PACKAGE ...${NO_COLOUR}"
            QUERY_STRING="SELECT SubscriberPackageVersionId FROM Package2Version WHERE Package2Id = '$PACKAGE' ORDER BY CreatedDate DESC"

            if [ -n "$TARGETDEVHUBUSERNAME" ] # check if target org username is available
            then # use the username to fetch the data
                OPTION_USERNAME="--targetusername $TARGETDEVHUBUSERNAME"
            fi

            # get package id from json
            PACKAGE_SUBID=$(sfdx force:data:soql:query --usetoolingapi --query "$QUERY_STRING" $OPTION_DH_USERNAME --json | jq '.result.records[0].SubscriberPackageVersionId')
            PACKAGE_SUBID=${PACKAGE_SUBID//"\""} # remove pre and trailing double quotes
            echo "${GREY_BOLD}Latest created package version Id for package id ${GREEN}$PACKAGE : ${GREEN_BOLD}$PACKAGE_SUBID${NO_COLOUR}"
        ;;
        *)
            echo "${RED_BOLD}Invalid Package Id : ${RED}$PACKAGE${NO_COLOUR}"
        ;;
    esac
}

# get package's latest package released version id
function getLatestReleasedPackageVersion {
    case $PACKAGE in
        0Ho*)
            echo "${GREY_BOLD}Getting latest released package version Id for package ${GREEN}$PACKAGE ...${NO_COLOUR}"
            QUERY_STRING="SELECT SubscriberPackageVersionId FROM Package2Version WHERE Package2Id = '$PACKAGE' AND IsReleased = true ORDER BY CreatedDate DESC"

            if [ -n "$TARGETDEVHUBUSERNAME" ] # check if target org username is available
            then # use the username to fetch the data
                OPTION_USERNAME="--targetusername $TARGETDEVHUBUSERNAME"
            fi

            # get package id from json
            PACKAGE_SUBID=$(sfdx force:data:soql:query --usetoolingapi --query "$QUERY_STRING" $OPTION_DH_USERNAME --json | jq '.result.records[0].SubscriberPackageVersionId')
            PACKAGE_SUBID=${PACKAGE_SUBID//"\""} # remove pre and trailing double quotes
            echo "${GREY_BOLD}Latest released package version Id for package id ${GREEN}$PACKAGE : ${GREEN_BOLD}$PACKAGE_SUBID${NO_COLOUR}"
        ;;
        *)
            echo "${RED_BOLD}Invalid Package Id : ${RED}$PACKAGE${NO_COLOUR}"
        ;;
    esac
}

function getPackageDependencies {
    ARR_DEPENDENCIES=()
    #STR_DEPENDENCIES=""
    case $PACKAGE_SUBID in
        04t*)
            echo "${GREY_BOLD}Getting dependencies for ${GREEN}$PACKAGE_SUBID${NO_COLOUR}"
            QUERY_STRING="SELECT Dependencies FROM SubscriberPackageVersion WHERE Id='$PACKAGE_SUBID'"

            if [ -n "$TARGETDEVHUBUSERNAME" ] # check if target org username is available
            then # use the username to fetch the data
                OPTION_USERNAME="--targetusername $TARGETDEVHUBUSERNAME"
            fi

            DEPENDENCIES=$(sfdx force:data:soql:query --usetoolingapi --query "$QUERY_STRING" $OPTION_DH_USERNAME --json | jq '.result.records[0].Dependencies')
            if [ "$DEPENDENCIES" != "null" ] # if no dependencies found
            then
                # get package dependencies
                for eachId in $(echo $DEPENDENCIES | jq '.ids[].subscriberPackageVersionId')
                do
                    ARR_DEPENDENCIES+=(${eachId//"\""})
                    #STR_DEPENDENCIES+="'"${eachId//"\""}"'",
                done
            else
                echo "${GREEN}No dependencies found for the package version ${GREEN_BOLD}$PACKAGE_SUBID${NO_COLOUR}"
                echo "${GREEN}Proceeding with source deploy.. ${NO_COLOUR}"
            fi
        ;;
        *)
            echo "${RED_BOLD}Invalid package version Id : ${RED}$PACKAGE_SUBID${NO_COLOUR}"
        ;;
    esac
}

function installDependencies {
    getPackageDependencies
    if [ -n "$TARGETDEVHUBUSERNAME" ] # check if target org username is available
    then # use the username to fetch the data
        OPTION_DH_USERNAME="--targetusername $TARGETDEVHUBUSERNAME"
    fi

    if [ "${#ARR_DEPENDENCIES[@]}" != 0 ]
    then
        echo "${GREY_BOLD}Installing dependencies..${NO_COLOUR}\n"
        for eachDependency in "${ARR_DEPENDENCIES[@]}"
        do
            QUERY_STRING="SELECT Name, MajorVersion, MinorVersion, PatchVersion, BuildNumber, SubscriberPackageId FROM SubscriberPackageVersion WHERE Id='$eachDependency'"
            # query in the loop due to salesforce implementation restrictions
            DEPENDENCY_RECORD=$(sfdx force:data:soql:query --usetoolingapi --query "$QUERY_STRING" $OPTION_DH_USERNAME --json | jq '.result.records[0]')
            # TODO: NEXT TWO LINES INTO ONE
            SUB_PACKAGE_VERSION_ID=$(echo $DEPENDENCY_RECORD | jq '.SubscriberPackageId')
            SUB_PACKAGE_VERSION_ID=(${SUB_PACKAGE_VERSION_ID//"\""})
            QUERY_STRING="SELECT Name FROM SubscriberPackage WHERE Id='$SUB_PACKAGE_VERSION_ID'"
            echo "${GREY_BOLD}Name : ${GREEN}"$(sfdx force:data:soql:query --usetoolingapi --query "$QUERY_STRING" $OPTION_DH_USERNAME --json | jq '.result.records[0].Name')${NO_COLOUR}
            echo "${GREY_BOLD}Version : ${GREEN}"$(echo $DEPENDENCY_RECORD | jq '.MajorVersion').$(echo $DEPENDENCY_RECORD | jq '.MinorVersion').$(echo $DEPENDENCY_RECORD | jq '.PatchVersion').$(echo $DEPENDENCY_RECORD | jq '.BuildNumber')${NO_COLOUR}
            echo "${GREY_BOLD}Id : ${GREEN}$eachDependency"${NO_COLOUR}
            echo "${GREY_BOLD}SubscriberPackageId : ${GREEN}$SUB_PACKAGE_VERSION_ID"${NO_COLOUR}
            echo "${GREY_BOLD}Target Org : ${GREEN}$TARGETUSERNAME"${NO_COLOUR}

            sfdx force:package:install -p ${eachDependency} -u $TARGETUSERNAME -w 20 -r # -r is no prompt
        done
    fi
}

function isPacakgeInstalled {
    echo "TODO: Implement this method to check if the package is already installed in the org"
}