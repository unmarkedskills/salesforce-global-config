#!/bin/bash


sfdx force:data:tree:export --query \
"select \
Async_Platform_Event__c, \
Name, \
External_Invocation__c,\
External_Restricted_User__c,\
Input_Creation_Class__c,\
Invocation_Type__c,\
Iteration__c,\
Log_Requests__c,\
Metadata_Invoker_Id__c,\
Method__c,\
Output_Interface_Version__c,\
Override_Default__c,\
Service_Name__c,\
Stub_Class__c,\
User_Permission__c from Service_Invocation_Override__c" \
 --prefix service-stub --outputdir safe --plan -u $1
