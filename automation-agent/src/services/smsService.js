import axios from 'axios';
import configLoader from '../config/loader.js';
import { extractVerificationCode } from './verificationCodeExtractor.js';

const sleep = (ms) => new Promise((resolve) => setTimeout(resolve, ms));

class SMSService {
  constructor() {
    this.config = configLoader.getSMSProviderConfig();
    this.enabled = this.config.enabled;

    if (this.enabled) {
      this.client = axios.create({
        baseURL: this.config.api_url,
        timeout: 20000,
        headers: {
          'Authorization': `Bearer ${this.config.api_key}`,
          'Content-Type': 'application/json'
        }
      });
    }
  }

  /**
   * Check if SMS service is enabled
   * @returns {boolean}
   */
  isEnabled() {
    return this.enabled;
  }

  /**
   * Request a phone number for verification
   * @returns {Promise<Object>} Phone number details
   */
  async requestPhoneNumber() {
    if (!this.enabled) {
      throw new Error('SMS service is not enabled');
    }

    try {
      console.log('Requesting phone number from crazytel...');

      const response = await this.client.post('/numbers/request', {
        service: 'verification',
        country: 'US'
      });

      return {
        success: true,
        phone_number: response.data.phone_number || this.config.phone_number,
        number_id: response.data.id,
        expires_at: response.data.expires_at
      };
    } catch (error) {
      const status = error.response?.status;
      const message = error.response?.data?.message || error.message;

      if (status === 429) {
        return { success: false, rateLimited: true, error: `Rate limited by crazytel: ${message}` };
      }

      console.error('Failed to request phone number:', status ?? '', message);
      return { success: false, error: message };
    }
  }

  /**
   * Get SMS messages for a phone number
   * @param {string} numberId - Phone number ID
   * @returns {Promise<Array>} Array of SMS messages
   */
  async getSMSMessages(numberId) {
    if (!this.enabled) {
      throw new Error('SMS service is not enabled');
    }

    try {
      const response = await this.client.get(`/numbers/${numberId}/messages`);
      return response.data.messages || [];
    } catch (error) {
      console.error('Failed to get SMS messages:', error.response?.data || error.message);
      return [];
    }
  }

  /**
   * Extract verification code from SMS message body.
   * Delegates to the shared extractor so email and SMS behave identically.
   * @param {string} message - SMS message text
   * @returns {string|null} Extracted code or null
   */
  extractVerificationCode(message) {
    return extractVerificationCode(message);
  }

  /**
   * Wait for an SMS verification code with progressive backoff.
   * @param {string} numberId - Phone number ID
   * @param {number} timeoutSeconds - Maximum time to wait
   * @param {Function|null} shouldCancel - Optional cancellation check
   * @returns {Promise<string>} Verification code
   */
  async waitForVerificationCode(numberId, timeoutSeconds = 60, shouldCancel = null) {
    const startTime = Date.now();
    let pollInterval = 5000;

    while (Date.now() - startTime < timeoutSeconds * 1000) {
      if (shouldCancel?.()) {
        throw new Error('Cancelled while waiting for SMS verification');
      }

      const messages = await this.getSMSMessages(numberId);

      for (const message of messages) {
        const code = this.extractVerificationCode(message.body || message.text || '');
        if (code) {
          console.log('Found SMS verification code');
          return code;
        }
      }

      console.log('Waiting for SMS verification...');
      await sleep(pollInterval);
      pollInterval = Math.min(pollInterval + 2500, 15000);
    }

    throw new Error('Timeout waiting for SMS verification');
  }

  /**
   * Release a phone number (best-effort; always safe to call).
   * @param {string} numberId - Phone number ID
   * @returns {Promise<boolean>}
   */
  async releasePhoneNumber(numberId) {
    if (!this.enabled || !numberId) {
      return true;
    }

    try {
      await this.client.post(`/numbers/${numberId}/release`);
      console.log('Phone number released');
      return true;
    } catch (error) {
      console.error('Failed to release phone number:', error.response?.data || error.message);
      return false;
    }
  }
}

export default SMSService;
