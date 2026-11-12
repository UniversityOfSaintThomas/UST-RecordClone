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

| Fix                                                 | Status                                                                                                 |
| --------------------------------------------------- | ------------------------------------------------------------------------------------------------------ |
| 1. Error propagation                                | Done (`983fb2a`). Message names the object, status code, reason and fields. A failed clone rolls back. |
| 2. Exclude external IDs                             | Done. `IS_EXTERNAL_ID` added in `sObjectSummary`. Harness findings for it: 19 to 0.                    |
| 3. Sibling reference remap                          | Not started. Detectable and fixable from the sample data.                                              |
| 4. Config-time check for children that cannot clone | Not started.                                                                                           |
| Child name format (inverted null check)             | Not started.                                                                                           |

### Known side effect

`RecordCloneHarness` is a dev-only class without a test. Where it is deployed, org-wide coverage drops
from 88% to 46%, below the 75% that `run_tests` requires. No CI flow deploys it. Anyone running
`cci task run run_tests --org dev` by hand sees the lower number.
