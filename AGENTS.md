# AGENTS.md

Context for AI agents working in this repo. Everything here was verified against the code or a scratch org.
Read `docs/ECRMSF-5087-recordclone-bugfix-plan.md` for the current bug-fix work and its status.

## What this is

RecordClone clones a Salesforce record and selected child records. This is the University of St. Thomas fork of
SalesforceLabs RecordClone, used for Jira ECRMSF-5087 (deferral process: clone an Application and its related
records to a new term).

- Package directory: `force-app` (the only packaged path). No namespace. API version 68.0.
- Build and deploy: CumulusCI (`cci`) and Salesforce CLI (`sf`). Scratch orgs only.
- The user commits. Do not run `git commit` or `git push`.

## Layout

| Path                                                      | What                                                                                                                                                 |
| --------------------------------------------------------- | ---------------------------------------------------------------------------------------------------------------------------------------------------- |
| `force-app/main/default/classes/`                         | `RecordCloneController`, `RecordCloneHandler`, `sObjectSummary`, `RecordCloneDebugController`, `RecordCloneChildRecordNamePicklist`, and their tests |
| `force-app/main/default/lwc/`                             | `recordClone` (the button and toasts), `recordCloneConfigurator`, `recordCloneRelatedListItem`                                                       |
| `force-app/main/default/objects/RecordCloneSettings__mdt` | Custom metadata that stores a clone configuration per object                                                                                         |
| `unpackaged/sample/model`                                 | Sample objects, fields, validation rules, record page, permission set, settings record. **Never packaged**                                           |
| `unpackaged/sample/tools`                                 | `RecordCloneHarness` and tests that need the sample objects. **Never packaged**                                                                      |
| `datasets/dev/dev.recipe.yml`                             | Snowfakery recipe for the sample data (`datasets/mapping.yml` is an unused leftover)                                                                 |
| `scripts/`                                                | `arm_sample_clone_failures.apex` and `clone_harness/part1-4.apex`                                                                                    |
| `cumulusci.yml`                                           | Tasks and flows, including the sample-data ones                                                                                                      |

Rule: packaged code (`force-app`) must never reference a `Sample_*` object. Tests that need them go in
`unpackaged/sample/tools`.

## How cloning works

Two entry points share `RecordCloneHandler`:

- `RecordCloneController.execClone` (`@AuraEnabled`, used by the LWC) calls `cloneRecord`. It wraps the clone in a
  savepoint and rolls back if any insert fails.
- `RecordCloneController.clone` (`@InvocableMethod`, used by Flow) calls `cloneRecords`. It reads its configuration
  from `RecordCloneSettings__mdt` through `sObjectSummary.getByRecordId(Id)`.

`sObjectSummary` describes the object, decides which fields are clonable (with reason codes such as `IS_UNIQUE`,
`IS_EXTERNAL_ID`, `NOT_CREATEABLE`) and which children are clonable. Children are matched by relationship name.

Behaviours to keep:

- Insert failures throw `RecordCloneHandler.RecordCloneException` with the object, status code, reason and fields.
  `execClone` converts it to an `AuraHandledException` and **must call `setMessage`**, or the browser only sees
  "Script-thrown exception".
- Lookups between cloned children are remapped to the new records (`insertChildBatches`). Lookups to records outside
  the clone are left unchanged.
- A child with a required field the clone must drop is reported not clonable and skipped.
- `ExcludedFieldNames__c` applies to the parent object only, not to children.
- Custom relationship names need `__r`: `Requirement_Responses__r`, `Opportunities__r`.

### Access modes (API 68.0)

Every class is `with sharing` and every query or DML names its access mode, so the code does not depend on the API
version default (user mode from 67.0, system mode before).

- Queries use `Database.queryWithBinds(..., AccessLevel.USER_MODE)` with bind variables. DML uses
  `Database.insert/update/delete(..., AccessLevel.USER_MODE)`. The `insert as user` form is not used because
  `prettier-plugin-apex` 1.x cannot parse it.
- The one `SYSTEM_MODE` read is the `RecordCloneSettings__mdt` query in `sObjectSummary.getByRecordId`. It is admin-owned
  configuration, and a user without access to that type gets a `QueryException` in user mode (measured).
- A user mode DML the user may not make throws `System.SecurityException` (no access to the object) or
  `System.TypeException` "DML operation INSERT not allowed" (can read, cannot create). Neither is a `DmlException`.
  `RecordCloneHandler.insertRows` converts both into a `RecordCloneException` that names the object.
- A queried record carries its child relationship lists, and user mode DML rejects them with
  `INVALID_FIELD_FOR_INSERT_UPDATE: bad field names ... Contacts`. The handler therefore inserts a clean copy built by
  `copyClonableFields` (only the clonable fields the original actually carries) and reads the children from the
  original. Do not insert the queried record itself.
- `getNameFieldValue` receives an object and field name from the browser. Both are checked against the schema of the
  record's own object before they reach the query.
