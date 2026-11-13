/*
 * Copyright (c) 2020, salesforce.com, inc.
 * All rights reserved.
 * SPDX-License-Identifier: BSD-3-Clause
 * For full license text, see LICENSE.txt file in the repo root or https://opensource.org/licenses/BSD-3-Clause
 */

/**
 * Plain-language text for the reason codes that sObjectSummary.cls attaches to an object, a field or a
 * child relationship that cannot be cloned. A code this file does not know is shown as it came, so a
 * new code added in Apex still appears in the interface.
 */
const reasonText = {
  // objects
  IS_TASK: "Tasks aren't supported",
  IS_EVENT: "Events aren't supported",
  IS_ATTACHMENT: "Attachments aren't supported",
  IS_DOCUMENT: "Documents aren't supported",
  IS_QUOTE_DOCUMENT: "Quote documents aren't supported",
  IS_CONTENT_DOCUMENT_LINK: "File links aren't supported",
  IS_PARTNER: "Partners aren't supported",
  IS_ACCOUNT_PARTNER: "Account partners aren't supported",
  IS_OPPORTUNITY_PARTNER: "Opportunity partners aren't supported",
  IS_SHARE_OBJECT: "Sharing records aren't supported",
  IS_COMMUNITY_RELATED_RESTRICTION:
    "Experience Cloud records of this kind can't be queried in bulk",
  // fields
  NOT_ACCESSIBLE: "You don't have access to this field",
  NOT_CREATEABLE: "It can't be set when a record is created",
  BASE64: "File content can't be copied",
  OPP_LINE_ITEM: "Total price is worked out from unit price and quantity",
  CASE_CLOSED_DATE: "The closed date is set by the system",
  IS_UNIQUE: "It must be unique, so a copy would clash",
  IS_EXTERNAL_ID: "It's an external ID, so a copy would duplicate the key",
  IS_PERSON_ACCOUNT: "It belongs to a person account",
  IS_CALCULATED: "It's calculated (a formula or roll-up)",
  IS_EXCLUDED: "It's excluded in the configuration"
};

// The same code reads differently for a whole object and for one field, so these replace the text
// above when the thing being described is an object.
const objectReasonText = {
  NOT_ACCESSIBLE: "You don't have access to this object",
  NOT_CREATEABLE: "You can't create records of this type",
  NOT_QUERYABLE: "Records of this type can't be queried"
};

const requiredFieldPattern = /^REQUIRED_FIELD_NOT_CLONABLE\((.+)\)$/;

/**
 * Turns one reason code into a sentence.
 *
 * @param {string} code A reason code from sObjectSummary.cls
 * @param {string} [kind] "field" (the default) or "object", for the codes that differ between them
 * @returns {string} Readable text, or the code itself if it is not recognised
 */
export function describeReason(code, kind = "field") {
  const trimmed = (code || "").trim();
  const required = requiredFieldPattern.exec(trimmed);
  if (required) {
    return `It needs a value for ${required[1]}, which can't be copied`;
  }
  if (kind === "object" && objectReasonText[trimmed]) {
    return objectReasonText[trimmed];
  }
  return reasonText[trimmed] || trimmed;
}

/**
 * Splits the comma-separated errorMessage of an object, field or child and describes every reason.
 *
 * @param {string} errorMessage The errorMessage value from sObjectSummary.cls
 * @param {string} [kind] "field" (the default) or "object"
 * @returns {Array<{code: string, text: string}>} One entry per reason; empty when there is none
 */
export function describeReasons(errorMessage, kind = "field") {
  if (!errorMessage) {
    return [];
  }
  // A comma inside brackets belongs to one code, so split only at the top level.
  const codes = errorMessage.match(/[^,(]+(\([^)]*\))?/g) || [];
  return codes
    .map((code) => code.trim())
    .filter((code) => code.length > 0)
    .map((code) => ({ code, text: describeReason(code, kind) }));
}
