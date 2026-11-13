/*
 * Copyright (c) 2020, salesforce.com, inc.
 * All rights reserved.
 * SPDX-License-Identifier: BSD-3-Clause
 * For full license text, see LICENSE.txt file in the repo root or https://opensource.org/licenses/BSD-3-Clause
 */
@IsTest
private class sObjectSummaryTest {
  @IsTest
  private static void simpleConstructor() {
    sObjectSummary accObj = new sObjectSummary(
      Account.sObjectType.getDescribe(SObjectDescribeOptions.DEFERRED)
    );
    System.assertEquals(accObj.apiName, 'Account');

    sObjectSummary caseObj = new sObjectSummary(
      Case.sObjectType.getDescribe(SObjectDescribeOptions.DEFERRED)
    );
    System.assertEquals(caseObj.apiName, 'Case');

    sObjectSummary oliObj = new sObjectSummary(
      OpportunityLineItem.sObjectType.getDescribe(
        SObjectDescribeOptions.DEFERRED
      )
    );
    System.assertEquals(oliObj.apiName, 'OpportunityLineItem');
  }

  @IsTest
  private static void withExcludedField() {
    String accExcluded = 'Phone';
    sObjectSummary accObj = new sObjectSummary(
      Account.sObjectType.getDescribe(SObjectDescribeOptions.DEFERRED),
      accExcluded
    );
    for (sObjectSummary.sFieldSummary fs : accObj.fields) {
      if (stringToList(accExcluded).contains(fs.apiName)) {
        System.assertEquals(fs.isClonable, false);
      }
    }

    String caseExcluded = 'BusinessHoursId, Description';
    sObjectSummary caseObj = new sObjectSummary(
      Case.sObjectType.getDescribe(SObjectDescribeOptions.DEFERRED),
      caseExcluded
    );
    for (sObjectSummary.sFieldSummary fs : caseObj.fields) {
      if (stringToList(caseExcluded).contains(fs.apiName)) {
        System.assertEquals(fs.isClonable, false);
      }
    }

    String oliExcluded = 'Discount, Description';
    sObjectSummary oliObj = new sObjectSummary(
      OpportunityLineItem.sObjectType.getDescribe(
        SObjectDescribeOptions.DEFERRED
      ),
      oliExcluded
    );
    for (sObjectSummary.sFieldSummary fs : oliObj.fields) {
      if (stringToList(oliExcluded).contains(fs.apiName)) {
        System.assertEquals(fs.isClonable, false);
      }
    }
  }

  @IsTest
  private static void notSupportedObj() {
    sObjectSummary taskObj = new sObjectSummary(
      Task.sObjectType.getDescribe(SObjectDescribeOptions.DEFERRED)
    );
    System.assertEquals(taskObj.isClonable, false);

    sObjectSummary eventObj = new sObjectSummary(
      Event.sObjectType.getDescribe(SObjectDescribeOptions.DEFERRED)
    );
    System.assertEquals(eventObj.isClonable, false);

    sObjectSummary attachmentObj = new sObjectSummary(
      Attachment.sObjectType.getDescribe(SObjectDescribeOptions.DEFERRED)
    );
    System.assertEquals(attachmentObj.isClonable, false);

    sObjectSummary docObj = new sObjectSummary(
      Document.sObjectType.getDescribe(SObjectDescribeOptions.DEFERRED)
    );
    System.assertEquals(docObj.isClonable, false);

    sObjectSummary cdlObj = new sObjectSummary(
      ContentDocumentLink.sObjectType.getDescribe(
        SObjectDescribeOptions.DEFERRED
      )
    );
    System.assertEquals(cdlObj.isClonable, false);

    sObjectSummary cdObj = new sObjectSummary(
      ContentDocument.sObjectType.getDescribe(SObjectDescribeOptions.DEFERRED)
    );
    System.assertEquals(cdObj.isClonable, false);
  }

