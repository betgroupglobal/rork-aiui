import Imap from 'imap';
import { simpleParser } from 'mailparser';
import configLoader from '../config/loader.js';
import { extractVerificationCode } from './verificationCodeExtractor.js';

const sleep = (ms) => new Promise((resolve) => setTimeout(resolve, ms));

class EmailReaderService {
  constructor() {
    this.config = configLoader.getReceivingEmailConfig();
    this.imap = null;
  }

  /**
   * Connect to the email server (idempotent — reuses an existing connection).
   * @returns {Promise<void>}
   */
  async connect() {
    if (this.imap) return;
    return new Promise((resolve, reject) => {
      this.imap = new Imap({
        user: this.config.email_address,
        password: this.config.email_password,
        host: this.config.imap_server,
        port: this.config.imap_port || 993,
        tls: true,
        connTimeout: this.config.timeout || 30000
      });

      this.imap.once('ready', () => {
        console.log('Connected to email server');
        resolve();
      });

      this.imap.once('error', (err) => {
        console.error('IMAP connection error:', err);
        this.imap = null;
        reject(err);
      });

      this.imap.connect();
    });
  }

  /**
   * Drop the current connection so the next call reconnects cleanly.
   */
  resetConnection() {
    try {
      this.imap?.end();
    } catch (error) {
      console.error('Error while resetting IMAP connection:', error.message);
    }
    this.imap = null;
  }

  /**
   * Search recent emails for verification codes.
   * Uses peek-fetch (readOnly box) so messages are NOT marked as read —
   * retried runs still see them.
   * @param {Object} options
   * @param {string|null} options.subjectFilter - IMAP SUBJECT filter
   * @param {number} options.sinceMinutes - Only accept emails newer than N minutes
   * @param {string|null} options.recipientEmail - Only accept emails addressed to this alias
   * @returns {Promise<Array>} Emails with verification codes
   */
  async searchVerificationEmails({ subjectFilter = null, sinceMinutes = 5, recipientEmail = null } = {}) {
    if (!this.imap) {
      await this.connect();
    }

    // IMAP SINCE is day-granular; precise filtering happens after parsing.
    const sinceDate = new Date(Date.now() - Math.max(sinceMinutes, 24 * 60) * 60 * 1000);
    const criteria = [['SINCE', sinceDate]];
    if (subjectFilter) {
      criteria.push(['SUBJECT', subjectFilter]);
    }

    return new Promise((resolve, reject) => {
      // readOnly: true => server-side peek semantics, messages stay UNSEEN.
      this.imap.openBox('INBOX', true, (err) => {
        if (err) {
          reject(err);
          return;
        }

        this.imap.search(criteria, (searchErr, results) => {
          if (searchErr) {
            reject(searchErr);
            return;
          }

          if (!results || results.length === 0) {
            resolve([]);
            return;
          }

          const emails = [];
          let pendingParses = 0;
          let fetchDone = false;
          let settled = false;

          const settle = (fn, value) => {
            if (settled) return;
            settled = true;
            fn(value);
          };

          // Resolve only when the fetch stream is done AND every parser has
          // finished — otherwise `end` can fire before results exist.
          const maybeFinish = () => {
            if (fetchDone && pendingParses === 0) {
              settle(resolve, emails);
            }
          };

          const fetch = this.imap.fetch(results, { bodies: '', bodyPeek: true });

          fetch.on('message', (msg) => {
            pendingParses += 1;
            let msgDone = false;
            const finishMessage = () => {
              if (msgDone) return;
              msgDone = true;
              pendingParses -= 1;
              maybeFinish();
            };

            msg.once('error', (msgErr) => {
              console.error('Error fetching message:', msgErr);
              finishMessage();
            });

            msg.on('body', (stream) => {
              simpleParser(stream, (parseErr, parsed) => {
                if (parseErr) {
                  console.error('Error parsing email:', parseErr);
                } else {
                  const code = extractVerificationCode(`${parsed.subject || ''} ${parsed.text || ''}`);
                  if (code && this.matchesRun(parsed, { recipientEmail, sinceMinutes })) {
                    emails.push({
                      from: parsed.from?.text,
                      to: parsed.to?.text,
                      subject: parsed.subject,
                      date: parsed.date,
                      code
                    });
                  }
                }
                finishMessage();
              });
            });
          });

          fetch.once('error', (fetchErr) => {
            settle(reject, fetchErr);
          });

          fetch.once('end', () => {
            fetchDone = true;
            maybeFinish();
          });
        });
      });
    });
  }

  /**
   * Verify a parsed email belongs to this run: addressed to the alias used
   * for the form and fresh enough to be the code we just triggered.
   * @param {Object} parsed - mailparser result
   * @param {Object} options
   * @returns {boolean}
   */
  matchesRun(parsed, { recipientEmail = null, sinceMinutes = 5 } = {}) {
    if (parsed.date && Date.now() - parsed.date.getTime() > sinceMinutes * 60 * 1000) {
      return false;
    }
    if (!recipientEmail) return true;
    const targets = `${parsed.to?.text || ''} ${parsed.cc?.text || ''}`.toLowerCase();
    if (targets.includes(recipientEmail.toLowerCase())) return true;
    // Some providers only expose the alias via Delivered-To / X-Original-To.
    const headers = JSON.stringify(parsed.headers?.get('delivered-to') || '');
    return headers.includes(recipientEmail.toLowerCase());
  }

  /**
   * Wait for a new verification email, polling with gentle backoff.
   * Reconnects automatically if the IMAP connection drops mid-wait.
   * @param {string|null} subjectFilter - Optional subject filter
   * @param {number} timeoutSeconds - Maximum time to wait
   * @param {string|null} recipientEmail - Alias the code was sent to
   * @param {Function|null} shouldCancel - Optional cancellation check
   * @returns {Promise<string>} Verification code
   */
  async waitForVerificationCode(subjectFilter = null, timeoutSeconds = 60, recipientEmail = null, shouldCancel = null) {
    const startTime = Date.now();
    let pollInterval = 5000;

    while (Date.now() - startTime < timeoutSeconds * 1000) {
      if (shouldCancel?.()) {
        throw new Error('Cancelled while waiting for verification email');
      }

      try {
        const emails = await this.searchVerificationEmails({ subjectFilter, sinceMinutes: 2, recipientEmail });
        if (emails.length > 0) {
          console.log(`Found verification code${recipientEmail ? ` for ${recipientEmail}` : ''}`);
          return emails[0].code;
        }
      } catch (error) {
        console.error('IMAP search failed, reconnecting:', error.message);
        this.resetConnection();
      }

      console.log('Waiting for verification email...');
      await sleep(pollInterval);
      pollInterval = Math.min(pollInterval + 2500, 15000);
    }

    throw new Error(
      `Timeout waiting for verification email${recipientEmail ? ` for ${recipientEmail}` : ''}`
    );
  }

  /**
   * Disconnect from the email server
   * @returns {Promise<void>}
   */
  async disconnect() {
    if (!this.imap) return;
    return new Promise((resolve) => {
      this.imap.once('end', () => {
        console.log('Disconnected from email server');
        this.imap = null;
        resolve();
      });
      this.imap.end();
    });
  }
}

export default EmailReaderService;
