#!/bin/sh

if [ -z "$1" ]; then
    echo "Usage : ./loadENVData.sh <ORG>"
    exit 1;
fi

DATADIR=../data

# Ensures that high volume connect requests are not logging in prod - you get > 60K calls a day. enable when issues arrise
queryAndKeyInfo(){
    sfdx force:data:tree:import -p $DATADIR/keyinfo_prodholdings/keyinfo-prodholding-Service_Invocation_Override__c-plan.json -u $1
}

doAll(){
    queryAndKeyInfo $1
}

doAll $1