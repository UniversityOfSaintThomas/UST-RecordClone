# RecordClone Bug Fix Plan (ECRMSF-5087)

**Related Jira:** [ECRMSF-5087](https://stthomas.atlassian.net/browse/ECRMSF-5087) — Automated Deferral Process - Between Academic Years (Fall to Fall, Spring to Fall)

## Background

ECRMSF-5087 requests an automation to clone an Application and all related objects
(Opportunity, Requirement Response, Question Responses, Award, etc.) to a new term
for deferral requests. During discussion, the CRM team investigated using this
repo's RecordClone component to solve it, and found bugs that make it unreliable
for this use case. Comment discussion (paraphrased):

- Farrah Friedrich: "we think this actually might be a configuration we can do in
  Record Clone."
- Shayna Stockton: "Found the issue, it is with non child records, they cause a
  record clone error even though they look like they can be cloned on the
  configuration. I vaguely recall this being an issue when we set up the record
  clone but we didn't really need the question responses so decided to move
  forward without them at the time."
- Shayna Stockton: "We should in theory be able to get a record and create a
  duplicate of it in flow, but I think we'll need to do that for each object
  individually." (i.e. considering abandoning RecordClone for a hand-rolled Flow
  solution)
- Shayna Stockton: "Note: exclude external ids from any clone function"
- Shayna Stockton: "Possible solution: Pull and update RecordClone code to fix
  bugs"

This document investigates the RecordClone codebase to ground those comments in
concrete, fixable root causes, as an alternative to abandoning RecordClone for a
hand-built Flow solution.

## Root Cause Analysis

### Bug 1 — Silent DML failure swallowing (explains "look clonable but error")

- `RecordCloneHandler.cloneRecord()` catches `DMLException` and just
  `return null;` — no message, no field/row detail is captured anywhere.
- `RecordCloneController.execClone()` returns that `null` straight to the LWC.
- `recordClone.js` (`onclickClone`) turns any falsy result into a hardcoded
  `"No Data"` error toast — the real DML failure reason is never seen by the user
  or logged anywhere retrievable.
- **Root cause:** `sObjectSummary`'s "clonable" check (used to build the
  configuration UI) is purely describe-based — it checks `isAccessible()`,
  `isCreateable()`, `isUnique()`, `isCalculated()`, BASE64 type, etc. It cannot
  see _runtime_ failures such as validation rules, required-but-blank lookups
  after re-parenting, or record-type/business-process mismatches. A field or
  child relationship can pass every describe-time check and still fail on the
  actual `insert`, and the user gets zero diagnostic info — exactly matching
  "look like they can be cloned on the configuration" but error at clone time.

  Relevant code (`RecordCloneHandler.cls`):

  ```apex
  try {
    insert cloned;
  } catch (DMLException e) {
    return null;
  }
  ```

### Bug 2 — No external ID exclusion (explains "exclude external ids")

- `sObjectSummary.sFieldSummary` checks `dfr.isUnique()` but never
  `dfr.isExternalId()`. An external ID field that is not _also_ flagged unique
  passes every check and is copied to the new record.
