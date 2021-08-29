#!/bin/bash
source "$SCRIPTS_PATH/scripts/ci/packageutil.sh"

# read notification related parameters
function readDeployParams() {
    while [[ $# -gt 0 ]] # for each positional parameter
    do key="$1"
        case "$key" in
            -p|--sourcepath) # matching argument with sfdx standards
                SOURCEPATH="$2"
                shift # past argument
                shift # past value
            ;;
            -u|--targetusername) # matching argument with sfdx standards
                TARGETUSERNAME="$2"
                shift # past argument
                shift # past value
            ;;
            -rt|--runtests) # matching argument with sfdx standards
                RUNTESTS="$2"
                shift # past argument
                shift # past value
            ;;
            -j|--jsonarray) # 
                JSONARRAY="$2"
                shift # past argument
                shift # past value
            ;;
            -m|--mainpath) # 
                MAINPATH="$2"
                shift # past argument
                shift # past value
            ;;
            -pid|--packageversionid) # 
                PACKAGEVERSIONID="$2"
                shift # past argument
                shift # past value
            ;;
            -pv|--packageversion) # 
                PACKAGEVERSION="$2"
                shift # past argument
                shift # past value
            ;;
            -pn|--packagename) # 
                PACKAGENAME="$2"
                shift # past argument
                shift # past value
            ;;
            -in|--instance) # 
                INSTANCE="$2"
                shift # past argument
                shift # past value
            ;;
            -c|--config) # 
                CONFIG="$2"
                shift # past argument
                shift # past value
            ;;
            -wt|--wait) #
                WAIT="$2"
                shift # past argument
                shift # past value
            ;;
            *) # unknown option
                shift # past argument
            ;;
        esac
    done
}

function installPackageVersion() {
    readDeployParams "$@"
    local COMMAND="sfdx force:package:install --targetusername=$TARGETUSERNAME --package=$PACKAGEVERSIONID --noprompt --json"
    echo "RUN: $COMMAND"
    local RESPONSE_INSTALL=$($COMMAND)
    # THIS IS DONE DUE TO SALESFORCE BUG INSERING UNSUPPORTED CHARS IN THE COMMAND RESPONSE
    RESPONSE_INSTALL=$(echo $RESPONSE_INSTALL | tee tempfile)
    rm tempfile

    local JOBID=$(echo $RESPONSE_INSTALL | jq -r ".result.Id")
    echo "Initilised with job id: $JOBID"
    while true
    do
        local INSTALL_REPORT=$(sfdx force:package:install:report --requestid=$JOBID --targetusername=$TARGETUSERNAME --json)
        # THIS IS DONE DUE TO SALESFORCE BUG INSERING UNSUPPORTED CHARS IN THE COMMAND RESPONSE
        INSTALL_REPORT=$(echo $INSTALL_REPORT | tee tempfile)
        rm tempfile
        if [ "$(echo $INSTALL_REPORT | jq -r ".status")" = "1" ]
        then
            handleSfdxResponse "$INSTALL_REPORT"
            break
        else
            local STATUS=$(echo $INSTALL_REPORT | jq -r ".result.Status")
            local INSTANCE=$(echo $AUTH_RESPONSE | jq '.result.loginUrl')
            if [ "$STATUS" = "SUCCESS" ]
            then
                echo "Package successfully installed.."
                sendNotification --statuscode "0" \
                   --message "Package insatllation successful" \
                   --details "Package version <b>$PACKAGEVERSION</b> for <b>$PACKAGENAME</b> is installed successfully 
                       in instance '$INSTANCE'."
            elif [ "$STATUS" = "ERROR" ] || [ "$STATUS" = "Error" ]
            then
                echo "Package installation failed.."
                sendNotification --statuscode "0" \
                   --message "Package insatllation failed" \
                   --details "Package version <b>$PACKAGEVERSION</b> for <b>$PACKAGENAME</b> installation is failed in instance '$INSTANCE'."
            else
                sleep 4
                echo "Request status $STATUS"
            fi
        fi
    done
}

function sourceDeploy() {
    readDeployParams "$@"
    echo "Starting source deploy.."
    local COMMAND="sfdx force:source:deploy --sourcepath=$SOURCEPATH --targetusername=$TARGETUSERNAME --testlevel=RunSpecifiedTests --runtests=$RUNTESTS --json"
    echo $COMMAND
    local DEPLOY_RESPONSE=$($COMMAND)
    echo $DEPLOY_RESPONSE
    handleSfdxResponse "$DEPLOY_RESPONSE"
}

function sourceDeployByPath() { # params $1 - data array, $2 - environment, $3 - source path, $4 - tests to run
    readDeployParams "$@"
    local iterator=0
    local PATH_TO_DEPLOY=""
    if [ -n "$CONFIG" ]
    then
        for eachConfig in $(echo $CONFIG | jq -rc ".[]")
        do
            #local eachPath=$(echo $eachPath | jq -rc '.value')
            local eachPath="$MAINPATH"/$(echo $eachConfig | jq -rc '.value')
            if [ -d $eachPath ]
            then
                if [ $iterator = 0 ]
                then
                    PATH_TO_DEPLOY=$MAINPATH/$(echo $eachConfig | jq -rc '.value')
                else
                    PATH_TO_DEPLOY=$PATH_TO_DEPLOY",$MAINPATH/$(echo $eachConfig | jq -rc '.value')"
                fi
            fi
            iterator=$((iterator+1))
        done
    else
        PATH_TO_DEPLOY=$SOURCE_PATH
    fi
    if [ -n "$PATH_TO_DEPLOY" ]
    then
        echo "DEPLOY START"
        sourceDeploy --sourcepath "$PATH_TO_DEPLOY" --targetusername "$TARGETUSERNAME" --runtests $RUNTESTS
    fi
}

