/*
 * Copyright (c) 2020, salesforce.com, inc.
 * All rights reserved.
 * SPDX-License-Identifier: BSD-3-Clause
 * For full license text, see LICENSE.txt file in the repo root or https://opensource.org/licenses/BSD-3-Clause
 */
@IsTest
private class RecordCloneHandlerTest {
  private static final Pattern datedPrefix = Pattern.compile(
    '^Cloned - (.+) - \\d{4}/\\d{2}/\\d{2} \\d{2}:\\d{2}$'
  );

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

  // ---- naming and large child lists, pinned before the child handling was shared ----

  /**
   * Builds an account with two opportunities, and the summary that clones the opportunities with it.
   *
   * @return The queried original account and its summary
   */
  private static List<Object> accountWithOpportunities() {
    Account acc = new Account(Name = 'Original Account');
    insert acc;
    insert new List<Opportunity>{
      new Opportunity(
        Name = 'Opp One',
        StageName = 'Prospecting',
        CloseDate = Date.today(),
        AccountId = acc.Id
      ),
      new Opportunity(
        Name = 'Opp Two',
        StageName = 'Prospecting',
        CloseDate = Date.today(),
        AccountId = acc.Id
      )
    };
    sObjectSummary summary = sObjectSummary.getByRecordId(
      acc.Id,
      'Opportunities',
      ''
    );
    return new List<Object>{
      RecordCloneHandler.getOriginalRecord(acc.Id, summary),
      summary
    };
  }

  private static List<String> opportunityNames(Id accountId) {
    List<String> names = new List<String>();
    for (Opportunity opp : [
      SELECT Name
      FROM Opportunity
      WHERE AccountId = :accountId
      ORDER BY Name
    ]) {
      names.add(opp.Name);
    }
    return names;
  }

  @IsTest
  private static void singleRecordKeepsTheOriginalChildNames() {
    List<Object> built = accountWithOpportunities();
    sObject cloned = RecordCloneHandler.cloneRecord(
      (sObject) built[0],
      (sObjectSummary) built[1],
      'New Account',
      RecordCloneChildRecordNamePicklist.valueOriginalName
    );
    Assert.areEqual(
      new List<String>{ 'Opp One', 'Opp Two' },
      opportunityNames(cloned.Id)
    );
    Assert.areEqual(
      'New Account',
      [SELECT Name FROM Account WHERE Id = :cloned.Id]
      .Name
    );
  }

  @IsTest
  private static void singleRecordPrefixesChildNamesWhenAsked() {
    List<Object> built = accountWithOpportunities();
    sObject cloned = RecordCloneHandler.cloneRecord(
      (sObject) built[0],
      (sObjectSummary) built[1],
      'New Account',
      RecordCloneChildRecordNamePicklist.valueWithCloned
    );
    Assert.areEqual(
      new List<String>{ 'Cloned - Opp One', 'Cloned - Opp Two' },
      opportunityNames(cloned.Id)
    );
  }

  @IsTest
  private static void singleRecordAddsThePrefixAndADateWhenAsked() {
    List<Object> built = accountWithOpportunities();
    sObject cloned = RecordCloneHandler.cloneRecord(
      (sObject) built[0],
      (sObjectSummary) built[1],
      'New Account',
      RecordCloneChildRecordNamePicklist.valueWithClonedAndDate
    );
    List<String> names = opportunityNames(cloned.Id);
    Assert.areEqual(2, names.size());
    Set<String> originals = new Set<String>();
    for (String name : names) {
      Matcher found = datedPrefix.matcher(name);
      Assert.isTrue(found.matches(), 'Unexpected child name: ' + name);
      originals.add(found.group(1));
    }
    Assert.areEqual(new Set<String>{ 'Opp One', 'Opp Two' }, originals);
  }

  /**
   * Clones the sample account with the given name format, in bulk.
   *
   * @param format One of the RecordCloneChildRecordNamePicklist values
   * @return The Id of the new account
   */
  private static Id cloneSampleAccountInBulk(String format) {
    List<Object> built = accountWithOpportunities();
    sObjectSummary summary = (sObjectSummary) built[1];
    summary.childRecordNameFormat = format;
    List<sObject> clones = RecordCloneHandler.cloneRecords(
      new List<sObject>{ (sObject) built[0] },
      summary
    );
    return clones[0].Id;
  }

  @IsTest
  private static void multipleRecordsKeepTheOriginalNames() {
    Id cloneId = cloneSampleAccountInBulk(
      RecordCloneChildRecordNamePicklist.valueOriginalName
    );
    Assert.areEqual(
      'Original Account',
      [SELECT Name FROM Account WHERE Id = :cloneId]
      .Name
    );
    Assert.areEqual(
      new List<String>{ 'Opp One', 'Opp Two' },
      opportunityNames(cloneId)
    );
  }

