import path from 'path';
import fs from 'fs';
import { fileURLToPath } from 'url';
import EmailAliasService from '../services/emailAliasService.js';
import PasswordService from '../services/passwordService.js';
import EmailReaderService from '../services/emailReaderService.js';
import SMSService from '../services/smsService.js';
import BrowserAutomationService from '../services/browserAutomationService.js';

const __filename = fileURLToPath(import.meta.url);
const SCREENSHOTS_DIR = path.join(path.dirname(__filename), '..', '..', 'screenshots');

class AutomationOrchestrator {
  /**
   * @param {Object} [options]
   * @param {Function|null} [options.onStep] - Live progress callback.
   *   Called with {step, status:'running'} when a step starts and with the
   *   full record ({step, status, duration, result?, error?}) when it ends.
   * @param {Object|null} [options.services] - Service overrides (for tests)
   */
  constructor({ onStep = null, services = null } = {}) {
    const s = services || {};
    this.emailAliasService = s.emailAliasService || new EmailAliasService();
    this.passwordService = s.passwordService || new PasswordService();
    this.emailReaderService = s.emailReaderService || new EmailReaderService();
    this.smsService = s.smsService || new SMSService();
    this.browserService = s.browserService || new BrowserAutomationService();

    this.onStep = onStep;
    this.cancelled = false;

    this.credentialName = null;
    this.generatedEmail = null;
    this.generatedPassword = null;
    this.phoneNumber = null;
    this.aliasId = null;
  }

  /**
   * Request cancellation. Checked between steps and inside wait loops;
   * also force-closes the browser session.
   */
  requestCancel() {
    this.cancelled = true;
    this.browserService.closeSession().catch(() => {});
  }

  assertNotCancelled() {
    if (this.cancelled) {
      throw new Error('Automation cancelled');
    }
  }

  /**
   * Run the complete automation flow
   * @param {string} targetUrl - Target website URL
   * @param {string} credentialName - Name for the credential
   * @returns {Promise<Object>} Automation result
   */
  async run(targetUrl, credentialName) {
    this.credentialName = credentialName;
    const result = {
      success: false,
      steps: [],
      credential: null
    };

    try {
      console.log(`Starting automation for ${targetUrl} with credential name: ${credentialName}`);

      // Step 1: Create email alias
      await this.executeStep('create_email', async () => {
        const emailResult = await this.emailAliasService.createEmailAlias(credentialName);
        if (!emailResult.success) {
          throw new Error(`Failed to create email: ${emailResult.error}`);
        }
        this.generatedEmail = emailResult.email;
        this.aliasId = emailResult.alias_id;
        return { email: this.generatedEmail };
      }, result);

      // Step 2: Generate password
      await this.executeStep('generate_password', async () => {
        this.generatedPassword = this.passwordService.generatePassword();
        const validation = this.passwordService.validatePassword(this.generatedPassword);
        if (!validation.valid) {
          throw new Error(`Password validation failed: ${validation.errors.join(', ')}`);
        }
        return { password: '********' }; // Don't log actual password
      }, result);

      // Step 3: Start browser and navigate to target
      await this.executeStep('start_browser', async () => {
        await this.browserService.startSession(targetUrl);
        await this.browserService.wait('--load networkidle');
        return { status: 'browser_started' };
      }, result);

      // Step 4: Fill registration form
      const formResult = await this.executeStep('fill_form', async () => {
        return await this.fillRegistrationForm();
      }, result);

      // Step 5: Handle verification (email or SMS)
      await this.executeStep('handle_verification', async () => {
        return await this.handleVerification(formResult);
      }, result);

      // Step 6: Complete registration
      await this.executeStep('complete_registration', async () => {
        await this.completeRegistration();
        return { status: 'registration_completed' };
      }, result);

      // Success!
      result.success = true;
      result.credential = {
        name: credentialName,
        email: this.generatedEmail,
        password: this.generatedPassword,
        phone: this.phoneNumber,
        created_at: new Date().toISOString()
      };

      console.log('Automation completed successfully');
      return result;
    } catch (error) {
      console.error('Automation failed:', error);
      result.error = error.message;
      result.cancelled = this.cancelled;

      // The alias is useless once the run has failed — free it (best effort).
      await this.cleanupAlias();

      // Take screenshot on error if configured
      try {
        const automationConfig = this.browserService.config;
        if (automationConfig.screenshot_on_error && this.browserService.sessionId) {
          fs.mkdirSync(SCREENSHOTS_DIR, { recursive: true });
          const screenshotPath = await this.browserService.screenshot(
            path.join(SCREENSHOTS_DIR, `error-${Date.now()}.png`)
          );
          result.error_screenshot = screenshotPath;
        }
      } catch (screenshotError) {
        console.error('Failed to take error screenshot:', screenshotError);
      }

      return result;
    } finally {
      // Cleanup
      await this.cleanup();
    }
  }

