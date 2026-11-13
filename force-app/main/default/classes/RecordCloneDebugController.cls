/*
 * Copyright (c) 2020, salesforce.com, inc.
 * All rights reserved.
 * SPDX-License-Identifier: BSD-3-Clause
 * For full license text, see LICENSE.txt file in the repo root or https://opensource.org/licenses/BSD-3-Clause
 */
/**
 * Supports the Record Clone configuration helper, which lists the child relationships an object has
 * so an admin can choose which to clone.
 */
public with sharing class RecordCloneDebugController {
  /**
   * The child relationships of one object, by relationship name, with the label of each child object.
   */
  public with sharing class RecordCloneDebugSummary {
    @AuraEnabled
    public String objectName;
    @AuraEnabled
    public Map<String, String> relations;

    private RecordCloneDebugSummary(
      String objectName,
      Map<String, String> relations
    ) {
      this.objectName = objectName;
      this.relations = relations;
    }
  }

  @AuraEnabled(cacheable=true)
  /**
   * Lists every child relationship of an object. The object is the one named, or, if no name is given,
   * the object of the record.
   *
   * @param recordId The Id of a record of the object, used when no object name is given
   * @param objectName The API name of the object, or blank to use the record's object
   * @return The relationships, or null when neither a record nor a valid object name is given
   */
  public static RecordCloneDebugSummary showAllChildRelationships(
    Id recordId,
    String objectName
  ) {
    if (String.isBlank(objectName)) {
      if (String.isBlank(recordId)) {
        return null;
      }
      DescribeSObjectResult describe = recordId.getSObjectType().getDescribe();
      objectName = describe.getLocalName();
    }
    Map<String, String> result = new Map<String, String>();
    sObjectType sObjType = (sObjectType) Schema.getGlobalDescribe()
      .get(objectName);
    if (sObjType == null) {
      return null;
    }
    for (
      Schema.ChildRelationship rel : sObjType.getDescribe()
        .getChildRelationships()
    ) {
      if (String.isBlank(rel.getRelationshipName())) {
        continue;
      }
      result.put(
        rel.getRelationshipName(),
        rel.getChildSObject().getDescribe().getLabel()
      );
    }
    RecordCloneDebugSummary summary = new RecordCloneDebugSummary(
      objectName,
      result
    );

    return summary;
  }
}