  @IsTest
  private static void multipleRecordsPrefixNamesWhenAsked() {
    Id cloneId = cloneSampleAccountInBulk(
      RecordCloneChildRecordNamePicklist.valueWithCloned
    );
    Assert.areEqual(
      'Cloned - Original Account',
      [SELECT Name FROM Account WHERE Id = :cloneId]
      .Name
    );
    Assert.areEqual(
      new List<String>{ 'Cloned - Opp One', 'Cloned - Opp Two' },
      opportunityNames(cloneId)
    );
  }

  @IsTest
  private static void multipleRecordsAddThePrefixAndADateWhenAsked() {
    List<Object> built = accountWithOpportunities();
    sObjectSummary summary = (sObjectSummary) built[1];
    summary.childRecordNameFormat = RecordCloneChildRecordNamePicklist.valueWithClonedAndDate;

    List<sObject> clones = RecordCloneHandler.cloneRecords(
      new List<sObject>{ (sObject) built[0] },
      summary
    );

    String parentName = [SELECT Name FROM Account WHERE Id = :clones[0].Id]
    .Name;
    Matcher parent = datedPrefix.matcher(parentName);
    Assert.isTrue(parent.matches(), 'Unexpected parent name: ' + parentName);
    Assert.areEqual('Original Account', parent.group(1));
    for (String name : opportunityNames(clones[0].Id)) {
      Assert.isTrue(
        datedPrefix.matcher(name).matches(),
        'Unexpected child name: ' + name
      );
    }
  }

  @IsTest
  private static void eachClonedParentGetsOnlyItsOwnChildren() {
    List<Account> accounts = new List<Account>{
      new Account(Name = 'First'),
      new Account(Name = 'Second')
    };
    insert accounts;
    insert new List<Opportunity>{
      new Opportunity(
        Name = 'First Opp',
        StageName = 'Prospecting',
        CloseDate = Date.today(),
        AccountId = accounts[0].Id
      ),
      new Opportunity(
        Name = 'Second Opp A',
        StageName = 'Prospecting',
        CloseDate = Date.today(),
        AccountId = accounts[1].Id
      ),
      new Opportunity(
        Name = 'Second Opp B',
        StageName = 'Prospecting',
        CloseDate = Date.today(),
        AccountId = accounts[1].Id
      )
    };
    sObjectSummary summary = sObjectSummary.getByRecordId(
      accounts[0].Id,
      'Opportunities',
      ''
    );
    summary.childRecordNameFormat = RecordCloneChildRecordNamePicklist.valueOriginalName;
    List<sObject> originals = RecordCloneHandler.getOriginalRecords(
      new List<Id>{ accounts[0].Id, accounts[1].Id },
      summary
    );

    List<sObject> clones = RecordCloneHandler.cloneRecords(originals, summary);

    Map<String, Id> cloneIdByName = new Map<String, Id>();
    for (Account clone : [
      SELECT Id, Name
      FROM Account
      WHERE Id IN :new Map<Id, sObject>(clones).keySet()
    ]) {
      cloneIdByName.put(clone.Name, clone.Id);
    }
    Assert.areEqual(
      new List<String>{ 'First Opp' },
      opportunityNames(cloneIdByName.get('First'))
    );
    Assert.areEqual(
      new List<String>{ 'Second Opp A', 'Second Opp B' },
      opportunityNames(cloneIdByName.get('Second'))
    );
  }

  @IsTest
  private static void singleRecordClonesAParentWithMoreThan200Children() {
    // Older API versions raised an error when a sub query result of more than 200 rows was read into a
    // list directly, and readChildren has a fallback for that. On API 68.0 the direct read works, so this
    // checks that a large child list is cloned whole, not that the fallback runs.
    Account acc = new Account(Name = 'Big Account');
    insert acc;
    List<Contact> contacts = new List<Contact>();
    for (Integer i = 0; i < 205; i++) {
      contacts.add(new Contact(LastName = 'Contact ' + i, AccountId = acc.Id));
    }
    insert contacts;
    sObjectSummary summary = sObjectSummary.getByRecordId(
      acc.Id,
      'Contacts',
      ''
    );

    sObject cloned = RecordCloneHandler.cloneRecord(
      RecordCloneHandler.getOriginalRecord(acc.Id, summary),
      summary,
      'Big Copy',
      RecordCloneChildRecordNamePicklist.valueOriginalName
    );

    Assert.areEqual(
      205,
      [SELECT COUNT() FROM Contact WHERE AccountId = :cloned.Id]
    );
  }
}
