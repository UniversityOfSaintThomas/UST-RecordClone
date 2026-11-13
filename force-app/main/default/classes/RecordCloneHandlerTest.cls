/*
 * Copyright (c) 2020, salesforce.com, inc.
 * All rights reserved.
 * SPDX-License-Identifier: BSD-3-Clause
 * For full license text, see LICENSE.txt file in the repo root or https://opensource.org/licenses/BSD-3-Clause
 */
@IsTest
private class RecordCloneHandlerTest {
  @IsTest
  private static void testGetOriginalRecord() {
    Account acc = new Account(Name = 'TestAccount');
    Contact con = new Contact(LastName = 'TestContact');
    insert acc;
    insert con;

    sObjectSummary accSummary = new sObjectSummary(
      Account.sObjectType.getDescribe(SObjectDescribeOptions.DEFERRED)
    );

    sObject withNullRecordId = RecordCloneHandler.getOriginalRecord(
      null,
      accSummary
    );
    System.assertEquals(withNullRecordId, null);
    sObject withInvalidRecordId = RecordCloneHandler.getOriginalRecord(
      con.Id,
      accSummary
    );
    System.assertEquals(withInvalidRecordId, null);
    sObject withNullSummary = RecordCloneHandler.getOriginalRecord(
      acc.Id,
      null
    );
    System.assertEquals(withNullSummary, null);
    sObject withCorrectRecordId = RecordCloneHandler.getOriginalRecord(
      acc.Id,
      accSummary
    );
    System.assertNotEquals(withCorrectRecordId, null);
  }

  @IsTest
  private static void testGetOriginalRecords() {
    List<Account> accs = new List<Account>();
    accs.add(new Account(Name = 'TestAccount1'));
    accs.add(new Account(Name = 'TestAccount2'));
    List<Contact> cons = new List<Contact>();
    cons.add(new Contact(LastName = 'TestContact1'));
    cons.add(new Contact(LastName = 'TestContact2'));
    insert accs;
    insert cons;

    List<Id> accIds = new List<Id>(new Map<Id, Account>(accs).keySet());
    List<Id> conIds = new List<Id>(new Map<Id, Contact>(cons).keySet());

    sObjectSummary accSummary = new sObjectSummary(
      Account.sObjectType.getDescribe(SObjectDescribeOptions.DEFERRED)
    );

    List<sObject> withNullRecordIds = RecordCloneHandler.getOriginalRecords(
      null,
      accSummary
    );
    System.assertEquals(withNullRecordIds, null);
    List<sObject> withEmptyRecordIds = RecordCloneHandler.getOriginalRecords(
      new List<Id>(),
      accSummary
    );
    System.assertEquals(withEmptyRecordIds, null);
    List<sObject> withInvalidRecordIds = RecordCloneHandler.getOriginalRecords(
      conIds,
      accSummary
    );
    System.assertNotEquals(withInvalidRecordIds, null);
    System.assertEquals(withInvalidRecordIds.size(), 0);
    List<sObject> withNullSummary = RecordCloneHandler.getOriginalRecords(
      accIds,
      null
    );
    System.assertEquals(withNullSummary, null);
    List<sObject> withCorrectRecordId = RecordCloneHandler.getOriginalRecords(
      accIds,
      accSummary
    );
    System.assertNotEquals(withCorrectRecordId, null);
    System.assertEquals(withCorrectRecordId.size(), accIds.size());
  }

