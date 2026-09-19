import AutomationOrchestrator from './automation/orchestrator.js';
import configLoader from './config/loader.js';

// Main CLI entry point
async function main() {
  const args = process.argv.slice(2);
  
  if (args.length < 2) {
    console.log('Usage: node src/index.js <targetUrl> <credentialName>');
    console.log('Example: node src/index.js https://example.com/register my-account-001');
    process.exit(1);
  }

  const [targetUrl, credentialName] = args;

  try {
    // Load configuration
    console.log('Loading configuration...');
    const config = configLoader.load();
    console.log('Configuration loaded successfully');

    // Create orchestrator and run automation
    const orchestrator = new AutomationOrchestrator({
      onStep: (step) => {
        const icon = step.status === 'success' ? '\u2705' : step.status === 'failed' ? '\u274c' : '\u23f3';
        const detail = step.duration != null ? ` (${step.duration}ms)` : '';
        const errorText = step.error ? ` \u2014 ${step.error}` : '';
        console.log(`${icon} ${step.step}${detail}${errorText}`);
      }
    });
    const result = await orchestrator.run(targetUrl, credentialName);

    // Output results
    console.log('\n=== AUTOMATION RESULTS ===');
    console.log(JSON.stringify(result, null, 2));

    if (result.success) {
      console.log('\n✅ Automation completed successfully!');
      console.log(`\nCredential Details:`);
      console.log(`Name: ${result.credential.name}`);
      console.log(`Email: ${result.credential.email}`);
      console.log(`Password: ${result.credential.password}`);
      if (result.credential.phone) {
        console.log(`Phone: ${result.credential.phone}`);
      }
      console.log(`\n⚠️  Please save these credentials securely!`);
    } else {
      console.log('\n❌ Automation failed!');
      console.log(`Error: ${result.error}`);
      process.exit(1);
    }

  } catch (error) {
    console.error('Fatal error:', error);
    process.exit(1);
  }
}

// Run if called directly
if (import.meta.url === `file://${process.argv[1]}`) {
  main();
}

export default main;