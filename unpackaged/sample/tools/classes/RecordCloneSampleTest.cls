/**
 * Dev-org test, not packaged: it needs the Sample_* objects from unpackaged/sample/model.
 * Proves RecordClone leaves external ID fields blank on a clone (ECRMSF-5087).
 */
@IsTest
private class RecordCloneSampleTest {
  @IsTest
  private static void externalIdFieldsAreNotClonable() {
    sObjectSummary application = new sObjectSummary(
      Sample_Application__c.sObjectType.getDescribe()
    );
    sObjectSummary.sFieldSummary externalId = field(
      application,
      'External_Id__c'
    );
    Assert.isFalse(externalId.isClonable, 'External ID must not be cloned');
    Assert.isTrue(
      externalId.errorMessage.contains('IS_EXTERNAL_ID'),
      'Reason should say why: ' + externalId.errorMessage
    );
    Assert.isTrue(
      field(application, 'Applicant_Email__c').isClonable,
      'Ordinary fields stay clonable'
    );

    sObjectSummary opportunity = new sObjectSummary(
      Opportunity.sObjectType.getDescribe()
    );
    Assert.isFalse(
      field(opportunity, 'Sample_External_Id__c').isClonable,
      'External ID on a standard object must not be cloned either'
    );
  }

  @IsTest
  private static void cloneLeavesExternalIdsBlankAndKeepsOtherData() {
    Sample_Application__c original = new Sample_Application__c(
      Name = 'Original Applicant',
      External_Id__c = 'BN-TEST-1',
      Applicant_Email__c = 'applicant@example.com',
      Status__c = 'Submitted'
    );
    insert original;
    Sample_Requirement_Response__c response = new Sample_Requirement_Response__c(
      Name = 'Transcript',
      Application__c = original.Id,
      External_Id__c = 'BN-TEST-RR-1',
      Status__c = 'Received'
    );
    insert response;

    sObjectSummary summary = sObjectSummary.getByRecordId(
      original.Id,
      'Requirement_Responses__r',
      ''
    );
    sObject clonedRecord = RecordCloneHandler.cloneRecord(
      RecordCloneHandler.getOriginalRecord(original.Id, summary),
      summary,
      'Cloned Applicant',
      RecordCloneChildRecordNamePicklist.valueOriginalName
    );

    Sample_Application__c clone = [
      SELECT Name, External_Id__c, Applicant_Email__c, Status__c
      FROM Sample_Application__c
      WHERE Id = :clonedRecord.Id
    ];
    Assert.isNull(
      clone.External_Id__c,
      'Parent external ID must be blank on the clone'
    );
    Assert.areEqual('applicant@example.com', clone.Applicant_Email__c);
    Assert.areEqual('Submitted', clone.Status__c);

    Sample_Requirement_Response__c clonedResponse = [
      SELECT External_Id__c, Status__c
      FROM Sample_Requirement_Response__c
      WHERE Application__c = :clonedRecord.Id
    ];
    Assert.isNull(
      clonedResponse.External_Id__c,
      'Child external ID must be blank on the clone'
    );
    Assert.areEqual('Received', clonedResponse.Status__c);

    Assert.areEqual(
      'BN-TEST-1',
      [SELECT External_Id__c FROM Sample_Application__c WHERE Id = :original.Id]
      .External_Id__c,
      'The original must keep its external ID'
    );
  }

  private static sObjectSummary.sFieldSummary field(
    sObjectSummary summary,
    String apiName
  ) {
    for (sObjectSummary.sFieldSummary candidate : summary.fields) {
      if (candidate.apiName == apiName) {
        return candidate;
      }
    }
    Assert.fail(
      'Field not found in summary (is Sample Data Access assigned?): ' + apiName
    );
    return null;
  }
}
