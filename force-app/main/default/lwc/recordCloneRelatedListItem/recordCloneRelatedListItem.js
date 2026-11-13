/*
 * Copyright (c) 2020, salesforce.com, inc.
 * All rights reserved.
 * SPDX-License-Identifier: BSD-3-Clause
 * For full license text, see LICENSE.txt file in the repo root or https://opensource.org/licenses/BSD-3-Clause
 */
import { LightningElement, api } from "lwc";
import { describeReasons } from "c/recordCloneReasons";

/**
 * The list inside one section of the clone details: the items that will be cloned, and the items
 * that will not, each with the reasons. The section heading and its open/closed state belong to the
 * parent's accordion.
 */
export default class RecordCloneRelatedListItem extends LightningElement {
  // Names the scrollable list for assistive technology.
  @api
  title;
  @api
  okItems;
  @api
  ngItems;
  @api
  errorMessage;
  @api
  isError = false;
  // What the items are: "field" (the default) or "object", which changes how some reasons read.
  @api
  kind = "field";

  get hasElements() {
    return this.totalLength > 0;
  }

  get okLength() {
    return this.okItems ? this.okItems.length : 0;
  }

  get ngLength() {
    return this.ngItems ? this.ngItems.length : 0;
  }

  get totalLength() {
    return this.okLength + this.ngLength;
  }

  // The items that will not be cloned, with each reason code turned into a sentence.
  get ngItemsWithReasons() {
    return (this.ngItems || []).map((item) => ({
      ...item,
      reasons: describeReasons(item.errorMessage, this.kind)
    }));
  }
}
