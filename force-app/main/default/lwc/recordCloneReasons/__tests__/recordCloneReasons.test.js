import { describeReason, describeReasons } from "c/recordCloneReasons";

describe("describeReason", () => {
  it("explains a known code in plain language", () => {
    expect(describeReason("IS_EXTERNAL_ID")).toBe(
      "It's an external ID, so a copy would duplicate the key"
    );
  });

  it("names the field in a required-field reason", () => {
    expect(describeReason("REQUIRED_FIELD_NOT_CLONABLE(Entry_Key__c)")).toBe(
      "It needs a value for Entry_Key__c, which can't be copied"
    );
  });

  it("words a code for a field and for an object differently", () => {
    expect(describeReason("NOT_CREATEABLE")).toBe(
      "It can't be set when a record is created"
    );
    expect(describeReason("NOT_CREATEABLE", "field")).toBe(
      "It can't be set when a record is created"
    );
    expect(describeReason("NOT_CREATEABLE", "object")).toBe(
      "You can't create records of this type"
    );
    expect(describeReason("NOT_ACCESSIBLE", "object")).toBe(
      "You don't have access to this object"
    );
  });

  it("uses the same text for a code that does not depend on the kind", () => {
    expect(describeReason("IS_TASK", "object")).toBe(
      describeReason("IS_TASK", "field")
    );
  });

  it("shows an unknown code as it came", () => {
    expect(describeReason("SOMETHING_NEW")).toBe("SOMETHING_NEW");
  });

  it("copes with a missing code", () => {
    expect(describeReason(undefined)).toBe("");
    expect(describeReason(null)).toBe("");
  });
});

describe("describeReasons", () => {
  it("returns nothing when there is no reason", () => {
    expect(describeReasons("")).toEqual([]);
    expect(describeReasons(undefined)).toEqual([]);
    expect(describeReasons(null)).toEqual([]);
  });

  it("describes every comma-separated reason and keeps the code", () => {
    expect(describeReasons("IS_UNIQUE,IS_EXCLUDED")).toEqual([
      { code: "IS_UNIQUE", text: "It must be unique, so a copy would clash" },
      { code: "IS_EXCLUDED", text: "It's excluded in the configuration" }
    ]);
  });

  it("passes the kind on to every reason", () => {
    expect(
      describeReasons("NOT_ACCESSIBLE,NOT_CREATEABLE", "object").map(
        (reason) => reason.text
      )
    ).toEqual([
      "You don't have access to this object",
      "You can't create records of this type"
    ]);
  });

  it("does not split a code at a comma inside its brackets", () => {
    const reasons = describeReasons(
      "NOT_CREATEABLE,REQUIRED_FIELD_NOT_CLONABLE(A__c, B__c)"
    );
    expect(reasons).toHaveLength(2);
    expect(reasons[1].code).toBe("REQUIRED_FIELD_NOT_CLONABLE(A__c, B__c)");
    expect(reasons[1].text).toContain("A__c, B__c");
  });

  it("ignores empty entries and surrounding spaces", () => {
    const reasons = describeReasons(" IS_TASK ,, ");
    expect(reasons).toHaveLength(1);
    expect(reasons[0].code).toBe("IS_TASK");
  });
});
