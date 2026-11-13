/*
 * Copyright (c) 2020, salesforce.com, inc.
 * All rights reserved.
 * SPDX-License-Identifier: BSD-3-Clause
 * For full license text, see LICENSE.txt file in the repo root or https://opensource.org/licenses/BSD-3-Clause
 */

/**
 * Turns the field errors or page errors of an Apex or UI API response into lines of text.
 *
 * @param {Array|Object} errors Either a list of errors, or an object that maps a field to its list of errors
 * @returns {string} One line per error, or an empty string when the input is neither
 */
export function buildErrorMessage(errors) {
  let errorMessage = "";
  if (Array.isArray(errors)) {
    errors.forEach((err) => {
      errorMessage += `[${err.statusCode}] ${err.message}\n`;
    });
  } else if (errors instanceof Object) {
    for (const key in errors) {
      if (Object.prototype.hasOwnProperty.call(errors, key)) {
        const errs = errors[key];
        for (const err of errs) {
          errorMessage += `${key} - [${err.statusCode}] ${err.message}\n`;
        }
      }
    }
  }
  return errorMessage;
}
