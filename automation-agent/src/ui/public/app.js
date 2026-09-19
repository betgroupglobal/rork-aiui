// DOM Elements
const automationForm = document.getElementById('automationForm');
const targetUrlInput = document.getElementById('targetUrl');
const credentialNameInput = document.getElementById('credentialName');
const authTokenInput = document.getElementById('authToken');
const goButton = document.getElementById('goButton');
const cancelButton = document.getElementById('cancelButton');
const btnText = goButton.querySelector('.btn-text');
const btnLoading = goButton.querySelector('.btn-loading');
const configStatus = document.getElementById('configStatus');
const progressSection = document.getElementById('progressSection');
const progressContent = document.getElementById('progressContent');
const resultsSection = document.getElementById('resultsSection');
const resultsContent = document.getElementById('resultsContent');
const logsSection = document.getElementById('logsSection');
const logsContent = document.getElementById('logsContent');

const TOKEN_STORAGE_KEY = 'automation-agent-token';

let currentJobId = null;
let eventSource = null;

// Check configuration on load
document.addEventListener('DOMContentLoaded', () => {
    authTokenInput.value = localStorage.getItem(TOKEN_STORAGE_KEY) || '';
    authTokenInput.addEventListener('change', () => {
        localStorage.setItem(TOKEN_STORAGE_KEY, authTokenInput.value.trim());
    });
    checkConfiguration();
});

// Form submission
automationForm.addEventListener('submit', handleAutomation);
cancelButton.addEventListener('click', handleCancel);

function authHeaders() {
    const token = authTokenInput.value.trim();
    return token ? { 'Authorization': `Bearer ${token}` } : {};
}

function escapeHtml(value) {
    const div = document.createElement('div');
    div.textContent = String(value ?? '');
    return div.innerHTML;
}

function addLog(message, className = '') {
    const time = new Date().toLocaleTimeString();
    logsContent.innerHTML += `
        <div class="log-entry">
            <span class="log-time">[${time}]</span>
            <span class="log-message ${className}">${message}</span>
        </div>
    `;
    logsContent.scrollTop = logsContent.scrollHeight;
}

async function checkConfiguration() {
    try {
        const response = await fetch('/api/config-check', { headers: authHeaders() });

        if (response.status === 401) {
            const data = await response.json().catch(() => ({}));
            configStatus.className = 'status-error';
            configStatus.innerHTML = `
                <span class="status-icon">🔒</span>
                <span>${escapeHtml(data.error || 'Unauthorized: enter your access token above')}</span>
            `;
            return;
        }

        const data = await response.json();

        if (data.valid) {
            configStatus.className = 'status-ok';
            configStatus.innerHTML = `
                <span class="status-icon">✅</span>
                <span>Configuration is valid and ready${data.config?.sms_enabled ? ' (SMS enabled)' : ''}</span>
            `;
        } else {
            configStatus.className = 'status-error';
            configStatus.innerHTML = `
                <span class="status-icon">❌</span>
                <span>Configuration error: ${escapeHtml(data.error)}</span>
            `;
        }
    } catch (error) {
        configStatus.className = 'status-error';
        configStatus.innerHTML = `
            <span class="status-icon">❌</span>
            <span>Failed to check configuration</span>
        `;
    }
}

