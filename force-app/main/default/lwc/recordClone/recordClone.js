/*
 * Copyright (c) 2020, salesforce.com, inc.
 * All rights reserved.
 * SPDX-License-Identifier: BSD-3-Clause
 * For full license text, see LICENSE.txt file in the repo root or https://opensource.org/licenses/BSD-3-Clause
 */
import { LightningElement, api, track, wire } from "lwc";
import getSObjectSummary from "@salesforce/apex/RecordCloneController.getSObjectSummary";
import getNameFieldValue from "@salesforce/apex/RecordCloneController.getNameFieldValue";
import execClone from "@salesforce/apex/RecordCloneController.execClone";
import { ShowToastEvent } from "lightning/platformShowToastEvent";
import { NavigationMixin } from "lightning/navigation";
import { describeReasons } from "c/recordCloneReasons";

export default class RecordClone extends NavigationMixin(LightningElement) {
  @api recordId;

  @api componentTitle = "";
  @api cloneButtonLabel = "Clone";
  @api nameInputLabel = "";
  @api showDetails = false;
  @api templateRecordId = "";
  @api excludedFieldNames = "";
  @api childRelationshipNames = "";
  @api childRecordNameType = "";

  // The record being cloned: the template record if one is set, otherwise the current record.
  targetRecordId;

  nameField;
  objectName;
  isInitialized = false;
  isCloning = false;
  // The details are folded away until the user asks for them, to keep the component small on the page.
  detailsExpanded = false;
  shouldShowChildren = false;
  shouldShowExcludedFields = false;
  shouldShowIncludedFields = false;
  newParentRecordName = "";
  @track clonableChildren = [];
  @track notClonableChildren = [];
  @track clonableFields = [];
  @track notClonableFields = [];
  @track sObjectSummary = {};

  get MAX_CHILDREN_COUNT() {
    return 20;
  }

  @wire(getSObjectSummary, {
    recordId: "$targetRecordId",
    childRelationshipNames: "$childRelationshipNames",
    excludedFieldNames: "$excludedFieldNames"
  })
  sObjectSummaryGet({ error, data }) {
    if (data === undefined) {
      if (error) {
        this.handleErrors(error);
      }
      return;
    }
    this.handleSObjectSummary(data);
  }

  @wire(getNameFieldValue, {
    recordId: "$targetRecordId",
    objectName: "$objectName",
    nameField: "$nameField"
  })
  recordNameFieldValue({ error, data }) {
    if (data === undefined) {
      if (error) {
        this.handleErrors(error);
      }
      return;
    }
    this.newParentRecordName = data;
  }

  connectedCallback() {
    this.targetRecordId = this.templateRecordId
      ? this.templateRecordId
      : this.recordId;
    if (!this.targetRecordId) {
      this.showErrorToast(`There is no available Record Id`);
    }
  }

  handleSObjectSummary(sObjectSummary) {
    sObjectSummary = this.format(sObjectSummary);

    const clonableFields = [];
    const notClonableFields = [];
    if (sObjectSummary.fields && sObjectSummary.fields.length > 0) {
      for (let field of sObjectSummary.fields) {
        if (field.isClonable) {
          clonableFields.push(field);
        } else {
          notClonableFields.push(field);
        }
      }
    }
    const clonableChildren = [];
    const notClonableChildren = [];
    if (sObjectSummary.children && sObjectSummary.children.length > 0) {
      for (let child of sObjectSummary.children) {
        if (child.isClonable) {
          clonableChildren.push(child);
        } else {
          notClonableChildren.push(child);
        }
      }
    }
    if (clonableChildren.length > this.MAX_CHILDREN_COUNT) {
      this.showErrorToast(
        `You can't include more than ${this.MAX_CHILDREN_COUNT} different child types.`
      );
    }
    this.clonableChildren = clonableChildren;
    this.notClonableChildren = notClonableChildren;
    this.clonableFields = clonableFields;
    this.notClonableFields = notClonableFields;
    this.sObjectSummary = sObjectSummary;

    if (sObjectSummary.isNamable) {
      this.nameField = sObjectSummary.nameField;
      this.objectName = sObjectSummary.apiName;
    }
    this.isInitialized = true;
  }

  format(sObjectSummary) {
    let children = null;
    if (sObjectSummary.children) {
      children = Object.values(sObjectSummary.children);
    }
    return { ...sObjectSummary, children: children };
  }