  /**
   * Execute a step with error handling, logging, and live progress callbacks
   * @param {string} stepName - Step identifier
   * @param {Function} stepFunction - Step implementation
   * @param {Object} result - Result object to update
   * @returns {Promise<*>} Step result
   */
  async executeStep(stepName, stepFunction, result) {
    this.assertNotCancelled();
    console.log(`Executing step: ${stepName}`);
    this.onStep?.({ step: stepName, status: 'running' });
    const startTime = Date.now();

    try {
      const stepResult = await stepFunction();
      const record = {
        step: stepName,
        status: 'success',
        duration: Date.now() - startTime,
        result: stepResult
      };
      result.steps.push(record);
      this.onStep?.(record);
      return stepResult;
    } catch (error) {
      const record = {
        step: stepName,
        status: 'failed',
        duration: Date.now() - startTime,
        error: error.message
      };
      result.steps.push(record);
      this.onStep?.(record);
      throw error;
    }
  }

  /**
   * Best-effort alias cleanup after a failed run.
   */
  async cleanupAlias() {
    if (!this.aliasId) return;
    try {
      const deleted = await this.emailAliasService.deleteAlias(this.aliasId);
      console.log(deleted ? 'Orphaned alias deleted' : 'Could not delete orphaned alias');
    } catch (error) {
      console.error('Alias cleanup error:', error.message);
    }
  }

  /**
   * Fill the registration form on the page: email, password, confirm-password,
   * and name fields when present. Phone is filled later by the SMS branch.
   * @returns {Promise<{filled: string[], skipped: string[]}>}
   */
  async fillRegistrationForm() {
    const filled = [];
    const skipped = [];

    // Derive name parts from the credential name when possible
    // ("john.doe-01" -> first "John", last "Doe").
    const nameParts = (this.credentialName || '')
      .replace(/[^a-zA-Z\s.-]/g, ' ')
      .split(/[.\s_-]+/)
      .filter((part) => part.length > 1);
    const firstName = nameParts[0]
      ? nameParts[0][0].toUpperCase() + nameParts[0].slice(1).toLowerCase()
      : null;
    const lastName = nameParts[1]
      ? nameParts[1][0].toUpperCase() + nameParts[1].slice(1).toLowerCase()
      : null;

    await this.fillFirstMatch(filled, skipped, 'email', this.generatedEmail, [
      'email', 'email address', 'username'
    ]);
    await this.fillFirstMatch(filled, skipped, 'password', this.generatedPassword, [
      'password', 'pass'
    ]);
    await this.fillFirstMatch(filled, skipped, 'confirm password', this.generatedPassword, [
      'confirm password', 'confirm', 'repeat password', 'retype password', 'verify password'
    ]);
    await this.fillFirstMatch(filled, skipped, 'first name', firstName, [
      'first name', 'given name', 'forename'
    ]);
    await this.fillFirstMatch(filled, skipped, 'last name', lastName, [
      'last name', 'surname', 'family name'
    ]);

    if (!filled.includes('email')) {
      throw new Error('Could not find the email field on the page');
    }
    if (!filled.includes('password')) {
      throw new Error('Could not find the password field on the page');
    }

    await this.clickSubmit('Could not find a submit button on the registration form.');

    await this.browserService.wait('--load networkidle');
    return { filled, skipped };
  }

  /**
   * Try each label until one resolves; record the outcome.
   * @param {string[]} filled - Fields successfully filled
   * @param {string[]} skipped - Fields with no matching element
   * @param {string} fieldLabel - Logical name for logging
   * @param {string|null} value - Value to fill (null skips the field)
   * @param {string[]} labels - Accessible-name candidates
   */
  async fillFirstMatch(filled, skipped, fieldLabel, value, labels) {
    this.assertNotCancelled();
    if (value == null) {
      skipped.push(fieldLabel);
      return;
    }

    for (const label of labels) {
      try {
        const ref = await this.browserService.findByRole('textbox', label);
        await this.browserService.fill(ref, value);
        filled.push(fieldLabel);
        return;
      } catch (e) {
        // Try next label
      }
    }

    // Some inputs expose no textbox role (custom widgets); try a text find.
    try {
      const ref = await this.browserService.findByText(labels[0]);
      await this.browserService.fill(ref, value);
      filled.push(fieldLabel);
      return;
    } catch (e) {
      // Fall through to skipped
    }

    skipped.push(fieldLabel);
  }

  /**
   * Click a submit-style button following a fallback chain.
   * @param {string} failureMessage - Error to throw if no button is found
   * @param {boolean} required - Whether absence is fatal (code submission is not)
   */
  async clickSubmit(failureMessage, required = true) {
    const names = ['submit', 'register', 'sign up', 'create account', 'verify', 'confirm'];
    for (const name of names) {
      try {
        this.assertNotCancelled();
        const ref = await this.browserService.findByRole('button', name);
        await this.browserService.click(ref);
        return;
      } catch (e) {
        // Try next candidate
      }
    }

    try {
      const ref = await this.browserService.findByText('submit');
      await this.browserService.click(ref);
      return;
    } catch (e) {
      // Fall through
    }

    if (required) {
      throw new Error(failureMessage);
    }
    console.log(`${failureMessage} (continuing — the page may auto-submit)`);
  }

