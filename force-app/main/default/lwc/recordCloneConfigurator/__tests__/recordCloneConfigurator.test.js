/*
  Copyright (c) 2020, salesforce.com, inc.
  All rights reserved.
  SPDX-License-Identifier: BSD-3-Clause
  For full license text, see LICENSE.txt file in the repo root or https://opensource.org/licenses/BSD-3-Clause 
*/
import { createElement } from "lwc";
import RecordCloneConfigurator from "c/recordCloneConfigurator";
import { registerApexTestWireAdapter } from "@salesforce/sfdx-lwc-jest";
import showAllChildRelationships from "@salesforce/apex/RecordCloneDebugController.showAllChildRelationships";
import { ShowToastEventName } from "lightning/platformShowToastEvent";

jest.mock(
  "@salesforce/apex/RecordCloneDebugController.showAllChildRelationships",
  () => {
    return {
      default: jest.fn()
    };
  },
  { virtual: true }
);

const WIRE_RESULT_SUCCESS = {
  objectName: "Opportunity",
  relations: {
    AccountPartners: "Account Partner",
    ActivityHistories: "Activity History",
    AttachedContentDocuments: "Attached Content Document",
    Attachments: "Attachment"
  }
};

const showAllChildRelationshipsAdapter = registerApexTestWireAdapter(
  showAllChildRelationships
);

