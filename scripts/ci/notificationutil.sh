#!/bin/sh
# read notification related parameters
function readNotificationParams() {
    while [[ $# -gt 0 ]] # for each positional parameter
    do key="$1"
        case "$key" in
            -l|--url) # matching argument with sfdx standards
                WEBHOOKURL="$2"
                shift # past argument
                shift # past value
            ;;
            -c|--themecolour) # matching argument with sfdx standards
                COLOUR="$2"
                shift # past argument
                shift # past value
            ;;
            -t|--title) # matching argument with sfdx standards
                TITLE="$2"
                shift # past argument
                shift # past value
            ;;
            -st|--subtitle) # matching argument with sfdx standards
                SUBTITLE="$2"
                shift # past argument
                shift # past value
            ;;
            -s|--statuscode) # matching argument with sfdx standards
                STATUSCODE="$2"
                shift # past argument
                shift # past value
            ;;
            -m|--message) # matching argument with sfdx standards
                MESSAGE="$2"
                shift # past argument
                shift # past value
            ;;
            -d|--details) # matching argument with sfdx standards
                DETAILS="$2"
                shift # past argument
                shift # past value
            ;;
            *) # unknown option
                shift # past argument
            ;;
        esac
    done
}

function sendTeamsNotification() {
    WEBHOOK_URL=$1

    # Post to Microsoft Teams.
    echo $(curl -sb -H "Content-Type: application/json" -d "${TEAM_NOTIFIATION_JSON}" "${WEBHOOK_URL}")
}

function sendNotification() {
    readNotificationParams "$@"
    if [ "$STATUSCODE" = "0" ] # success notification
    then
        STATUS="SUCCESS"
        prepareNotificationJson
        echo "Success! Sending teams notification."
        sendTeamsNotification "https://sage365.webhook.office.com/webhookb2/1684ded0-b7a0-46f0-af48-d46b403ea75b@3e32dd7c-41f6-492d-a1a3-c58eb02cf4f8/IncomingWebhook/42190d8ce99e4602af2d5c9e8ead3157/29be0f97-c2eb-4d1f-8b31-93c80f2b466e"
        exit 0
    else # failure notification
        STATUS="FAILURE"
        prepareNotificationJson
        echo "Failed! Sending teams notification."
        sendTeamsNotification "https://sage365.webhook.office.com/webhookb2/1684ded0-b7a0-46f0-af48-d46b403ea75b@3e32dd7c-41f6-492d-a1a3-c58eb02cf4f8/IncomingWebhook/42190d8ce99e4602af2d5c9e8ead3157/29be0f97-c2eb-4d1f-8b31-93c80f2b466e"
        exit 1
    fi
}

function sendNotificationWoStatus() {
    readNotificationParams "$@"
    STATUS="FAILURE"
    COLOUR="d70000"
    prepareNotificationJson
    echo "Failed! Sending teams notification."
    sendTeamsNotification "https://sage365.webhook.office.com/webhookb2/1684ded0-b7a0-46f0-af48-d46b403ea75b@3e32dd7c-41f6-492d-a1a3-c58eb02cf4f8/IncomingWebhook/42190d8ce99e4602af2d5c9e8ead3157/29be0f97-c2eb-4d1f-8b31-93c80f2b466e"
    exit 1
}

function prepareNotificationJson() {
    DATE=$(date)
    case "$STATUSCODE" in
        "0") COLOUR="00d793" ;;
        "1") COLOUR="d70000" ;;
        *) COLOUR="00d793" ;;
    esac

    TEAM_NOTIFIATION_JSON="{
        \"@type\": \"MessageCard\",
        \"themeColor\": \"$COLOUR\",
        \"summary\": \"DX Notifications\",
        \"sections\": [{
            \"activityTitle\": \"$TITLE\",
            \"activitySubtitle\": \"$SUBTITLE\",
            \"activityImage\": \"https://d259t2jj6zp7qm.cloudfront.net/images/v1517507037-trailhead_module_salesforce_dx_development_model_c3rpsu.png\",
            \"facts\": [{
                \"name\": \"Date Time\",
                \"value\": \"$DATE\"
            }, {
                \"name\": \"Status\",
                \"value\": \"$STATUS\"
            }, {
                \"name\": \"Message\",
                \"value\": \"$MESSAGE\"
            }, {
                \"name\": \"Details\",
                \"value\": \"$DETAILS\"
            }],
            \"markdown\": true
        }],
        \"potentialAction\": [{
            \"@type\": \"OpenUri\",
            \"name\": \"Open Log\",
            \"targets\": [{
                \"os\": \"default\",
                \"uri\": \"$GITHUB_SERVER_URL/$GITHUB_REPOSITORY/actions/runs/$GITHUB_RUN_ID\"
            }]
        }]
    }"
}