async function handleAutomation(e) {
    e.preventDefault();

    const targetUrl = targetUrlInput.value.trim();
    const credentialName = credentialNameInput.value.trim();

    if (!targetUrl || !credentialName) {
        alert('Please fill in all fields');
        return;
    }

    localStorage.setItem(TOKEN_STORAGE_KEY, authTokenInput.value.trim());

    // Disable button and show loading state
    goButton.disabled = true;
    btnText.classList.add('hidden');
    btnLoading.classList.remove('hidden');
    cancelButton.classList.remove('hidden');

    // Reset previous output
    resultsSection.classList.add('hidden');
    resultsContent.innerHTML = '';
    progressSection.classList.remove('hidden');
    progressContent.innerHTML = '';
    logsSection.classList.remove('hidden');
    logsContent.innerHTML = '';

    try {
        const response = await fetch('/api/automate', {
            method: 'POST',
            headers: { 'Content-Type': 'application/json', ...authHeaders() },
            body: JSON.stringify({ targetUrl, credentialName })
        });

        if (response.status === 401) {
            const data = await response.json().catch(() => ({}));
            throw new Error(data.error || 'Unauthorized: enter your access token');
        }
        if (response.status === 409) {
            const data = await response.json().catch(() => ({}));
            throw new Error(data.error || 'Another automation is already running');
        }
        if (!response.ok) {
            const data = await response.json().catch(() => ({}));
            throw new Error(data.error || `Request failed (${response.status})`);
        }

        const data = await response.json();
        currentJobId = data.jobId;
        addLog(`Job started (${data.jobId}) — streaming progress...`);
        streamJob(data.jobId);
    } catch (error) {
        addLog(`Error: ${escapeHtml(error.message)}`, 'step-failed');
        resetRunState();
    }
}

/**
 * Follow a running job over SSE and render step-by-step progress.
 * Falls back to polling if EventSource fails.
 */
function streamJob(jobId) {
    const token = authTokenInput.value.trim();
    const url = `/api/stream/${encodeURIComponent(jobId)}${token ? `?token=${encodeURIComponent(token)}` : ''}`;

    try {
        eventSource = new EventSource(url);
    } catch (error) {
        pollJob(jobId);
        return;
    }

    let fellBack = false;
    eventSource.onerror = () => {
        // On connection failure, fall back to status polling once.
        if (!fellBack && !eventSource.readyState) {
            fellBack = true;
            eventSource.close();
            pollJob(jobId);
        }
    };
    eventSource.addEventListener('snapshot', (event) => renderJob(parse(event)));
    eventSource.addEventListener('step', (event) => renderJob(parse(event)));
    eventSource.addEventListener('done', (event) => {
        eventSource.close();
        eventSource = null;
        renderJob(parse(event));
        resetRunState();
    });

    function parse(event) {
        try {
            return JSON.parse(event.data);
        } catch {
            return null;
        }
    }
}

async function pollJob(jobId) {
    try {
        const response = await fetch(`/api/status/${encodeURIComponent(jobId)}`, { headers: authHeaders() });
        if (!response.ok) throw new Error(`Status failed (${response.status})`);
        const job = await response.json();
        renderJob(job);
        if (job.status === 'running') {
            setTimeout(() => pollJob(jobId), 1500);
        } else {
            resetRunState();
        }
    } catch (error) {
        addLog(`Error: ${escapeHtml(error.message)}`, 'step-failed');
        resetRunState();
    }
}

const STEP_LABELS = {
    create_email: 'Create email alias',
    generate_password: 'Generate password',
    start_browser: 'Start browser',
    fill_form: 'Fill registration form',
    handle_verification: 'Handle verification',
    complete_registration: 'Complete registration'
};

