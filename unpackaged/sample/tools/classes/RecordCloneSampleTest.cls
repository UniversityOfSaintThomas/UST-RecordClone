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

  @IsTest
  private static void siblingLookupsFollowTheCloneWhateverTheConfiguredOrder() {
    Sample_Requirement__c requirement = new Sample_Requirement__c(Name = 'Req');
    Sample_Question__c question = new Sample_Question__c(Name = 'Question');
    insert requirement;
    insert question;
    Sample_Application__c original = new Sample_Application__c(
      Name = 'Applicant'
    );
    insert original;
    List<Sample_Requirement_Response__c> responses = new List<Sample_Requirement_Response__c>{
      new Sample_Requirement_Response__c(
        Name = 'First',
        Application__c = original.Id,
        Requirement__c = requirement.Id
      ),
      new Sample_Requirement_Response__c(
        Name = 'Second',
        Application__c = original.Id,
        Requirement__c = requirement.Id
      )
    };
    insert responses;
    insert new List<Sample_Question_Response__c>{
      new Sample_Question_Response__c(
        Name = 'About first',
        Application__c = original.Id,
        Question__c = question.Id,
        Requirement_Response__c = responses[0].Id
      ),
      new Sample_Question_Response__c(
        Name = 'About second',
        Application__c = original.Id,
        Question__c = question.Id,
        Requirement_Response__c = responses[1].Id
      )
    };

    // Question responses are listed BEFORE the requirement responses they depend on
    sObjectSummary summary = sObjectSummary.getByRecordId(
      original.Id,
      'Question_Responses__r,Requirement_Responses__r',
      ''
    );
    sObject cloned = RecordCloneHandler.cloneRecord(
      RecordCloneHandler.getOriginalRecord(original.Id, summary),
      summary,
      'Cloned Applicant',
      RecordCloneChildRecordNamePicklist.valueOriginalName
    );

    List<Sample_Question_Response__c> clonedAnswers = [
      SELECT
        Name,
        Question__c,
        Requirement_Response__c,
        Requirement_Response__r.Application__c,
        Requirement_Response__r.Name
      FROM Sample_Question_Response__c
      WHERE Application__c = :cloned.Id
      ORDER BY Name
    ];
    Assert.areEqual(2, clonedAnswers.size());
    for (Sample_Question_Response__c answer : clonedAnswers) {
      Assert.areEqual(
        cloned.Id,
        answer.Requirement_Response__r.Application__c,
        'Must point at a cloned requirement response, not the original'
      );
      Assert.areEqual(
        question.Id,
        answer.Question__c,
        'A shared lookup stays as it was'
      );
    }
    Assert.areEqual('First', clonedAnswers[0].Requirement_Response__r.Name);
    Assert.areEqual('Second', clonedAnswers[1].Requirement_Response__r.Name);
  }

  @IsTest
  private static void childWithARequiredFieldTheCloneMustDropIsNotClonable() {
    Sample_Application__c original = new Sample_Application__c(
      Name = 'Applicant'
    );
    insert original;
    insert new Sample_Audit_Entry__c(
      Application__c = original.Id,
      Entry_Key__c = 'KEY-1',
      Reviewer_Note__c = 'Checked'
    );

    sObjectSummary summary = sObjectSummary.getByRecordId(
      original.Id,
      'Audit_Entries__r',
      ''
    );
    sObjectSummary audit = summary.children.get('Audit_Entries__r');
    Assert.isFalse(audit.isClonable);
    Assert.isTrue(
      audit.errorMessage.contains('REQUIRED_FIELD_NOT_CLONABLE(Entry_Key__c)'),
      'Reason should name the field: ' + audit.errorMessage
    );

    // The clone goes ahead without that child, instead of failing
    sObject cloned = RecordCloneHandler.cloneRecord(
      RecordCloneHandler.getOriginalRecord(original.Id, summary),
      summary,
      'Cloned Applicant',
      RecordCloneChildRecordNamePicklist.valueOriginalName
    );
    Assert.areEqual(
      0,
      [
        SELECT COUNT()
        FROM Sample_Audit_Entry__c
        WHERE Application__c = :cloned.Id
      ]
    );
    Assert.areEqual(
      1,
      [
        SELECT COUNT()
        FROM Sample_Audit_Entry__c
        WHERE Application__c = :original.Id
      ]
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
