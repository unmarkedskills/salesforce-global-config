#!/bin/bash
# read notification related parameters
function readNotificationParams() {
    while [[ $# -gt 0 ]] # for each positional parameter
    do key="$1"
        case "$key" in 
            -e|--environment) # matching argument with sfdx standards
                ENVIRONMENT="$2"
                shift # past argument
                shift # past value
            ;;
            -r|--repository) # matching argument with sfdx standards
                REPOSITORY="$2"
                shift # past argument
                shift # past value
            ;;
            -k|--sshkey) # matching argument with sfdx standards
                SSHKEY="$2"
                shift # past argument
                shift # past value
            ;;
            *) # unknown option
                shift # past argument
            ;;
        esac
    done
}

function initDeployment() {
    
    echo "GITHUB URL"
    echo $GIT_URL
    echo $ENV_UAT2_URL > /root/secrets/sshkey
    echo "initDeployment"
    echo $ENVIRONMENT
    ls -l
    cat releases/deployment.json | jq -r '.releaseName'
    setupWorkspace
}

# function checkoutRepository() {

# }

function setupEnvironment() {
    if [ "$ENVIRONMENT" = "sandboxes" ] 
    then
        # sandbox enviornment
        git clone "$GIT_URL/salesforce-global-community" wp-uat
    else
        # production enviornment
        mkdir wp-production
    fi
}

function setupWorkspace() {
    echo "setupWorkspace"
    echo "Get git repo url"
    GIT_URL=$GITHUB_SERVER_URL/$(echo $GITHUB_REPOSITORY | cut -d/ -f1)
    echo "Git Url: $GIT_URL"

    echo "Setup ssh for repo clone"
    mkdir /root/.ssh
    ls -l
    cp id_github_wf_clone /root/.ssh
    cp config /root/.ssh
    ssh-keyscan github.com >> ~/.ssh/known_hosts
    chmod 600 ~/.ssh/known_hosts
    ls -l /root/.ssh
    
    echo "Clone 1 Done"
    git clone $GIT_SSH_REPO/salesforce-global-sales
    echo "Clone 2 Done"
    ls -l
    echo "setupWorkspace END"
}

function setupGit() {
    # TODO: GIT SETUP IN CONTAINER FOR PRIVATE REPOS
    echo "Test"
}