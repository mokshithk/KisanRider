import { defineConfig, devices } from '@playwright/test';
import path from 'path';

process.env.PLAYWRIGHT_BROWSERS_PATH = path.resolve('D:/kisanRider-project/.playwright-browsers');

export default defineConfig({
  testDir: './e2e',
  timeout: 30000,
  expect: {
    timeout: 5000,
  },
  fullyParallel: false,
  reporter: 'list',
  use: {
    baseURL: 'http://localhost:4173',
    trace: 'on-first-retry',
    screenshot: 'only-on-failure',
  },
  projects: [
    {
      name: 'chromium',
      use: { ...devices['Desktop Chrome'] },
    },
  ],
  webServer: [
    {
      command: 'npm run preview -- --port 4173',
      url: 'http://localhost:4173',
      reuseExistingServer: true,
      timeout: 15000,
    },
  ],
});
