#!/bin/sh

if [ -z "$1" ]; then
    echo "Usage : ./loadENVData.sh <ORG>"
    exit 1;
fi

DATADIR=../data

paynow(){
    sfdx force:data:tree:import -p ./data/paynow/auth-Auth_Credentials_Override__c-plan.json -u $1
}

commerceServices(){
    sfdx force:data:tree:import -p $DATADIR/commerce-services/auth-Auth_Credentials_Override__c-plan.json -u $1
}

connectViews(){
    sfdx force:data:tree:import -p $DATADIR/connect-views/service-stub-Service_Invocation_Override__c-plan.json -u $1
}

doAll(){
    paynow $1
    commerceServices $1
}

doAll $1