function deployPackage() {
    readDeployParams "$@"
    echo "Preparing package details..."
    # get package name from sfdx project json
    local JSON_DATA=$(cat $SCRIPTS_PATH/sfdx-project.json | jq -r ".packageDirectories | map(select(.default == true))  | .[0].package,.[0].path")
    PACKAGE_NAME=$(echo $JSON_DATA | cut -d ' ' -f1)
    local PACKAGEID=$(cat $SCRIPTS_PATH/sfdx-project.json | jq -r ".packageAliases.\"${PACKAGE_NAME}\"")
    echo "PACKAGEID: "$PACKAGEID
    local SVI=""

    if [ -n "$PACKAGEVERSIONID" ]
    then # if package version id passed in the method
        # TODO CHECK PACKAGE VERSION PASSED IS OF CURRENT PACKAGE
        SVI=$PACKAGEVERSIONID
    else # if not passed, get latest cretaed package version id
        # query latest created package from devhub
        local QUERY_RESPONSE=$(queryLatestPackageVersionByPackageId $PACKAGEID)
        local VERSION_NUMBER=$(echo $QUERY_RESPONSE | jq -r '"\(.result.records[0].MajorVersion)"+"."+"\(.result.records[0].MinorVersion)"+"."+"\(.result.records[0].PatchVersion)"')
        SVI=$(echo $QUERY_RESPONSE | jq -r '.result.records[0].SubscriberPackageVersion.attributes.url' | sed 's/.*\///')
    fi

    if [ -n "$SVI" ]
    then
        echo "Package version id to be installed : "$SVI
        # check if version is already installed
        # get all installed versions of org
        echo "Get package installed version id from the org"
        local INSTALLED_PACKAGE=$(sfdx force:package:installed:list --targetusername=$TARGETUSERNAME --json)
        handleSfdxResponse "$INSTALLED_PACKAGE"

        local SVI_INSTALLED=$(echo $INSTALLED_PACKAGE | jq -r ".result | map(select(.SubscriberPackageName == \"$PACKAGE_NAME\")) | .[0].SubscriberPackageVersionId")
        echo "Installed package version in $TARGETUSERNAME : $SVI_INSTALLED"
        if [ "$SVI" != "$SVI_INSTALLED" ]
        then # move ahead with package deployment
            # get local config
            local CI_CONFIG=$(cat $SCRIPTS_PATH/config/scripts/ci/config.json)
            # source deploy from the folders specified in config json
            # TODO: USE GIT DIFF HERE
            sourceDeployByPath --config "$(echo $CI_CONFIG | jq -r '.sourceDeploy.pathInSource')" \
                --runtests "$(echo $CI_CONFIG | jq -r '.sourceDeploy.testClass')" \
                --targetusername $TARGETUSERNAME --mainpath $(echo $JSON_DATA | cut -d ' ' -f2)
            # query latest released package from devhub
            local QUERY_RESPONSE_RELEASED=$(queryLatestReleasedVersionByPackageId $PACKAGEID)
            # latest commit on the branch
            local COMMIT_CURRENT=$(echo $QUERY_RESPONSE | jq -r '.result.records[0].Tag')
            # commit on last released package version
            local COMMIT_RELEASED=$(echo $QUERY_RESPONSE_RELEASED | jq -r '.result.records[0].Tag')

            if [ -n "$COMMIT_RELEASED" ] && [ "$COMMIT_RELEASED" != null ]
            then
                echo "inside COMMIT_RELEASED"
                if [ -n "$COMMIT_CURRENT" ] && [ "$COMMIT_CURRENT" != null ]
                then
                    echo "inside COMMIT_CURRENT"
                    # get all changed files between commits based on config
                    local COMPONENTS=$(git diff --name-only --ignore-submodules --diff-filter=AM -S"<type>Picklist</type>" $COMMIT_RELEASED $COMMIT_CURRENT \
                            $(echo $CI_CONFIG | jq -r '.sourceDeploy.metadata[] | select(has("extn")) | "*."+.extn') \
                            | tr '\n' ',' | sed 's/\(.*\),/\1 /')
                    if [ -n $COMPONENTS ] 
                    then
                        sourceDeployByPath --sourcepath $COMPONENTS \
                            --runtests "$(echo $CI_CONFIG | jq -r '.sourceDeploy.testClass')" \
                            --targetusername $TARGETUSERNAME
                    fi
                fi
            fi

            installPackageVersion --packageversionid $SVI --packagename $PACKAGE_NAME \
                --wait "$(echo $CI_CONFIG | jq -r '.installWait')" --packageversion $VERSION_NUMBER --instance "$INSTANCE" 
        else # Do not deploy and send a notification
            echo "Package version is already installed in $TARGETUSERNAME environment."
            sendNotification --statuscode "0" --message "Package version id $SVI already installed" --details "Package version id $SVI already installed in $INSTANCE."
        fi
    else
        echo "Package version id not found."
        sendNotification --statuscode "1" --message "Package version not found" --details "Package version ($SVI) not found for package $PACKAGE_NAME."
    fi
}