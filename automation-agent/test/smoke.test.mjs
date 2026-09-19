// Smoke tests for the fixed automation-agent.
// Run from the package root: node --test
import assert from 'node:assert/strict';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

const SRC = new URL('../src/', import.meta.url);

// Provide a hermetic config before any service is constructed. The loader
// resolves its JSON schema relative to the CWD (package root when running
// `npm test`), and the config file itself via CONFIG_PATH.
process.env.CONFIG_PATH = path.join(os.tmpdir(), `automation-agent-test-${process.pid}.json`);
fs.writeFileSync(process.env.CONFIG_PATH, JSON.stringify({
  emailalias: { api_key: 'test-key', api_url: 'http://127.0.0.1:9/api' },
  passwords: { selection_strategy: 'random', min_length: 12 },
  receiving_email: {
    email_address: 'tester@example.com',
    access_method: 'imap',
    imap_server: '127.0.0.1',
    imap_port: 993,
    email_password: 'unused'
  },
  sms_provider: { enabled: false },
  automation: { timeout: 2, headless: true, screenshot_on_error: false }
}));

const { extractVerificationCode } = await import(new URL('services/verificationCodeExtractor.js', SRC).href);
const { default: AutomationOrchestrator } = await import(new URL('automation/orchestrator.js', SRC).href);

let passed = 0;
let failed = 0;

async function test(name, fn) {
  try {
    await fn();
    passed++;
    console.log(`  ok  ${name}`);
  } catch (error) {
    failed++;
    console.error(`FAIL  ${name}: ${error.message}`);
  }
}

// --- 1. Verification-code extractor: specific beats generic ---------------
await test('labelled code beats footer numbers', () =>
  assert.equal(
    extractVerificationCode('Your order 2026 has shipped.\nYour verification code is 483920\nPrice: $19.99'),
    '483920'
  ));

await test('colon style', () => assert.equal(extractVerificationCode('Code: 552102'), '552102'));
await test('trailing style falls back to generic digits', () =>
  assert.equal(extractVerificationCode('123456 is your login code'), '123456'));
await test('generic digit fallback', () =>
  assert.equal(extractVerificationCode('please type 8421 to continue'), '8421'));
await test('rejects years', () =>
  assert.notEqual(extractVerificationCode('copyright 2026 thank you'), '2026'));
await test('rejects repeated digits', () =>
  assert.equal(extractVerificationCode('use code 1111 now'), null));
await test('empty input', () => assert.equal(extractVerificationCode(''), null));
await test('no code', () => assert.equal(extractVerificationCode('welcome aboard'), null));

// --- 2. Orchestrator (stubbed services) ------------------------------------

function makeStubs(overrides = {}) {
  const calls = { fills: [], clicks: [], deletedAliases: [], releasedNumbers: [] };
  const browserService = {
    config: { screenshot_on_error: false, headless: true, timeout: 5 },
    sessionId: 'session-x',
    startSession: async () => {},
    wait: async () => {},
    snapshot: async () => 'Welcome! Create your account. First name, last name, email, password.',
    findByRole: async (role, name) => `@ref-${name.replace(/\s+/g, '-')}`,
    findByText: async () => { throw new Error('not found'); },
    fill: async (ref, value) => calls.fills.push([ref, value]),
    click: async (ref) => calls.clicks.push(ref),
    closeSession: async () => {},
    ...overrides.browserService
  };
  const emailAliasService = {
    createEmailAlias: async () => ({ success: true, email: 'test.user@emailalias.io', alias_id: 'alias-1' }),
    deleteAlias: async (id) => { calls.deletedAliases.push(id); return true; },
    ...overrides.emailAliasService
  };
  const emailReaderService = {
    connect: async () => {},
    disconnect: async () => {},
    waitForVerificationCode: async () => '654321',
    ...overrides.emailReaderService
  };
  const smsService = {
    isEnabled: () => false,
    ...overrides.smsService
  };
  const passwordService = {
    generatePassword: () => 'Str0ng!Passw0rd',
    validatePassword: () => ({ valid: true, errors: [] }),
    ...overrides.passwordService
  };
  return { calls, services: { browserService, emailAliasService, emailReaderService, smsService, passwordService } };
}

await test('happy path completes with credential', async () => {
  const { calls, services } = makeStubs();
  const orchestrator = new AutomationOrchestrator({ services });
  const result = await orchestrator.run('https://example.com/register', 'john.doe-01');

  assert.equal(result.success, true, `expected success, got: ${result.error}`);
  assert.equal(result.credential.email, 'test.user@emailalias.io');
  assert.equal(result.credential.password, 'Str0ng!Passw0rd');
  assert.deepEqual(result.steps.map((s) => s.step), [
    'create_email', 'generate_password', 'start_browser', 'fill_form', 'handle_verification', 'complete_registration'
  ]);
  const fillStep = result.steps.find((s) => s.step === 'fill_form');
  for (const field of ['email', 'password', 'confirm password', 'first name', 'last name']) {
    assert.ok(fillStep.result.filled.includes(field), `${field} filled`);
  }
  // The password reaches fill() intact (execFile path, no shell mangling).
  assert.ok(calls.fills.some(([, v]) => v === 'Str0ng!Passw0rd'), 'password passed intact');
  assert.equal(orchestrator.aliasId, 'alias-1');
});

