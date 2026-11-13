import { buildErrorMessage } from "c/recordCloneErrors";

describe("buildErrorMessage", () => {
  it("writes one line per error in a list", () => {
    expect(
      buildErrorMessage([
        { statusCode: 400, message: "first" },
        { statusCode: 500, message: "second" }
      ])
    ).toBe("[400] first\n[500] second\n");
  });

  it("names the field for errors grouped by field", () => {
    expect(
      buildErrorMessage({
        Name: [{ statusCode: 400, message: "required" }],
        Phone: [
          { statusCode: 400, message: "too long" },
          { statusCode: 400, message: "bad format" }
        ]
      })
    ).toBe(
      "Name - [400] required\nPhone - [400] too long\nPhone - [400] bad format\n"
    );
  });

  it("returns nothing for an empty list or object", () => {
    expect(buildErrorMessage([])).toBe("");
    expect(buildErrorMessage({})).toBe("");
  });

  it("returns nothing for input that is not a list or an object", () => {
    expect(buildErrorMessage(undefined)).toBe("");
    expect(buildErrorMessage(null)).toBe("");
    expect(buildErrorMessage("text")).toBe("");
  });

  it("ignores properties that come from the prototype", () => {
    const grouped = Object.create({
      inherited: [{ statusCode: 1, message: "no" }]
    });
    grouped.own = [{ statusCode: 2, message: "yes" }];
    expect(buildErrorMessage(grouped)).toBe("own - [2] yes\n");
  });
});