- The describe checks in `sObjectSummary` leave a user with no create access with no clonable fields, so `execClone`
  returns `null` for them (the UI shows its generic "did not return a new record" message). The DML refusal path is
  reached only when a cached summary is older than the user's permissions.

## Commands

The `dev` scratch org's `sf` alias is `UST-RecordClone__dev` (confirm with `cci org info dev`).

```bash
cci task run deploy --path force-app/main/default/classes --org dev
cci task run deploy --path force-app/main/default/lwc --org dev      # also needed for any LWC change
cci task run deploy_sample_model --org dev
cci task run deploy_sample_tools --org dev
cci flow run sample_data --org dev          # add sample objects + data to an existing dev org
cci flow run check_clone_harness --org dev  # pass/fail gate for the harness
cci flow run dev_org --org <name>           # full build of a new scratch org (about 80 seconds)

sf apex run test --test-level RunLocalTests --target-org UST-RecordClone__dev --result-format human --code-coverage --wait 20
npx jest force-app/main/default/lwc
npx prettier --list-different "force-app/main/default/classes/*.cls" "unpackaged/**/*.{cls,xml}" cumulusci.yml
```

`config_dev` (part of `dev_org`) deploys the sample model and tools, assigns the `Sample_Data_Access` permission set,
loads the dataset, then breaks two scenarios on purpose (`arm_sample_clone_failures`).

## The harness

`RecordCloneHarness` clones each sample scenario inside a savepoint, compares the outcome with what a correct
RecordClone should do, and reports data-quality findings (copied external IDs, sibling lookups still pointing at the
original, wrong child counts). The data is never changed.

- Full report: `sf apex run --target-org <alias> --file scripts/clone_harness/part1.apex`, then parts 2 to 4. Look for
  `HARNESS` lines in the debug log. `cci` does not print debug logs.
- One anonymous Apex run allows 100 SOQL queries and a rollback does not refund them, which is why there are four parts.
- `execClone` cannot be called from anonymous Apex (an `AuraHandledException` outside an Aura context raises an
  uncatchable `LimitException`). The harness repeats its steps in `cloneSingle`; `RecordCloneTest` covers the wrapper.

## Gotchas

- **Deploy the LWC as well as the Apex.** With only the classes deployed, users see an empty "RecordClone Error"
  toast because the old component ignores `body.message`.
- A failing clone in the UI is easiest to debug from the Aura response body (`aura.ApexAction.execute`) in the network
  tab; the message is in `error[0].message`.
- `cci` output contains ANSI colour codes. Strip them (`sed 's/\x1b\[[0-9;]*m//g'`) before parsing.
- Debug lines from `sf apex run` appear as `USER_DEBUG|[n]|DEBUG|<text>`; filter on your own prefix.
- A mutation test must redeploy after restoring the file, or the org keeps the broken code. `ai-logs/mutate.py` does
  this and asserts the mutation applied (a mutation that silently did not apply looks like a passing test).
- `cci task run deploy --path` needs a folder, not a single file. Use `sf project deploy start --source-dir <file>` for
  one class.
- Apex is case-insensitive: a parameter named `accountAccess` shadows an enum named `AccountAccess`.
- `cci org info` prints the scratch org password. Never copy that output into a file or a message.
- The sample permission set `Sample_Data_Access` is required for field access; without it describe results look empty.
- `get_file_problems` (IDE MCP) cannot resolve Apex built-ins in this project, so it reports noise on every class.
- chrome-devtools-mcp rejects file paths that go through the `/var/home` symlink for screenshots. Inspect with
  `take_snapshot` or `evaluate_script` instead. The LWC shadow DOM needs a recursive query helper.
- `sf org open --url-only` returns a one-time login URL. Do not save it to a file.

## Conventions

- Match the file you are editing. Existing Apex uses short names such as `sObjSummary`; new code uses full
  unabbreviated camelCase, braces on every `if`/`for`, and complete Javadoc (`@param`, `@return`) when a method has a
  Javadoc block. Constants are camelCase, not `UPPER_CASE`.
- Prettier formats `.cls`, `.js`, `.xml`, `.yml` and `.md`. Run it on files you change.
- Put generated output (logs, JSON, backups) in `ai-logs/`, which is gitignored. Never leave temp files in the root.
- Test that a new test can fail: break the fix, watch the test fail with a clear message, then restore.
- Do not put secrets or one-time login URLs in any file.

## Known issues (not fixed)

- ESLint reports `@lwc/lwc/no-api-reassignments` at `recordClone.js:76` (present before this work).
- Code Analyzer has no Critical or High findings. The Moderate, Low and Info findings (complexity, ApexDoc, naming) are
  unchanged apart from the new test class, and were not part of the work.
- Children ignore `ExcludedFieldNames__c`.
- On the multi-record path the Opportunity contact-role cleanup checks `isDeletable` of the parent (Opportunity), not of
  the contact role. The single-record path checks the child. Not changed.
- The Banner field list from the Enterprise team (TDX ticket linked in the plan doc) is still needed to configure
  which real fields to exclude.
