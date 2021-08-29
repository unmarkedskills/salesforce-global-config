#!/bin/bash
source "$SCRIPTS_PATH/scripts/ci/globalutil.sh"
source "$SCRIPTS_PATH/scripts/ci/createPackage.sh"
source "$SCRIPTS_PATH/scripts/ci/deployutil.sh"
source "$SCRIPTS_PATH/scripts/ci/deployment.sh"

function init() {
    # set path for sfdx
    PATH=/root/sfdx/bin:$PATH
    sfdx --version
    sfdx plugins --core
    CURRENT_BRANCH=$(echo $BRANCH | sed 's/.*\///')
    USE_SFDX_BRANCH=$(cat $SCRIPTS_PATH/scripts/ci/config.json | jq '.useBranch')
    DEPDENCY_VAL=$(cat $SCRIPTS_PATH/scripts/ci/config.json | jq '.dependecyValidation')

    GIT_SSH_REPO="git@github.com:Sage/" # git environment ssh link
    TARGETDEVHUBUSERNAME="devhubuser" # setup devhubuser alias
    echo $DEV_HUB_URL > /root/secrets/devhub.txt # save the devhub org secret
    echo "Authorising devhub..."
    AUTH_RESPONSE=$(authorizeOrg "/root/secrets/devhub.txt" $TARGETDEVHUBUSERNAME)
    # TODO: REMVOE DEPENDENCY FROM GITHUB URLS
    handleSfdxResponse "$AUTH_RESPONSE" "DX DevHub Authorization Failed" "Failed at $GITHUB_SERVER_URL/$GITHUB_REPOSITORY repository"
    echo "Success! DevHub authorised..."

    echo "Fetch local config"
    CI_CONFIG=$(cat $SCRIPTS_PATH/scripts/ci/config.json)

    if [ "$OPERATION" = "create_version" ]
    then
        echo "Package version request.."
        TITLE="Package Creation Notifications"
        VALIDATE_DEPENDENCY_ERROR=$ERR_DEPENDENCY_VALIDATION
        packageCreate
        echo "::set-output git comname=package_version_id::$SUBSCRIBER_PACKAGE_VERSION"
    elif [ "$OPERATION" == "install_version" ]
    then
        echo "Install Package Version Request"
        echo $ENV_URL > /root/secrets/environment.txt # save the devhub org secret
        echo "Authorizing target environment..."
        TARGETUSERNAME="envuser"
        local AUTH_RESPONSE=$(authorizeOrg "/root/secrets/environment.txt" $TARGETUSERNAME)
        # TODO: REMVOE DEPENDENCY FROM GITHUB URLS
        handleSfdxResponse "$AUTH_RESPONSE" "DX DevHub Authorization Failed" "Failed at $GITHUB_SERVER_URL/$GITHUB_REPOSITORY repository"
        local INSTANCE=$(echo $AUTH_RESPONSE | jq -r '.result.instanceUrl')
        echo "Success! Environment authorised..."
        deployPackage --targetusername $TARGETUSERNAME --instance "$INSTANCE"
    elif [ "$OPERATION" == "deployment" ]
    then
        echo "HERE FOR DEPLOYMENT!!!!!!!!!!!!!!!!!!!!!!!!!!"
        if [ "$ENVIRONMENT" = "sandboxes" ]
        then
            echo "Continue with prod path sandbox installation.."
            echo "Authorise environments..."
            # TODO: put environments in a config
            echo $ENV_UAT_URL > /root/secrets/envuat.txt # save the org secret
            ENV_UAT="envuat"
            AUTH_RESPONSE=$(authorizeOrg "/root/secrets/envuat.txt" "$ENV_UAT")
            handleSfdxResponse "$AUTH_RESPONSE"
            echo "Uat environment authorised"

            ENV_TRAINING="envtraining"
            echo $ENV_TRAINING_URL > /root/secrets/envtraining.txt # save the org secret
            AUTH_RESPONSE=$(authorizeOrg "/root/secrets/envtraining.txt" "$ENV_TRAINING")
            handleSfdxResponse "$AUTH_RESPONSE"
            echo "Training environment authorised"
        elif [ "$ENVIRONMENT" = "production" ]
        then
            echo "Continue with production deployment.."
        else
            sendNotification --statuscode "1" --message "Version of commit id already exist" \
                        --details "A version ($VERSION_DEVHUB) is already available for commit id $LATEST_COMMIT, please remove the version and retry"
        fi
        # initialize deployment
        initDeployment --environment $ENVIRONMENT
    else
        echo "Validation Request.."
    fi
}