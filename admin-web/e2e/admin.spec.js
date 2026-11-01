import { test, expect } from '@playwright/test';

test.describe('KisanRider Admin Web — Complete End-to-End Suite', () => {

  test('Page 1 — Login Rendering & Authentication Validation', async ({ page }) => {
    await page.goto('/login');
    await expect(page.locator('h2')).toContainText('KisanRider Admin Web');

    // Invalid credentials attempt
    await page.fill('input[type="email"]', 'wrong_admin@kisanrider.in');
    await page.fill('input[type="password"]', 'WrongPassword999!');
    await page.click('button[type="submit"]');

    await expect(page.locator('text=Invalid admin credentials')).toBeVisible({ timeout: 10000 });
  });

  test('Successful Admin Login and Complete Session Navigation Across All Pages', async ({ page }) => {
    // 1. Log in with provisioned credentials
    await page.goto('/login');
    await page.fill('input[type="email"]', 'admin@kisanrider.in');
    await page.fill('input[type="password"]', 'AdminSecure2026!');
    await page.click('button[type="submit"]');

    // Redirected to Dashboard
    await expect(page).toHaveURL('/');
    await expect(page.locator('h2')).toContainText('KisanRider Operational Overview');

    // 2. Dashboard — Check Stat Cards
    await expect(page.locator('span:has-text("Total Farmers")').first()).toBeVisible();
    await expect(page.locator('span:has-text("Total Riders")').first()).toBeVisible();
    await expect(page.locator('span:has-text("Total Trips")').first()).toBeVisible();
    await expect(page.locator('span:has-text("Completed Trips")').first()).toBeVisible();
    await expect(page.locator('span:has-text("Active Pools")').first()).toBeVisible();
    await expect(page.locator('span:has-text("Pending Settlements")').first()).toBeVisible();
    await expect(page.locator('span:has-text("Total Payout Volume")').first()).toBeVisible();

    // 3. Navigate to Farmers
    await page.click('a[href="/farmers"]');
    await expect(page).toHaveURL('/farmers');
    await expect(page.locator('text=Policy Note:')).toBeVisible();
    await expect(page.locator('table').first()).toBeVisible();

    // Test Farmer Details Modal
    const viewFarmerButtons = page.locator('button[title="View Details"]');
    if (await viewFarmerButtons.count() > 0) {
      await viewFarmerButtons.first().click();
      await expect(page.locator('h3:has-text("Farmer Details")').or(page.locator('h3:has-text("Farmer")'))).toBeVisible({ timeout: 5000 });
      await page.click('button:has-text("Close")');
    }

    // 4. Navigate to Riders
    await page.click('a[href="/riders"]');
    await expect(page).toHaveURL('/riders');
    await expect(page.locator('table').first()).toBeVisible();

    // 5. Navigate to Transport Requests
    await page.click('a[href="/transport-requests"]');
    await expect(page).toHaveURL('/transport-requests');
    await expect(page.locator('table').first()).toBeVisible();

    // 6. Navigate to Trips
    await page.click('a[href="/trips"]');
    await expect(page).toHaveURL('/trips');
    await expect(page.locator('table').first()).toBeVisible();

    // 7. Navigate to Farmer Pools
    await page.click('a[href="/pools"]');
    await expect(page).toHaveURL('/pools');
    await expect(page.locator('table').first()).toBeVisible();

    // 8. Navigate to Settlements
    await page.click('a[href="/settlements"]');
    await expect(page).toHaveURL('/settlements');
    await expect(page.locator('table').first()).toBeVisible();

    // 9. Navigate to Mandi Prices
    await page.click('a[href="/mandi-prices"]');
    await expect(page).toHaveURL('/mandi-prices');
    await expect(page.locator('table').first()).toBeVisible();
    await expect(
      page.locator('text=Live Agmarknet Data Feed').or(page.locator('text=Local Fallback Dataset'))
    ).toBeVisible();

    // 10. Navigate to Reports & Analytics
    await page.click('a[href="/reports"]');
    await expect(page).toHaveURL('/reports');
    await expect(page.locator('button:has-text("Download Official CSV")')).toBeVisible();

    // Switch report tab
    await page.click('button:has-text("Transport Dispatches")');
    await expect(page.locator('th:has-text("Mandi District")')).toBeVisible();

    // 11. Navigate to Admin Management
    await page.click('a[href="/admin-management"]');
    await expect(page).toHaveURL('/admin-management');
    await expect(page.locator('h3:has-text("Active Administrators")')).toBeVisible();
    await expect(page.locator('h3:has-text("Pending Invitations")')).toBeVisible();
    await expect(page.locator('button:has-text("Invite New Administrator")')).toBeVisible();

    // 12. Navigate to Activity Logs
    await page.click('a[href="/activity-logs"]');
    await expect(page).toHaveURL('/activity-logs');
    await expect(page.locator('table').first()).toBeVisible();
    await expect(page.locator('text=ADMIN_LOGIN').first()).toBeVisible();

    // 13. Navigate to Profile & Logout
    await page.click('a[href="/profile"]');
    await expect(page).toHaveURL('/profile');
    await expect(page.locator('h3:has-text("Change Password")')).toBeVisible();
    await expect(page.locator('button:has-text("End Session")')).toBeVisible();

    // Log out
    await page.click('button:has-text("End Session")');
    await expect(page).toHaveURL('/login');
  });

  test('Page 14 — Accept Invitation Onboarding View', async ({ page }) => {
    await page.goto('/accept-invitation?token=mock_test_token_12345');
    await expect(page.locator('h2')).toContainText('Administrator Onboarding');
    await expect(page.locator('input[placeholder="••••••••••••"]').first()).toBeVisible();
  });
});
