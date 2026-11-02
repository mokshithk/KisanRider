const { execSync } = require('child_process');
const path = require('path');

process.env.PLAYWRIGHT_BROWSERS_PATH = path.resolve('D:/kisanRider-project/.playwright-browsers');

try {
  console.log('Executing Playwright E2E Browser Suite...');
  execSync('npx playwright test', {
    stdio: 'inherit',
    env: process.env,
  });
  console.log('Playwright E2E Suite Completed Successfully!');
} catch (err) {
  console.error('Playwright E2E test execution error:', err.status);
  process.exit(1);
}
