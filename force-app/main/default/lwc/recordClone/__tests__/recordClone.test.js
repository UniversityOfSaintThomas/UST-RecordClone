/*
  Copyright (c) 2020, salesforce.com, inc.
  All rights reserved.
  SPDX-License-Identifier: BSD-3-Clause
  For full license text, see LICENSE.txt file in the repo root or https://opensource.org/licenses/BSD-3-Clause 
*/
import { createElement } from "lwc";
import RecordClone from "c/recordClone";
import { registerApexTestWireAdapter } from "@salesforce/sfdx-lwc-jest";
import getSObjectSummary from "@salesforce/apex/RecordCloneController.getSObjectSummary";
import getNameFieldValue from "@salesforce/apex/RecordCloneController.getNameFieldValue";
import execClone from "@salesforce/apex/RecordCloneController.execClone";

const sObjectSummaryError = require("./data/sObjectSummaryError.json");
const sObjectSummarySuccess = require("./data/sObjectSummarySuccess.json");
const sObjectSummaryNonSupport = require("./data/sObjectSummaryNonSupport.json");
const sObjectSummaryTooManyChildren = require("./data/sObjectSummaryTooManyChildren.json");
import { ShowToastEventName } from "lightning/platformShowToastEvent";
import { getNavigateCalledWith } from "lightning/navigation";

jest.mock(
  "@salesforce/apex/RecordCloneController.getSObjectSummary",
  () => {
    return {
      default: jest.fn()
    };
  },
  { virtual: true }
);

jest.mock(
  "@salesforce/apex/RecordCloneController.getNameFieldValue",
  () => {
    return {
      default: jest.fn()
    };
  },
  { virtual: true }
);

jest.mock(
  "@salesforce/apex/RecordCloneController.execClone",
  () => {
    return {
      default: jest.fn()
    };
  },
  { virtual: true }
);

const getNameFieldValueAdapter = registerApexTestWireAdapter(getNameFieldValue);
const getSObjectSummaryAdapter = registerApexTestWireAdapter(getSObjectSummary);

// Lets the promise callbacks chained after a rejection run (catch, then finally). No timer is
// needed: they are a fixed number of microtask turns.
const flushPromises = () =>
  [1, 2, 3, 4, 5].reduce((chain) => chain.then(() => {}), Promise.resolve());

// The toggle that folds the details away.
const detailsToggle = (element) =>
  Array.from(element.shadowRoot.querySelectorAll("lightning-button")).find(
    (button) => button.label === "Clone details"
  );

// The spinner that is on screen, by its accessible name.
const spinnerNamed = (element, name) =>
  Array.from(element.shadowRoot.querySelectorAll("lightning-spinner")).find(
    (spinner) => spinner.alternativeText === name
  );

