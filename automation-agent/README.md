# Automation Agent

Browser automation system for account creation with email/SMS verification using emailalias.io and crazytel.

## Features

- **Email Alias Creation**: Automatically creates email aliases using emailalias.io API
- **Password Generation**: Configurable password generation strategies (random, fixed, pattern-based)
- **Email Verification**: Reads verification codes from configured receiving email via IMAP
- **SMS Verification**: Optional SMS verification using crazytel
- **Browser Automation**: Uses agent-browser for form filling and website interaction
- **Web UI**: Simple web interface for running automations
- **CLI Support**: Command-line interface for scripting

## Setup

### Prerequisites

- Node.js 18+
- agent-browser CLI installed: `npm i -g agent-browser && agent-browser install`
- Valid emailalias.io API credentials
- Configured receiving email with IMAP access
- Optional: crazytel API credentials for SMS verification

**Note**: agent-browser is a separate CLI tool that must be installed globally. The automation uses it via shell commands rather than as an npm package.

### Installation

1. Clone the repository and navigate to the automation-agent directory
2. Install dependencies:
```bash
npm install
```

3. Copy the example configuration:
```bash
cp config/config.example.json config/config.json
```

4. Edit `config/config.json` with your credentials:
```json
{
  "emailalias": {
    "api_key": "your_emailalias_api_key_here",
    "api_url": "https://emailalias.io/api",
    "domain": "optional_custom_domain.com"
  },
  "passwords": {
    "selection_strategy": "random",
    "min_length": 12,
    "include_numbers": true,
    "include_symbols": true
  },
  "receiving_email": {
    "email_address": "your_email@example.com",
    "access_method": "imap",
    "imap_server": "imap.example.com",
    "imap_port": 993,
    "email_password": "your_email_password"
  },
  "sms_provider": {
    "enabled": false,
    "provider": "crazytel",
    "api_key": "your_crazytel_api_key",
    "api_url": "https://api.crazytel.com",
    "phone_number": "+1234567890"
  },
  "automation": {
    "timeout": 30,
    "headless": true,
    "screenshot_on_error": true,
    "log_level": "info"
  }
}
```

## Usage

### Web UI

Start the web server:
```bash
npm run ui
```

Open http://localhost:3000 in your browser and:
1. Enter your access token (only needed when the server has one configured)
2. Enter the target registration URL
3. Enter a credential name (used for email generation)
4. Click "Go" to start the automation

Runs execute as background jobs: the UI shows each step live (via server-sent
events, with automatic polling fallback) and a **Cancel** button stops the run
and closes its browser immediately.

#### Web UI authentication

By default the API only accepts requests from localhost. To make it reachable
from other machines, set a token — either via the environment:

```bash
AUTOMATION_UI_TOKEN=your-secret-token npm run ui
```

or in `config/config.json`:

```json
"ui": { "token": "your-secret-token" }
```

Requests authenticate with `Authorization: Bearer <token>` — the web UI's
token field handles this automatically (it is stored in your browser's
localStorage).

### CLI

Run automation from command line:
```bash
npm start https://example.com/register my-account-001
```

## Configuration

### Email Alias Service

Configure emailalias.io credentials in the `emailalias` section:
- `api_key`: Your emailalias.io API key
- `api_url`: API endpoint (default: https://emailalias.io/api)
- `domain`: Optional custom domain for email aliases

### Password Configuration

Configure password generation in the `passwords` section:
- `selection_strategy`: "random", "fixed", or "pattern"
- `fixed_password`: Fixed password (if strategy is "fixed")
- `password_pattern`: Pattern for generation (if strategy is "pattern")
- `min_length`: Minimum password length (default: 12)
- `include_numbers`: Include numbers in random passwords (default: true)
- `include_symbols`: Include symbols in random passwords (default: true)

### Receiving Email

Configure email for receiving verification codes in the `receiving_email` section:
- `email_address`: Email address to receive codes
- `access_method`: "imap", "api", or "pop3"
- `imap_server`: IMAP server address (if using IMAP)
- `imap_port`: IMAP port (default: 993)
- `email_password`: Password for email access

### SMS Provider

Configure SMS verification in the `sms_provider` section:
- `enabled`: Enable SMS verification (default: false)
- `provider`: SMS provider (default: "crazytel")
- `api_key`: crazytel API key
- `api_url`: crazytel API endpoint
- `phone_number`: Phone number for verification

### Automation Settings

Configure general automation behavior in the `automation` section:
- `timeout`: Timeout for automation steps in seconds (default: 30)
- `headless`: Run browser in headless mode (default: true)
- `screenshot_on_error`: Take screenshot on errors (default: true)
- `log_level`: Logging level (default: "info")

## How It Works

1. **Email Creation**: Creates an email alias based on the credential name using emailalias.io (with retry/backoff and explicit rate-limit handling)
2. **Password Generation**: Generates a password using the configured strategy
3. **Browser Automation**: Opens the target URL and fills registration forms — email, password, confirm-password, and name fields when present (every browser command runs as a safe process spawn with a per-command timeout)
4. **Verification Handling**: 
   - For email verification: Polls the configured receiving mailbox (peek-fetch, so messages stay unread) for a code addressed to the alias
   - For SMS verification: Uses crazytel to receive and extract SMS codes; the rented number is always released, even on timeout
   - If a page requires SMS but no SMS provider is configured, the run fails fast with a clear message
5. **Form Completion**: Fills verification codes, submits, and completes registration
6. **Credential Output**: Returns the generated credentials (email, password, phone)

If a run fails mid-way, the orphaned alias is deleted automatically and an
error screenshot is saved to `screenshots/`.

## Security Notes

- Never commit `config/config.json` to version control
- Use strong, unique passwords for your emailalias.io and receiving email accounts
- Consider using environment variables for sensitive credentials
- The automation runs browser automation - ensure you have permission to automate the target site
- Generated credentials are displayed once - save them securely
- **Web UI access**: set `AUTOMATION_UI_TOKEN` or `config.ui.token` to require a
  token on all API endpoints; without a token only localhost can connect
- Browser commands never pass values through a shell (argument-array spawning),
  so passwords and URLs cannot be shell-interpreted

## Troubleshooting

### Browser fails to start
- Ensure agent-browser is installed: `agent-browser install`
- Check that Chrome/Chromium is available on your system

### Email verification fails
- Verify IMAP credentials and server settings
- Check that the receiving email can access emails from the alias service
- Ensure emails are not being filtered as spam

### SMS verification fails
- Verify crazytel API credentials
- Check that SMS is enabled in configuration
- Ensure phone number is properly formatted

### Form filling fails
- Some sites may have custom form structures not automatically detected
- Consider running in non-headless mode for debugging: set `"headless": false`
- Check screenshots taken on error for visual debugging

## Development

Run in development mode with auto-reload:
```bash
npm run dev
```

## License

MIT