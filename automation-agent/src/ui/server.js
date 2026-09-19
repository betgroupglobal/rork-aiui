import express from 'express';
import fs from 'fs';
import path from 'path';
import { fileURLToPath } from 'url';
import { randomUUID } from 'crypto';
import AutomationOrchestrator from '../automation/orchestrator.js';
import configLoader from '../config/loader.js';

const __filename = fileURLToPath(import.meta.url);
const __dirname = path.dirname(__filename);
const projectRoot = path.join(__dirname, '..', '..');

// Config lives in <project root>/config/config.json — set once at startup.
process.env.CONFIG_PATH = path.join(projectRoot, 'config', 'config.json');

const SCREENSHOTS_DIR = path.join(projectRoot, 'screenshots');
fs.mkdirSync(SCREENSHOTS_DIR, { recursive: true });

const app = express();
const PORT = process.env.PORT || 3000;

/**
 * Auth token resolution: AUTOMATION_UI_TOKEN env var first, then config
 * `ui.token`. With no token configured, only localhost requests are served.
 */
let cachedToken;
function getAuthToken() {
  if (cachedToken !== undefined) return cachedToken;
  if (process.env.AUTOMATION_UI_TOKEN) {
    cachedToken = process.env.AUTOMATION_UI_TOKEN;
    return cachedToken;
  }
  try {
    const config = configLoader.get();
    cachedToken = config?.ui?.token || null;
  } catch (error) {
    cachedToken = null;
  }
  return cachedToken;
}

function isLocalRequest(req) {
  const addr = req.socket?.remoteAddress || '';
  return addr === '127.0.0.1' || addr === '::1' || addr === '::ffff:127.0.0.1';
}

// EventSource cannot set headers, so the token is also accepted via ?token=
// (scoped to this trusted deployment; prefer headers for everything else).
function providedToken(req) {
  return (
    (req.get('authorization') || '').replace(/^Bearer\s+/i, '') ||
    req.get('x-auth-token') ||
    req.query.token ||
    ''
  );
}

function requireAuth(req, res, next) {
  const token = getAuthToken();
  if (token) {
    if (providedToken(req) !== token) {
      return res.status(401).json({ success: false, error: 'Unauthorized: missing or invalid token' });
    }
    return next();
  }
  if (!isLocalRequest(req)) {
    return res.status(401).json({
      success: false,
      error: 'Unauthorized: set AUTOMATION_UI_TOKEN (env) or ui.token (config.json) to allow non-local access'
    });
  }
  next();
}

// --- Job registry + single-run lock -------------------------------------

const jobs = new Map();
let activeJobId = null;

function isRunning(job) {
  return job.status === 'running';
}

function anyJobRunning() {
  return activeJobId !== null && jobs.get(activeJobId)?.status === 'running';
}

function jobSnapshot(job) {
  return {
    id: job.id,
    status: job.status,
    steps: job.steps,
    result: job.result,
    error: job.error,
    targetUrl: job.targetUrl,
    credentialName: job.credentialName,
    createdAt: job.createdAt,
    finishedAt: job.finishedAt,
    active: job.id === activeJobId && isRunning(job)
  };
}

function broadcast(job, eventName) {
  const payload = `event: ${eventName}\ndata: ${JSON.stringify(jobSnapshot(job))}\n\n`;
  for (const client of job.listeners) {
    client.write(payload);
  }
}

/**
 * Record a step on the job, replacing its provisional "running" entry with
 * the final one so the UI shows one entry per step.
 */
function recordStep(job, step) {
  const existing = job.steps.findIndex((entry) => entry.step === step.step);
  if (existing !== -1) {
    if (step.status === 'running') return;
    job.steps.splice(existing, 1);
  }
  job.steps.push(step);
}

async function runJob(job) {
  activeJobId = job.id;

  try {
    // Constructed inside the try: a constructor throw (e.g. missing config)
    // must fail the job and release the run lock, not hang it as 'running'.
    const orchestrator = new AutomationOrchestrator({
      onStep: (step) => {
        recordStep(job, step);
        broadcast(job, 'step');
      }
    });
    job.orchestrator = orchestrator;

    const result = await orchestrator.run(job.targetUrl, job.credentialName);
    job.result = result;
    job.status = result.success ? 'success' : result.cancelled ? 'cancelled' : 'failed';
  } catch (error) {
    console.error('Job failed:', error);
    job.error = error.message;
    job.status = 'failed';
  } finally {
    job.finishedAt = Date.now();
    if (activeJobId === job.id) {
      activeJobId = null;
    }
    broadcast(job, 'done');
  }
}

