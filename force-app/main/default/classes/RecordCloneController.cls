/*
 * Copyright (c) 2020, salesforce.com, inc.
 * All rights reserved.
 * SPDX-License-Identifier: BSD-3-Clause
 * For full license text, see LICENSE.txt file in the repo root or https://opensource.org/licenses/BSD-3-Clause
 */
/**
 * Entry points for cloning a record and its children: an Aura method for the Record Clone component,
 * a second for the summary shown on the page, and an invocable method for Flow.
 */
global with sharing class RecordCloneController {
  // get sObject summarized information so that users can see what's going on during clone.
  @AuraEnabled(cacheable=true)
  /**
   * Describes what a clone of this record would do, so the page can show it before the user clicks.
   *
   * @param recordId The Id of the record to be cloned
   * @param childRelationshipNames Comma separated child relationship names to clone with the record
   * @param excludedFieldNames Comma separated field names to leave out of the clone
   * @return The summary of the object, its fields and its children, or null when there is no record Id
   */
  public static sObjectSummary getSObjectSummary(
    Id recordId,
    String childRelationshipNames,
    String excludedFieldNames
  ) {
    return sObjectSummary.getByRecordId(
      recordId,
      childRelationshipNames,
      excludedFieldNames
    );
  }

  // get the name field value of the original record if the sObject has name field.
  @AuraEnabled(cacheable=true)
  /**
   * Reads the name of the record being cloned, to pre-fill the name box. The object and field names
   * come from the browser, so both are checked against the record's own schema before they are used.
   *
   * @param recordId The Id of the record
   * @param objectName The API name of the record's object; it must match the Id
   * @param nameField The API name of the field that holds the name; it must exist on that object
   * @return The name, or null when the names do not match the record or the user cannot read it
   */
  public static String getNameFieldValue(
    Id recordId,
    String objectName,
    String nameField
  ) {
    if (recordId == null) {
      return null;
    }
    try {
      // objectName and nameField arrive from the browser, so they are never placed in the query
      // as given. Both must match the schema of the record's own object, and the query uses the
      // names from that schema. A mismatch is the same "no value" answer the page already handles.
      Schema.DescribeSObjectResult describe = recordId.getSObjectType()
        .getDescribe(SObjectDescribeOptions.DEFERRED);
      if (!describe.getName().equalsIgnoreCase(objectName)) {
        return null;
      }
      Schema.SObjectField field = describe.fields.getMap().get(nameField);
      if (field == null) {
        return null;
      }
      String query =
        'SELECT ' +
        field.getDescribe().getName() +
        ' FROM ' +
        describe.getName() +
        ' WHERE Id = :recordId';
      List<sObject> found = Database.queryWithBinds(
        query,
        new Map<String, Object>{ 'recordId' => recordId },
        AccessLevel.USER_MODE
      );
      if (found.isEmpty()) {
        return null;
      }
      return (String) found[0].get(field.getDescribe().getName());
    } catch (System.QueryException dmle) {
      return null;
    } catch (System.SObjectException sobje) {
      return null;
    } catch (System.TypeException typee) {
      return null;
    }
  }

  @AuraEnabled
  /**
   * Clones one record and the children chosen in the configuration. It is all or nothing: if the
   * record or any child cannot be inserted, everything is rolled back and the reason is thrown with
   * the message the browser can show.
   *
   * @param recordId The Id of the record to clone
   * @param newParentRecordName The name for the new record; required when the object has a name field
   * @param childRelationshipNames Comma separated child relationship names to clone with the record
   * @param excludedFieldNames Comma separated field names to leave out of the clone
   * @param childRecordNameType How child records are named: one of the RecordCloneChildRecordNamePicklist values
   * @return The new record, or null when the record cannot be read or a required name is missing
   * @throws AuraHandledException When an insert fails; the message names the object and the reason
   */
  public static sObject execClone(
    Id recordId,
    String newParentRecordName,
    String childRelationshipNames,
    String excludedFieldNames,
    String childRecordNameType
  ) {
    // get sObject summary of the clone target
    sObjectSummary sObjSummary = sObjectSummary.getByRecordId(
      recordId,
      childRelationshipNames,
      excludedFieldNames
    );

    if (sObjSummary == null) {
      return null;
    }

    // return error in case of missing a new record name
    if (sObjSummary.isNamable && String.isBlank(newParentRecordName)) {
      return null;
    }

    // get the original record
    sObject originalRecord = RecordCloneHandler.getOriginalRecord(
      recordId,
      sObjSummary
    );

    if (originalRecord == null) {
      return null;
    }

    // exec clone. All-or-nothing: if the parent or any child fails to insert,
    // roll back so the user is not left with a half-cloned record set.
    Savepoint beforeClone = Database.setSavepoint();
    try {
      return RecordCloneHandler.cloneRecord(
        originalRecord,
        sObjSummary,
        newParentRecordName,
        childRecordNameType
      );
    } catch (RecordCloneHandler.RecordCloneException e) {
      Database.rollback(beforeClone);
      throw buildAuraException(e.getMessage());
    }
  }

  /**
   * Builds an AuraHandledException whose message reaches the browser.
   * Without setMessage, getMessage() on the client returns "Script-thrown exception".
   *
   * @param message The user-facing message
   * @return Exception ready to be thrown from an AuraEnabled method
   */
  private static AuraHandledException buildAuraException(String message) {
    AuraHandledException auraException = new AuraHandledException(message);
    auraException.setMessage(message);
    return auraException;
  }

  // support for multiple record cloning
  // available with flow, process builder...etc
  @InvocableMethod(
    label='Clone records'
    description='Cloning multiple records by passing recordIds'
    category='Record Clone'
  )
  /**
   * Clones records for Flow. The clone settings stored for the object (custom metadata) decide which
   * children are included, which fields are left out, and how names are formed.
   *
   * @param recordIds One list of Ids per group; each list is cloned together, and all records are the same object
   * @return The Ids of the new records, one list per input list
   * @throws RecordCloneHandler.RecordCloneException When the records cannot be read or an insert fails
   */
  global static List<List<Id>> clone(List<List<Id>> recordIds) {
    if (
      recordIds == null ||
      recordIds.size() <= 0 ||
      recordIds[0].size() <= 0
    ) {
      return null;
    }

    List<List<Id>> clonedRecordList = new List<List<Id>>();
    for (List<Id> rids : recordIds) {
      if (rids.size() <= 0) {
        continue;
      }

      // Assuming all records are the same sObject, get sObject summary from the first record
      sObjectSummary sObjSummary = sObjectSummary.getByRecordId(rids[0]);

      // get original records
      List<sObject> originalRecords = RecordCloneHandler.getOriginalRecords(
        rids,
        sObjSummary
      );
      if (originalRecords == null) {
        // The query runs in user mode. Without access to the object or its fields it finds nothing.
        throw new RecordCloneHandler.RecordCloneException(
          'Clone failed. The records could not be read. Check that you have access to the object and its fields.'
        );
      }

      // exec clone
      Map<Id, sObject> clonedRecords = new Map<Id, sObject>(
        RecordCloneHandler.cloneRecords(originalRecords, sObjSummary)
      );

      clonedRecordList.add(new List<Id>(clonedRecords.keySet()));
    }

    return clonedRecordList;
  }
}
