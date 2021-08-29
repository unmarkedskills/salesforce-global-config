#!/bin/sh
function readParams {
    while [[ $# -gt 0 ]] # for each positional parameter
    do key="$1"
        case "$key" in
            -p|--package) # matching argument with sfdx standards
                PACKAGE="$2"
                shift # past argument
                shift # past value
            ;;
            -v|--targetdevhubusername) # matching argument with sfdx standards
                TARGETDEVHUBUSERNAME="$2"
                shift # past argument
                shift # past value
            ;;
            -u|--targetusername) # matching argument with sfdx standards
                TARGETUSERNAME="$2"
                shift # past argument
                shift # past value
            ;;
            -p|--sourcepath) #matching argument with sfdx standards
                TARGETUSERNAME="$2"
                shift # past argument
                shift # past value
            ;;
            -a|--setalias)
                SETALIAS="$2"
                shift # past argument
                shift # past value
                ;;
            -d|--durationdays)
                DURATIONDAYS="$2"
                shift # past argument
                shift # past value
                ;;
            --configpath)
                CONFIGPATH="$2"
                shift # past argument
                shift # past value
                ;;
            --runfromci) # Switch parameter with no values
                RUNFROMCI=TRUE
                shift # past argument
                ;;                
            *) # unknown option
                shift # past argument
            ;;
        esac
    done
}

# get package id if package name is passed
function getPacakgeIdFromName {
    case $PACKAGE in
        0Ho*)
            echo "${GREEN}Package Id : $PACKAGE${NO_COLOUR}"
        ;;
        *)
            echo "${GREY_BOLD}Getting package Id for package name ${GREEN}$PACKAGE ...${NO_COLOUR}"
            QUERY_STRING="SELECT Id FROM Package2 WHERE Name = '$PACKAGE'"

            if [ -n "$TARGETDEVHUBUSERNAME" ] # check if target org username is available
            then # use the username to fetch the data
                OPTION_DH_USERNAME="--targetusername $TARGETDEVHUBUSERNAME"
            fi

            # get package id from json
            PACKAGE=$(sfdx force:data:soql:query --usetoolingapi --query "$QUERY_STRING" $OPTION_DH_USERNAME --json | jq '.result.records[0].Id')
            PACKAGE=${PACKAGE//"\""} # remove pre and trailing double quotes
            echo "${GREY_BOLD}Package Id : ${GREEN_BOLD}$PACKAGE${NO_COLOUR}"
        ;;
    esac
}

function isTargetDevHubAvailable {
    if [ -z $TARGETDEVHUBUSERNAME ]
    then
        echo "${RED_BOLD}\nTARGETDEVHUBUSERNAME environment variable not set, please set the same before proceeding..${RED}$PACKAGE_SUBID${NO_COLOUR}"
        echo "${GREEN}*********************** Help ***********************${NO_COLOUR}"
        case "$OSTYPE" in 
            "darwin"*|"linux-gnu"*|"cygwin")
                echo "${GREY_BOLD}OS: ${GREEN}Mac OSX or Linux${NO_COLOUR}"
                echo "${GREY_BOLD}Setup variable for current user${NO_COLOUR}"
                echo "${GREY_BOLD}\t1. Run ${GREEN}export TARGETDEVHUBUSERNAME=[SAGE_PROD_USERNAME]"
                echo "${GREY_BOLD}\t2. Replace ${GREEN}[SAGE_PROD_USERNAME] ${GREY_BOLD}with corresponding value \n"${NO_COLOUR}
            ;;
            "win32"|"msys")
                echo "${GREEN}OS: Microsoft Windows${NO_COLOUR}"
                echo "${GREEN}Setup variable for current user${NO_COLOUR}"
                echo "${GREEN}\t1. Right-click the Computer icon and choose Properties, or in Windows Control Panel, choose System."
                echo "\t1. Right-click the Computer icon and choose Properties, or in Windows Control Panel, choose System."
                echo "\t2. Choose Advanced system settings."
                echo "\t3. On the Advanced tab, click Environment Variables."
                echo "\t4. Click New to create a new environment variable. Click Edit to modify an existing environment variable."
                echo "\t5. After creating or modifying the environment variable, click Apply and then OK to have the change take effect.${NO_COLOUR}"
            ;;
        esac
        exit
    else
        echo "${GREY_BOLD}Target dev hub org: ${GREEN}$TARGETDEVHUBUSERNAME${NO_COLOUR}"
    fi
}

function updateScratchDef {
	TEMPFILE="$SCRATCH_ORG_PATH""user-scratch-def.json"
	ORGFILE="$SCRATCH_ORG_PATH""project-scratch-def.json"
	echo "${GREY_BOLD}Updating adminEmail to users email address : ${GREEN}$TARGETDEVHUBUSERNAME${NO_COLOUR}"
	jq --arg foo $TARGETDEVHUBUSERNAME '.adminEmail  = $foo | .settings.caseSettings.systemUserEmail  = $foo' $ORGFILE > $TEMPFILE
}