describe("c-record-clone-configurator", () => {
  afterEach(() => {
    while (document.body.firstChild) {
      document.body.removeChild(document.body.firstChild);
    }
    jest.clearAllMocks();
  });

  it("asks for a named object on a page that has no record", () => {
    // App, home, utility bar and flow pages have no record, only the target object property.
    // Apex rejects an empty string as an Id, so the missing Id must go out as null.
    const element = createElement("c-record-clone-configurator", {
      is: RecordCloneConfigurator
    });
    element.targetSObject = "Opportunity";
    document.body.appendChild(element);

    return Promise.resolve().then(() => {
      const config = showAllChildRelationshipsAdapter.getLastConfig();
      expect(config.recordId).toBeNull();
      expect(config.objectName).toBe("Opportunity");
    });
  });

  it("asks for the record's object on a record page", () => {
    const element = createElement("c-record-clone-configurator", {
      is: RecordCloneConfigurator
    });
    element.recordId = "MockRecordId";
    document.body.appendChild(element);

    return Promise.resolve().then(() => {
      const config = showAllChildRelationshipsAdapter.getLastConfig();
      expect(config.recordId).toBe("MockRecordId");
      expect(config.objectName).toBe("");
    });
  });

  it("shows a spinner until the relationships arrive", () => {
    const element = createElement("c-record-clone-configurator", {
      is: RecordCloneConfigurator
    });
    document.body.appendChild(element);
    element.recordId = "MockRecordId";

    return Promise.resolve().then(() => {
      expect(
        element.shadowRoot.querySelector("lightning-spinner")
      ).not.toBeNull();
      expect(element.shadowRoot.querySelector("table")).toBeNull();
    });
  });

  it("renders list of child relationships", () => {
    const element = createElement("c-record-clone-configurator", {
      is: RecordCloneConfigurator
    });
    document.body.appendChild(element);
    element.recordId = "MockRecordId";

    showAllChildRelationshipsAdapter.emit(WIRE_RESULT_SUCCESS);

    return Promise.resolve().then(() => {
      const heading = element.shadowRoot.querySelector("h3");
      expect(heading.textContent).toBe("Child objects related to Opportunity");

      const rows = Array.from(element.shadowRoot.querySelectorAll("tbody tr"));
      expect(rows).toHaveLength(4);
      const cells = rows[0].querySelectorAll("th, td");
      expect(cells[0].textContent.trim()).toBe("AccountPartners");
      expect(cells[1].textContent.trim()).toBe("Account Partner");

      // the relationship name is the row header, so a screen reader announces it with each value
      expect(rows[0].querySelector("th").getAttribute("scope")).toBe("row");
      expect(element.shadowRoot.querySelector("lightning-spinner")).toBeNull();
    });
  });

  it("offers every relationship name in one read-only field to copy", () => {
    const element = createElement("c-record-clone-configurator", {
      is: RecordCloneConfigurator
    });
    document.body.appendChild(element);
    element.recordId = "MockRecordId";

    showAllChildRelationshipsAdapter.emit(WIRE_RESULT_SUCCESS);

    return Promise.resolve().then(() => {
      const copyField = element.shadowRoot.querySelector("lightning-textarea");
      expect(copyField.readOnly).toBe(true);
      expect(copyField.label).toBe("All child relationship names");
      expect(copyField.value).toBe(
        "AccountPartners,ActivityHistories,AttachedContentDocuments,Attachments"
      );
    });
  });

  it("names the scrollable list for assistive technology", () => {
    const element = createElement("c-record-clone-configurator", {
      is: RecordCloneConfigurator
    });
    document.body.appendChild(element);
    element.recordId = "MockRecordId";

    showAllChildRelationshipsAdapter.emit(WIRE_RESULT_SUCCESS);

    return Promise.resolve().then(() => {
      const region = element.shadowRoot.querySelector('[role="region"]');
      expect(region.getAttribute("aria-label")).toBe(
        "Child relationships of Opportunity"
      );
      expect(region.getAttribute("tabindex")).toBe("0");
    });
  });

  it("shows an error notification, not a table, for an invalid object", () => {
    const element = createElement("c-record-clone-configurator", {
      is: RecordCloneConfigurator
    });
    document.body.appendChild(element);
    element.targetSObject = "NotAnObject";

    showAllChildRelationshipsAdapter.error({
      body: { message: "invalid" }
    });

    return Promise.resolve().then(() => {
      const notification = element.shadowRoot.querySelector(
        ".slds-scoped-notification"
      );
      expect(notification.getAttribute("role")).toBe("alert");
      expect(notification.textContent).toContain("Invalid sObject");
      expect(element.shadowRoot.querySelector("table")).toBeNull();
      expect(element.shadowRoot.querySelector("lightning-spinner")).toBeNull();
    });
  });

  it("show error toast on wire error", () => {
    const element = createElement("c-record-clone-configurator", {
      is: RecordCloneConfigurator
    });
    document.body.appendChild(element);
    element.recordId = "MockRecordId";
    const handler = jest.fn();
    element.addEventListener(ShowToastEventName, handler);

    showAllChildRelationshipsAdapter.error({
      fieldErrors: [{ statusCode: 400, message: "error" }],
      pageErrors: {
        sampleError: [{ statusCode: 400, message: "error" }]
      },
      otherCase: "whaaaat"
    });

    return Promise.resolve().then(() => {
      expect(handler).toHaveBeenCalled();
      expect(handler.mock.calls[0][0].detail.title).toBe("RecordClone Error");
      expect(handler.mock.calls[0][0].detail.message).not.toBe("Unknown error");
      expect(handler.mock.calls[0][0].detail.variant).toBe("error");
    });
  });

  it("show error toast on wire error 2", () => {
    const element = createElement("c-record-clone-configurator", {
      is: RecordCloneConfigurator
    });
    document.body.appendChild(element);
    element.recordId = "MockRecordId";
    const handler = jest.fn();
    element.addEventListener(ShowToastEventName, handler);

    showAllChildRelationshipsAdapter.error({
      fieldErrors: {
        aaa: [{ statusCode: 400, message: "error" }]
      },
      pageErrors: [{ statusCode: 400, message: "error" }],
      otherCase: "whaaaat"
    });

    return Promise.resolve().then(() => {
      expect(handler).toHaveBeenCalled();
      expect(handler.mock.calls[0][0].detail.title).toBe("RecordClone Error");
      expect(handler.mock.calls[0][0].detail.message).not.toBe("Unknown error");
      expect(handler.mock.calls[0][0].detail.variant).toBe("error");
    });
  });
});
