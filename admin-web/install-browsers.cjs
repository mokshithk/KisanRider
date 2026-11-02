const { execSync } = require('child_process');
const path = require('path');

const browserPath = path.resolve('D:/kisanRider-project/.playwright-browsers');
console.log('Installing Playwright Chromium to:', browserPath);

process.env.PLAYWRIGHT_BROWSERS_PATH = browserPath;

try {
  execSync('npx playwright install chromium', {
    stdio: 'inherit',
    env: process.env,
  });
  console.log('Playwright Chromium installation completed on D drive.');
} catch (err) {
  console.error('Playwright installation error:', err);
  process.exit(1);
}