describe("c-record-clone", () => {
  afterEach(() => {
    while (document.body.firstChild) {
      document.body.removeChild(document.body.firstChild);
    }
    jest.clearAllMocks();
  });

  it("renders clone button after initialization done", () => {
    const element = createElement("c-record-clone", {
      is: RecordClone
    });
    document.body.appendChild(element);
    element.nameInputLabel = "nanikore";
    getNameFieldValueAdapter.emit("Test Record Name");
    getSObjectSummaryAdapter.emit(sObjectSummarySuccess);

    return Promise.resolve().then(() => {
      const cloneButton = element.shadowRoot.querySelector("lightning-button");
      expect(cloneButton).not.toBeUndefined();
      expect(cloneButton).not.toBeNull();
    });
  });

  it("renders not supported", () => {
    const element = createElement("c-record-clone", {
      is: RecordClone
    });
    document.body.appendChild(element);
    element.nameInputLabel = "nanikore";
    getNameFieldValueAdapter.emit("Test Record Name");
    getSObjectSummaryAdapter.emit(sObjectSummaryNonSupport);

    return Promise.resolve().then(() => {
      const notification = element.shadowRoot.querySelector(
        ".slds-scoped-notification"
      );
      expect(notification.textContent).toContain(
        `${sObjectSummaryNonSupport.label} records can't be cloned.`
      );
      expect(element.shadowRoot.querySelector("lightning-button")).toBeNull();
      expect(element.shadowRoot.querySelector("lightning-input")).toBeNull();
    });
  });

  it("explains in plain language why a record type cannot be cloned", () => {
    const element = createElement("c-record-clone", {
      is: RecordClone
    });
    document.body.appendChild(element);
    getSObjectSummaryAdapter.emit({
      ...sObjectSummaryNonSupport,
      label: "Task",
      errorMessage: "NOT_CREATEABLE,IS_TASK,SOMETHING_NEW"
    });

    return Promise.resolve().then(() => {
      const reasons = Array.from(
        element.shadowRoot.querySelectorAll(".slds-scoped-notification li")
      );
      expect(reasons.map((item) => item.textContent.trim())).toEqual([
        // for a whole object, not a single field
        "You can't create records of this type",
        "Tasks aren't supported",
        // a code the interface does not know is shown as it came
        "SOMETHING_NEW"
      ]);
      expect(reasons[1].title).toBe("IS_TASK");
    });
  });

  it("renders input default value after init", () => {
    const element = createElement("c-record-clone", {
      is: RecordClone
    });
    document.body.appendChild(element);

    const recordName = "Test Record Name";
    element.recordId = "MockRecordId";
    element.showDetails = true;
    getSObjectSummaryAdapter.emit(sObjectSummarySuccess);
    getNameFieldValueAdapter.emit(recordName);

    return Promise.resolve().then(() => {
      const nameInput = element.shadowRoot.querySelector("lightning-input");
      expect(nameInput.value).toBe(recordName);
    });
  });

  it("show toast on error getNameValue", () => {
    const element = createElement("c-record-clone", {
      is: RecordClone
    });
    document.body.appendChild(element);
    const handler = jest.fn();
    element.addEventListener(ShowToastEventName, handler);

    getNameFieldValueAdapter.error({
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

  it("reflects input value change", () => {
    const element = createElement("c-record-clone", {
      is: RecordClone
    });
    document.body.appendChild(element);

    const recordName = "Test Record Name";
    element.recordId = "MockRecordId";
    element.showDetails = true;
    getSObjectSummaryAdapter.emit(sObjectSummarySuccess);
    getNameFieldValueAdapter.emit(recordName);

    return Promise.resolve()
      .then(() => {
        const nameInput = element.shadowRoot.querySelector("lightning-input");
        expect(nameInput.value).toBe(recordName);
      })
      .then(() => {
        const nameInput = element.shadowRoot.querySelector("lightning-input");
        nameInput.value = "changed name";
        nameInput.dispatchEvent(new CustomEvent("change"));
      })
      .then(() => {
        const nameInput = element.shadowRoot.querySelector("lightning-input");
        expect(nameInput.value).toBe("changed name");
      });
  });

  it("renders error message after initialization done with any error", () => {
    const element = createElement("c-record-clone", {
      is: RecordClone
    });
    document.body.appendChild(element);

    // getNameFieldValueAdapter.emit("Test Record Name");
    getSObjectSummaryAdapter.error(sObjectSummaryError);

    return Promise.resolve().then(() => {
      expect(spinnerNamed(element, "Initializing")).toBeTruthy();
      expect(element.shadowRoot.querySelector("lightning-button")).toBeNull();
    });
  });

  it("shows unknown error message when no meaningful message in response", () => {
    const element = createElement("c-record-clone", {
      is: RecordClone
    });
    document.body.appendChild(element);
    const handler = jest.fn();
    element.addEventListener(ShowToastEventName, handler);

    getSObjectSummaryAdapter.error({
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

  it("shows error toast on too many children", () => {
    const element = createElement("c-record-clone", {
      is: RecordClone
    });
    document.body.appendChild(element);
    const handler = jest.fn();
    element.addEventListener(ShowToastEventName, handler);
    const recordName = "Test Record Name";
    element.recordId = "MockRecordId";
    element.showDetails = true;
    getSObjectSummaryAdapter.emit(sObjectSummaryTooManyChildren);
    getNameFieldValueAdapter.emit(recordName);

    return Promise.resolve().then(() => {
      expect(handler).toHaveBeenCalled();
      expect(handler.mock.calls[0][0].detail.title).toBe("RecordClone Error");
      expect(handler.mock.calls[0][0].detail.message).toBe(
        "You can't include more than 20 different child types."
      );
      expect(handler.mock.calls[0][0].detail.variant).toBe("error");
    });
  });

  it("renders a component title if title property set.", () => {
    const element = createElement("c-record-clone", {
      is: RecordClone
    });
    document.body.appendChild(element);

    const titleText = "Hello Record Clone";
    element.componentTitle = titleText;
    return Promise.resolve().then(() => {
      const titleElement = element.shadowRoot.querySelector(
        ".slds-card__header-title .slds-truncate"
      );
      expect(titleElement.textContent).toBe(titleText);
    });
  });

  it("does not render a header if title property not set.", () => {
    const element = createElement("c-record-clone", {
      is: RecordClone
    });
    document.body.appendChild(element);
    return Promise.resolve().then(() => {
      const header = element.shadowRoot.querySelector(".slds-card__header");
      expect(header).toBe(null);
    });
  });

  it("exec Clone on click clone button", () => {
    const element = createElement("c-record-clone", {
      is: RecordClone
    });
    document.body.appendChild(element);

    const recordId = "MockRecordId";
    element.recordId = recordId;
    element.showDetails = true;
    element.childRecordNameType = "originalName";
    execClone.mockResolvedValue({
      Id: recordId
    });
    getNameFieldValueAdapter.emit("Test Record Name");
    getSObjectSummaryAdapter.emit(sObjectSummarySuccess);

    return Promise.resolve()
      .then(() => {
        const cloneButton =
          element.shadowRoot.querySelector("lightning-button");
        cloneButton.click();
      })
      .then(() => {
        // the form stays where it is, locked, with a spinner over it
        expect(spinnerNamed(element, "Cloning")).toBeTruthy();
        expect(
          element.shadowRoot.querySelector("lightning-button").disabled
        ).toBe(true);
        expect(
          element.shadowRoot.querySelector("lightning-input").disabled
        ).toBe(true);
      })
      .then(() => {
        const { pageReference } = getNavigateCalledWith();
        expect(pageReference.type).toBe("standard__recordPage");
        expect(pageReference.attributes.actionName).toBe("view");
      });
  });

  it("shows an error toast when clone execution returns null", () => {
    const element = createElement("c-record-clone", {
      is: RecordClone
    });
    document.body.appendChild(element);
    const handler = jest.fn();
    element.addEventListener(ShowToastEventName, handler);

    element.recordId = "MockRecordId";
    element.childRecordNameType = "originalName";
    execClone.mockResolvedValue(null);
    getNameFieldValueAdapter.emit("Test Record Name");
    getSObjectSummaryAdapter.emit(sObjectSummarySuccess);

    return Promise.resolve()
      .then(() => {
        const cloneButton =
          element.shadowRoot.querySelector("lightning-button");
        cloneButton.click();
      })
      .then(() => Promise.resolve())
      .then(() => {
        expect(execClone).toHaveBeenCalled();
        expect(handler).toHaveBeenCalled();
        expect(handler.mock.calls[0][0].detail.variant).toBe("error");
        expect(handler.mock.calls[0][0].detail.message).toContain(
          "did not return a new record"
        );
      });
  });

  it("shows the Apex exception message when clone execution is rejected", () => {
    const element = createElement("c-record-clone", {
      is: RecordClone
    });
    document.body.appendChild(element);
    const handler = jest.fn();
    element.addEventListener(ShowToastEventName, handler);

    element.recordId = "MockRecordId";
    element.childRecordNameType = "originalName";
    const apexMessage =
      "Clone failed. Opportunity - [STRING_TOO_LONG] Name: data value too large (Name)";
    execClone.mockRejectedValue({
      body: { message: apexMessage },
      ok: false,
      status: 400
    });
    getNameFieldValueAdapter.emit("Test Record Name");
    getSObjectSummaryAdapter.emit(sObjectSummarySuccess);

    return Promise.resolve()
      .then(() => {
        const cloneButton =
          element.shadowRoot.querySelector("lightning-button");
        cloneButton.click();
      })
      .then(() => Promise.resolve())
      .then(() => {
        expect(execClone).toHaveBeenCalled();
        expect(handler).toHaveBeenCalled();
        expect(handler.mock.calls[0][0].detail.title).toBe("RecordClone Error");
        expect(handler.mock.calls[0][0].detail.message).toBe(apexMessage);
        expect(handler.mock.calls[0][0].detail.variant).toBe("error");
      });
  });

  it("shows custom toast events after clone complete", () => {
    const element = createElement("c-record-clone", {
      is: RecordClone
    });
    document.body.appendChild(element);
    const handler = jest.fn();
    element.addEventListener(ShowToastEventName, handler);

    const recordId = "MockRecordId";
    element.recordId = recordId;
    element.childRecordNameType = "originalName";
    execClone.mockResolvedValue({
      Id: recordId
    });
    getNameFieldValueAdapter.emit("Test Record Name");
    getSObjectSummaryAdapter.emit(sObjectSummarySuccess);

    return Promise.resolve()
      .then(() => {
        const cloneButton =
          element.shadowRoot.querySelector("lightning-button");
        cloneButton.click();
      })
      .then(() => {
        // the form stays where it is, locked, with a spinner over it
        expect(spinnerNamed(element, "Cloning")).toBeTruthy();
        expect(
          element.shadowRoot.querySelector("lightning-button").disabled
        ).toBe(true);
        expect(
          element.shadowRoot.querySelector("lightning-input").disabled
        ).toBe(true);
      })
      .then(() => {
        expect(handler).toHaveBeenCalled();
        expect(handler.mock.calls[0][0].detail.title).toBe("Clone well done!");
        expect(handler.mock.calls[0][0].detail.message).toBe(
          "Now navigating to the newly cloned record."
        );
        expect(handler.mock.calls[0][0].detail.variant).toBe("success");
      });
  });

  it("shows custom toast events on clone error", () => {
    const element = createElement("c-record-clone", {
      is: RecordClone
    });
    document.body.appendChild(element);
    const handler = jest.fn();
    element.addEventListener(ShowToastEventName, handler);

    element.recordId = "MockRecordId";
    element.childRecordNameType = "originalName";
    execClone.mockRejectedValue({
      message: "mock error"
    });
    getNameFieldValueAdapter.emit("Test Record Name");
    getSObjectSummaryAdapter.emit(sObjectSummarySuccess);

    return Promise.resolve()
      .then(() => {
        element.shadowRoot.querySelector("lightning-button").click();
      })
      .then(() => {
        expect(spinnerNamed(element, "Cloning")).toBeTruthy();
      })
      .then(() => {
        expect(handler).toHaveBeenCalled();
        expect(handler.mock.calls[0][0].detail.title).toBe("RecordClone Error");
        expect(handler.mock.calls[0][0].detail.message).toBe("mock error");
        expect(handler.mock.calls[0][0].detail.variant).toBe("error");
      })
      .then(flushPromises)
      .then(() => {
        // after the failure the user can correct the name and try again
        expect(spinnerNamed(element, "Cloning")).toBeFalsy();
        expect(
          element.shadowRoot.querySelector("lightning-button").disabled
        ).toBe(false);
        expect(
          element.shadowRoot.querySelector("lightning-input").disabled
        ).toBe(false);
      });
  });

  it("shows the label the admin set and gives the input a name otherwise", () => {
    const element = createElement("c-record-clone", {
      is: RecordClone
    });
    document.body.appendChild(element);
    element.nameInputLabel = "New application name";
    getNameFieldValueAdapter.emit("Test Record Name");
    getSObjectSummaryAdapter.emit(sObjectSummarySuccess);

    return Promise.resolve()
      .then(() => {
        // a label the admin typed is for people to read, so it is shown
        const input = element.shadowRoot.querySelector("lightning-input");
        expect(input.label).toBe("New application name");
        expect(input.variant).toBe("standard");

        element.nameInputLabel = "";
      })
      .then(() => {
        // with none, the input still has a name for a screen reader, but it is not drawn
        const input = element.shadowRoot.querySelector("lightning-input");
        expect(input.label).toBe("New record name");
        expect(input.variant).toBe("label-hidden");
      });
  });

  it("does not lock the form when there is no record id", () => {
    const element = createElement("c-record-clone", {
      is: RecordClone
    });
    document.body.appendChild(element);
    const handler = jest.fn();
    element.addEventListener(ShowToastEventName, handler);

    getNameFieldValueAdapter.emit("Test Record Name");
    getSObjectSummaryAdapter.emit(sObjectSummarySuccess);

    return Promise.resolve()
      .then(() => {
        element.shadowRoot.querySelector("lightning-button").click();
      })
      .then(() => {
        expect(execClone).not.toHaveBeenCalled();
        expect(handler).toHaveBeenCalled();
        expect(handler.mock.calls[0][0].detail.message).toBe(
          "There is no available Record Id"
        );
        // nothing was started, so nothing is left spinning or disabled
        expect(spinnerNamed(element, "Cloning")).toBeFalsy();
        expect(
          element.shadowRoot.querySelector("lightning-button").disabled
        ).toBe(false);
      });
  });

  it("folds the details away until the user asks for them", () => {
    const element = createElement("c-record-clone", {
      is: RecordClone
    });
    document.body.appendChild(element);
    element.showDetails = true;
    getNameFieldValueAdapter.emit("Test Record Name");
    getSObjectSummaryAdapter.emit(sObjectSummarySuccess);

    return Promise.resolve()
      .then(() => {
        // one line, a toggle, and nothing else, so the component stays small on the page
        const toggle = Array.from(
          element.shadowRoot.querySelectorAll("lightning-button")
        ).find((button) => button.label === "Clone details");
        expect(toggle).toBeTruthy();
        expect(toggle.ariaExpanded).toBe("false");
        expect(toggle.iconName).toBe("utility:chevronright");
        expect(
          element.shadowRoot.querySelector("lightning-accordion")
        ).toBeNull();
        expect(
          element.shadowRoot.querySelector("c-record-clone-related-list-item")
        ).toBeNull();
      })
      .then(() => {
        detailsToggle(element).click();
      })
      .then(() => {
        expect(detailsToggle(element).ariaExpanded).toBe("true");
        expect(detailsToggle(element).iconName).toBe("utility:chevrondown");
        expect(
          element.shadowRoot.querySelector("lightning-accordion")
        ).not.toBeNull();

        detailsToggle(element).click();
      })
      .then(() => {
        expect(detailsToggle(element).ariaExpanded).toBe("false");
        expect(
          element.shadowRoot.querySelector("lightning-accordion")
        ).toBeNull();
      });
  });

  it("lists the details in accordion sections once they are opened", () => {
    const element = createElement("c-record-clone", {
      is: RecordClone
    });
    document.body.appendChild(element);
    element.showDetails = true;
    getNameFieldValueAdapter.emit("Test Record Name");
    getSObjectSummaryAdapter.emit(sObjectSummarySuccess);

    return Promise.resolve()
      .then(() => {
        detailsToggle(element).click();
      })
      .then(() => {
        const accordion = element.shadowRoot.querySelector(
          "lightning-accordion"
        );
        expect(accordion).not.toBeNull();
        expect(accordion.allowMultipleSectionsOpen).toBe(true);

        const sections = Array.from(
          element.shadowRoot.querySelectorAll("lightning-accordion-section")
        );
        expect(sections.map((section) => section.label)).toEqual([
          "Included child objects (1)",
          expect.stringMatching(/^Excluded fields \(\d+\)$/),
          expect.stringMatching(/^Included fields \(\d+\)$/)
        ]);

        // every section holds one list, handed its items and a name for assistive technology
        const lists = element.shadowRoot.querySelectorAll(
          "c-record-clone-related-list-item"
        );
        expect(lists).toHaveLength(3);
        expect(lists[0].title).toBe("Included child objects (1)");
        expect(lists[0].okItems).toHaveLength(1);
      });
  });

  it("does not render the details unless asked to", () => {
    const element = createElement("c-record-clone", {
      is: RecordClone
    });
    document.body.appendChild(element);
    getNameFieldValueAdapter.emit("Test Record Name");
    getSObjectSummaryAdapter.emit(sObjectSummarySuccess);

    return Promise.resolve().then(() => {
      expect(
        element.shadowRoot.querySelector("lightning-accordion")
      ).toBeNull();
    });
  });
});
