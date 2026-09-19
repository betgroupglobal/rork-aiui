import { execFile } from 'child_process';
import { promisify } from 'util';
import configLoader from '../config/loader.js';

const execFileAsync = promisify(execFile);

const sleep = (ms) => new Promise((resolve) => setTimeout(resolve, ms));

/**
 * Runs the agent-browser CLI.
 *
 * Every command is spawned with an ARGUMENT ARRAY (no shell interpolation),
 * so generated passwords containing $ | ; & ( ) etc. and user-supplied URLs
 * can never be reinterpreted by a shell. Every command carries a timeout so a
 * hung CLI call can never stall a run forever.
 */
class BrowserAutomationService {
  constructor() {
    this.config = configLoader.getAutomationConfig();
    this.sessionId = null;
  }

  /**
   * Spawn agent-browser safely.
   * @param {string[]} args - CLI arguments
   * @param {Object} [options]
   * @param {number|null} [options.timeoutSeconds] - Per-command timeout
   * @param {boolean} [options.useSession] - Prefix with --session <id>
   * @returns {Promise<string>} stdout
   */
  async runCli(args, { timeoutSeconds = null, useSession = true } = {}) {
    const timeoutSecondsDefault = this.config.timeout || 30;
    const timeoutMs = Math.max(1, timeoutSeconds ?? timeoutSecondsDefault) * 1000;
    const fullArgs = useSession && this.sessionId ? ['--session', this.sessionId, ...args] : [...args];

    try {
      const { stdout } = await execFileAsync('agent-browser', fullArgs, {
        timeout: timeoutMs,
        killSignal: 'SIGKILL',
        maxBuffer: 10 * 1024 * 1024,
        windowsHide: true
      });
      return stdout;
    } catch (error) {
      if (error.killed || error.signal === 'SIGKILL') {
        throw new Error(`agent-browser ${args[0]} timed out after ${timeoutMs / 1000}s`);
      }
      const detail = [error.stderr, error.stdout].filter(Boolean).join(' ').trim();
      throw new Error(`agent-browser ${args[0]} failed: ${detail || error.message}`);
    }
  }

  /**
   * Check that the agent-browser binary exists (used for a friendly error).
   * @returns {Promise<boolean>}
   */
  async isInstalled() {
    try {
      await execFileAsync('which', ['agent-browser'], { timeout: 5000 });
      return true;
    } catch {
      return false;
    }
  }

  /**
   * Start a browser session and navigate to the target URL.
   * @param {string} url - Target URL
   * @returns {Promise<void>}
   */
  async startSession(url) {
    if (!(await this.isInstalled())) {
      throw new Error('agent-browser CLI is not installed. Install it with: npm i -g agent-browser && agent-browser install');
    }

    const sessionName = `automation-${Date.now()}`;
    const args = ['--session', sessionName];
    if (!this.config.headless) {
      args.push('--headed');
    }
    args.push('open', url);

    await this.runCli(args, { useSession: false, timeoutSeconds: 60 });
    this.sessionId = sessionName;
    console.log(`Browser session started: ${sessionName}`);
  }

  /**
   * Take a snapshot of the current page
   * @param {boolean} interactive - Only show interactive elements
   * @returns {Promise<string>} Snapshot output
   */
  async snapshot(interactive = true) {
    const args = interactive ? ['snapshot', '-i'] : ['snapshot'];
    return (await this.runCli(args)).trim();
  }

  /**
   * Click an element by reference
   * @param {string} ref - Element reference (e.g., @e1)
   * @returns {Promise<void>}
   */
  async click(ref) {
    await this.runCli(['click', ref]);
    console.log(`Clicked ${ref}`);
  }

  /**
   * Fill an input field. The value is passed as its own process argument —
   * it is never interpreted by a shell.
   * @param {string} ref - Element reference
   * @param {string} value - Value to fill
   * @returns {Promise<void>}
   */
  async fill(ref, value) {
    await this.runCli(['fill', ref, String(value)]);
    console.log(`Filled ${ref}`);
  }

  /**
   * Type text without clearing
   * @param {string} ref - Element reference
   * @param {string} value - Value to type
   * @returns {Promise<void>}
   */
  async type(ref, value) {
    await this.runCli(['type', ref, String(value)]);
    console.log(`Typed into ${ref}`);
  }

  /**
   * Press a key
   * @param {string} key - Key to press (e.g., Enter, Tab)
   * @returns {Promise<void>}
   */
  async pressKey(key) {
    await this.runCli(['press', key]);
    console.log(`Pressed ${key}`);
  }

  /**
   * Wait for a condition
   * @param {string} condition - Wait condition
   * @returns {Promise<void>}
   */
  async wait(condition) {
    await this.runCli(['wait', condition]);
    console.log(`Wait completed: ${condition}`);
  }

  /**
   * Take a screenshot
   * @param {string|null} filename - Optional absolute output path
   * @returns {Promise<string>} Screenshot path from CLI output
   */
  async screenshot(filename = null) {
    const args = filename ? ['screenshot', filename] : ['screenshot'];
    const stdout = await this.runCli(args);
    return stdout.trim();
  }

  /**
   * Close the browser session
   * @returns {Promise<void>}
   */
  async closeSession() {
    if (!this.sessionId) return;
    try {
      await this.runCli(['close']);
      console.log('Browser session closed');
    } catch (error) {
      console.error('Failed to close browser session:', error.message);
    } finally {
      this.sessionId = null;
    }
  }

  /**
   * Extract text from an element
   * @param {string} ref - Element reference
   * @returns {Promise<string>} Element text
   */
  async getText(ref) {
    return (await this.runCli(['get', 'text', ref])).trim();
  }

  /**
   * Find element by accessible role and name
   * @param {string} role - Element role (button, textbox, etc.)
   * @param {string} name - Accessible name
   * @returns {Promise<string>} Element reference
   */
  async findByRole(role, name) {
    return (await this.runCli(['find', 'role', role, '--name', name])).trim();
  }

  /**
   * Find element by visible text
   * @param {string} text - Text to find
   * @returns {Promise<string>} Element reference
   */
  async findByText(text) {
    return (await this.runCli(['find', 'text', text])).trim();
  }

  /**
   * Select dropdown option
   * @param {string} ref - Element reference
   * @param {string} value - Option value
   * @returns {Promise<void>}
   */
  async select(ref, value) {
    await this.runCli(['select', ref, String(value)]);
    console.log(`Selected value in ${ref}`);
  }

  /**
   * Check checkbox
   * @param {string} ref - Element reference
   * @returns {Promise<void>}
   */
  async check(ref) {
    await this.runCli(['check', ref]);
    console.log(`Checked ${ref}`);
  }

  /**
   * Execute JavaScript in the browser
   * @param {string} script - JavaScript code
   * @returns {Promise<string>} Result
   */
  async eval(script) {
    return (await this.runCli(['eval', script])).trim();
  }
}

export { sleep };
export default BrowserAutomationService;
