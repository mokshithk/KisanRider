import 'package:flutter/material.dart';

import 'rider_common.dart';

/// Tab 2 of the rider shell — placeholder for the earnings / settlement
/// history view. Replaced with a real feed once the payout workflow is
/// wired into the rider app.
class RiderEarningsTab extends StatelessWidget {
  const RiderEarningsTab({super.key});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return SafeArea(
      child: Center(
        child: Padding(
          padding: const EdgeInsets.all(32),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Container(
                padding: const EdgeInsets.all(24),
                decoration: BoxDecoration(
                  color: kRiderGreen.withOpacity(0.08),
                  shape: BoxShape.circle,
                ),
                child: const Icon(
                  Icons.account_balance_wallet_outlined,
                  size: 64,
                  color: kRiderGreen,
                ),
              ),
              const SizedBox(height: 24),
              Text(
                'Earnings',
                style: theme.textTheme.titleLarge?.copyWith(
                  fontWeight: FontWeight.w600,
                ),
                textAlign: TextAlign.center,
              ),
              const SizedBox(height: 8),
              Text(
                'Earnings & Settlement features coming soon',
                style: theme.textTheme.bodyMedium?.copyWith(
                  color: theme.colorScheme.onSurfaceVariant,
                ),
                textAlign: TextAlign.center,
              ),
            ],
          ),
        ),
      ),
    );
  }
}