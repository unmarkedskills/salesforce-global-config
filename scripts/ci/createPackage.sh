#!/bin/bash
source "$SCRIPTS_PATH/scripts/ci/notificationutil.sh"
source "$SCRIPTS_PATH/scripts/ci/globalutil.sh"
source "$SCRIPTS_PATH/scripts/ci/packageutil.sh"

function packageCreate() {
    # get sfdx json file
    DEFINITIONFILE="$SCRIPTS_PATH/scratch-org-config/project-scratch-def.json"
    SFDX_JSON=$(cat sfdx-project.json)
    P_NAME=$(echo $SFDX_JSON | jq -r ".packageDirectories | map(select(.default == true))  | .[0].package")
    echo "Package name found : $P_NAME"
    if [ -n "$P_NAME" ]
    then # if package name not found in sfdx project json (package not created yet)
        echo "Query package details.."
        SUBTITLE="Create package version $P_NAME - $VERSION_SFDX_JSON"
        QUERY_RESPONSE=$(queryLatestPackageVersionByName $P_NAME)
        handleSfdxResponse "$QUERY_RESPONSE"
        VERSION_DEVHUB=$(echo $QUERY_RESPONSE | jq -r '"\(.result.records[0].MajorVersion)"+"."+"\(.result.records[0].MinorVersion)"+"."+"\(.result.records[0].PatchVersion)"+"."+"\(.result.records[0].BuildNumber)"')
        VERSION_SFDX_JSON=$(echo $SFDX_JSON | jq -r ".packageDirectories | map(select(.package == \"$P_NAME\")) | .[0].versionNumber" | cut -d "." -f1,2,3)
        if [ "$(echo $QUERY_RESPONSE | jq ".result.totalSize")" = "0" ]
        then # package not found
            # TODO: REVISIT AS PACKAGE NAME WILL NOT BE AVAILABLE iN SFDX PROJECT JSON
            echo "$P_NAME not found, create a package and then version"
            # TODO: CREATE PACKAGE BEFORE CREATING VERSION
        else # package found
            if [ "$LATEST_COMMIT" = $(echo $QUERY_RESPONSE | jq -r ".result.records[0].Tag") ]
            then # if a version is already available for  commit id
                echo "A version ($VERSION_DEVHUB) with current commit $LATEST_COMMIT already created. please remove the version and rerun the job"
                sendNotification --statuscode "1" --message "Version of commit id already exist" \
                        --details "A version ($VERSION_DEVHUB) is already available for commit id $LATEST_COMMIT, please remove the version and retry"
            else
                echo "$P_NAME found, continue to create package version"
                # get package version id
                PACKAGE_Id=$(echo $QUERY_RESPONSE | jq -r ".result.records | map(select(.Package2.Name == \"$P_NAME\"))  | .[0].Package2Id")
                # get package version without beta/release version
                MAIN_VERSION_DEVHUB=${VERSION_DEVHUB%.*}
                if [ "$VERSION_SFDX_JSON" = "$MAIN_VERSION_DEVHUB" ]
                then # if package version (major.minor.patch) is same as requested (sfdx json)
                    echo "Latest devhub package version is same as requested (sfdx-project.json)"
                    if [ "$(echo $QUERY_RESPONSE | jq -r ".result.records[0].IsReleased")" = "true" ]
                    then # if requested package version released, fail the job and send notification
                        echo "Requested version $VERSION_SFDX_JSON is already released, please update sfdx project json and rerun the job"
                        sendNotification --statuscode "1" --message "Requested version is already released" \
                            --details "Requested version $VERSION_SFDX_JSON is already released, please increase either major, minor or patch version."
                    else # create package version
                        checkDependencyVersions "$P_NAME" "$SFDX_JSON"
                        echo "Creating next beta version ($VERSION_SFDX_JSON) for package $P_NAME ..."
                        createVersion --package $PACKAGE_Id --tag $LATEST_COMMIT --targetdevhubusername $TARGETDEVHUBUSERNAME \
                            --wait 30 --definitionfile $DEFINITIONFILE --versionnumber $VERSION_SFDX_JSON
                    fi
                else # if package version (major.minor.patch) is not same as requested (sfdx json)
                    echo "Requested package version (sfdx-project.json) and latest devhub version are not same"
                    # check if the package version requested is downgrading
                    if [ "$(isUpgrade $MAIN_VERSION_DEVHUB $VERSION_SFDX_JSON)" = "0" ]
                    then # create package version
                        checkDependencyVersions "$P_NAME" "$SFDX_JSON"
                        echo "Creating next beta version ($VERSION_SFDX_JSON) for package $P_NAME ..."
                        createVersion --package $PACKAGE_Id --tag $LATEST_COMMIT --targetdevhubusername $TARGETDEVHUBUSERNAME --wait 30 --definitionfile $DEFINITIONFILE
                    else # error! package version is downgrading
                        echo "Cannot downgrade a package version from $MAIN_VERSION_DEVHUB to $VERSION_SFDX_JSON."
                        sendNotification --statuscode "1" --message "Cannot downgrade a package version" \
                            --details "Version downgrade not possible, please increase either major, minor or patch version. Latest DevHub version is : $MAIN_VERSION_DEVHUB, sfdx project json/requested version: $VERSION_SFDX_JSON."
                    fi
                fi
            fi
        fi
    else
        echo "Package Name not found in sfdx-json"
        # TODO: SEND NOTIFICATION OR HANDLE THIS SCENARIO
    fi
}