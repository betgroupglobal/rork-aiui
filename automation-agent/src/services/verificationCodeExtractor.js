/**
 * Shared verification-code extraction used by both the email and SMS readers.
 *
 * Patterns are ordered specific -> generic so labelled codes ("your code is
 * 123456") win over incidental numbers (years, prices, order IDs) that appear
 * in message footers.
 */

// Specific, labelled patterns first. Each has a capture group for the code.
const LABELLED_PATTERNS = [
  /(?:code|otp|pin|passcode)\s*(?:is|:|=)?\s*[:\-]?\s*([A-Z0-9]{4,12})\b/i,
  /\byour\s+(?:verification\s+)?(?:code|otp|pin)\s+(?:is\s+)?([A-Z0-9]{4,12})\b/i,
  /\b([A-Z0-9]{4,12})\b\s+is\s+your\s+(?:verification\s+)?(?:code|otp|pin)\b/i,
  /(?:enter|input|use)\s+(?:the\s+)?(?:code|otp|pin)\s+([A-Z0-9]{4,12})\b/i,
];

// Generic fallbacks, tried only when nothing labelled matched.
const GENERIC_PATTERNS = [
  /\b(\d{4,8})\b/, // 4-8 digit codes
  /\b([A-Z0-9]{6,10})\b/, // standalone alphanumeric codes
];

/**
 * Decide whether a candidate looks like a real code rather than noise.
 * @param {string} candidate
 * @returns {boolean}
 */
function isPlausibleCode(candidate) {
  if (!candidate) return false;
  // Reject years (19xx / 20xx) and all-repeated digits.
  if (/^(19|20)\d{2}$/.test(candidate)) return false;
  if (/^(\d)\1+$/.test(candidate)) return false;
  return true;
}

/**
 * Extract a verification code from arbitrary message text.
 * @param {string} text - Message content (subject + body, SMS body, etc.)
 * @returns {string|null} The extracted code, or null if none found.
 */
export function extractVerificationCode(text) {
  const content = typeof text === 'string' ? text : '';
  if (!content.trim()) return null;

  for (const pattern of [...LABELLED_PATTERNS, ...GENERIC_PATTERNS]) {
    const match = content.match(pattern);
    const candidate = match?.[1]?.trim();
    if (candidate && isPlausibleCode(candidate)) {
      return candidate;
    }
  }
  return null;
}

export default extractVerificationCode;
