import 'package:flutter/material.dart';

/// Descriptor for a single segment inside [SegmentedFilterBar].
class SegmentedFilterOption<T> {
  const SegmentedFilterOption({
    required this.value,
    required this.label,
  });

  final T value;
  final String label;
}

/// Connected pill-style `SegmentedButton` filter bar shared by Active Trips
/// and My Orders, matching the Available Requests toggle layout.
class SegmentedFilterBar<T> extends StatelessWidget {
  const SegmentedFilterBar({
    super.key,
    required this.options,
    required this.selectedValue,
    required this.onChanged,
    required this.accentColor,
    this.padding = const EdgeInsets.symmetric(horizontal: 12.0, vertical: 8.0),
  });

  final List<SegmentedFilterOption<T>> options;
  final T selectedValue;
  final ValueChanged<T> onChanged;
  final Color accentColor;
  final EdgeInsetsGeometry padding;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: padding,
      child: LayoutBuilder(
        builder: (context, constraints) {
          return Center(
            child: ConstrainedBox(
              constraints: BoxConstraints(maxWidth: constraints.maxWidth),
              child: FittedBox(
                fit: BoxFit.scaleDown,
                child: SegmentedButton<T>(
                  segments: [
                    for (final option in options)
                      ButtonSegment<T>(
                        value: option.value,
                        label: Text(
                          option.label,
                          maxLines: 1,
                          softWrap: false,
                        ),
                      ),
                  ],
                  selected: {selectedValue},
                  onSelectionChanged: (selection) {
                    if (selection.isNotEmpty) {
                      onChanged(selection.first);
                    }
                  },
                  style: SegmentedButton.styleFrom(
                    selectedBackgroundColor: accentColor,
                    selectedForegroundColor: Colors.white,
                    foregroundColor: accentColor,
                    side: BorderSide(color: accentColor.withValues(alpha: 0.4)),
                    visualDensity: VisualDensity.compact,
                    padding: const EdgeInsets.symmetric(horizontal: 10),
                  ),
                ),
              ),
            ),
          );
        },
      ),
    );
  }
}