  @IsTest
  private static void testCloneRecord() {
    String newRecordName = 'New Record Name';

    Account acc = new Account(Name = 'TestAccount');
    insert acc;
    Contact con = new Contact(LastName = 'TestContact', AccountId = acc.Id);
    insert con;

    Opportunity opp = new Opportunity(
      Name = 'Test Opp',
      StageName = 'Test Stage Name',
      CloseDate = Date.today(),
      AccountId = acc.Id
    );
    insert opp;

    OpportunityContactRole ocr = new OpportunityContactRole(
      ContactId = con.Id,
      OpportunityId = opp.Id,
      IsPrimary = true,
      Role = 'TestRole'
    );
    insert ocr;

    sObjectSummary accSummary1 = new sObjectSummary(
      Account.sObjectType.getDescribe(SObjectDescribeOptions.DEFERRED)
    );

    sObjectSummary oppSummary1 = sObjectSummary.getByRecordId(
      opp.Id,
      'OpportunityContactRoles',
      'StageName'
    );

    // no child, no excluded
    sObject cloned1 = RecordCloneHandler.cloneRecord(
      acc,
      accSummary1,
      newRecordName,
      RecordCloneChildRecordNamePicklist.valueWithClonedAndDate
    );
    System.assertNotEquals(cloned1.Id, null);

    // with children and excluded fields
    sObjectSummary accSummary2 = sObjectSummary.getByRecordId(
      acc.Id,
      'Contacts',
      'excludedFieldNames'
    );
    sObject cloned2 = RecordCloneHandler.cloneRecord(
      acc,
      accSummary2,
      newRecordName,
      RecordCloneChildRecordNamePicklist.valueWithCloned
    );
    System.assertNotEquals(cloned2.Id, null);

    // not namable
    accSummary1.isNamable = false;
    sObject notNamable = RecordCloneHandler.cloneRecord(
      acc,
      accSummary1,
      null,
      RecordCloneChildRecordNamePicklist.valueWithClonedAndDate
    );
    System.assertNotEquals(notNamable.Id, null);

    // with opp and auto created opp contact role
    sObject oppCloned = RecordCloneHandler.cloneRecord(
      opp,
      oppSummary1,
      newRecordName,
      RecordCloneChildRecordNamePicklist.valueOriginalName
    );
    System.assertNotEquals(oppCloned.Id, null);
  }

  @IsTest
  private static void testCloneRecordThrowsOnParentFailure() {
    Account acc = new Account(Name = 'TestAccount');
    insert acc;
    sObjectSummary accSummary = new sObjectSummary(
      Account.sObjectType.getDescribe(SObjectDescribeOptions.DEFERRED)
    );

    String thrownMessage;
    try {
      RecordCloneHandler.cloneRecord(
        acc,
        accSummary,
        'x'.repeat(300),
        RecordCloneChildRecordNamePicklist.valueOriginalName
      );
    } catch (RecordCloneHandler.RecordCloneException e) {
      thrownMessage = e.getMessage();
    }

    Assert.isNotNull(thrownMessage, 'Expected a RecordCloneException');
    Assert.isTrue(thrownMessage.contains('STRING_TOO_LONG'), thrownMessage);
    Assert.isTrue(thrownMessage.contains('Account'), thrownMessage);
  }

  @IsTest
  private static void testCloneRecordsThrowsOnChildFailure() {
    // Flow / invocable path: children are inserted together after the parents
    Account acc = new Account(Name = 'TestAccount');
    insert acc;
    insert new Opportunity(
      Name = 'o'.repeat(115),
      StageName = 'Prospecting',
      CloseDate = Date.today(),
      AccountId = acc.Id
    );

    sObjectSummary accSummary = sObjectSummary.getByRecordId(
      acc.Id,
      'Opportunities',
      ''
    );
    accSummary.childRecordNameFormat = RecordCloneChildRecordNamePicklist.valueWithClonedAndDate;
    List<sObject> originals = RecordCloneHandler.getOriginalRecords(
      new List<Id>{ acc.Id },
      accSummary
    );

    String thrownMessage;
    try {
      RecordCloneHandler.cloneRecords(originals, accSummary);
    } catch (RecordCloneHandler.RecordCloneException e) {
      thrownMessage = e.getMessage();
    }

    Assert.isNotNull(thrownMessage, 'Expected a RecordCloneException');
    Assert.isTrue(thrownMessage.contains('STRING_TOO_LONG'), thrownMessage);
  }

  @IsTest
  private static void testCloneRecordRemapsSiblingReferences() {
    // Contact.ReportsToId points at another contact. When both contacts are cloned, the cloned
    // report must point at the cloned boss, not at the original boss.
    Account acc = new Account(Name = 'Sibling Account');
    insert acc;
    Account other = new Account(Name = 'Other Account');
    insert other;
    Contact outsider = new Contact(LastName = 'Outsider', AccountId = other.Id);
    insert outsider;
    Contact boss = new Contact(
      LastName = 'Boss',
      AccountId = acc.Id,
      ReportsToId = outsider.Id
    );
    insert boss;
    Contact report = new Contact(
      LastName = 'Report',
      AccountId = acc.Id,
      ReportsToId = boss.Id
    );
    insert report;

    sObjectSummary summary = sObjectSummary.getByRecordId(
      acc.Id,
      'Contacts',
      ''
    );
    sObject clonedAccount = RecordCloneHandler.cloneRecord(
      RecordCloneHandler.getOriginalRecord(acc.Id, summary),
      summary,
      'Cloned Account',
      RecordCloneChildRecordNamePicklist.valueOriginalName
    );

    Map<String, Contact> clonedByName = new Map<String, Contact>();
    for (Contact c : [
      SELECT LastName, ReportsToId
      FROM Contact
      WHERE AccountId = :clonedAccount.Id
    ]) {
      clonedByName.put(c.LastName, c);
    }
    Assert.areEqual(2, clonedByName.size());
    Assert.areNotEqual(
      boss.Id,
      clonedByName.get('Report').ReportsToId,
      'Cloned report must not point at the original boss'
    );
    Assert.areEqual(
      clonedByName.get('Boss').Id,
      clonedByName.get('Report').ReportsToId,
      'Cloned report must point at the cloned boss'
    );
    Assert.areEqual(
      outsider.Id,
      clonedByName.get('Boss').ReportsToId,
      'A lookup to a record outside the clone must stay as it was'
    );
    Assert.areEqual(
      boss.Id,
      [SELECT ReportsToId FROM Contact WHERE Id = :report.Id]
      .ReportsToId,
      'The original must not change'
    );
  }