  @IsTest
  private static void everyUnsupportedObjectReportsItsOwnReason() {
    // The reason code is what the interface turns into a sentence, so each object must keep its own.
    Map<String, String> expectedReason = new Map<String, String>{
      'Task' => 'IS_TASK',
      'Event' => 'IS_EVENT',
      'Attachment' => 'IS_ATTACHMENT',
      'Document' => 'IS_DOCUMENT',
      'QuoteDocument' => 'IS_QUOTE_DOCUMENT',
      'ContentDocumentLink' => 'IS_CONTENT_DOCUMENT_LINK',
      'Partner' => 'IS_PARTNER',
      'AccountPartner' => 'IS_ACCOUNT_PARTNER',
      'OpportunityPartner' => 'IS_OPPORTUNITY_PARTNER',
      'AccountShare' => 'IS_SHARE_OBJECT',
      'NetworkUserHistoryRecent' => 'IS_COMMUNITY_RELATED_RESTRICTION'
    };

    Map<String, Schema.SObjectType> objectTypes = Schema.getGlobalDescribe();
    Integer checked = 0;
    for (String objectName : expectedReason.keySet()) {
      Schema.SObjectType objectType = objectTypes.get(objectName);
      if (objectType == null) {
        // not every org has every object, for example quotes may be switched off
        continue;
      }
      sObjectSummary summary = new sObjectSummary(
        objectType.getDescribe(SObjectDescribeOptions.DEFERRED)
      );
      Assert.isFalse(
        summary.isClonable,
        objectName + ' should not be clonable'
      );
      Assert.isTrue(
        new Set<String>(summary.errorMessage.split(','))
          .contains(expectedReason.get(objectName)),
        objectName +
        ' should report ' +
        expectedReason.get(objectName) +
        ' but reported: ' +
        summary.errorMessage
      );
      checked++;
    }
    Assert.isTrue(
      checked >= 8,
      'Only ' +
      checked +
      ' objects could be checked'
    );
  }

  @IsTest
  private static void personAccountCheckMatchesWhatTheOrgSupports() {
    Account business = new Account(Name = 'Business Account');
    insert business;

    if (sObjectSummary.hasPersonAccounts()) {
      Assert.areEqual(
        false,
        sObjectSummary.isPersonAccount(business.Id),
        'A business account is not a person account'
      );
      Assert.areEqual(
        'Name',
        sObjectSummary.getByRecordId(business.Id).nameField,
        'A business account is named by Name'
      );
    } else {
      // Without person accounts there is no IsPersonAccount field to ask about. The answer is
      // "unknown", and the summary still has to be built from the ordinary name field.
      Assert.isNull(sObjectSummary.isPersonAccount(business.Id));
      Assert.areEqual(
        'Name',
        sObjectSummary.getByRecordId(business.Id).nameField
      );
    }
    Assert.isNull(
      sObjectSummary.getByRecordId(null),
      'No record Id gives no summary'
    );
  }

  @IsTest
  private static void personAccountsAreNamedByLastNameAndBusinessAccountsByName() {
    // Person accounts cannot be switched on here, so the choice is tested on its own.
    Assert.areEqual('LastName', sObjectSummary.nameFieldOfAccount(true));
    Assert.areEqual('Name', sObjectSummary.nameFieldOfAccount(false));
  }

  @IsTest
  private static void aSupportedObjectReportsNoReason() {
    sObjectSummary summary = new sObjectSummary(
      Account.sObjectType.getDescribe(SObjectDescribeOptions.DEFERRED)
    );
    Assert.isTrue(summary.isClonable);
    Assert.areEqual('', summary.errorMessage);
  }

  @IsTest
  private static void exceptionalFields() {
    sObjectSummary caseObj = new sObjectSummary(
      Case.sObjectType.getDescribe(SObjectDescribeOptions.DEFERRED)
    );
    for (sObjectSummary.sFieldSummary fs : caseObj.fields) {
      if (fs.apiName == 'ClosedDate') {
        System.assertEquals(fs.isClonable, false);
      }
    }

    sObjectSummary oliObj = new sObjectSummary(
      OpportunityLineItem.sObjectType.getDescribe(
        SObjectDescribeOptions.DEFERRED
      )
    );
    for (sObjectSummary.sFieldSummary fs : oliObj.fields) {
      if (fs.apiName == 'TotalPrice') {
        System.assertEquals(fs.isClonable, false);
      }
    }
  }

