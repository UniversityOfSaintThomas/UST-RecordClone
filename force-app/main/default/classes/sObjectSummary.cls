/*
 * Copyright (c) 2020, salesforce.com, inc.
 * All rights reserved.
 * SPDX-License-Identifier: BSD-3-Clause
 * For full license text, see LICENSE.txt file in the repo root or https://opensource.org/licenses/BSD-3-Clause
 */
/**
 * Describes an object for cloning: whether it can be cloned and why not, which of its fields can be
 * copied and why not, and which of its children are cloned with it. The browser receives it as is.
 */
public with sharing class sObjectSummary {
  @AuraEnabled
  public String label;
  @AuraEnabled
  public String apiName;
  @AuraEnabled
  public Boolean isClonable;
  @AuraEnabled
  public String nameField;
  @AuraEnabled
  public Boolean isNamable;
  @AuraEnabled
  public String parentRelationshipField;
  @AuraEnabled
  public List<sFieldSummary> fields;
  @AuraEnabled
  public Boolean isDeletable;
  @AuraEnabled
  public String errorMessage;
  @AuraEnabled
  public Map<String, sObjectSummary> children;

  // Objects that cannot be cloned, and the reason code the interface explains. Share objects are
  // recognised by their name instead (see the constructor).
  private static final Map<String, String> unsupportedObjectReasons = new Map<String, String>{
    'Task' => 'IS_TASK',
    'Event' => 'IS_EVENT',
    'Attachment' => 'IS_ATTACHMENT',
    'Document' => 'IS_DOCUMENT',
    'QuoteDocument' => 'IS_QUOTE_DOCUMENT',
    'ContentDocumentLink' => 'IS_CONTENT_DOCUMENT_LINK',
    'Partner' => 'IS_PARTNER',
    'AccountPartner' => 'IS_ACCOUNT_PARTNER',
    'OpportunityPartner' => 'IS_OPPORTUNITY_PARTNER',
    // Implementation restriction: when querying NetworkUserHistoryRecent you must filter on a single
    // NetworkUserId or Id, or on a list of Ids.
    'NetworkUserHistoryRecent' => 'IS_COMMUNITY_RELATED_RESTRICTION'
  };

  // Fields the database requires a value for when a record is created. Not sent to the UI.
  private Set<String> requiredFieldNames = new Set<String>();

  // for multiple records cloning
  @AuraEnabled
  public String parentRecordNameFormat;
  @AuraEnabled
  public String childRecordNameFormat;

  /**
   * One field of the object: its names, whether it can be cloned, and the reasons if it cannot.
   */
  public with sharing class sFieldSummary {
    @AuraEnabled
    public String apiName;
    @AuraEnabled
    public String label;
    @AuraEnabled
    public Boolean isClonable;
    @AuraEnabled
    public String errorMessage;

    /**
     * Works out whether a field can be copied. A field that cannot is given reason codes.
     *
     * @param describe The describe result of the object the field belongs to
     * @param dfr The describe result of the field
     * @param excludedFieldNameSet Names of fields the configuration leaves out
     */
    public sFieldSummary(
      DescribeSObjectResult describe,
      Schema.DescribeFieldResult dfr,
      Set<String> excludedFieldNameSet
    ) {
      this.apiName = dfr.getLocalName();
      this.label = dfr.getLabel();

      List<String> errors = new List<String>();
      // BASE64 field is not supported
      if (dfr.getType().name() == 'BASE64') {
        errors.add('BASE64');
      }
      // Inserting a OpportunityLineItem record with both of TotalPrice and UnitPrice filled causes DML Exception
      if (
        describe.getLocalName() == 'OpportunityLineItem' &&
        dfr.getLocalName() == 'TotalPrice'
      ) {
        errors.add('OPP_LINE_ITEM');
      }
      // Case ClosedDate cannot be manually edited
      if (
        describe.getLocalName() == 'Case' &&
        dfr.getLocalName() == 'ClosedDate'
      ) {
        errors.add('CASE_CLOSED_DATE');
      }
      if (!dfr.isAccessible()) {
        errors.add('NOT_ACCESSIBLE');
      }
      if (!dfr.isCreateable()) {
        errors.add('NOT_CREATEABLE');
      }
      if (dfr.isUnique()) {
        errors.add('IS_UNIQUE');
      }
      // External IDs identify the record in another system. A copy would give two records the
      // same key, so the next sync from that system could update the wrong one.
      if (dfr.isExternalId()) {
        errors.add('IS_EXTERNAL_ID');
      }
      if (dfr.getLocalName().endsWith('__pc')) {
        errors.add('IS_PERSON_ACCOUNT');
      }
      if (dfr.isCalculated()) {
        errors.add('IS_CALCULATED');
      }
      if (
        excludedFieldNameSet != null &&
        excludedFieldNameSet.contains(dfr.getLocalName()) &&
        (dfr.isNillable() || dfr.isDefaultedOnCreate())
      ) {
        errors.add('IS_EXCLUDED');
      }

      this.errorMessage = String.join(errors, ',');
      this.isClonable = errors.size() == 0;
    }
  }

  /**
   * Summarises an object with no fields excluded and no chosen name field.
   *
   * @param describe The describe result of the object
   */
  public sObjectSummary(DescribeSObjectResult describe) {
    this(describe, '', '');
  }

  /**
   * Summarises an object, leaving out the named fields.
   *
   * @param describe The describe result of the object
   * @param excludedFieldNames Comma separated names of fields to leave out
   */
  public sObjectSummary(
    DescribeSObjectResult describe,
    String excludedFieldNames
  ) {
    this(describe, excludedFieldNames, '');
  }

  /**
   * Summarises an object: whether it can be cloned and why not, and for each field whether it can be
   * copied and why not.
   *
   * @param describe The describe result of the object
   * @param excludedFieldNames Comma separated names of fields to leave out
   * @param specifiedNameField The field that holds the record name, when it is not the usual name field
   */
  public sObjectSummary(
    DescribeSObjectResult describe,
    String excludedFieldNames,
    String specifiedNameField
  ) {
    this.label = describe.getLabel();
    this.apiName = describe.getLocalName();
    this.isNamable = false;
    this.fields = new List<sFieldSummary>();

    // check if sObject is able to be cloned
    List<String> errors = new List<String>();
    if (!describe.isAccessible()) {
      errors.add('NOT_ACCESSIBLE');
    }
    if (!describe.isCreateable()) {
      errors.add('NOT_CREATEABLE');
    }

    if (!describe.isQueryable()) {
      errors.add('NOT_QUERYABLE');
    }
    String unsupportedReason = unsupportedObjectReasons.get(this.apiName);
    if (unsupportedReason != null) {
      errors.add(unsupportedReason);
    }
    if (this.apiName.endsWith('__share') || this.apiName.endsWith('Share')) {
      // https://salesforce.stackexchange.com/questions/219200/how-to-distinguish-manual-sharing-and-apex-sharing-in-code-level
      errors.add('IS_SHARE_OBJECT');
    }
    this.errorMessage = String.join(errors, ',');
    this.isClonable = errors.size() == 0;

    this.isDeletable = describe.isDeletable();

    Set<String> excludedFieldNameSet = new Set<String>(
      new List<String>{
        'CreatedDate',
        'LastModifiedDate',
        'CreatedById',
        'LastModifiedById'
      }
    );

    // PersonAccount Name field is not able to clone.
    if (this.apiName == 'Account' && specifiedNameField == 'LastName') {
      excludedFieldNameSet.add('Name');
    }

    if (String.isNotBlank(excludedFieldNames)) {
      List<String> excludedFieldNameList = excludedFieldNames.deleteWhitespace()
        .split(',');
      excludedFieldNameSet.addAll(excludedFieldNameList);
    }

    Map<String, Schema.SObjectField> fieldMap = describe.fields.getMap();

    if (String.isNotBlank(specifiedNameField)) {
      this.nameField = specifiedNameField;
      this.isNamable = true;
    }

    for (Schema.SObjectField sfield : fieldMap.Values()) {
      Schema.DescribeFieldResult dfr = sfield.getDescribe();

      if (dfr.getLocalName() != 'Id') {
        this.fields.add(new sFieldSummary(describe, dfr, excludedFieldNameSet));
        if (
          dfr.isCreateable() &&
          !dfr.isNillable() &&
          !dfr.isDefaultedOnCreate()
        ) {
          this.requiredFieldNames.add(dfr.getLocalName());
        }
      }

      if (dfr.isNameField() && dfr.isUpdateable()) {
        this.nameField = dfr.getLocalName();
        this.isNamable = !dfr.isAutoNumber() && !dfr.isUnique();
      }
    }
  }

  /**
   * The fields that can be copied.
   *
   * @return The API names of the clonable fields
   */
  // Return list of api names of clonable fields
  public List<String> filterClonableFields() {
    List<String> fieldList = new List<String>();
    for (sFieldSummary sField : this.fields) {
      if (sField.isClonable) {
        fieldList.add(sField.apiName);
      }
    }
    return fieldList;
  }

  /**
   * Summarises the object of a record using the clone settings stored for it (custom metadata). Used
   * by Flow, where the settings are the only way to say what to clone. The settings are read in system
   * mode, because they are admin configuration that any cloning user needs.
   *
   * @param recordId The Id of the record to be cloned
   * @return The summary, or null when there is no record Id or the record cannot be read
   */
  // fetching sObjectSummary from a custom metadata type
  // Used with process builder or flow
  public static sObjectSummary getByRecordId(Id recordId) {
    if (recordId == null) {
      return null;
    }
    DescribeSObjectResult describe = recordId.getSObjectType().getDescribe();

    String objectName = describe.getLocalName();
    // SYSTEM_MODE on purpose: this is admin-owned clone configuration, not user data. A user who can
    // clone a record does not need read access to the settings type, and a probe showed that
    // USER_MODE throws a QueryException for such a user.
    List<RecordCloneSettings__mdt> settings = [
      SELECT
        Id,
        ObjectName__c,
        ChildRelationshipNames__c,
        ExcludedFieldNames__c,
        ChildRecordNameType__c
      FROM RecordCloneSettings__mdt
      WHERE ObjectName__c = :objectName
      WITH SYSTEM_MODE
    ];

    String childRelationshipNames = '';
    String excludedFieldNames = '';
    String childRecordNameFormat = RecordCloneChildRecordNamePicklist.valueOriginalName;
    if (settings != null && settings.size() > 0) {
      childRelationshipNames = settings[0].ChildRelationshipNames__c;
      excludedFieldNames = settings[0].ExcludedFieldNames__c;
      String settingChildRecordNameFormat = RecordCloneChildRecordNamePicklist.values.get(
        settings[0].ChildRecordNameType__c
      );
      if (settingChildRecordNameFormat != null) {
        childRecordNameFormat = settingChildRecordNameFormat;
      }
    }

    sObjectSummary sObjSummary = getByRecordId(
      recordId,
      childRelationshipNames,
      excludedFieldNames
    );
    sObjSummary.childRecordNameFormat = childRecordNameFormat;
    return sObjSummary;
  }

  /**
   * Summarises the object of a record for a clone with the given children and exclusions.
   *
   * @param recordId The Id of the record to be cloned
   * @param childRelationshipNames Comma separated child relationship names to clone with the record
   * @param excludedFieldNames Comma separated names of fields to leave out
   * @return The summary, or null when there is no record Id or the record cannot be read
   */
  public static sObjectSummary getByRecordId(
    Id recordId,
    String childRelationshipNames,
    String excludedFieldNames
  ) {
    if (recordId == null) {
      return null;
    }
    DescribeSObjectResult describe = recordId.getSObjectType().getDescribe();

    String specifiedNameField = '';

    // Distinguish the name field of person accounts from that of regular accounts
    if (describe.getLocalName() == 'Account' && hasPersonAccounts()) {
      Boolean isPersonAccount = isPersonAccount(recordId);
      if (isPersonAccount == null) {
        return null;
      }
      specifiedNameField = nameFieldOfAccount(isPersonAccount);
    }

    sObjectSummary sObj = new sObjectSummary(
      describe,
      excludedFieldNames,
      specifiedNameField
    );
    sObj.children = getChildren(describe, childRelationshipNames);
    return sObj;
  }

  /**
   * Whether this org has person accounts switched on.
   *
   * @return True when the Account object has the IsPersonAccount field
   */
  @TestVisible
  private static Boolean hasPersonAccounts() {
    return Schema.sObjectType.Account.fields.getMap()
      .containsKey('IsPersonAccount');
  }

  /**
   * The field that holds an account's name. A person account is named by its last name, a business
   * account by Name.
   *
   * @param isPersonAccount Whether the account is a person account
   * @return The API name of the name field
   */
  @TestVisible
  private static String nameFieldOfAccount(Boolean isPersonAccount) {
    return isPersonAccount ? 'LastName' : 'Name';
  }

  /**
   * Whether an account is a person account, read in user mode.
   *
   * @param accountId The Id of the account
   * @return True or false, or null when the account cannot be read by the running user
   */
  @TestVisible
  private static Boolean isPersonAccount(Id accountId) {
    try {
      List<sObject> found = Database.queryWithBinds(
        'SELECT Id, IsPersonAccount FROM Account WHERE Id = :accountId',
        new Map<String, Object>{ 'accountId' => accountId },
        AccessLevel.USER_MODE
      );
      if (found.isEmpty()) {
        return null;
      }
      return (Boolean) found[0].get('IsPersonAccount');
    } catch (QueryException ignored) {
      return null;
    } catch (System.TypeException ignored) {
      return null;
    } catch (System.SObjectException ignored) {
      return null;
    }
  }

  private static Map<String, sObjectSummary> getChildren(
    DescribeSObjectResult describe,
    String childRelationshipNames
  ) {
    // Split up childRelationshipNames
    if (String.isBlank(childRelationshipNames)) {
      return null;
    }

    List<String> childRelationshipList = childRelationshipNames.deleteWhitespace()
      .split(',');
    Set<String> childRelationshipSet = new Set<String>(childRelationshipList);

    Map<String, sObjectSummary> children = new Map<String, sObjectSummary>();
    for (Schema.ChildRelationship child : describe.getChildRelationships()) {
      // Match inputted child relationship names with actual object names.
      if (childRelationshipSet.contains(child.getRelationshipName())) {
        sObjectSummary sObjectSummary = new sObjectSummary(
          child.getChildSObject().getDescribe()
        );
        sObjectSummary.parentRelationshipField = child.getField()
          .getDescribe()
          .getName();
        sObjectSummary.markRequiredFieldsThatCannotBeCloned();
        children.put(child.getRelationshipName(), sObjectSummary);
      }
    }
    return children;
  }

  /**
   * A child record cannot be inserted if the database requires a field the clone leaves out (for
   * example a required unique field). Such a child is shown as not clonable, with the field names,
   * instead of failing every clone. The lookup back to the parent and the record name are filled in
   * by the clone, so they do not count.
   */
  private void markRequiredFieldsThatCannotBeCloned() {
    List<String> blockers = new List<String>();
    for (sFieldSummary field : this.fields) {
      if (
        field.isClonable ||
        !this.requiredFieldNames.contains(field.apiName) ||
        field.apiName == this.parentRelationshipField ||
        (this.isNamable && field.apiName == this.nameField)
      ) {
        continue;
      }
      blockers.add(field.apiName);
    }
    if (blockers.isEmpty()) {
      return;
    }
    this.isClonable = false;
    String reason =
      'REQUIRED_FIELD_NOT_CLONABLE(' +
      String.join(blockers, ' ') +
      ')';
    this.errorMessage = String.isBlank(this.errorMessage)
      ? reason
      : this.errorMessage + ',' + reason;
  }
}