  /**
   * Detect which verification method is required.
   * Fails fast when the page demands SMS but no SMS provider is configured,
   * instead of silently waiting 60s for an email that can never arrive.
   * @returns {Promise<'email'|'sms'>}
   */
  async detectVerificationMethod() {
    const snapshot = await this.browserService.snapshot(true);
    const snapshotLower = snapshot.toLowerCase();

    const smsSignals = ['sms', 'phone', 'mobile', 'text message', 'phone number'];
    const needsSms = smsSignals.some((signal) => snapshotLower.includes(signal));

    if (needsSms) {
      if (this.smsService.isEnabled()) {
        return 'sms';
      }
      throw new Error(
        'Page requires SMS verification but the SMS provider is disabled in config. ' +
        'Enable sms_provider or use a different target.'
      );
    }

    return 'email';
  }

  /**
   * Route to the detected verification method.
   * @param {Object} formResult - Result of fill_form (unused today, kept for context)
   * @returns {Promise<Object>} { method, code: '********' }
   */
  async handleVerification(formResult) {
    const verificationMethod = await this.detectVerificationMethod();

    if (verificationMethod === 'email') {
      return await this.handleEmailVerification();
    }
    return await this.handleSMSVerification();
  }

  /**
   * Fill the verification code input and submit.
   * @param {string} code - Verification code
   */
  async fillVerificationCode(code) {
    const labels = ['code', 'verification code', 'otp', 'verification'];
    for (const label of labels) {
      try {
        const codeRef = await this.browserService.findByRole('textbox', label);
        await this.browserService.fill(codeRef, code);
        return;
      } catch (e) {
        // Try next label
      }
    }
    try {
      const codeRef = await this.browserService.findByText('code');
      await this.browserService.fill(codeRef, code);
      return;
    } catch (e) {
      throw new Error('Could not find verification code field');
    }
  }

  /**
   * Handle email verification: poll the mailbox for the code sent to the
   * alias, fill it, and submit.
   * @returns {Promise<Object>} { method: 'email', code: '********' }
   */
  async handleEmailVerification() {
    await this.emailReaderService.connect();

    try {
      const code = await this.emailReaderService.waitForVerificationCode(
        'verification',
        60,
        this.generatedEmail,
        () => this.cancelled
      );

      await this.fillVerificationCode(code);
      await this.clickSubmit(
        'Could not find a submit button after entering the verification code.',
        false
      );

      return { method: 'email', code: '********' };
    } finally {
      await this.emailReaderService.disconnect();
    }
  }

  /**
   * Handle SMS verification. The rented number is ALWAYS released in the
   * finally block — a timeout must never strand a paid number.
   * @returns {Promise<Object>} { method: 'sms', code: '********' }
   */
  async handleSMSVerification() {
    const phoneResult = await this.smsService.requestPhoneNumber();
    if (!phoneResult.success) {
      throw new Error(`Failed to get phone number: ${phoneResult.error}`);
    }

    this.phoneNumber = phoneResult.phone_number;
    const numberId = phoneResult.number_id;

    try {
      // Fill phone number in form
      try {
        const phoneRef = await this.browserService.findByRole('textbox', 'phone');
        await this.browserService.fill(phoneRef, this.phoneNumber);
      } catch (e) {
        throw new Error('Could not find phone number field');
      }

      // Submit to request SMS
      try {
        const sendRef = await this.browserService.findByRole('button', 'send');
        await this.browserService.click(sendRef);
      } catch (e) {
        throw new Error('Could not find send SMS button');
      }

      // Wait for SMS
      const code = await this.smsService.waitForVerificationCode(numberId, 60, () => this.cancelled);

      // Fill verification code and submit
      await this.fillVerificationCode(code);
      await this.clickSubmit(
        'Could not find a submit button after entering the verification code.',
        false
      );

      return { method: 'sms', code: '********' };
    } finally {
      await this.smsService.releasePhoneNumber(numberId);
    }
  }

  /**
   * Complete the registration process
   */
  async completeRegistration() {
    this.assertNotCancelled();

    // Look for a final submit/confirm button
    try {
      const confirmRef = await this.browserService.findByRole('button', 'confirm');
      await this.browserService.click(confirmRef);
    } catch (e) {
      try {
        const completeRef = await this.browserService.findByRole('button', 'complete');
        await this.browserService.click(completeRef);
      } catch (e2) {
        // May not need additional confirmation
        console.log('No additional confirmation button found');
      }
    }

    await this.browserService.wait('--load networkidle');

    // Check for success indicators
    const snapshot = await this.browserService.snapshot(true);
    const snapshotLower = snapshot.toLowerCase();

    if (snapshotLower.includes('success') || snapshotLower.includes('welcome') || snapshotLower.includes('dashboard')) {
      console.log('Registration appears successful');
    } else {
      console.log('Registration completed but success indicator not found');
    }
  }

  /**
   * Cleanup resources
   */
  async cleanup() {
    try {
      await this.browserService.closeSession();
    } catch (error) {
      console.error('Error during cleanup:', error);
    }
  }
}

export default AutomationOrchestrator;
