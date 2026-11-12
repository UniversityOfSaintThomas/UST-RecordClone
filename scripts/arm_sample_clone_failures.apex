// Arms the sample scenarios that must fail at clone time (ECRMSF-5087).
// Runs after the sample dataset loads. The rules that make these fail would also have rejected
// the rows during the load, so they are broken here instead. Safe to run more than once.
//
// 1. "Withdrawn application": the status becomes Withdrawn, so a clone's new requirement
//    responses are rejected by the No_Response_On_Withdrawn_App validation rule.
// 2. "Retired term": the term is deactivated, so a cloned application is rejected by the
//    active-term lookup filter.

List<Sample_Application__c> withdrawn = [
  SELECT Id, Status__c
  FROM Sample_Application__c
  WHERE Scenario__c = 'Withdrawn application with responses (armed after load)'
];
for (Sample_Application__c application : withdrawn) {
  application.Status__c = 'Withdrawn';
}
update withdrawn;

List<Sample_Term__c> retiredTerms = [
  SELECT Id, Is_Active__c
  FROM Sample_Term__c
  WHERE Banner_Code__c = '202510'
];
for (Sample_Term__c term : retiredTerms) {
  term.Is_Active__c = false;
}
update retiredTerms;

System.debug(
  'ARMED withdrawn=' +
  withdrawn.size() +
  ' retiredTerms=' +
  retiredTerms.size()
);