function preInstallDeploy() { # deploy components/setting which are required for scratch org deployment
    if [ -n "$SCRATCH_PRE_PATH" ] # check if repo reference to coredatamodel 
	then
        echo "${GREY_BOLD}Deploy scratch org pre deployment components in ${GREEN}$TARGETUSERNAME "${NO_COLOUR}
		sfdx force:source:deploy --targetusername=$TARGETUSERNAME --sourcepath=$SCRATCH_PRE_PATH # deploy config pre deploy path
        errorExit
    fi

    if [ -d cdm/coredatamodel ] # check if repo reference to coredatamodel 
	then
        echo "${GREY_BOLD}Deploy scratch org pre deployment components in ${GREEN}$TARGETUSERNAME "${NO_COLOUR}
		sfdx force:source:deploy --targetusername=$TARGETUSERNAME --sourcepath=cdm/coredatamodel/unpackaged-1/standardValueSets # deploy cdm unpackaged
        errorExit
    fi

    if [ -d demo/scratchDeploy ] # check if repo contains it's own scratch deploy settingsßß
	then
		echo "${GREY_BOLD}Deploy scratch org pre deployment components in ${GREEN}$TARGETUSERNAME "${NO_COLOUR}
		sfdx force:source:deploy --targetusername=$TARGETUSERNAME --sourcepath=demo/scratchDeploy # repo specific pre scratch components
        errorExit
	fi
}

function deploySource() {
	echo "${GREY_BOLD}Deploy source in ${GREEN}$TARGETUSERNAME "${NO_COLOUR}
    sfdx force:source:push --targetusername=$TARGETUSERNAME
    errorExit
}

function errorExit() {
    if [ "$?" = "1" ]
    then
        if [ -n "$1" ]
        then
            if [ "$1" = "1" ]
            then
                echo "${RED}Fatal error: $2${NO_COLOUR}"
            else
                echo "${RED}Fatal error: $1${NO_COLOUR}"
            fi
        else
            echo "${RED}Fatal error: please see error above for more info. Exiting..${NO_COLOUR}"
        fi
        exit
    else
        if [ "$1" = "1" ]
        then
            echo "${RED}Fatal error: $2${NO_COLOUR}"
            exit
        fi
    fi
}

function createScratchOrg() {
	isTargetDevHubAvailable
	updateScratchDef

    CMD_CREATE_ORG="sfdx force:org:create --definitionfile="$SCRATCH_ORG_PATH"user-scratch-def.json " # intialise command string

    if [ -n "$TARGETDEVHUBUSERNAME" ]
	then
		CMD_CREATE_ORG+="--targetdevhubusername=${TARGETDEVHUBUSERNAME} "
    else
        echo "${RED_BOLD}\nTARGETDEVHUBUSERNAME environment variable not set, please set the same before proceeding..${NO_COLOUR}"
        exit
	fi
    
    if [ -n "$SETALIAS" ]
    then
        echo "${GREEN_BOLD}Org Alias will be $SETALIAS ${NO_COLOUR}"
    else
        printf "${GREY_BOLD}Enter Org Alias to create : ${NO_COLOUR}"
        read SETALIAS
    fi
    CMD_CREATE_ORG+="--setalias=$SETALIAS "

    if [ -n "$DURATIONDAYS" ]
    then
        echo "${GREEN_BOLD}Duration will be $DURATIONDAYS ${NO_COLOUR}"
    else
        printf "${GREY_BOLD}Days to keep (max 30, default 7) : ${NO_COLOUR}"
        read DURATIONDAYS
    fi

    if [ -n "$DURATIONDAYS" ]
    then
        # TODO: validation for duration days between 1-30
        while ! [[ "$DURATIONDAYS" =~ ^[0-9]+$ ]]
        do
            echo "${RED_BOLD}$DURATIONDAYS ${RED}is not a valid value for Days to keep. Please try again.${NO_COLOUR}"
            printf "${GREY_BOLD}Days to keep (max 30, default 7) : ${NO_COLOUR}"
            read DURATIONDAYS
        done
        CMD_CREATE_ORG+="--durationdays=$DURATIONDAYS "
    fi

    CMD_CREATE_ORG+="--json" # output in json

    echo "${GREY_BOLD}Creating org with alias/username: ${GREEN_BOLD}$SETALIAS${NO_COLOUR}"
    echo "${GREY_BOLD}Creating Org : .. .. ..${NO_COLOUR}"
    echo "${GREY_BOLD}Command to create org : ${NO_COLOUR}$CMD_CREATE_ORG"
    
    iterator=0
    for eachValue in $($CMD_CREATE_ORG | jq -r ".status,.result.username,.name,.message")
    do
        if [ $iterator = "0" ]
        then
            STATUS=$eachValue
        else
            if [ $STATUS = "0" ]
            then
                TARGETUSERNAME=$eachValue
                break
            else
                ERROR+="$eachValue "
            fi
        fi
        iterator=$((iterator+1))
    done

    if [ $STATUS = "1" ]
    then
        errorExit $STATUS "$ERROR"
    else
        echo "${GREEN_BOLD}Org created with username ${GREEN}$TARGETUSERNAME${GREEN_BOLD} and alias ${GREEN}$SETALIAS${GREEN_BOLD} successfully.${NO_COLOUR}"
    fi
}

function assignPermissionSet(){
    echo "${GREY_BOLD}Assigning permission ${GREEN}$1${NO_COLOUR}."
    sfdx force:user:permset:assign -n $1 -u $2

    if [ "$?" = "1" ]
    then
        echo "${RED}Can't assign the permission set: ${RED_BOLD}$1${NO_COLOUR}"
    else
        echo "${GREY_BOLD}Permission set ${GREEN}$1 ${GREY_BOLD}assigned successfully.${NO_COLOUR}"
    fi
}