// --- App + routes ---------------------------------------------------------

app.use(express.json());
app.use(express.static(path.join(__dirname, 'public')));
app.use('/api', requireAuth);

app.get('/api/config-check', (req, res) => {
  try {
    const config = configLoader.get();
    res.json({
      valid: true,
      config: {
        emailalias: !!config.emailalias,
        passwords: !!config.passwords,
        receiving_email: !!config.receiving_email,
        sms_enabled: !!config.sms_provider?.enabled
      }
    });
  } catch (error) {
    res.json({ valid: false, error: error.message });
  }
});

app.post('/api/automate', (req, res) => {
  const { targetUrl, credentialName } = req.body || {};

  if (!targetUrl || !credentialName) {
    return res.status(400).json({
      success: false,
      error: 'targetUrl and credentialName are required'
    });
  }

  let parsedUrl;
  try {
    parsedUrl = new URL(targetUrl);
  } catch {
    return res.status(400).json({ success: false, error: 'targetUrl must be a valid URL' });
  }
  if (parsedUrl.protocol !== 'http:' && parsedUrl.protocol !== 'https:') {
    return res.status(400).json({ success: false, error: 'targetUrl must use http(s)' });
  }

  if (anyJobRunning()) {
    return res.status(409).json({
      success: false,
      error: 'Another automation is already running. Cancel it or wait for it to finish.',
      activeJobId
    });
  }

  const job = {
    id: randomUUID(),
    status: 'running',
    steps: [],
    result: null,
    error: null,
    targetUrl,
    credentialName,
    createdAt: Date.now(),
    finishedAt: null,
    orchestrator: null,
    listeners: new Set()
  };
  jobs.set(job.id, job);

  // Run in the background; respond immediately with tracking URLs.
  setImmediate(() => {
    runJob(job).catch((error) => console.error('Unexpected job error:', error));
  });

  res.json({
    success: true,
    jobId: job.id,
    statusUrl: `/api/status/${job.id}`,
    streamUrl: `/api/stream/${job.id}`
  });
});

app.get('/api/status/:sessionId', (req, res) => {
  const job = jobs.get(req.params.sessionId);
  if (!job) {
    return res.status(404).json({ error: 'Job not found' });
  }
  res.json(jobSnapshot(job));
});

app.get('/api/stream/:sessionId', (req, res) => {
  const job = jobs.get(req.params.sessionId);
  if (!job) {
    return res.status(404).json({ error: 'Job not found' });
  }

  res.writeHead(200, {
    'Content-Type': 'text/event-stream',
    'Cache-Control': 'no-cache',
    Connection: 'keep-alive'
  });

  res.write(`event: snapshot\ndata: ${JSON.stringify(jobSnapshot(job))}\n\n`);
  job.listeners.add(res);

  const heartbeat = setInterval(() => res.write(': ping\n\n'), 15000);

  req.on('close', () => {
    clearInterval(heartbeat);
    job.listeners.delete(res);
  });
});

app.delete('/api/sessions/:sessionId', async (req, res) => {
  const job = jobs.get(req.params.sessionId);
  if (!job) {
    return res.status(404).json({ error: 'Job not found' });
  }

  if (isRunning(job)) {
    job.orchestrator?.requestCancel();
    // Closing the browser here breaks any in-flight CLI command immediately.
    await job.orchestrator?.cleanup();
    return res.json({ success: true, cancelling: true });
  }

  jobs.delete(job.id);
  res.json({ success: true, deleted: true });
});

app.listen(PORT, () => {
  const token = getAuthToken();
  console.log(`Automation agent UI running at http://localhost:${PORT}`);
  console.log(
    token
      ? 'Auth: token required (env AUTOMATION_UI_TOKEN or config ui.token)'
      : 'Auth: no token configured — localhost access only'
  );
});