await test('onStep fires running + final per step', async () => {
  const { services } = makeStubs();
  const events = [];
  const orchestrator = new AutomationOrchestrator({ services, onStep: (step) => events.push(step) });
  await orchestrator.run('https://example.com/register', 'john.doe');
  const names = new Set(events.map((e) => e.step));
  assert.equal(names.size, 6, 'six distinct steps');
  for (const name of names) {
    assert.ok(events.some((e) => e.step === name && e.status === 'running'), `running event for ${name}`);
    assert.ok(events.some((e) => e.step === name && e.status === 'success'), `success event for ${name}`);
  }
});

await test('failed run deletes the orphaned alias', async () => {
  const { calls, services } = makeStubs({
    browserService: { startSession: async () => { throw new Error('Browser startup failed: boom'); } }
  });
  const orchestrator = new AutomationOrchestrator({ services });
  const result = await orchestrator.run('https://example.com/register', 'test');
  assert.equal(result.success, false);
  assert.match(result.error, /boom/);
  assert.deepEqual(calls.deletedAliases, ['alias-1'], 'orphaned alias cleaned up');
});

await test('SMS timeout still releases the rented number', async () => {
  const { calls, services } = makeStubs({
    browserService: { snapshot: async () => 'Enter your phone number to receive an SMS code' },
    smsService: {
      isEnabled: () => true,
      requestPhoneNumber: async () => ({ success: true, phone_number: '+15550001111', number_id: 'num-9' }),
      waitForVerificationCode: async () => { throw new Error('Timeout waiting for SMS verification'); },
      releasePhoneNumber: async (id) => { calls.releasedNumbers.push(id); return true; }
    }
  });
  const orchestrator = new AutomationOrchestrator({ services });
  const result = await orchestrator.run('https://example.com/register', 'sms-test');
  assert.equal(result.success, false);
  assert.match(result.error, /Timeout waiting for SMS/);
  assert.deepEqual(calls.releasedNumbers, ['num-9'], 'number released in finally');
});

await test('SMS-required page fails fast when SMS disabled', async () => {
  const { services } = makeStubs({
    browserService: { snapshot: async () => 'We sent a text message. Enter your mobile number.' }
  });
  const orchestrator = new AutomationOrchestrator({ services });
  const result = await orchestrator.run('https://example.com/register', 'nosms');
  assert.equal(result.success, false);
  assert.match(result.error, /SMS provider is disabled/);
});

await test('cancellation stops before the next step', async () => {
  const { services } = makeStubs();
  const orchestrator = new AutomationOrchestrator({ services });
  orchestrator.requestCancel();
  const result = await orchestrator.run('https://example.com/register', 'cancel-test');
  assert.equal(result.success, false);
  assert.equal(result.cancelled, true);
  assert.match(result.error, /cancelled/i);
  assert.deepEqual(result.steps.map((s) => s.step), [], 'no steps executed after cancel');
});

// --- 3. Email reader: valid IMAP criteria + parser-race-safe resolution ----

await test('searchVerificationEmails builds valid IMAP criteria (read-only, peek)', async () => {
  const { default: EmailReaderService } = await import(new URL('services/emailReaderService.js', SRC).href);
  const service = new EmailReaderService();

  const capturedCriteria = [];
  const fakeFetch = {
    on: () => {},
    once: (event, cb) => { if (event === 'end') setImmediate(cb); }
  };
  service.imap = {
    openBox: (name, readOnly, cb) => {
      service.__openedReadOnly = readOnly;
      setImmediate(() => cb(null, {}));
    },
    search: (criteria, cb) => {
      capturedCriteria.push(criteria);
      setImmediate(() => cb(null, []));
    },
    fetch: () => fakeFetch
  };

  const emails = await service.searchVerificationEmails({ subjectFilter: 'verification', sinceMinutes: 2 });
  assert.deepEqual(emails, []);
  assert.equal(service.__openedReadOnly, true, 'box opened read-only (peek semantics)');
  const criteria = capturedCriteria[0];
  assert.ok(Array.isArray(criteria), 'criteria is an array (old code called it as a function)');
  assert.ok(criteria.some((c) => Array.isArray(c) && c[0] === 'SINCE'), 'SINCE filter present');
  assert.ok(criteria.some((c) => Array.isArray(c) && c[0] === 'SUBJECT'), 'SUBJECT filter present');
});

// Cleanup the temp config fixture
try { fs.unlinkSync(process.env.CONFIG_PATH); } catch {}

console.log(`\n${passed} passed, ${failed} failed`);
process.exitCode = failed > 0 ? 1 : 0;