- For objects synced to Banner via external ID (Application, Opportunity,
  Requirement Response, Question Responses per the ticket's "Required Objects to
  be Cloned" list), copying the external ID forward risks duplicate/colliding
  external keys on insert, or a wrong match on the next Banner sync.
- No code anywhere in the repo currently references `isExternalId()`.

### Bug 3 — No reference/lookup field validation (likely explains "non child records")

- No code anywhere checks `dfr.getType() == Schema.DisplayType.REFERENCE` or
  `getReferenceTo()`. Any lookup field on a cloned parent or child object —
  including lookups to a _sibling_ record that is not itself part of the clone
  operation (e.g. a Question/Requirement _definition_ record referenced by a
  Question/Requirement _Response_ record) — is blindly copied over unfiltered.
- If that reference is invalid or has different validation requirements in the
  new term's context, the `insert` fails (and is swallowed by Bug 1), or worse,
  succeeds while pointing at data that is semantically wrong for the new term.

### Bug 4 — Child relationship matching is name-only, no structural validation

- `sObjectSummary.getChildren()` matches child relationships purely by
  relationship name from the comma-separated `ChildRelationshipNames__c` custom
  metadata field, with no check on whether that relationship is a genuine
  "child" in the cloning sense versus a shared/junction-style lookup.
- Combined with Bug 3, this is the most likely mechanism behind "non child
  records ... cause a record clone error" — a relationship was added to the
  config that isn't a true parent-child relationship, and nothing in the code
  detects or flags that at configuration time.

## Proposed Fix Plan

1. **Add real error propagation (prerequisite for diagnosing the rest)**

   - Replace `catch (DMLException e) { return null; }` in
     `RecordCloneHandler.cloneRecord()` / `cloneRecords()` with a wrapper that
     captures `e.getDmlMessage(0)` and `e.getStatusCode(0)`.
   - Change `RecordCloneController.execClone()` to throw an
     `AuraHandledException` carrying the real message instead of returning
     `null`.
   - Update `recordClone.js` (`handleErrors` / `onclickClone`) to render the
     actual DML error instead of the generic `"No Data"` message.
   - This is a prerequisite: it turns "clone silently fails" into "clone fails
     with an actual reason," which is required to verify fixes 2–4 against real
     org behavior instead of guessing blind.

2. **Exclude external ID fields from cloning**

   - In `sObjectSummary.sFieldSummary`, add:
     ```apex
     if (dfr.isExternalId()) {
       errors.add('IS_EXTERNAL_ID');
     }
     ```
   - Verify against the org which fields on Application, Opportunity, Question
     Response, and Requirement Response are actually external-ID-flagged, to
     confirm this resolves the reported symptom (or surfaces a new, now-visible
     error via Fix #1).

3. **Add reference/lookup field classification**

   - In `sFieldSummary`, detect `dfr.getType() == Schema.DisplayType.REFERENCE`.
   - For each reference field, classify whether its target is:
     - (a) the object being cloned/re-parented — keep, remap to the new parent's
       Id (this already happens implicitly for the direct parent relationship
       field via `childSummary.parentRelationshipField`, but not for _other_
       lookups on the same record);
     - (b) a genuinely shared reference that should carry over unchanged (e.g. a
       lookup to a static reference/definition record) — keep as-is;
     - (c) something invalid post-clone — exclude, with a clear reason string
       surfaced in the config UI's existing "excluded fields" list (e.g.
       `IS_UNVALIDATED_REFERENCE`).
   - This classification needs the actual Question Response / Requirement
     Response schema from the org — cannot be finalized from static code
     analysis alone. Depends on the Enterprise team's object/field list (see
     Dependencies below).

4. **Validate "non-child" relationships before allowing them in config**

   - In `sObjectSummary.getChildren()`, when resolving
     `childRelationshipNames`, flag or reject relationships where the child's
     lookup back to the parent is not clearly the primary/expected relationship,
     so a bad configuration fails fast in the configurator UI rather than
     silently at clone time with an opaque error.

