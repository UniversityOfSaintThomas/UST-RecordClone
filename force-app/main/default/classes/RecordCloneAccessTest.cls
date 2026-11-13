/**
 * Proves that cloning runs in user mode: the running user's object permissions decide what can be
 * read and created, and the clone settings are still readable by a user who cannot see the type.
 * Each test builds its own users, because a scratch org has a limited supply of licenses to share.
 */
@IsTest
private class RecordCloneAccessTest {
  private static final String minimumAccessProfileName = 'Minimum Access - Salesforce';

  /**
   * Creates a user on the Minimum Access profile, who can do nothing until a permission set says so.
   *
   * @param suffix Makes the alias and username unique within the test
   * @param grant How much access to Account the user is given
   * @param canSeePhone Whether the user gets field-level access to Account.Phone
   * @return The inserted user
   */
  private static User createUser(
    String suffix,
    AccountGrant grant,
    Boolean canSeePhone
  ) {
    Profile minimumAccess = [
      SELECT Id
      FROM Profile
      WHERE Name = :minimumAccessProfileName
      LIMIT 1
    ];
    User testUser = new User(
      Alias = suffix.left(8),
      Email = suffix + '@example.com',
      EmailEncodingKey = 'UTF-8',
      LastName = 'Access ' + suffix,
      LanguageLocaleKey = 'en_US',
      LocaleSidKey = 'en_US',
      ProfileId = minimumAccess.Id,
      TimeZoneSidKey = 'America/Chicago',
      Username = suffix + System.currentTimeMillis() + '@example.com'
    );

    // Setup objects (users, permission sets) and data records cannot change in one transaction
    // unless the setup work runs as another user.
    System.runAs(new User(Id = UserInfo.getUserId())) {
      insert testUser;
      if (grant != AccountGrant.None) {
        PermissionSet accountPermissions = new PermissionSet(
          Name = 'RecordCloneAccessTest' + suffix,
          Label = 'RecordCloneAccessTest ' + suffix
        );
        insert accountPermissions;
        insert new ObjectPermissions(
          ParentId = accountPermissions.Id,
          SobjectType = 'Account',
          PermissionsRead = true,
          PermissionsViewAllRecords = true,
          PermissionsCreate = grant == AccountGrant.ReadCreateEdit,
          PermissionsEdit = grant == AccountGrant.ReadCreateEdit
        );
        if (canSeePhone) {
          insert new FieldPermissions(
            ParentId = accountPermissions.Id,
            SobjectType = 'Account',
            Field = 'Account.Phone',
            PermissionsRead = true,
            PermissionsEdit = grant == AccountGrant.ReadCreateEdit
          );
        }
        insert new PermissionSetAssignment(
          AssigneeId = testUser.Id,
          PermissionSetId = accountPermissions.Id
        );
      }
    }
    return testUser;
  }

  private enum AccountGrant {
    None,
    ReadOnly,
    ReadCreateEdit
  }

  @IsTest
  private static void userWhoCanOnlyReadAnAccountGetsNoCloneAndNoCopy() {
    Account original = new Account(Name = 'Read Only Original');
    insert original;
    User readOnlyUser = createUser('readonly', AccountGrant.ReadOnly, false);

    sObject cloned;
    System.runAs(readOnlyUser) {
      cloned = RecordCloneController.execClone(
        original.Id,
        'Read Only Copy',
        '',
        '',
        RecordCloneChildRecordNamePicklist.valueOriginalName
      );
    }

    // No field is createable for this user, so there is nothing to select and the clone is refused
    // before any insert is attempted.
    Assert.isNull(cloned, 'The clone should be refused');
    Assert.areEqual(
      0,
      [SELECT COUNT() FROM Account WHERE Name = 'Read Only Copy'],
      'No copy may be created for a user without create access'
    );
  }