  @IsTest
  private static void testFilterClonableFields() {
    String accExcluded = 'Phone, Email';
    sObjectSummary accObj = new sObjectSummary(
      Account.sObjectType.getDescribe(SObjectDescribeOptions.DEFERRED),
      accExcluded
    );

    List<String> accClonableFields = accObj.filterClonableFields();
    for (String accExcludedField : stringToList(accExcluded)) {
      System.assertEquals(accClonableFields.contains(accExcludedField), false);
    }
  }

  @IsTest
  private static void testGetByRecordId() {
    Account acc = new Account(Name = 'Hello', Phone = '0123456789');
    insert acc;

    Contact con = new Contact(LastName = 'Test', AccountId = acc.Id);
    insert con;

    Opportunity opp1 = new Opportunity(
      Name = 'Test Opp 1',
      AccountId = acc.Id,
      StageName = 'First Step',
      CloseDate = Date.today()
    );
    insert opp1;

    Opportunity opp2 = new Opportunity(
      Name = 'Test Opp 2',
      AccountId = acc.Id,
      StageName = 'First Step',
      CloseDate = Date.today()
    );
    insert opp2;

    String fieldsExcluded = 'Stage, Phone, Email ';
    String childrenIncluded = 'Contacts, Opportunities';
    String childrenIncludedApiNames = 'Contact, Opportunity';
    sObjectSummary accById = sObjectSummary.getByRecordId(acc.Id);
    sObjectSummary accWithChildren = sObjectSummary.getByRecordId(
      acc.Id,
      childrenIncluded,
      fieldsExcluded
    );

    System.assertEquals(accById.apiName, 'Account');
    System.assertEquals(accById.isClonable, true);
    System.assertEquals(accById.isNamable, true);
    System.assertEquals(accById.children, null);
    System.assertNotEquals(accById.fields.size(), 0);

    System.assertEquals(accWithChildren.apiName, 'Account');
    System.assertEquals(accWithChildren.isClonable, true);
    System.assertEquals(accWithChildren.isNamable, true);
    System.assertEquals(accWithChildren.children.size(), 2);
    System.assertNotEquals(accWithChildren.fields.size(), 0);

    List<String> clonableFields = accWithChildren.filterClonableFields();
    for (String excludedField : stringToList(fieldsExcluded)) {
      System.assertEquals(clonableFields.contains(excludedField), false);
    }

    for (String child : stringToList(childrenIncluded)) {
      sObjectSummary childSummary = accWithChildren.children.get(child);
      System.assertEquals(
        stringToList(childrenIncludedApiNames).contains(childSummary.apiName),
        true
      );
    }
  }

  @IsTest
  private static void testChildNameFormatComesFromTheSettingsRecord() {
    // The packaged SampleOpportunityCloneSettings record asks for "Cloned - name - date" on children.
    Account acc = new Account(Name = 'Format Account');
    insert acc;
    Opportunity opp = new Opportunity(
      Name = 'Format Opp',
      AccountId = acc.Id,
      StageName = 'First Step',
      CloseDate = Date.today()
    );
    insert opp;

    sObjectSummary withSettings = sObjectSummary.getByRecordId(opp.Id);
    Assert.areEqual(
      RecordCloneChildRecordNamePicklist.valueWithClonedAndDate,
      withSettings.childRecordNameFormat,
      'The format stored on the settings record must be used'
    );

    Case noSettings = new Case(Subject = 'No settings for Case');
    insert noSettings;
    Assert.areEqual(
      RecordCloneChildRecordNamePicklist.valueOriginalName,
      sObjectSummary.getByRecordId(noSettings.Id).childRecordNameFormat,
      'Without a settings record the original name is kept'
    );
  }

  private static List<String> stringToList(String commaSeparatedString) {
    List<String> splitted = commaSeparatedString.split(',');
    for (Integer i = 0; i < splitted.size(); i++) {
      splitted[i] = splitted[i].trim();
    }
    return splitted;
  }

  private static String listToString(List<String> stringList) {
    return String.join(stringList, ',');
  }
}