5. **Regression tests**
   - Add cases to `RecordCloneTest.cls` / `RecordCloneHandlerTest.cls` covering:
     - external ID field exclusion (Fix #2),
     - reference-field exclusion/classification (Fix #3),
     - a DML failure surfacing a real message instead of `null` (Fix #1).
   - Reproduce the actual ECRMSF-5087 scenario in a sandbox: one real
     Application + Opportunity + Question Response + Requirement Response record
     set, attempt clone with current (unfixed) code to confirm the exact
     swallowed error live via Fix #1's new error surfacing, then confirm Fixes
     #2–#4 resolve it.

## Dependencies

- **Blocking:** Maddy Wrobel's comment on ECRMSF-5087 references a separate
  ticket submitted to the Enterprise team to get the definitive object/field
  list required for Banner integration cloning
  ([TDX ticket](https://services.stthomas.edu/TDClient/1898/ClientPortal/Requests/TicketRequests/TicketDet?TicketID=e-y9g2Yae9sf3VARFhldeA__)).
  That answer is required to correctly scope Fix #3 (which reference fields must
  be kept vs. excluded) — this should not be guessed around.

## Decision Point

This plan is an alternative to the "build it in Flow per-object instead" approach
Shayna Stockton floated in the comments. Recommendation: fix RecordClone rather
than hand-roll a parallel per-object Flow solution, because:

- The bugs found are narrow and mechanical (missing `isExternalId()` check,
  missing reference-field handling, swallowed exceptions) rather than
  architectural — RecordClone's core describe-driven, configuration-based design
  is otherwise sound and already handles bulk child cloning generically.
- A hand-rolled per-object Flow solution would need to reimplement equivalent
  logic (name-field handling, child re-parenting, exclusion rules) per object,
  multiplying maintenance surface for the same underlying problem.

## Implementation Status (updated 2026-11-12)

### Sample data and harness

The root causes below were checked against a sample dataset instead of guessed. It lives outside
`force-app`, so it is never packaged, and `dev_org` builds it automatically.

| What                                                                   | Where                                              |
| ---------------------------------------------------------------------- | -------------------------------------------------- |
| Sample objects, fields, validation rule, lookup filter, permission set | `unpackaged/sample/model`                          |
| Harness class and its test (dev orgs only)                             | `unpackaged/sample/tools`                          |
| Snowfakery dataset (49 applications, ~540 rows)                        | `datasets/dev/dev.recipe.yml`                      |
| Step that breaks two scenarios after the load                          | `scripts/arm_sample_clone_failures.apex`           |
| Full harness report, one file per part                                 | `scripts/clone_harness/part1.apex` to `part4.apex` |

CumulusCI tasks and flows (all in `cumulusci.yml`):

- `cci flow run sample_data --org dev` adds the sample data to an existing dev org.
- `cci flow run check_clone_harness --org dev` is the pass/fail gate; it fails and names the case that misbehaved.
- `dev_org` includes all of it through `config_dev`. A fresh scratch org built with `dev_org` alone reproduces the results.
- Full report: `sf apex run --file scripts/clone_harness/part1.apex --target-org <alias>`, then parts 2 to 4. `cci` does not print debug logs, which is why the report is separate. One run is limited to 100 SOQL queries, hence four parts.

The sample objects are a stand-in. They have the same shape as the Banner objects (shared definition
lookups, sibling lookups, external IDs, a standard Opportunity), not the same schema. They show which
classes of problem RecordClone mishandles. They cannot say which fields on the real objects need
attention; that still needs the Enterprise team's list.

### Findings that change the root-cause analysis

- **Bug 1 was larger than described.** Only the parent `insert` was caught. Child inserts, and every insert on the Flow path, threw an uncaught `DmlException`. The LWC read only `fieldErrors` and `pageErrors`, so a thrown Apex error produced an empty toast. The "No Data" text was never shown either; users saw "Unknown error".
- **Bug 2 confirmed.** A non-unique external ID was copied on the parent and on every child type (19 findings across the harness).
- **Bug 3 is two different problems.**
  - Lookups to shared definition records (a question or requirement) carry over correctly. Nothing to fix.
  - A lookup to a _sibling_ record in the same clone (Question Response to Requirement Response) is copied unchanged, so the clone points at the original application's record. No error is raised. 120 of 120 on the bulk case.
- **Bug 4 refined.** The configurator lists every relationship pointing at the object, plain lookups included. A child object with a required field the clone must drop (a required unique field) is shown as clonable but can never be inserted.
- **Not in the original plan:** on the Flow path the child-name format from custom metadata is ignored (`sObjectSummary.getByRecordId(Id)` has an inverted null check). Child objects also ignore `ExcludedFieldNames__c`.

### Fix status

| Fix                                                 | Status                                                                                                                                                                                                                                                                                                            |
| --------------------------------------------------- | ----------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| 1. Error propagation                                | Done (`983fb2a`). Message names the object, status code, reason and fields. A failed clone rolls back.                                                                                                                                                                                                            |
| 2. Exclude external IDs                             | Done. `IS_EXTERNAL_ID` added in `sObjectSummary`. Harness findings for it: 19 to 0.                                                                                                                                                                                                                               |
| 3. Sibling reference remap                          | Done. Children are inserted in dependency order and a lookup to another cloned child is pointed at the new record. Self-references and cycles are patched with one update after the inserts. Works on the single-record and Flow paths. Lookups to records outside the clone (shared definitions) are left alone. |
| 4. Config-time check for children that cannot clone | Done. A child with a required field the clone must drop is shown as not clonable with `REQUIRED_FIELD_NOT_CLONABLE(Field)`, and the clone skips it instead of failing.                                                                                                                                            |
| Child name format (inverted null check)             | Done. The Flow path now uses the format stored on the settings record.                                                                                                                                                                                                                                            |

Every fix was checked by breaking it on purpose: the sample-data tests and the harness each fail with a clear message
when the fix is removed. The same checks pass on a fresh scratch org built with `dev_org` alone.

### Browser check (scratch org)

The sample application record page (`Sample_Application_Record_Page`) shows the RecordClone component. Checked in a
real browser:

- A clean application clones, navigates to the new record, and shows the success toast. The clone has 2 requirement
  responses, 2 question responses (each pointing at a requirement response under the **new** application), 1 award and
  1 opportunity, and blank external IDs.
- An application on a retired term shows the full reason in the error toast: `Clone failed. Sample Application - [FIELD_FILTER_VALIDATION_EXCEPTION] The term must be active. (Term__c)`. No partial clone was left behind.
- The details panel lists the audit-entry child as not clonable (`REQUIRED_FIELD_NOT_CLONABLE(Entry_Key__c)`) and the
  external ID field as excluded (`IS_EXTERNAL_ID`).

Deploying the Apex classes alone is not enough for the toast: the component (`force-app/main/default/lwc`) must be
deployed too, or users still see an empty "RecordClone Error" toast.

### Coverage

`RecordCloneHarnessTest` (unpackaged) covers the harness. Org-wide coverage is 88% with everything deployed.

### API 68.0 and Code Analyzer (updated 2026-11-13)

Everything is on API 68.0: the 8 classes (were 48.0), 3 LWC bundles (were 52.0), the 3 sample tools (were 67.0),
`sfdx-project.json` (was 52.0) and `cumulusci.yml` (was 67.0).

**What changed in the platform.** User mode as the default for Apex database operations, `with sharing` as the default,
and the removal of `WITH SECURITY_ENFORCED` all arrived in API 67.0, not 68.0. The classes sat at 48.0, so moving them
crossed all of it at once. `USER_MODE` and `SYSTEM_MODE` themselves are older than either version.

**What the version bump alone did.** It failed 12 of 33 tests with `INVALID_FIELD_FOR_INSERT_UPDATE: bad field names on insert/update call: Contacts`. A queried record carries its child relationship lists, and user mode DML rejects them.
At 48.0 they were ignored. The handler now inserts a clean copy of each parent built from the clonable fields
(`copyClonableFields`) and reads the children from the original.

**Explicit modes.** Every query and DML names its mode and uses bind variables:

- Queries and DML run in `USER_MODE`. The running user's sharing, object permissions and field-level security apply.
- The `RecordCloneSettings__mdt` read is `WITH SYSTEM_MODE`. It is admin-owned configuration. In user mode a user
  without access to that type gets a `QueryException`, which would break cloning for every ordinary user.
- A refused user mode DML throws `SecurityException` (cannot see the object) or `TypeException` "DML operation INSERT
  not allowed" (can read, cannot create), not `DmlException`. Both are caught and reported with the object name.
- `getNameFieldValue` took an object and field name from the browser and put them straight into the SOQL string. Both
  are now checked against the record's own schema first.
- On the Flow path, a user who cannot read the records got a bare `NullPointerException`. They now get "Clone failed.
  The records could not be read."

**Code Analyzer.** Critical 0, High 57 to 0. The 57 were: 23 `EagerlyLoadedDescribeSObjectResult` (tests, harness),
15 `ApexCRUDViolation`, 11 `AvoidOldSalesforceApiVersions`, 6 `ApexSOQLInjection`, 2 `EmptyCatchBlock`. Moderate stayed at
87, Low 92 to 93, Info 9 to 10. The new ones are naming rules in `RecordCloneAccessTest` (camelCase constants, per
project convention). Complexity warnings on the handler were not addressed.

**Tests.** 33 to 43 (all pass, 88% coverage). `RecordCloneAccessTest` runs real restricted users (Minimum Access
profile plus permission sets) and checks: a read-only user gets no clone and no copy; a stale summary meets a refused
insert and reports it by object name on both paths; a user without `Phone` access clones without the phone; the
settings are readable by a user with no access to the type; a user with no access gets nothing back from either query
even with an administrator's summary; the name lookup rejects smuggled SOQL. In `RecordCloneTest` the assertions that read
child lists off the returned record now count the real child rows under the new parent, which is a stronger check.

**Checked by breaking it.** Nine mutations, each caught by a named test: single-record and multi-record queries in
system mode, insert in system mode, no `TypeException` catch, object-name check removed, settings read in user mode,
parent inserted with its child lists, Flow null guard removed, all fields copied whether populated or not. Script:
`ai-logs/mutate.py`, which restores the file byte for byte and redeploys.

**Browser check (scratch org, API 68.0).** As admin: a clean application cloned and navigated to the new record with 4
requirement responses, 3 question responses all pointing at the clone's requirement responses, 1 award, blank external
ID; an application on a retired term showed the full reason in the toast and left nothing behind. As a Standard User
with no access to the settings type: the component loaded the same summary and the clone worked. The temporary clones,
permission set and user were removed (the user is deactivated; users cannot be deleted). The harness gate
(`check_clone_harness`) passes.

**Found by a fresh build (2026-11-13).** A new `dev_org` build stopped at `deploy_sample_model`: at API 68.0 each
component instance on a FlexiPage needs an `<identifier>`, and `Sample_Application_Record_Page` had none ("The
'c:recordClone' component instance doesn't have an identifier specified"). Deploys to the older dev org never hit it
because the page was already there. Both instances now have an identifier. After the fix, `cci flow run sample_data`
completed on the new org (49 applications, no load errors), all 43 tests pass with 88% coverage, and the harness
gate passes.

**Not verified.** One uninterrupted `dev_org` build with the fix in place. The fix was checked with a validate-only
deploy and by running the remaining steps through `sample_data`, which uses the same tasks.

### Still needs the real org

- Which fields on the real Banner objects to exclude (needs the Enterprise team's list). The mechanism is built; the
  `ExcludedFieldNames__c` values are configuration.
- Validation rules, required fields and lookup filters specific to the real Application, Opportunity, Requirement
  Response, Question Response and Award objects. The sample objects have the same shape, not the same schema.
- Child objects ignore `ExcludedFieldNames__c` (it applies to the parent only). Not changed; raise it if the real
  children need field exclusions.
- ESLint reports an existing `no-api-reassignments` error at `recordClone.js:76`. Not changed.
- Code Analyzer has no Critical or High findings (see the API 68.0 section above). Moderate, Low and Info findings
  (complexity, ApexDoc, naming) remain and were not part of the work.
