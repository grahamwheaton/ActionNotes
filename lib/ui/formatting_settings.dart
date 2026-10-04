import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../models/view_preferences.dart';
import '../state/app_state.dart';
import 'theme.dart';

class FormattingSettingsScreen extends StatelessWidget {
  const FormattingSettingsScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final state = context.watch<AppState>();
    final preferences = state.viewPreferences;
    final format = preferences.formatting;
    void save(NoteFormatting value) => state.setViewPreferences(
        state.viewPreferences.copyWith(formatting: value));
    return Scaffold(
      appBar: AppBar(title: const Text('Formatting')),
      body: ListView(padding: const EdgeInsets.all(24), children: [
        const Text('Saved on this device. Changes apply to existing notes as well as new ones.'),
        const SizedBox(height: 24),
        Text('Page layout', style: Theme.of(context).textTheme.titleLarge),
        const SizedBox(height: 8),
        const Text('Notes use the full available width inside these margins.'),
        _FormatSlider(label: 'Left and right margins', value: format.horizontalMargin,
          min: 0, max: 80, unit: 'px',
          onChanged: (value) => save(format.copyWith(horizontalMargin: value))),
        _FormatSlider(label: 'Top and bottom margins', value: format.verticalMargin,
          min: 0, max: 80, unit: 'px',
          onChanged: (value) => save(format.copyWith(verticalMargin: value))),
        const SizedBox(height: 16),
        Text('Typography', style: Theme.of(context).textTheme.titleLarge),
        const SizedBox(height: 12),
        DropdownButtonFormField<String>(
          key: ValueKey(format.font),
          initialValue: format.font,
          decoration: const InputDecoration(labelText: 'Font'),
          items: [for (final font in ['System', 'Serif', 'Monospace'])
            DropdownMenuItem(value: font, child: Text(font))],
          onChanged: (value) { if (value != null) save(format.copyWith(font: value)); },
        ),
        _FormatSlider(label: 'Text size', value: format.fontSize,
          min: 12, max: 26, unit: 'px',
          onChanged: (value) => save(format.copyWith(fontSize: value))),
        _FormatSlider(label: 'Line spacing', value: format.lineHeight,
          min: 1.1, max: 2.2, unit: '×', precision: 2,
          onChanged: (value) => save(format.copyWith(lineHeight: value))),
        _FormatSlider(label: 'Paragraph spacing', value: format.paragraphSpacing,
          min: 0, max: 24, unit: 'px',
          onChanged: (value) => save(format.copyWith(paragraphSpacing: value))),
        _FormatSlider(label: 'Heading size', value: format.headingScale,
          min: .8, max: 1.6, unit: '×', precision: 2,
          onChanged: (value) => save(format.copyWith(headingScale: value))),
        const SizedBox(height: 16),
        Text('Sidebar', style: Theme.of(context).textTheme.titleLarge),
        _FormatSlider(label: 'Sidebar width', value: preferences.sidebarWidth,
          min: 220, max: 600, unit: 'px',
          onChanged: (value) => state.setViewPreferences(
            state.viewPreferences.copyWith(sidebarWidth: value))),
        const Text('You can also drag its right edge. The displayed width adapts to the window.'),
        const SizedBox(height: 24),
        Card(child: Padding(padding: EdgeInsets.symmetric(
          horizontal: format.horizontalMargin.clamp(0, 40).toDouble(),
          vertical: format.verticalMargin.clamp(0, 40).toDouble()),
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text('Preview', style: NoteTypography.heading(Theme.of(context), 2, format)),
            SizedBox(height: format.paragraphSpacing),
            Text('Notes fill the available page, with your preferred margins and spacing.',
              style: NoteTypography.body(Theme.of(context), format)),
          ]),
        )),
        const SizedBox(height: 16),
        OutlinedButton.icon(
          onPressed: () => state.setViewPreferences(state.viewPreferences.copyWith(
            formatting: const NoteFormatting(), sidebarWidth: 280)),
          icon: const Icon(Icons.restore), label: const Text('Reset formatting and width'),
        ),
      ]),
    );
  }
}

class _FormatSlider extends StatelessWidget {
  const _FormatSlider({required this.label, required this.value,
    required this.min, required this.max, required this.unit,
    required this.onChanged, this.precision = 0});
  final String label, unit;
  final double value, min, max;
  final int precision;
  final ValueChanged<double> onChanged;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.only(top: 16),
    child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      Text('$label: ${value.toStringAsFixed(precision)} $unit'),
      Slider(value: value.clamp(min, max).toDouble(), min: min, max: max,
        label: value.toStringAsFixed(precision),
        onChanged: onChanged),
    ]),
  );
}