  @IsTest
  private static void insertRefusedByTheDatabaseIsReportedWithTheObjectName() {
    // The summary is cacheable, so it can be older than the user's current permissions. Build it
    // as an administrator, then clone as a user who cannot create accounts.
    Account original = new Account(Name = 'Stale Summary Original');
    insert original;
    sObjectSummary summary = sObjectSummary.getByRecordId(original.Id);
    sObject originalRecord = RecordCloneHandler.getOriginalRecord(
      original.Id,
      summary
    );
    User readOnlyUser = createUser('stale', AccountGrant.ReadOnly, false);

    String thrownMessage;
    System.runAs(readOnlyUser) {
      try {
        RecordCloneHandler.cloneRecord(
          originalRecord,
          summary,
          'Stale Copy',
          RecordCloneChildRecordNamePicklist.valueOriginalName
        );
      } catch (RecordCloneHandler.RecordCloneException e) {
        thrownMessage = e.getMessage();
      }
    }

    Assert.isNotNull(
      thrownMessage,
      'A user mode insert the user is not allowed to make must be reported, not swallowed'
    );
    Assert.isTrue(thrownMessage.startsWith('Clone failed.'), thrownMessage);
    Assert.isTrue(thrownMessage.contains('Account'), thrownMessage);
    Assert.areEqual(0, [SELECT COUNT() FROM Account WHERE Name = 'Stale Copy']);
  }

  @IsTest
  private static void flowPathReportsARefusedInsertWithTheObjectName() {
    Account original = new Account(Name = 'Flow Stale Original');
    insert original;
    sObjectSummary summary = sObjectSummary.getByRecordId(original.Id);
    List<sObject> originals = RecordCloneHandler.getOriginalRecords(
      new List<Id>{ original.Id },
      summary
    );
    User readOnlyUser = createUser('flowstal', AccountGrant.ReadOnly, false);

    String thrownMessage;
    System.runAs(readOnlyUser) {
      try {
        RecordCloneHandler.cloneRecords(originals, summary);
      } catch (RecordCloneHandler.RecordCloneException e) {
        thrownMessage = e.getMessage();
      }
    }

    Assert.isNotNull(thrownMessage, 'The refused insert must be reported');
    Assert.isTrue(thrownMessage.startsWith('Clone failed.'), thrownMessage);
    Assert.isTrue(thrownMessage.contains('Account'), thrownMessage);
    Assert.areEqual(
      1,
      [SELECT COUNT() FROM Account WHERE Name = 'Flow Stale Original'],
      'Only the original should exist'
    );
  }

  @IsTest
  private static void flowGivesAReadableErrorWhenTheUserCannotReadTheRecords() {
    Account original = new Account(Name = 'Flow Hidden Original');
    insert original;
    User readOnlyUser = createUser('flowread', AccountGrant.ReadOnly, false);

    String thrownMessage;
    System.runAs(readOnlyUser) {
      try {
        RecordCloneController.clone(
          new List<List<Id>>{ new List<Id>{ original.Id } }
        );
      } catch (RecordCloneHandler.RecordCloneException e) {
        thrownMessage = e.getMessage();
      }
    }

    Assert.isNotNull(
      thrownMessage,
      'A user who cannot read the records should get an error, not a null pointer'
    );
    Assert.isTrue(thrownMessage.contains('could not be read'), thrownMessage);
  }

  @IsTest
  private static void userWhoCanCreateAccountsCanStillCloneOne() {
    Account original = new Account(
      Name = 'Allowed Original',
      Phone = '0123456789'
    );
    insert original;
    User creatingUser = createUser(
      'creator',
      AccountGrant.ReadCreateEdit,
      true
    );

    sObject cloned;
    System.runAs(creatingUser) {
      cloned = RecordCloneController.execClone(
        original.Id,
        'Allowed Copy',
        '',
        '',
        RecordCloneChildRecordNamePicklist.valueOriginalName
      );
    }

    Assert.isNotNull(
      cloned,
      'A user with create access should be able to clone'
    );
    Account copy = [SELECT Name, Phone FROM Account WHERE Id = :cloned.Id];
    Assert.areEqual('Allowed Copy', copy.Name);
    Assert.areEqual(
      '0123456789',
      copy.Phone,
      'Fields the user can read and create are copied'
    );
  }

  @IsTest
  private static void fieldsTheUserCannotSeeAreLeftOutOfTheCopy() {
    Account original = new Account(
      Name = 'Field Level Original',
      Phone = '0123456789'
    );
    insert original;
    User creatingUser = createUser(
      'nophone',
      AccountGrant.ReadCreateEdit,
      false
    );

    sObject cloned;
    System.runAs(creatingUser) {
      cloned = RecordCloneController.execClone(
        original.Id,
        'Field Level Copy',
        '',
        '',
        RecordCloneChildRecordNamePicklist.valueOriginalName
      );
    }

    Assert.isNotNull(cloned, 'The clone itself is allowed');
    Account copy = [SELECT Name, Phone FROM Account WHERE Id = :cloned.Id];
    Assert.areEqual('Field Level Copy', copy.Name);
    Assert.isNull(
      copy.Phone,
      'A field the user has no access to must not be copied into the new record'
    );
  }

