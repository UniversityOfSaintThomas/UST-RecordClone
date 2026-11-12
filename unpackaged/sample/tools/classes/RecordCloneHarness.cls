/**
 * Dev-org tool, not packaged. Runs RecordClone against the sample dataset (datasets/dev) and reports
 * what happens, so changes to RecordClone can be checked against realistic failures (ECRMSF-5087).
 *
 * Every case runs inside a savepoint that is rolled back, so the dataset is never changed.
 *
 * Usage (full report in the debug log):
 *   sf apex run --file scripts/run_clone_harness.apex --target-org <alias>
 * Usage (pass/fail only, because cci does not print debug logs):
 *   cci task run run_clone_harness --org dev
 *
 * Options, comma separated: strict (throw when a case does not behave as expected),
 * single (only single-record cases), bulk (only multi-record cases).
 *
 * Each case has an expected outcome. "Expected" is what a correct RecordClone should do, so a case
 * that cannot succeed by design (a required unique field the clone has to drop) expects an error.
 * Findings are data-quality problems on clones that did succeed; they are reported, not failed.
 */
public with sharing class RecordCloneHarness {
  public class HarnessException extends Exception {
  }

  private static final String standardChildren = 'Requirement_Responses__r,Question_Responses__r,Awards__r,Opportunities__r';
  private static final String withAuditChildren =
    standardChildren + ',Audit_Entries__r';
  private static final String nameOriginal = RecordCloneChildRecordNamePicklist.valueOriginalName;
  private static final String nameWithDate = RecordCloneChildRecordNamePicklist.valueWithClonedAndDate;

  private static final String ok = 'OK';
  private static final String error = 'ERROR';

  // Stop before the 100 query limit so a case is never cut off halfway
  private static final Integer queryBudget = 70;

  private static void stoppedEarly(String nextKey) {
    mismatches.add(
      'stoppedEarly before ' +
      nextKey +
      ': SOQL budget spent, run with part=1 to part=4'
    );
    log(
      'FAIL stoppedEarly before ' +
      nextKey +
      ' (SOQL budget spent, use part=N)'
    );
  }

  private class CaseDefinition {
    private String key;
    private String scenario;
    private String children;
    private String excluded;
    private String nameType;
    private String expectedOutcome;
    private String expectedReason;

    private CaseDefinition(
      String key,
      String scenario,
      String children,
      String excluded,
      String nameType,
      String expectedOutcome,
      String expectedReason
    ) {
      this.key = key;
      this.scenario = scenario;
      this.children = children;
      this.excluded = excluded;
      this.nameType = nameType;
      this.expectedOutcome = expectedOutcome;
      this.expectedReason = expectedReason;
    }
  }

  @TestVisible
  private static List<String> mismatches = new List<String>();
  @TestVisible
  private static Map<String, Integer> findingTotals = new Map<String, Integer>();
  @TestVisible
  private static Integer matched = 0;

  /**
   * Runs the harness.
   *
   * Anonymous Apex allows 100 SOQL queries per run and a rollback does not give them back, so the
   * cases are split into parts. part=1 to part=3 are single-record cases, part=4 is the multi-record
   * (Flow) path. With no part, everything runs and stops early, saying so, if the query budget is
   * nearly spent. scripts/run_clone_harness.sh runs every part for the full report.
   *
   * @param options Comma separated options: strict, part=N, single, bulk. Anything else is ignored.
   */
  public static void run(String options) {
    Set<String> tokens = new Set<String>();
    Integer part = null;
    if (String.isNotBlank(options)) {
      for (String token : options.toLowerCase().split(',')) {
        String trimmed = token.trim();
        tokens.add(trimmed);
        if (
          trimmed.startsWith('part=') && trimmed.substringAfter('=').isNumeric()
        ) {
          part = Integer.valueOf(trimmed.substringAfter('='));
        }
      }
    }
    Boolean strict = tokens.contains('strict');
    Boolean runSingle = !tokens.contains('bulk') && (part == null || part <= 3);
    Boolean runBulk = !tokens.contains('single') && (part == null || part == 4);

    if (runSingle) {
      List<CaseDefinition> cases = singleCases();
      Integer first = 0;
      Integer last = cases.size() - 1;
      if (part == 1) {
        last = 3;
      } else if (part == 2) {
        first = 4;
        last = 7;
      } else if (part == 3) {
        first = 8;
      }
      for (Integer i = first; i <= last; i++) {
        if (Limits.getQueries() > queryBudget) {
          stoppedEarly(cases[i].key);
          break;
        }
        runSingleCase(cases[i]);
      }
    }
    if (runBulk && Limits.getQueries() <= queryBudget) {
      runBulkCases();
    } else if (runBulk) {
      stoppedEarly('bulk');
    }

    log(
      'SUMMARY matched=' +
      matched +
      ' unexpected=' +
      mismatches.size() +
      ' findingTypes=' +
      findingTotals.size()
    );
    for (String code : findingTotals.keySet()) {
      log('SUMMARY finding ' + code + ' x' + findingTotals.get(code));
    }

    if (strict && !mismatches.isEmpty()) {
      throw new HarnessException(
        mismatches.size() +
        ' unexpected: ' +
        String.join(mismatches, ' || ')
      );
    }
  }

  private static List<CaseDefinition> singleCases() {
    return new List<CaseDefinition>{
      new CaseDefinition(
        'clean',
        'Clean application with every child type',
        standardChildren,
        '',
        nameWithDate,
        ok,
        null
      ),
      new CaseDefinition(
        'minimal',
        'Minimal application with no children',
        standardChildren,
        '',
        nameOriginal,
        ok,
        null
      ),
      new CaseDefinition(
        'noTerm',
        'Application with no term',
        standardChildren,
        '',
        nameOriginal,
        ok,
        null
      ),
      new CaseDefinition(
        'awardsOnly',
        'Application with awards only',
        standardChildren,
        '',
        nameOriginal,
        ok,
        null
      ),
      new CaseDefinition(
        'auditNotIncluded',
        'Application with audit trail (required unique child field)',
        standardChildren,
        '',
        nameOriginal,
        ok,
        null
      ),
      new CaseDefinition(
        'auditIncluded',
        'Application with audit trail (required unique child field)',
        withAuditChildren,
        '',
        nameOriginal,
        ok,
        null
      ),
      new CaseDefinition(
        'withdrawn',
        'Withdrawn application with responses (armed after load)',
        standardChildren,
        '',
        nameOriginal,
        error,
        'Sample Requirement Response'
      ),
      new CaseDefinition(
        'withdrawnStatusExcluded',
        'Withdrawn application with responses (armed after load)',
        standardChildren,
        'Status__c',
        nameOriginal,
        ok,
        null
      ),
      new CaseDefinition(
        'retiredTerm',
        'Application on a retired term (armed after load)',
        standardChildren,
        '',
        nameOriginal,
        error,
        'FIELD_FILTER_VALIDATION_EXCEPTION'
      ),
      new CaseDefinition(
        'retiredTermExcluded',
        'Application on a retired term (armed after load)',
        standardChildren,
        'Term__c',
        nameOriginal,
        ok,
        null
      ),
      new CaseDefinition(
        'longChildNameOriginal',
        'Child record name near the 120 character limit',
        standardChildren,
        '',
        nameOriginal,
        ok,
        null
      ),
      new CaseDefinition(
        'longChildNameDated',
        'Child record name near the 120 character limit',
        standardChildren,
        '',
        nameWithDate,
        error,
        'STRING_TOO_LONG'
      ),
      new CaseDefinition(
        'bulkChildren',
        'Bulk application with 120 requirement and 120 question responses',
        standardChildren,
        '',
        nameOriginal,
        ok,
        null
      )
    };
  }

  private static void runSingleCase(CaseDefinition definition) {
    String scenarioName = definition.scenario;
    List<Sample_Application__c> originals = [
      SELECT Id, Name
      FROM Sample_Application__c
      WHERE Scenario__c = :scenarioName
      LIMIT 1
    ];
    if (originals.isEmpty()) {
      record(
        definition.key,
        false,
        'no sample application for scenario "' +
        scenarioName +
        '" (is the dataset loaded?)'
      );
      return;
    }
    Sample_Application__c original = originals[0];

    Savepoint beforeCase = Database.setSavepoint();
    String outcome;
    String message = '';
    List<String> findings = new List<String>();
    try {
      sObject cloned = cloneSingle(
        original.Id,
        'Clone of ' + original.Name,
        definition.children,
        definition.excluded,
        definition.nameType
      );
      if (cloned == null) {
        outcome = error;
        message = 'returned null with no reason';
      } else {
        outcome = ok;
        findings = inspect(original.Id, cloned.Id, definition.children);
      }
    } catch (Exception e) {
      outcome = error;
      message = e.getTypeName() + ': ' + e.getMessage();
    }
    Database.rollback(beforeCase);

    Boolean outcomeMatches = outcome == definition.expectedOutcome;
    Boolean reasonMatches =
      definition.expectedReason == null ||
      message.contains(definition.expectedReason);
    String detail = 'expected=' + definition.expectedOutcome;
    if (definition.expectedReason != null) {
      detail += '(' + definition.expectedReason + ')';
    }
    detail += ' actual=' + outcome;
    if (String.isNotBlank(message)) {
      detail += ' message=' + message.abbreviate(300);
    }
    record(definition.key, outcomeMatches && reasonMatches, detail);
    for (String finding : findings) {
      recordFinding(definition.key, finding);
    }
  }

  /**
   * Does what RecordCloneController.execClone does, without its AuraHandledException wrapper.
   * execClone cannot be called from anonymous Apex: throwing AuraHandledException outside an Aura
   * or Visualforce context raises a LimitException that cannot be caught. The wrapper's message
   * handling is covered by RecordCloneTest instead.
   *
   * @param recordId The record to clone
   * @param newParentRecordName Name for the new parent record
   * @param childRelationshipNames Comma separated child relationship names
   * @param excludedFieldNames Comma separated field names to leave blank on the clone
   * @param childRecordNameType Child name format value
   * @return The cloned record, or null when RecordClone returns nothing
   */
  private static sObject cloneSingle(
    Id recordId,
    String newParentRecordName,
    String childRelationshipNames,
    String excludedFieldNames,
    String childRecordNameType
  ) {
    sObjectSummary summary = sObjectSummary.getByRecordId(
      recordId,
      childRelationshipNames,
      excludedFieldNames
    );
    sObject originalRecord = RecordCloneHandler.getOriginalRecord(
      recordId,
      summary
    );
    if (originalRecord == null) {
      return null;
    }
    return RecordCloneHandler.cloneRecord(
      originalRecord,
      summary,
      newParentRecordName,
      childRecordNameType
    );
  }

  /**
   * A child that can never be inserted must say so up front instead of failing every clone. The
   * audit entry has a required unique key that a clone has to leave out.
   */
  private static void checkConfigurationReportsUnclonableChild() {
    List<Sample_Application__c> originals = [
      SELECT Id
      FROM Sample_Application__c
      WHERE
        Scenario__c = 'Application with audit trail (required unique child field)'
      LIMIT 1
    ];
    if (originals.isEmpty()) {
      record('auditChildReportedNotClonable', false, 'no sample application');
      return;
    }
    sObjectSummary summary = sObjectSummary.getByRecordId(
      originals[0].Id,
      withAuditChildren,
      ''
    );
    sObjectSummary audit = summary.children.get('Audit_Entries__r');
    sObjectSummary requirement = summary.children.get(
      'Requirement_Responses__r'
    );
    Boolean reported =
      audit != null &&
      !audit.isClonable &&
      audit.errorMessage.contains('REQUIRED_FIELD_NOT_CLONABLE') &&
      audit.errorMessage.contains('Entry_Key__c');
    record(
      'auditChildReportedNotClonable',
      reported &&
      requirement != null &&
      requirement.isClonable,
      'expected=not clonable(REQUIRED_FIELD_NOT_CLONABLE Entry_Key__c) actual=' +
      (audit == null ? 'missing' : audit.isClonable + ' ' + audit.errorMessage)
    );
  }

  private static void runBulkCases() {
    checkConfigurationReportsUnclonableChild();

    List<Id> passingIds = new List<Id>(
      new Map<Id, Sample_Application__c>(
          [
            SELECT Id
            FROM Sample_Application__c
            WHERE Expected_Outcome__c = 'PASS'
          ]
        )
        .keySet()
    );
    Integer originalChildren = [
      SELECT COUNT()
      FROM Sample_Requirement_Response__c
      WHERE Application__c IN :passingIds
    ];

    // Multi-record path with the custom metadata record for Sample_Application__c. It excludes Status__c.
    Savepoint beforeBulk = Database.setSavepoint();
    try {
      List<List<Id>> result = RecordCloneController.clone(
        new List<List<Id>>{ passingIds }
      );
      List<Id> clonedIds = result[0];
      Integer clonedChildren = [
        SELECT COUNT()
        FROM Sample_Requirement_Response__c
        WHERE Application__c IN :clonedIds
      ];
      Integer prefixed = [
        SELECT COUNT()
        FROM Sample_Requirement_Response__c
        WHERE Application__c IN :clonedIds AND Name LIKE 'Cloned - %'
      ];
      Integer duplicateExternalIds = [
          SELECT External_Id__c
          FROM Sample_Application__c
          WHERE External_Id__c != NULL
          GROUP BY External_Id__c
          HAVING COUNT(Id) > 1
        ]
        .size();
      Boolean countsMatch =
        clonedIds.size() == passingIds.size() &&
        clonedChildren == originalChildren;
      record(
        'bulkAllPassing',
        countsMatch,
        'applications ' +
        clonedIds.size() +
        '/' +
        passingIds.size() +
        ' requirementResponses ' +
        clonedChildren +
        '/' +
        originalChildren
      );
      if (duplicateExternalIds > 0) {
        recordFinding(
          'bulkAllPassing',
          'EXTERNAL_ID_COPIED Sample_Application__c.External_Id__c now shared by ' +
          duplicateExternalIds +
          ' groups'
        );
      }
      if (clonedChildren > 0 && prefixed == 0) {
        recordFinding(
          'bulkAllPassing',
          'CHILD_NAME_FORMAT_IGNORED custom metadata asks for "Cloned - " but 0 of ' +
          clonedChildren +
          ' child names have it'
        );
      }
    } catch (Exception e) {
      record(
        'bulkAllPassing',
        false,
        'expected=OK actual=ERROR message=' +
        (e.getTypeName() + ': ' + e.getMessage()).abbreviate(300)
      );
    }
    Database.rollback(beforeBulk);

    // One bad record in the batch fails the whole batch, and says why.
    List<Sample_Application__c> retired = [
      SELECT Id
      FROM Sample_Application__c
      WHERE Scenario__c = 'Application on a retired term (armed after load)'
      LIMIT 1
    ];
    if (!retired.isEmpty()) {
      Savepoint beforeMixed = Database.setSavepoint();
      String outcome = ok;
      String message = '';
      try {
        RecordCloneController.clone(
          new List<List<Id>>{ new List<Id>{ passingIds[0], retired[0].Id } }
        );
      } catch (Exception e) {
        outcome = error;
        message = e.getTypeName() + ': ' + e.getMessage();
      }
      Database.rollback(beforeMixed);
      record(
        'bulkWithRetiredTerm',
        outcome == error &&
        message.contains('FIELD_FILTER_VALIDATION_EXCEPTION'),
        'expected=ERROR(FIELD_FILTER_VALIDATION_EXCEPTION) actual=' +
        outcome +
        ' message=' +
        message.abbreviate(300)
      );
    }
  }

  /**
   * Checks the quality of a clone that succeeded, using describe so it works for any child.
   * Reports external IDs that were copied, sibling references that still point at the original
   * record set, and child counts that differ.
   *
   * @param originalId The application that was cloned
   * @param clonedId The new application
   * @param childRelationships Comma separated child relationship names used for the clone
   * @return Finding codes with detail, empty when the clone looks right
   */
  private static List<String> inspect(
    Id originalId,
    Id clonedId,
    String childRelationships
  ) {
    List<String> findings = new List<String>();
    Set<String> included = new Set<String>(
      childRelationships.deleteWhitespace().split(',')
    );

    // Parent external IDs
    Schema.DescribeSObjectResult parentDescribe = Sample_Application__c.sObjectType.getDescribe();
    List<String> parentExternalIds = externalIdFields(parentDescribe);
    if (!parentExternalIds.isEmpty()) {
      String parentQuery =
        'SELECT Id, ' +
        String.join(parentExternalIds, ',') +
        ' FROM Sample_Application__c WHERE Id = :originalId OR Id = :clonedId';
      Map<Id, sObject> parents = new Map<Id, sObject>(
        Database.query(parentQuery)
      );
      for (String field : parentExternalIds) {
        Object originalValue = parents.get(originalId).get(field);
        if (
          originalValue != null &&
          originalValue == parents.get(clonedId).get(field)
        ) {
          findings.add(
            'EXTERNAL_ID_COPIED Sample_Application__c.' +
            field +
            '=' +
            originalValue
          );
        }
      }
    }

    // Collect the child relationships that were part of the clone and are clonable. A relationship
    // reported as not clonable is skipped on purpose, so it is not a count difference.
    sObjectSummary cloneSummary = sObjectSummary.getByRecordId(
      originalId,
      childRelationships,
      ''
    );
    Map<String, Schema.ChildRelationship> relationships = new Map<String, Schema.ChildRelationship>();
    for (
      Schema.ChildRelationship relationship : parentDescribe.getChildRelationships()
    ) {
      String relationshipName = relationship.getRelationshipName();
      if (
        relationshipName != null &&
        included.contains(relationshipName) &&
        cloneSummary.children.get(relationshipName).isClonable
      ) {
        relationships.put(relationshipName, relationship);
      }
    }
    Set<Schema.SObjectType> siblingTypes = new Set<Schema.SObjectType>();
    for (Schema.ChildRelationship relationship : relationships.values()) {
      siblingTypes.add(relationship.getChildSObject());
    }

    Map<String, List<sObject>> originalRows = new Map<String, List<sObject>>();
    Map<String, List<sObject>> clonedRows = new Map<String, List<sObject>>();
    Set<Id> originalChildIds = new Set<Id>();
    for (String relName : relationships.keySet()) {
      Schema.ChildRelationship relationship = relationships.get(relName);
      Schema.DescribeSObjectResult childDescribe = relationship.getChildSObject()
        .getDescribe();
      String parentField = relationship.getField().getDescribe().getName();
      Set<String> wanted = new Set<String>{ 'Id' };
      wanted.addAll(externalIdFields(childDescribe));
      wanted.addAll(referenceFields(childDescribe, siblingTypes));
      String baseQuery =
        'SELECT ' +
        parentField +
        ',' +
        String.join(new List<String>(wanted), ',') +
        ' FROM ' +
        childDescribe.getName() +
        ' WHERE ' +
        parentField +
        ' IN (:originalId, :clonedId)';
      List<sObject> originalSide = new List<sObject>();
      List<sObject> clonedSide = new List<sObject>();
      for (sObject row : Database.query(baseQuery)) {
        if ((Id) row.get(parentField) == originalId) {
          originalSide.add(row);
        } else {
          clonedSide.add(row);
        }
      }
      originalRows.put(relName, originalSide);
      clonedRows.put(relName, clonedSide);
      for (sObject row : originalSide) {
        originalChildIds.add(row.Id);
      }
    }

    for (String relName : relationships.keySet()) {
      Schema.DescribeSObjectResult childDescribe = relationships.get(relName)
        .getChildSObject()
        .getDescribe();
      List<sObject> before = originalRows.get(relName);
      List<sObject> after = clonedRows.get(relName);
      if (before.size() != after.size()) {
        findings.add(
          'CHILD_COUNT_DIFFERS ' +
          relName +
          ' original=' +
          before.size() +
          ' cloned=' +
          after.size()
        );
      }

      for (String field : externalIdFields(childDescribe)) {
        Set<Object> originalValues = new Set<Object>();
        for (sObject row : before) {
          if (row.get(field) != null) {
            originalValues.add(row.get(field));
          }
        }
        Integer copied = 0;
        for (sObject row : after) {
          if (originalValues.contains(row.get(field))) {
            copied++;
          }
        }
        if (copied > 0) {
          findings.add(
            'EXTERNAL_ID_COPIED ' +
            childDescribe.getName() +
            '.' +
            field +
            ' ' +
            copied +
            ' of ' +
            after.size()
          );
        }
      }

      for (String field : referenceFields(childDescribe, siblingTypes)) {
        Integer stale = 0;
        for (sObject row : after) {
          Object value = row.get(field);
          if (value != null && originalChildIds.contains((Id) value)) {
            stale++;
          }
        }
        if (stale > 0) {
          findings.add(
            'SIBLING_REFERENCE_NOT_REMAPPED ' +
            childDescribe.getName() +
            '.' +
            field +
            ' ' +
            stale +
            ' of ' +
            after.size() +
            ' still point at the original records'
          );
        }
      }
    }
    return findings;
  }

  private static List<String> externalIdFields(
    Schema.DescribeSObjectResult describe
  ) {
    List<String> fields = new List<String>();
    for (Schema.SObjectField field : describe.fields.getMap().values()) {
      Schema.DescribeFieldResult fieldDescribe = field.getDescribe();
      if (
        fieldDescribe.isExternalId() &&
        fieldDescribe.isCreateable() &&
        !fieldDescribe.isUnique()
      ) {
        fields.add(fieldDescribe.getName());
      }
    }
    return fields;
  }

  private static List<String> referenceFields(
    Schema.DescribeSObjectResult describe,
    Set<Schema.SObjectType> targetTypes
  ) {
    List<String> fields = new List<String>();
    for (Schema.SObjectField field : describe.fields.getMap().values()) {
      Schema.DescribeFieldResult fieldDescribe = field.getDescribe();
      if (
        fieldDescribe.getType() == Schema.DisplayType.REFERENCE &&
        fieldDescribe.isCustom() &&
        targetTypes.contains(fieldDescribe.getReferenceTo()[0])
      ) {
        fields.add(fieldDescribe.getName());
      }
    }
    return fields;
  }

  private static void record(String key, Boolean isExpected, String detail) {
    if (isExpected) {
      matched++;
      log('PASS ' + key + ' ' + detail);
    } else {
      mismatches.add(key + ' ' + detail);
      log('FAIL ' + key + ' ' + detail);
    }
  }

  private static void recordFinding(String key, String finding) {
    String code = finding.substringBefore(' ');
    findingTotals.put(
      code,
      (findingTotals.containsKey(code) ? findingTotals.get(code) : 0) + 1
    );
    log('FINDING ' + key + ' ' + finding);
  }

  private static void log(String line) {
    System.debug('HARNESS ' + line);
  }
}
