---
tags: [CustomerManagement, CustomerAPU]
---


# History 
18-12-2020 | Craig B
- removed the state and country refdata endpoint
- changed address items to line1,line2
- emailOptin moved to Contact
- currency is reserved in SF - now currencyCode
- global-id now globalId

06-01-2020 | Craig B
- Account and Contact include the id object
- PUT On customer-account now includes the product (for opportunity matching)

11-01-2020 | Craig B
- Updated the Contact docs and response type 

20-01-2020 | Craig B
- Account, ExistingAccount and Contact,ExistinContact added so we can suppor mandatory id in PUT/GET requests
- GET now only needs an id (not a type)

02-02-2021 | Craig
- Added /v2/opportunity{id}/stage-and-product
- removed client Id
- products are mandatory

03-02-2021 | Craig
- products is a list on v2 opp stage

11-02-2021 | Craig
- Opportunityid changed to ref ObjectId Type

05-03-2021 | Craig
- added vatNumber to account

10-05-2021 | Craig
- Account : added salesOffice + billingAccountId (still V1 - non breaking change)
- Address : added countryCode
- GetCustomerAccountResponse and GET:customer-account updated for Client Management
- optional GET parameter - email - to filter the contacts returned

# Notes 
The customer api (customer management) v1 is geared around crating account & contacts for digital
- /customer-account is a hybrid endpoint as it creates 
    : Account
    : Contact (if supplied)
    : Opportunity

As we are trying to implement a different ID (global-id) to share around the enterprise, what you get back to your request
is a scoped id (scope being account, contact, opportunity) and the identifiers the record is then known by in SF. 
This will always inclide the guid (internal salesforce recordid) and a global-id if it is supported.

The intention being that overtime systems will only need the global-id and not the internal guid