  @IsTest
  private static void queryHonoursTheUsersAccessEvenWithAnAdministratorsSummary() {
    // The describe checks leave a no-access user with no fields to select, which would fail the
    // query by itself. Build the summary as an administrator so the only thing left to refuse the
    // read is the access mode of the query.
    Account original = new Account(Name = 'Summary Mismatch Original');
    insert original;
    sObjectSummary administratorsSummary = sObjectSummary.getByRecordId(
      original.Id
    );
    Assert.isNotNull(
      RecordCloneHandler.getOriginalRecord(original.Id, administratorsSummary),
      'Control: the administrator can read the record with this summary'
    );
    User noAccessUser = createUser('mismatch', AccountGrant.None, false);

    sObject single;
    List<sObject> several;
    System.runAs(noAccessUser) {
      single = RecordCloneHandler.getOriginalRecord(
        original.Id,
        administratorsSummary
      );
      several = RecordCloneHandler.getOriginalRecords(
        new List<Id>{ original.Id },
        administratorsSummary
      );
    }

    Assert.isNull(
      single,
      'The user cannot read accounts, so nothing comes back'
    );
    Assert.isNull(several, 'The multi-record query is refused in the same way');
  }

  @IsTest
  private static void userWithoutReadAccessGetsNothingBack() {
    Account original = new Account(Name = 'Hidden Original');
    insert original;
    User noAccessUser = createUser('noaccess', AccountGrant.None, false);

    Assert.areEqual(
      'Hidden Original',
      RecordCloneController.getNameFieldValue(original.Id, 'Account', 'Name'),
      'Control: the same call works for a user who can read the account'
    );

    sObject cloned;
    String name;
    System.runAs(noAccessUser) {
      cloned = RecordCloneController.execClone(
        original.Id,
        'Hidden Copy',
        '',
        '',
        RecordCloneChildRecordNamePicklist.valueOriginalName
      );
      name = RecordCloneController.getNameFieldValue(
        original.Id,
        'Account',
        'Name'
      );
    }

    Assert.isNull(
      cloned,
      'Nothing is cloned when the user cannot read the record'
    );
    Assert.isNull(
      name,
      'The record name must not leak to a user without access'
    );
    Assert.areEqual(
      0,
      [SELECT COUNT() FROM Account WHERE Name = 'Hidden Copy']
    );
  }

  @IsTest
  private static void userWithoutAccessToTheSettingsTypeStillGetsTheConfiguration() {
    Account original = new Account(Name = 'Configured Original');
    insert original;
    User noAccessUser = createUser('settings', AccountGrant.ReadOnly, false);

    sObjectSummary summary;
    System.runAs(noAccessUser) {
      summary = sObjectSummary.getByRecordId(original.Id);
    }

    Assert.isNotNull(
      summary,
      'Reading the clone settings is a system mode query, so it works for any user'
    );
    Assert.areEqual('Account', summary.apiName);
  }

  @IsTest
  private static void nameFieldLookupRejectsNamesTheBrowserMadeUp() {
    Account original = new Account(Name = 'Injection Original');
    insert original;

    Assert.isNull(
      RecordCloneController.getNameFieldValue(
        original.Id,
        'Account',
        'Name, Phone'
      ),
      'More than one field is not a field name'
    );
    Assert.isNull(
      RecordCloneController.getNameFieldValue(
        original.Id,
        'Account',
        'Name FROM Account WHERE Name != null LIMIT 1 --'
      ),
      'SOQL smuggled into the field name is rejected'
    );
    Assert.isNull(
      RecordCloneController.getNameFieldValue(
        original.Id,
        'Account WHERE Name != null --',
        'Name'
      ),
      'SOQL smuggled into the object name is rejected'
    );
    Assert.isNull(
      RecordCloneController.getNameFieldValue(null, 'Account', 'Name'),
      'A missing record Id gives no value'
    );
    Assert.areEqual(
      'Injection Original',
      RecordCloneController.getNameFieldValue(original.Id, 'account', 'name'),
      'Names are matched without regard to case, as Apex does'
    );
  }
}
