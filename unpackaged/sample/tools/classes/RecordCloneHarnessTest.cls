/**
 * Dev-org test, not packaged: it needs the Sample_* objects from unpackaged/sample/model.
 *
 * Seeds the same scenarios as datasets/dev, runs the clone harness, and requires that every
 * outcome is the expected one and that the harness reports no findings. That makes it a regression
 * test for RecordClone's behavior on the sample cases, and it keeps the harness itself covered.
 *
 * The harness is split into parts because one transaction allows 100 SOQL queries, so each part
 * runs in its own test method.
 */
@IsTest
private class RecordCloneHarnessTest {
  @TestSetup
  private static void seedScenarios() {
    Sample_Term__c currentTerm = new Sample_Term__c(
      Name = 'Fall 2026',
      Banner_Code__c = '202610',
      Is_Active__c = true
    );
    Sample_Term__c retiredTerm = new Sample_Term__c(
      Name = 'Fall 2025',
      Banner_Code__c = '202510',
      Is_Active__c = true
    );
    insert new List<Sample_Term__c>{ currentTerm, retiredTerm };

    Sample_Requirement__c requirement = new Sample_Requirement__c(
      Name = 'Requirement 1',
      Requirement_Code__c = 'REQ-1'
    );
    insert requirement;
    Sample_Question__c question = new Sample_Question__c(
      Name = 'Question 1',
      Question_Text__c = 'Why?'
    );
    insert question;

    Map<String, Sample_Application__c> applications = new Map<String, Sample_Application__c>();
    Integer counter = 0;
    for (
      String scenario : new List<String>{
        'Clean application with every child type',
        'Minimal application with no children',
        'Application with no term',
        'Application with awards only',
        'Application with audit trail (required unique child field)',
        'Withdrawn application with responses (armed after load)',
        'Application on a retired term (armed after load)',
        'Child record name near the 120 character limit',
        'Bulk application with 120 requirement and 120 question responses'
      }
    ) {
      counter++;
      Boolean failsOnPurpose =
        scenario.startsWith('Withdrawn') ||
        scenario.startsWith('Application on a retired') ||
        scenario.startsWith('Child record name');
      applications.put(
        scenario,
        new Sample_Application__c(
          Name = 'Applicant ' + counter,
          Term__c = scenario == 'Application with no term'
            ? null
            : scenario.startsWith('Application on a retired')
                ? retiredTerm.Id
                : currentTerm.Id,
          External_Id__c = 'BN-APP-' + counter,
          Status__c = 'Submitted',
          Applicant_Email__c = 'applicant' + counter + '@example.com',
          Expected_Outcome__c = failsOnPurpose ? 'FAIL' : 'PASS',
          Scenario__c = scenario
        )
      );
    }
    insert applications.values();

    Id cleanId = applications.get('Clean application with every child type').Id;
    Id bulkId = applications.get(
        'Bulk application with 120 requirement and 120 question responses'
      )
      .Id;
    List<Sample_Requirement_Response__c> responses = new List<Sample_Requirement_Response__c>();
    for (Id applicationId : new List<Id>{ cleanId, bulkId }) {
      for (Integer i = 0; i < 3; i++) {
        responses.add(
          new Sample_Requirement_Response__c(
            Name = 'Response ' + i,
            Application__c = applicationId,
            Requirement__c = requirement.Id,
            External_Id__c = 'BN-RR-' + applicationId + i,
            Status__c = 'Received'
          )
        );
      }
    }
    for (
      String scenario : new List<String>{
        'Withdrawn application with responses (armed after load)',
        'Application on a retired term (armed after load)',
        'Application with no term'
      }
    ) {
      responses.add(
        new Sample_Requirement_Response__c(
          Name = 'Transcript',
          Application__c = applications.get(scenario).Id,
          Requirement__c = requirement.Id,
          External_Id__c = 'BN-RR-' + scenario.left(6),
          Status__c = 'Received'
        )
      );
    }
    insert responses;

    // Each question response points at a requirement response of the same application
    List<Sample_Question_Response__c> answers = new List<Sample_Question_Response__c>();
    for (Sample_Requirement_Response__c response : responses) {
      if (
        response.Application__c == cleanId ||
        response.Application__c == bulkId
      ) {
        answers.add(
          new Sample_Question_Response__c(
            Name = 'Answer',
            Application__c = response.Application__c,
            Question__c = question.Id,
            Requirement_Response__c = response.Id,
            External_Id__c = 'BN-QR-' + response.External_Id__c
          )
        );
      }
    }
    insert answers;

    insert new List<sObject>{
      new Sample_Award__c(Application__c = cleanId, Amount__c = 100),
      new Sample_Award__c(
        Application__c = applications.get('Application with awards only').Id,
        Amount__c = 200
      ),
      new Opportunity(
        Name = 'Deposit',
        StageName = 'Prospecting',
        CloseDate = Date.today(),
        Sample_Application__c = cleanId,
        Sample_External_Id__c = 'BN-OPP-1'
      ),
      new Opportunity(
        Name = 'o'.repeat(115),
        StageName = 'Prospecting',
        CloseDate = Date.today(),
        Sample_Application__c = applications.get(
            'Child record name near the 120 character limit'
          )
          .Id,
        Sample_External_Id__c = 'BN-OPP-2'
      ),
      new Sample_Audit_Entry__c(
        Application__c = applications.get(
            'Application with audit trail (required unique child field)'
          )
          .Id,
        Entry_Key__c = 'AUD-1',
        Reviewer_Note__c = 'Checked'
      )
    };

    // Break the two scenarios that must fail, as scripts/arm_sample_clone_failures.apex does
    applications.get('Withdrawn application with responses (armed after load)')
      .Status__c = 'Withdrawn';
    update applications.get(
      'Withdrawn application with responses (armed after load)'
    );
    retiredTerm.Is_Active__c = false;
    update retiredTerm;
  }

  @IsTest
  private static void partOneSingleRecordCases() {
    assertCleanRun('part=1', 4);
  }

  @IsTest
  private static void partTwoSingleRecordCases() {
    assertCleanRun('part=2', 4);
  }

  @IsTest
  private static void partThreeSingleRecordCases() {
    assertCleanRun('part=3', 5);
  }

  @IsTest
  private static void partFourMultiRecordCases() {
    assertCleanRun('part=4', 3);
  }

  @IsTest
  private static void strictModeThrowsWhenACaseMisbehaves() {
    delete [SELECT Id FROM Sample_Application__c];
    try {
      RecordCloneHarness.run('strict,part=1');
      Assert.fail('strict mode must throw when the sample data is missing');
    } catch (RecordCloneHarness.HarnessException e) {
      Assert.isTrue(e.getMessage().contains('unexpected'), e.getMessage());
    }
  }

  private static void assertCleanRun(String options, Integer expectedMatches) {
    RecordCloneHarness.run(options);
    Assert.areEqual(
      0,
      RecordCloneHarness.mismatches.size(),
      'Unexpected outcomes: ' +
      String.join(RecordCloneHarness.mismatches, ' || ')
    );
    Assert.areEqual(expectedMatches, RecordCloneHarness.matched);
    Assert.isTrue(
      RecordCloneHarness.findingTotals.isEmpty(),
      'A clone lost data quality: ' + RecordCloneHarness.findingTotals
    );
  }
}
