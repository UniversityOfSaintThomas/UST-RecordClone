/*
  Copyright (c) 2020, salesforce.com, inc.
  All rights reserved.
  SPDX-License-Identifier: BSD-3-Clause
  For full license text, see LICENSE.txt file in the repo root or https://opensource.org/licenses/BSD-3-Clause 
*/
import { createElement } from "lwc";
import RecordCloneRelatedListItem from "c/recordCloneRelatedListItem";

const create = (properties) => {
  const element = createElement("c-record-clone-related-list-item", {
    is: RecordCloneRelatedListItem
  });
  Object.assign(element, properties);
  document.body.appendChild(element);
  return element;
};

describe("c-record-clone-related-list-item", () => {
  afterEach(() => {
    while (document.body.firstChild) {
      document.body.removeChild(document.body.firstChild);
    }
  });

  it("renders nothing when there are no items", () => {
    const element = create({ title: "Empty", okItems: [], ngItems: [] });
    return Promise.resolve().then(() => {
      expect(element.shadowRoot.querySelector("ul")).toBeNull();
      expect(element.shadowRoot.querySelector('[role="region"]')).toBeNull();
    });
  });

  it("renders nothing when the lists were never given", () => {
    const element = create({ title: "Unset" });
    return Promise.resolve().then(() => {
      expect(element.shadowRoot.querySelector("ul")).toBeNull();
    });
  });

  it("lists items to clone with their label and API name", () => {
    const element = create({
      title: "Included fields (2)",
      okItems: [
        { label: "Phone", apiName: "Phone" },
        { label: "Term", apiName: "Term__c" }
      ]
    });
    return Promise.resolve().then(() => {
      const items = element.shadowRoot.querySelectorAll("li");
      expect(items).toHaveLength(2);
      // label and API name are two separate pieces, not one run-together word
      const parts = Array.from(items[1].children).map((child) =>
        child.textContent.trim()
      );
      expect(parts).toEqual(["Term", "Term__c"]);
      expect(element.shadowRoot.querySelector('[data-id="reason"]')).toBeNull();
    });
  });

  it("gives each item that will not be cloned a line per reason", () => {
    const element = create({
      title: "Excluded fields (1)",
      ngItems: [
        {
          label: "External Id",
          apiName: "External_Id__c",
          errorMessage: "IS_UNIQUE,IS_EXTERNAL_ID"
        }
      ]
    });
    return Promise.resolve().then(() => {
      const reasons = Array.from(
        element.shadowRoot.querySelectorAll('[data-id="reason"]')
      );
      expect(reasons.map((reason) => reason.textContent.trim())).toEqual([
        "It must be unique, so a copy would clash",
        "It's an external ID, so a copy would duplicate the key"
      ]);
      // the code stays available as a tooltip, for an admin who needs to search for it
      expect(reasons.map((reason) => reason.title)).toEqual([
        "IS_UNIQUE",
        "IS_EXTERNAL_ID"
      ]);
    });
  });

  it("words a reason for an object when told the items are objects", () => {
    const element = create({
      title: "Included child objects (1)",
      kind: "object",
      ngItems: [
        { label: "Task", apiName: "Tasks", errorMessage: "NOT_CREATEABLE" }
      ]
    });
    return Promise.resolve().then(() => {
      expect(
        element.shadowRoot
          .querySelector('[data-id="reason"]')
          .textContent.trim()
      ).toBe("You can't create records of this type");
    });
  });

  it("shows no badge for an item that has no reason", () => {
    const element = create({
      title: "Excluded fields (1)",
      ngItems: [{ label: "Name", apiName: "Name" }]
    });
    return Promise.resolve().then(() => {
      expect(element.shadowRoot.querySelectorAll("li")).toHaveLength(1);
      expect(element.shadowRoot.querySelector('[data-id="reason"]')).toBeNull();
    });
  });

  it("puts the list in a labelled region that the keyboard can reach", () => {
    const element = create({
      title: "Included fields (1)",
      okItems: [{ label: "Phone", apiName: "Phone" }]
    });
    return Promise.resolve().then(() => {
      const region = element.shadowRoot.querySelector('[role="region"]');
      expect(region.getAttribute("aria-label")).toBe("Included fields (1)");
      expect(region.getAttribute("tabindex")).toBe("0");
    });
  });

  it("shows the error as an alert only when it is set", () => {
    const element = create({
      title: "Included child objects (21)",
      okItems: [{ label: "Contact", apiName: "Contacts" }],
      errorMessage: "You can't include more than 20 different child types",
      isError: false
    });
    return Promise.resolve()
      .then(() => {
        expect(element.shadowRoot.querySelector('[role="alert"]')).toBeNull();
        element.isError = true;
      })
      .then(() => {
        const alert = element.shadowRoot.querySelector('[role="alert"]');
        expect(alert.textContent).toContain(
          "You can't include more than 20 different child types"
        );
      });
  });
});
