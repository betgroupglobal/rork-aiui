import axios from 'axios';
import configLoader from '../config/loader.js';

const sleep = (ms) => new Promise((resolve) => setTimeout(resolve, ms));

class EmailAliasService {
  constructor() {
    this.config = configLoader.getEmailAliasConfig();
    this.client = axios.create({
      baseURL: this.config.api_url,
      timeout: 20000,
      headers: {
        'Authorization': `Bearer ${this.config.api_key}`,
        'Content-Type': 'application/json'
      }
    });
  }

  /**
   * Create an email alias based on a credential name.
   * Retries transient failures with exponential backoff and surfaces
   * rate limiting explicitly instead of retrying into a 429 wall.
   * @param {string} credentialName - Name to base the email on
   * @param {Object} [options]
   * @param {number} [options.retries] - Extra attempts after the first
   * @returns {Promise<Object>} Email alias details (alias_id may be null)
   */
  async createEmailAlias(credentialName, { retries = 2 } = {}) {
    const emailName = this.sanitizeEmailName(credentialName);
    const domain = this.config.domain || 'emailalias.io';
    const email = `${emailName}@${domain}`;

    for (let attempt = 0; attempt <= retries; attempt++) {
      if (attempt > 0) {
        const backoffMs = 1000 * 2 ** (attempt - 1);
        console.log(`Retrying alias creation in ${backoffMs}ms (attempt ${attempt + 1}/${retries + 1})`);
        await sleep(backoffMs);
      }

      try {
        console.log(`Creating email alias: ${email}`);

        const response = await this.client.post('/aliases', {
          email: email,
          description: `Created for automation: ${credentialName}`,
          active: true
        });

        const aliasId = response.data?.id ?? null;

        return {
          success: true,
          email,
          alias_id: aliasId,
          alias_id_missing: aliasId === null,
          created_at: new Date().toISOString()
        };
      } catch (error) {
        const status = error.response?.status;
        const message = error.response?.data?.message || error.message;

        // Premium plan: 20 aliases/day — retrying cannot help.
        if (status === 429) {
          console.error('Alias creation rate limited by emailalias.io');
          return {
            success: false,
            rateLimited: true,
            error: `Rate limited by emailalias.io (Premium allows ~20 aliases/day): ${message}`
          };
        }

        const retriable = status === undefined || status >= 500;
        console.error(`Failed to create email alias (attempt ${attempt + 1}):`, status ?? '', message);

        if (!retriable || attempt === retries) {
          return { success: false, error: message };
        }
      }
    }

    return { success: false, error: 'Alias creation failed after retries' };
  }

  /**
   * Sanitize credential name to create valid email local part
   * @param {string} name - Credential name
   * @returns {string} Sanitized email name
   */
  sanitizeEmailName(name) {
    // Remove special characters, replace spaces with dots, lowercase
    return name
      .toLowerCase()
      .replace(/[^a-z0-9\s-]/g, '')
      .replace(/\s+/g, '.')
      .replace(/-+/g, '.')
      .replace(/\.+/g, '.')
      .replace(/^\.|\.$/g, '')
      .substring(0, 50);
  }

  /**
   * Delete an email alias (used to clean up after failed runs).
   * @param {string|null} aliasId - ID of the alias to delete
   * @returns {Promise<boolean>}
   */
  async deleteAlias(aliasId) {
    if (!aliasId) {
      console.warn('deleteAlias called without an alias id — the API did not return one at creation time');
      return false;
    }
    try {
      await this.client.delete(`/aliases/${aliasId}`);
      return true;
    } catch (error) {
      console.error('Failed to delete alias:', error.response?.data || error.message);
      return false;
    }
  }

  /**
   * Check if an email alias exists
   * @param {string} email - Email to check
   * @returns {Promise<boolean>}
   */
  async checkAliasExists(email) {
    try {
      const response = await this.client.get(`/aliases/check`, {
        params: { email }
      });
      return response.data.exists || false;
    } catch (error) {
      console.error('Failed to check alias:', error.response?.data || error.message);
      return false;
    }
  }
}

export default EmailAliasService;