function renderJob(job) {
    if (!job) return;

    // Live progress chips
    progressContent.innerHTML = job.steps.map((step) => {
        const label = STEP_LABELS[step.step] || step.step;
        const state = step.status === 'success' ? 'step-success'
            : step.status === 'failed' ? 'step-failed'
            : 'step-running';
        const icon = step.status === 'success' ? '✅'
            : step.status === 'failed' ? '❌'
            : '⏳';
        const detail = step.error
            ? `<div class="step-detail">${escapeHtml(step.error)}</div>`
            : step.result?.filled?.length
                ? `<div class="step-detail">filled: ${escapeHtml(step.result.filled.join(', '))}${step.result.skipped?.length ? ` · skipped: ${escapeHtml(step.result.skipped.join(', '))}` : ''}</div>`
                : '';
        return `
            <div class="progress-entry ${state}">
                <span>${icon} ${escapeHtml(label)}</span>
                ${step.duration != null ? `<span class="step-duration">${step.duration}ms</span>` : ''}
                ${detail}
            </div>
        `;
    }).join('');

    // Append-only execution log
    const lastLogged = logsContent.dataset.lastStepCount || 0;
    for (const step of job.steps.slice(Number(lastLogged))) {
        const state = step.status === 'success' ? 'step-success'
            : step.status === 'failed' ? 'step-failed'
            : 'step-running';
        const icon = step.status === 'success' ? '✅'
            : step.status === 'failed' ? '❌'
            : '⏳';
        addLog(`${icon} <span class="${state}">${escapeHtml(STEP_LABELS[step.step] || step.step)}</span>${step.duration != null ? ` (${step.duration}ms)` : ''}`);
        if (step.error) {
            addLog(`&nbsp;&nbsp;↳ ${escapeHtml(step.error)}`, 'step-failed');
        }
    }
    logsContent.dataset.lastStepCount = String(job.steps.length);

    // Final result
    if (job.status && job.status !== 'running') {
        if (job.status === 'success') {
            displayResults(job.result || { success: true, credential: null });
        } else {
            displayResults({
                success: false,
                error: job.result?.error || job.error || (job.status === 'cancelled' ? 'Job was cancelled' : 'Job failed'),
                error_screenshot: job.result?.error_screenshot,
                cancelled: job.status === 'cancelled'
            });
        }
    }
}

async function handleCancel() {
    if (!currentJobId) return;
    try {
        const response = await fetch(`/api/sessions/${encodeURIComponent(currentJobId)}`, {
            method: 'DELETE',
            headers: authHeaders()
        });
        if (!response.ok) {
            const data = await response.json().catch(() => ({}));
            throw new Error(data.error || `Cancel failed (${response.status})`);
        }
        addLog('Cancel requested — stopping the run...', 'step-failed');
        cancelButton.disabled = true;
    } catch (error) {
        addLog(`Cancel failed: ${escapeHtml(error.message)}`, 'step-failed');
    }
}

function resetRunState() {
    goButton.disabled = false;
    btnText.classList.remove('hidden');
    btnLoading.classList.add('hidden');
    cancelButton.classList.add('hidden');
    cancelButton.disabled = false;
    currentJobId = null;
    if (eventSource) {
        eventSource.close();
        eventSource = null;
    }
}

function displayResults(result) {
    resultsSection.classList.remove('hidden');

    if (result.success && result.credential) {
        resultsContent.innerHTML = `
            <div class="results-content">
                <h3>✅ Automation Successful</h3>
                <div class="credential-card">
                    <strong>Credential Name:</strong> ${escapeHtml(result.credential.name)}
                </div>
                <div class="credential-card">
                    <strong>Email:</strong> ${escapeHtml(result.credential.email)}
                </div>
                <div class="credential-card">
                    <strong>Password:</strong> ********
                </div>
                ${result.credential.phone ? `
                <div class="credential-card">
                    <strong>Phone:</strong> ${escapeHtml(result.credential.phone)}
                </div>
                ` : ''}
                <div class="credential-card">
                    <strong>Created:</strong> ${new Date(result.credential.created_at).toLocaleString()}
                </div>
                <p style="margin-top: 15px; color: #667eea; font-weight: 600;">
                    ⚠️ Please save your credentials securely. The password will not be shown again.
                </p>
            </div>
        `;
    } else {
        const title = result.cancelled ? '🛑 Automation Cancelled' : '❌ Automation Failed';
        resultsContent.innerHTML = `
            <div class="results-content" style="border-left-color: #dc3545;">
                <h3>${title}</h3>
                <p><strong>Error:</strong> ${escapeHtml(result.error || 'Unknown error')}</p>
                ${result.error_screenshot ? `<p><strong>Screenshot:</strong> ${escapeHtml(result.error_screenshot)}</p>` : ''}
            </div>
        `;
    }
}
