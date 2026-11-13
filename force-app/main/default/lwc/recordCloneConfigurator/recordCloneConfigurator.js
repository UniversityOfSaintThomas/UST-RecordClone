/*
 * Copyright (c) 2020, salesforce.com, inc.
 * All rights reserved.
 * SPDX-License-Identifier: BSD-3-Clause
 * For full license text, see LICENSE.txt file in the repo root or https://opensource.org/licenses/BSD-3-Clause
 */
import { LightningElement, api, track, wire } from "lwc";
import showAllChildRelationships from "@salesforce/apex/RecordCloneDebugController.showAllChildRelationships";
import { ShowToastEvent } from "lightning/platformShowToastEvent";
import { buildErrorMessage } from "c/recordCloneErrors";

export default class RecordCloneConfigurator extends LightningElement {
  @api
  recordId = "";

  @track
  childrenList = [];

  childrenListStr = "";

  objectName = "";

  @api
  targetSObject = "";

  isInvalidObjectName = false;

  // Apex rejects an empty string as an Id, and a wire that is given undefined never runs. So on a page
  // with no record (app, home, utility bar, flow screen) the missing Id is sent as null.
  get recordIdParameter() {
    return this.recordId || null;
  }

  @wire(showAllChildRelationships, {
    recordId: "$recordIdParameter",
    objectName: "$targetSObject"
  })
  allChildRelationships({ error, data }) {
    if (!data) {
      if (error) {
        this.handleErrors(error);
        this.isInvalidObjectName = true;
      }
      return;
    }

    const childrenList = [];
    const childrenListStr = [];
    this.objectName = data.objectName;
    for (const key of Object.keys(data.relations)) {
      childrenList.push({ name: key, label: data.relations[key] });
      childrenListStr.push(key);
    }
    this.childrenList = childrenList;
    this.childrenListStr = childrenListStr.join(",");
  }

  get hasObjectName() {
    return this.objectName && this.objectName.length > 0;
  }

  get childrenTableLabel() {
    return `Child relationships of ${this.objectName}`;
  }

  handleErrors = (errors) => {
    let errorMessage = "Unknown error";
    if (errors && errors.body) {
      errorMessage = "";
      if (errors.body.fieldErrors) {
        errorMessage += buildErrorMessage(errors.body.fieldErrors);
      }
      if (errors.body.pageErrors) {
        errorMessage += buildErrorMessage(errors.body.pageErrors);
      }
      // Apex exceptions (AuraHandledException) put their text in body.message
      if (!errorMessage && typeof errors.body.message === "string") {
        errorMessage = errors.body.message;
      }
    }
    const errorToast = new ShowToastEvent({
      variant: "error",
      title: "RecordClone Error",
      message: errorMessage
    });
    this.dispatchEvent(errorToast);
  };
}
