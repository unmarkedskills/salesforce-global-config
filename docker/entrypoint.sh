#!/bin/bash
# add bash files from config repo
set -e # exit on error
source "$SCRIPTS_PATH/scripts/ci/entry.sh" # get scripts
OPERATION=$1
init