  buildErrorMessage = (errors) => {
    let errorMessage = "";
    if (Array.isArray(errors)) {
      errors.forEach((err) => {
        errorMessage += `[${err.statusCode}] ${err.message}\n`;
      });
    } else if (errors instanceof Object) {
      for (let key in errors) {
        if (Object.prototype.hasOwnProperty.call(errors, key)) {
          const errs = errors[key];
          for (let err of errs) {
            errorMessage += `${key} - [${err.statusCode}] ${err.message}\n`;
          }
        }
      }
    }
    return errorMessage;
  };

  handleErrors = (errors) => {
    console.log(errors);
    let errorMessage = "";
    if (errors && errors.body) {
      if (errors.body.fieldErrors) {
        errorMessage += this.buildErrorMessage(errors.body.fieldErrors);
      }
      if (errors.body.pageErrors) {
        errorMessage += this.buildErrorMessage(errors.body.pageErrors);
      }
      // Apex exceptions (AuraHandledException) put their text in body.message
      if (!errorMessage && typeof errors.body.message === "string") {
        errorMessage = errors.body.message;
      }
    }
    if (!errorMessage && errors && typeof errors.message === "string") {
      errorMessage = errors.message;
    }
    this.showErrorToast(errorMessage || "Unknown error");
  };

  showSuccessToast = (title, message) => {
    const toastEvent = new ShowToastEvent({
      variant: "success",
      title: title,
      message: message
    });
    this.dispatchEvent(toastEvent);
  };

  showErrorToast = (message) => {
    const errorToast = new ShowToastEvent({
      variant: "error",
      title: "RecordClone Error",
      message
    });
    this.dispatchEvent(errorToast);
  };

  navTo = (recordId) => {
    this[NavigationMixin.Navigate]({
      type: "standard__recordPage",
      attributes: {
        recordId,
        actionName: "view"
      }
    });
  };

  handleRecordNameChange = (e) => {
    this.newParentRecordName = e.target.value;
  };

  onclickClone = () => {
    // if templateRecordId is specified, prioritize  it
    const recordId = this.templateRecordId
      ? this.templateRecordId
      : this.recordId;
    if (!recordId) {
      this.showErrorToast(`There is no available Record Id`);
      return;
    }
    this.isCloning = true;

    execClone({
      recordId,
      newParentRecordName: this.newParentRecordName,
      childRelationshipNames: this.childRelationshipNames,
      excludedFieldNames: this.excludedFieldNames,
      childRecordNameType: this.childRecordNameType
    })
      .then((clonedRecord) => {
        if (!clonedRecord) {
          throw new Error(
            "The clone did not return a new record. Check that a new record name is entered and that you can access the record."
          );
        }
        this.showSuccessToast(
          "Clone well done!",
          "Now navigating to the newly cloned record."
        );
        this.navTo(clonedRecord.Id);
      })
      .catch(this.handleErrors)
      .finally(() => (this.isCloning = false));
  };

  get hasTitle() {
    return !!this.componentTitle;
  }

  get childrenTitle() {
    return `Included child objects (${
      this.clonableChildren ? this.clonableChildren.length : 0
    })`;
  }

  get childrenListError() {
    return `You can't include more than ${this.MAX_CHILDREN_COUNT} different child types`;
  }

  get isExceedingMaxChidrenCount() {
    return this.clonableChildren.length > this.MAX_CHILDREN_COUNT;
  }

  get excludedFieldsTitle() {
    return `Excluded fields (${
      this.notClonableFields ? this.notClonableFields.length : 0
    })`;
  }

  get includedFieldsTitle() {
    return `Included fields (${
      this.clonableFields ? this.clonableFields.length : 0
    })`;
  }

  // A label that the admin typed is shown. With none, the input keeps a default label for screen
  // readers and hides it, as the card already says what the field is for.
  get nameInputLabelText() {
    return this.nameInputLabel || "New record name";
  }

  get nameInputVariant() {
    return this.nameInputLabel ? "standard" : "label-hidden";
  }

  get notClonableHeadline() {
    const label = this.sObjectSummary.label || "This type of";
    return `${label} records can't be cloned.`;
  }

  get notClonableReasons() {
    return describeReasons(this.sObjectSummary.errorMessage, "object");
  }

  get hasNotClonableReasons() {
    return this.notClonableReasons.length > 0;
  }

  toggleDetails = () => {
    this.detailsExpanded = !this.detailsExpanded;
  };

  get detailsIconName() {
    return this.detailsExpanded
      ? "utility:chevrondown"
      : "utility:chevronright";
  }

  get detailsAriaExpanded() {
    return this.detailsExpanded ? "true" : "false";
  }

  get hasChildItems() {
    return this.clonableChildren.length + this.notClonableChildren.length > 0;
  }

  get hasExcludedFields() {
    return this.notClonableFields.length > 0;
  }

  get hasIncludedFields() {
    return this.clonableFields.length > 0;
  }
}
