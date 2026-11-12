/*
 * Copyright (c) 2020, salesforce.com, inc.
 * All rights reserved.
 * SPDX-License-Identifier: BSD-3-Clause
 * For full license text, see LICENSE.txt file in the repo root or https://opensource.org/licenses/BSD-3-Clause
 */
global with sharing class RecordCloneController {
  // get sObject summarized information so that users can see what's going on during clone.
  @AuraEnabled(cacheable=true)
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
  public static String getNameFieldValue(
    Id recordId,
    String objectName,
    String nameField
  ) {
    try {
      // handle error on frontend.
      sObject sobj = Database.query(
        'SELECT ' +
        nameField +
        ' FROM ' +
        objectName +
        ' WHERE Id = \'' +
        recordId +
        '\''
      );
      return (String) sobj.get(nameField);
    } catch (System.QueryException dmle) {
      return null;
    } catch (System.SObjectException sobje) {
      return null;
    } catch (System.TypeException typee) {
      return null;
    }
  }

  @AuraEnabled
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

      // exec clone
      Map<Id, sObject> clonedRecords = new Map<Id, sObject>(
        RecordCloneHandler.cloneRecords(originalRecords, sObjSummary)
      );

      clonedRecordList.add(new List<Id>(clonedRecords.keySet()));
    }

    return clonedRecordList;
  }
}