  @IsTest
  private static void testCloneRecordsRemapsSiblingReferencesPerParent() {
    // Two accounts in one multi-record clone. Each cloned report must point at the cloned boss of
    // its own account, never at the other account's boss.
    List<Account> accounts = new List<Account>{
      new Account(Name = 'First'),
      new Account(Name = 'Second')
    };
    insert accounts;
    List<Contact> bosses = new List<Contact>();
    for (Account a : accounts) {
      bosses.add(new Contact(LastName = 'Boss ' + a.Name, AccountId = a.Id));
    }
    insert bosses;
    List<Contact> reports = new List<Contact>();
    for (Integer i = 0; i < accounts.size(); i++) {
      reports.add(
        new Contact(
          LastName = 'Report ' + accounts[i].Name,
          AccountId = accounts[i].Id,
          ReportsToId = bosses[i].Id
        )
      );
    }
    insert reports;

    sObjectSummary summary = sObjectSummary.getByRecordId(
      accounts[0].Id,
      'Contacts',
      ''
    );
    List<sObject> originals = RecordCloneHandler.getOriginalRecords(
      new List<Id>{ accounts[0].Id, accounts[1].Id },
      summary
    );
    List<sObject> clonedAccounts = RecordCloneHandler.cloneRecords(
      originals,
      summary
    );

    Set<Id> clonedAccountIds = new Map<Id, sObject>(clonedAccounts).keySet();
    Map<Id, Contact> contactsById = new Map<Id, Contact>(
      [
        SELECT LastName, AccountId, ReportsToId
        FROM Contact
        WHERE AccountId IN :clonedAccountIds
      ]
    );
    Assert.areEqual(4, contactsById.size());
    Integer checkedReports = 0;
    for (Contact c : contactsById.values()) {
      if (!c.LastName.startsWith('Report')) {
        continue;
      }
      Contact boss = contactsById.get(c.ReportsToId);
      Assert.isNotNull(boss, 'Cloned report must point at a cloned contact');
      Assert.areEqual(
        c.AccountId,
        boss.AccountId,
        'Boss must be in the same cloned account'
      );
      Assert.isTrue(boss.LastName.startsWith('Boss'));
      checkedReports++;
    }
    Assert.areEqual(2, checkedReports);
  }

  @IsTest
  private static void testCloneRecords() {
    Account acc = new Account(Name = 'TestAccount');
    insert acc;
    Account acc2 = new Account(Name = 'TestAccount2');
    insert acc2;
    Contact con = new Contact(LastName = 'TestContact', AccountId = acc.Id);
    insert con;

    Opportunity opp = new Opportunity(
      Name = 'Test Opp',
      StageName = 'Test Stage Name',
      CloseDate = Date.today(),
      AccountId = acc.Id
    );
    insert opp;

    OpportunityContactRole ocr = new OpportunityContactRole(
      ContactId = con.Id,
      OpportunityId = opp.Id,
      IsPrimary = true,
      Role = 'TestRole'
    );
    insert ocr;

    sObjectSummary accSummary1 = new sObjectSummary(
      Account.sObjectType.getDescribe(SObjectDescribeOptions.DEFERRED)
    );

    List<sObject> originals = new List<SObject>();
    originals.add(acc);
    originals.add(acc2);

    List<sObject> clones = RecordCloneHandler.cloneRecords(
      originals,
      accSummary1
    );
    System.assertNotEquals(clones, null);
    System.assertEquals(clones.size(), 2);
  }
}
