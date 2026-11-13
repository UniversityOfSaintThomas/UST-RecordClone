/*
 * Copyright (c) 2020, salesforce.com, inc.
 * All rights reserved.
 * SPDX-License-Identifier: BSD-3-Clause
 * For full license text, see LICENSE.txt file in the repo root or https://opensource.org/licenses/BSD-3-Clause
 */
/**
 * Does the work of a clone: reads the original records, inserts the copies, then the copies of their
 * children, pointing each child at its new parent. Everything runs in user mode, so the running
 * user's sharing, object permissions and field-level security apply.
 */
public with sharing class RecordCloneHandler {
  /**
   * Raised when a clone cannot complete. The message names the object that
   * failed and the reason Salesforce gave, so callers can show it to the user.
   */
  public class RecordCloneException extends Exception {
  }

  /**
   * The cloned children of one relationship, waiting to be inserted. The original Ids are kept so a
   * lookup from one cloned child to another can be pointed at the new record instead of the old one.
   */
  private class ChildBatch {
    private sObjectSummary summary;
    private List<sObject> rows = new List<sObject>();
    private List<Id> originalIds = new List<Id>();
    private List<String> siblingFields = new List<String>();
    // How the children are named: one of the RecordCloneChildRecordNamePicklist values, and the
    // time of the clone, already formatted
    private String nameFormat;
    private String timestamp;
  }

  /**
   * A lookup to a sibling that has no new Id yet, because the sibling is inserted later or in the
   * same batch. It is patched with one update after every batch is in.
   */
  private class DeferredReference {
    private sObject row;
    private String fieldName;
    private Id originalSiblingId;
  }

  /**
   * Reads one record with the fields and children a clone needs.
   *
   * @param recordId The Id of the record to read
   * @param sObjSummary Says which fields and which children can be cloned
   * @return The record with its children, or null when it cannot be read, or an input is missing
   */
  // single records
  public static sObject getOriginalRecord(
    Id recordId,
    sObjectSummary sObjSummary
  ) {
    if (recordId == null || sObjSummary == null) {
      return null;
    }

    try {
      // The object and field names come from describe results, never from user input.
      // The record Id is a bind variable. USER_MODE applies the running user's sharing,
      // object permissions and field-level security to the query.
      String q =
        'SELECT Id, ' +
        String.join(sObjSummary.filterClonableFields(), ',') +
        buildChildrenSelectQuery(sObjSummary) +
        ' FROM ' +
        sObjSummary.apiName +
        ' WHERE Id = :recordId';
      List<sObject> found = Database.queryWithBinds(
        q,
        new Map<String, Object>{ 'recordId' => recordId },
        AccessLevel.USER_MODE
      );
      return found.isEmpty() ? null : found[0];
    } catch (System.QueryException e) {
      return null;
    }
  }

  /**
   * Reads several records of one object with the fields and children a clone needs.
   *
   * @param recordIds The Ids of the records to read
   * @param sObjSummary Says which fields and which children can be cloned
   * @return The records with their children, or null when they cannot be read, or an input is missing
   */
  // multiple records
  public static List<sObject> getOriginalRecords(
    List<Id> recordIds,
    sObjectSummary sObjSummary
  ) {
    if (recordIds == null || recordIds.size() == 0 || sObjSummary == null) {
      return null;
    }

    try {
      // See getOriginalRecord: names come from describe results, the Ids are a bind variable.
      String q =
        'SELECT Id, ' +
        String.join(sObjSummary.filterClonableFields(), ',') +
        buildChildrenSelectQuery(sObjSummary) +
        ' FROM ' +
        sObjSummary.apiName +
        ' WHERE Id IN :recordIds';
      return Database.queryWithBinds(
        q,
        new Map<String, Object>{ 'recordIds' => recordIds },
        AccessLevel.USER_MODE
      );
    } catch (System.QueryException e) {
      return null;
    }
  }

  /**
   * Clones one record and its children. The record is named by the caller; its children keep their
   * names or are renamed by the chosen format.
   *
   * @param original The record to clone, as read by getOriginalRecord
   * @param sObjectSummary Says which fields and children can be cloned and how the object is named
   * @param newRecordName The name for the new record, used when the object has a name field
   * @param childRecordNameType How child records are named: one of the RecordCloneChildRecordNamePicklist values
   * @return The new record, with its Id
   * @throws RecordCloneException When an insert fails; the message names the object and the reason
   */
  public static sObject cloneRecord(
    sObject original,
    sObjectSummary sObjectSummary,
    String newRecordName,
    String childRecordNameType
  ) {
    // Insert a clean copy that holds only the clonable fields. The queried original also carries its
    // child relationship lists, and user mode DML rejects those as fields that cannot be written.
    sObject cloned = copyClonableFields(original, sObjectSummary);

    // update the record name field to user specified
    if (sObjectSummary.isNamable) {
      cloned.put(sObjectSummary.nameField, newRecordName);
    }

    // insert a parent object record
    insertRows(new List<sObject>{ cloned }, sObjectSummary.label);

    // cloning child records
    if (
      sObjectSummary.children != null &&
      sObjectSummary.children.keySet().size() > 0
    ) {
      // append to child records' name fields
      String todayStr = Datetime.now().format('yyyy/MM/dd HH:mm');
      List<ChildBatch> batches = new List<ChildBatch>();

      // remove child record IDs, assign then cloned parent record Id to ref field
      for (String childRelName : sObjectSummary.children.keySet()) {
        sObjectSummary childSummary = sObjectSummary.children.get(childRelName);

        if (!childSummary.isClonable) {
          continue;
        }

        List<sObject> children = readChildren(original, childRelName);
        if (children == null || children.size() == 0) {
          continue;
        }

        // On creating an opportunity record, system automatically creates an OpportunityContactRole record.
        // Delete the created record as of now.
        if (
          sObjectSummary.apiName == 'Opportunity' &&
          childRelName == 'OpportunityContactRoles' &&
          childSummary.isDeletable
        ) {
          deleteAutoCreatedContactRoles(new List<Id>{ cloned.Id });
        }

        ChildBatch batch = new ChildBatch();
        batch.summary = childSummary;
        batch.nameFormat = childRecordNameType;
        batch.timestamp = todayStr;
        addPreparedChildren(batch, children, cloned.Id);
        batches.add(batch);
      }
      insertChildBatches(batches);
    }

    return cloned;
  }

  /**
   * The name a cloned record gets under the chosen format: unchanged, prefixed with "Cloned - ", or
   * prefixed and followed by the time of the clone.
   *
   * @param originalName The name of the record being cloned
   * @param nameFormat One of the RecordCloneChildRecordNamePicklist values; anything else keeps the name
   * @param timestamp The time of the clone, already formatted
   * @return The name for the new record
   */
  private static String clonedName(
    String originalName,
    String nameFormat,
    String timestamp
  ) {
    if (nameFormat == RecordCloneChildRecordNamePicklist.valueWithCloned) {
      return 'Cloned - ' + originalName;
    }
    if (
      nameFormat == RecordCloneChildRecordNamePicklist.valueWithClonedAndDate
    ) {
      return 'Cloned - ' + originalName + ' - ' + timestamp;
    }
    return originalName;
  }

  /**
   * Reads the children of one relationship from a queried record.
   *
   * @param parent The queried record
   * @param relationshipName The child relationship name, as used in the sub query
   * @return The children, or null when the record has no such relationship loaded
   */
  private static List<sObject> readChildren(
    sObject parent,
    String relationshipName
  ) {
    try {
      try {
        // System.QueryException: Aggregate query has too many rows for direct assignment, use FOR loop
        // https://www.kineticgrowth.com/system-queryexception-aggregate-query-many-rows-direct-assignment-use-loop/
        // https://developer.salesforce.com/docs/atlas.en-us.apexcode.meta/apexcode/langCon_apex_loops_for_SOQL.htm
        // There are weird cases.
        // https://developer.salesforce.com/forums/?id=906F0000000AtTyIAK
        return parent.getSObjects(relationshipName);
      } catch (System.QueryException ignored) {
        List<sObject> children = new List<sObject>();
        for (sObject child : parent.getSObjects(relationshipName)) {
          children.add(child);
        }
        return children;
      }
    } catch (System.SObjectException ignored) {
      return null;
    }
  }

  /**
   * Turns queried children into rows to insert: remembers each original Id, clears it, names the
   * copy, and points it at the new parent. The rows are added to the batch.
   *
   * @param batch The batch the rows belong to; it says how the children are named and linked
   * @param children The queried children of one parent
   * @param newParentId The Id of the cloned parent
   */
  private static void addPreparedChildren(
    ChildBatch batch,
    List<sObject> children,
    Id newParentId
  ) {
    sObjectSummary childSummary = batch.summary;
    for (sObject child : children) {
      batch.originalIds.add(child.Id);
      child.put('Id', null);
      if (childSummary.isNamable) {
        child.put(
          childSummary.nameField,
          clonedName(
            (String) child.get(childSummary.nameField),
            batch.nameFormat,
            batch.timestamp
          )
        );
      }
      child.put(childSummary.parentRelationshipField, newParentId);
    }
    batch.rows.addAll(children);
  }

  /**
   * Inserts the cloned children of every relationship. A lookup from one cloned child to another
   * (a sibling) is pointed at the new record, not the original. Batches go in dependency order so
   * the sibling already exists; a self reference or a cycle is inserted pointing at the original
   * and patched afterwards. A lookup to a record outside the clone set is left as it was.
   *
   * @param batches The cloned children, one batch per relationship, with their original Ids
   */
  private static void insertChildBatches(List<ChildBatch> batches) {
    if (batches == null || batches.isEmpty()) {
      return;
    }

    Set<Id> allOriginalIds = new Set<Id>();
    Set<Schema.SObjectType> includedTypes = new Set<Schema.SObjectType>();
    for (ChildBatch batch : batches) {
      allOriginalIds.addAll(batch.originalIds);
      includedTypes.add(batch.rows[0].getSObjectType());
    }
    for (ChildBatch batch : batches) {
      batch.siblingFields = findSiblingFields(batch, includedTypes);
    }

    Map<Id, Id> newIdByOriginalId = new Map<Id, Id>();
    Set<Schema.SObjectType> insertedTypes = new Set<Schema.SObjectType>();
    List<DeferredReference> deferred = new List<DeferredReference>();

    List<ChildBatch> pending = new List<ChildBatch>(batches);
    while (!pending.isEmpty()) {
      ChildBatch next = pickNextBatch(pending, insertedTypes);
      pending.remove(pending.indexOf(next));

      for (Integer i = 0; i < next.rows.size(); i++) {
        for (String fieldName : next.siblingFields) {
          Object value = next.rows[i].get(fieldName);
          if (value == null || !allOriginalIds.contains((Id) value)) {
            continue;
          }
          if (newIdByOriginalId.containsKey((Id) value)) {
            next.rows[i].put(fieldName, newIdByOriginalId.get((Id) value));
          } else {
            DeferredReference reference = new DeferredReference();
            reference.row = next.rows[i];
            reference.fieldName = fieldName;
            reference.originalSiblingId = (Id) value;
            deferred.add(reference);
          }
        }
      }

      insertRows(next.rows, next.summary.label);
      for (Integer i = 0; i < next.rows.size(); i++) {
        newIdByOriginalId.put(next.originalIds[i], next.rows[i].Id);
      }
      insertedTypes.add(next.rows[0].getSObjectType());
    }

    patchDeferredReferences(deferred, newIdByOriginalId);
  }

  /**
   * Picks a batch whose siblings are all inserted already. If none is ready the remaining batches
   * depend on each other, so the first is taken and its lookups are patched afterwards.
   *
   * @param pending Batches not inserted yet
   * @param insertedTypes Object types that already have rows in the database
   * @return The batch to insert next
   */
  private static ChildBatch pickNextBatch(
    List<ChildBatch> pending,
    Set<Schema.SObjectType> insertedTypes
  ) {
    for (ChildBatch candidate : pending) {
      Boolean ready = true;
      for (Schema.SObjectType dependency : dependencies(candidate)) {
        if (!insertedTypes.contains(dependency)) {
          ready = false;
          break;
        }
      }
      if (ready) {
        return candidate;
      }
    }
    return pending[0];
  }

  /**
   * The other child types a batch points at through its sibling lookups. A lookup to its own type
   * is not a dependency, because it can only be patched after the insert.
   *
   * @param batch The batch to inspect
   * @return Object types that should be inserted before this batch
   */
  private static Set<Schema.SObjectType> dependencies(ChildBatch batch) {
    Set<Schema.SObjectType> result = new Set<Schema.SObjectType>();
    Schema.SObjectType ownType = batch.rows[0].getSObjectType();
    Map<String, Schema.SObjectField> fieldMap = ownType.getDescribe()
      .fields.getMap();
    for (String fieldName : batch.siblingFields) {
      for (
        Schema.SObjectType target : fieldMap.get(fieldName)
          .getDescribe()
          .getReferenceTo()
      ) {
        if (target != ownType) {
          result.add(target);
        }
      }
    }
    return result;
  }

  /**
   * Finds the lookups on a child that can point at another cloned child: queried, clonable,
   * and aimed at a type that is part of this clone. The lookup back to the parent is not one.
   *
   * @param batch The batch to inspect
   * @param includedTypes Object types of all children in this clone
   * @return API names of the sibling lookup fields
   */
  private static List<String> findSiblingFields(
    ChildBatch batch,
    Set<Schema.SObjectType> includedTypes
  ) {
    List<String> result = new List<String>();
    Map<String, Schema.SObjectField> fieldMap = batch.rows[0]
      .getSObjectType()
      .getDescribe()
      .fields.getMap();
    for (String fieldName : batch.summary.filterClonableFields()) {
      Schema.SObjectField field = fieldMap.get(fieldName);
      if (
        field == null ||
        fieldName == batch.summary.parentRelationshipField ||
        field.getDescribe().getType() != Schema.DisplayType.REFERENCE
      ) {
        continue;
      }
      for (Schema.SObjectType target : field.getDescribe().getReferenceTo()) {
        if (includedTypes.contains(target)) {
          result.add(fieldName);
          break;
        }
      }
    }
    return result;
  }

  private static void patchDeferredReferences(
    List<DeferredReference> deferred,
    Map<Id, Id> newIdByOriginalId
  ) {
    if (deferred.isEmpty()) {
      return;
    }
    Map<Id, sObject> patches = new Map<Id, sObject>();
    for (DeferredReference reference : deferred) {
      Id newSiblingId = newIdByOriginalId.get(reference.originalSiblingId);
      if (newSiblingId == null) {
        continue;
      }
      sObject patch = patches.get(reference.row.Id);
      if (patch == null) {
        patch = reference.row.getSObjectType().newSObject(reference.row.Id);
        patches.put(reference.row.Id, patch);
      }
      patch.put(reference.fieldName, newSiblingId);
    }
    try {
      Database.update(patches.values(), AccessLevel.USER_MODE);
    } catch (DmlException e) {
      throw new RecordCloneException(
        buildDmlMessage('Cloned record', patches.values(), e)
      );
    } catch (System.SecurityException e) {
      throw new RecordCloneException(
        buildNotPermittedMessage('Cloned record', e)
      );
    } catch (System.TypeException e) {
      throw new RecordCloneException(
        buildNotPermittedMessage('Cloned record', e)
      );
    }
  }

  /**
   * Inserts records in user mode, so the running user's object permissions and field-level
   * security apply. A failure is reported as a RecordCloneException that names the object.
   *
   * @param rows The records to insert
   * @param label Label of the object, used when the failing row cannot be identified
   */
  private static void insertRows(List<sObject> rows, String label) {
    try {
      Database.insert(rows, AccessLevel.USER_MODE);
    } catch (DmlException e) {
      throw new RecordCloneException(buildDmlMessage(label, rows, e));
    } catch (System.SecurityException e) {
      throw new RecordCloneException(buildNotPermittedMessage(label, e));
    } catch (System.TypeException e) {
      // User mode raises a TypeException, "DML operation INSERT not allowed", when the user can
      // read the object but not create it. A SecurityException is raised when they cannot see it.
      throw new RecordCloneException(buildNotPermittedMessage(label, e));
    }
  }

  /**
   * Message for a user mode DML call the running user is not allowed to make. Salesforce raises a
   * SecurityException or a TypeException for this, not a DmlException, so it carries no per-row
   * detail.
   *
   * @param label Label of the object the user cannot write
   * @param refusal The exception thrown by the user mode DML
   * @return Message naming the object and the reason Salesforce gave
   */
  private static String buildNotPermittedMessage(
    String label,
    Exception refusal
  ) {
    return 'Clone failed. ' + label + ' - ' + refusal.getMessage();
  }

  /**
   * Builds the record to insert: a new record of the same type holding the clonable fields that
   * the original actually carries. A field that was never queried or set is left out, so the
   * platform fills its default (for example the owner). Child relationship lists on the original
   * are not copied.
   *
   * @param original The queried record to clone
   * @param summary Describes which fields can be cloned
   * @return A new, unsaved record with no Id
   */
  private static sObject copyClonableFields(
    sObject original,
    sObjectSummary summary
  ) {
    Set<String> populatedNames = new Set<String>();
    for (String populatedName : original.getPopulatedFieldsAsMap().keySet()) {
      populatedNames.add(populatedName.toLowerCase());
    }
    sObject copy = original.getSObjectType().newSObject();
    for (String fieldName : summary.filterClonableFields()) {
      if (populatedNames.contains(fieldName.toLowerCase())) {
        copy.put(fieldName, original.get(fieldName));
      }
    }
    return copy;
  }

  /**
   * Inserting an Opportunity creates an OpportunityContactRole of its own, which would duplicate
   * the role being cloned. Deletes the ones the system created. A role that cannot be deleted
   * is left in place.
   *
   * @param opportunityIds The Ids of the new Opportunity records
   */
  private static void deleteAutoCreatedContactRoles(List<Id> opportunityIds) {
    List<OpportunityContactRole> roles = [
      SELECT Id
      FROM OpportunityContactRole
      WHERE OpportunityId IN :opportunityIds
      WITH USER_MODE
    ];
    try {
      Database.delete(roles, AccessLevel.USER_MODE);
    } catch (DmlException ignored) {
      // Leaving the auto-generated role is harmless, so the clone carries on.
    } catch (System.SecurityException ignored) {
      // The user may not delete these roles. Same outcome: leave them.
    } catch (System.TypeException ignored) {
      // Raised instead of a SecurityException when the user can read but not delete.
    }
  }

  /**
   * Builds a readable message from a failed insert, naming the object, the
   * status code, the reason and the fields involved. At most three failures are
   * listed so the message still fits in a toast.
   *
   * @param fallbackLabel Label of the object to name when the failing row cannot be identified
   * @param attempted The records the insert was attempted on, used to name each failing row's object
   * @param dmlException The exception thrown by the insert
   * @return Message describing which object failed and why
   */
  @TestVisible
  private static String buildDmlMessage(
    String fallbackLabel,
    List<sObject> attempted,
    DmlException dmlException
  ) {
    Integer failureCount = dmlException.getNumDml();
    if (failureCount == 0) {
      return 'Clone failed for ' +
        fallbackLabel +
        ': ' +
        dmlException.getMessage();
    }

    Integer shownCount = Math.min(failureCount, 3);
    List<String> parts = new List<String>();
    for (Integer i = 0; i < shownCount; i++) {
      String label = fallbackLabel;
      Integer rowIndex = dmlException.getDmlIndex(i);
      if (
        attempted != null &&
        rowIndex != null &&
        rowIndex >= 0 &&
        rowIndex < attempted.size()
      ) {
        label = attempted[rowIndex].getSObjectType().getDescribe().getLabel();
      }

      String part =
        label +
        ' - [' +
        dmlException.getDmlStatusCode(i) +
        '] ' +
        dmlException.getDmlMessage(i);
      List<String> fieldNames = dmlException.getDmlFieldNames(i);
      if (fieldNames != null && !fieldNames.isEmpty()) {
        part += ' (' + String.join(fieldNames, ', ') + ')';
      }
      parts.add(part);
    }

    String message = 'Clone failed. ' + String.join(parts, '; ');
    if (failureCount > shownCount) {
      message += ' (+' + (failureCount - shownCount) + ' more)';
    }
    return message;
  }

  private static String buildChildrenSelectQuery(sObjectSummary sObjSummary) {
    // concatenate clonable field names of child sObjects to build SOQL string
    String childrenSelect = '';
    if (sObjSummary.children != null && sObjSummary.children.size() > 0) {
      for (String childRelName : sObjSummary.children.keySet()) {
        sObjectSummary child = sObjSummary.children.get(childRelName);
        List<String> childFields = child.filterClonableFields();
        if (child.isClonable && childFields.size() > 0) {
          childrenSelect +=
            ', ( SELECT Id, ' +
            String.join(childFields, ',') +
            ' FROM ' +
            childRelName +
            ' )';
        }
      }
    }
    return childrenSelect;
  }

  /**
   * Clones several records and their children, in bulk. Names of the new records and of their children
   * follow the format stored in the summary.
   *
   * @param originals The records to clone, as read by getOriginalRecords
   * @param sObjectSummary Says which fields and children can be cloned, and the name format
   * @return The new records, in the same order as the originals
   * @throws RecordCloneException When an insert fails; the message names the object and the reason
   */
  public static List<sObject> cloneRecords(
    List<sObject> originals,
    sObjectSummary sObjectSummary
  ) {
    // append to child records' name fields
    String todayStr = Datetime.now().format('yyyy/MM/dd HH:mm');

    // Insert clean copies that hold only the clonable fields. The queried originals also carry their
    // child relationship lists, and user mode DML rejects those as fields that cannot be written.
    List<sObject> clonings = new List<sObject>();
    for (sObject original : originals) {
      sObject cloning = copyClonableFields(original, sObjectSummary);
      if (sObjectSummary.isNamable) {
        // Parent record name
        // use sObject parentRecordNameFormat or specify custom record name inputted by user.
        cloning.put(
          sObjectSummary.nameField,
          clonedName(
            (String) original.get(sObjectSummary.nameField),
            sObjectSummary.childRecordNameFormat,
            todayStr
          )
        );
      }
      clonings.add(cloning);
    }

    insertRows(clonings, sObjectSummary.label);

    if (
      sObjectSummary.children != null &&
      sObjectSummary.children.keySet().size() > 0
    ) {
      // remove child record IDs, assign then cloned parent record Id to ref field
      List<ChildBatch> batches = new List<ChildBatch>();
      List<Id> opportunityIds = new List<Id>();
      for (String childRelName : sObjectSummary.children.keySet()) {
        sObjectSummary childSummary = sObjectSummary.children.get(childRelName);

        if (!childSummary.isClonable) {
          continue;
        }

        ChildBatch batch = new ChildBatch();
        batch.summary = childSummary;
        batch.nameFormat = sObjectSummary.childRecordNameFormat;
        batch.timestamp = todayStr;
        for (
          Integer parentIndex = 0; parentIndex < originals.size(); parentIndex++
        ) {
          List<sObject> children = readChildren(
            originals[parentIndex],
            childRelName
          );

          if (children == null) {
            continue;
          }

          // On creating an opportunity record, system automatically creates an OpportunityContactRole record.
          // Delete the created record as of now.
          if (
            sObjectSummary.apiName == 'Opportunity' &&
            childRelName == 'OpportunityContactRoles' &&
            sObjectSummary.isDeletable
          ) {
            opportunityIds.add(clonings[parentIndex].Id);
          }

          addPreparedChildren(batch, children, clonings[parentIndex].Id);
        }
        if (!batch.rows.isEmpty()) {
          batches.add(batch);
        }
      }

      if (!opportunityIds.isEmpty()) {
        deleteAutoCreatedContactRoles(opportunityIds);
      }

      insertChildBatches(batches);
    }

    return clonings;
  }
}
