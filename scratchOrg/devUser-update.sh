#!/bin/bash

whichOrg(){
    if [ -z "$ORG_NAME" ]
    then
        while [ ! -n "$ORG_NAME"  ] 
        do
            echo -e "${GREEN_BOLD}Loading active scratch Orgs...${NO_COLOUR}"
            ORGS=$(sfdx force:org:list --json | jq '.result.scratchOrgs[] .alias' | tr -d \")
            
            echo $ORGS
            echo -e "${GREEN_BOLD}🐱  Please enter a name for your scratch org:${NO_COLOUR}"
            read ORG_NAME
        done
    fi  

}

enableDevMode(){
    sfdx force:data:record:update -s User -w "Name='User User'" -v "UserPreferencesApexPagesDeveloperMode=true UserPreferencesUserDebugModePref=true" -u ${ORG_NAME}
}

if [ $# -eq 0 ]
then
    echo "Reading Org info..."
    whichOrg
else
    ORG_NAME=$1
    echo "Loading For..${ORG_NAME}"
fi


enableDevMode