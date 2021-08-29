#!/bin/bash
# send teams notification on job failure
source "$SCRIPTS_PATH/scripts/ci/notificationutil.sh"
TITLE="DX Job Run Status"
SUBTITLE="Job run failed"
sendNotificationWoStatus --statuscode "1" --message "Unknown error occured" \
                --details "Error occured during package creation, please check dev channel or view logs by clicking View Log button"