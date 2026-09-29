import 'package:flutter/material.dart';

enum ClaritasSyncState { idle, syncing, current, failed }

final class ClaritasSyncStatus extends StatelessWidget {
  const ClaritasSyncStatus({
    required this.state,
    this.revision,
    this.errorMessage,
    super.key,
  });

  final ClaritasSyncState state;
  final int? revision;
  final String? errorMessage;

  String get _statusLabel {
    switch (state) {
      case ClaritasSyncState.idle:
        return 'Idle';
      case ClaritasSyncState.syncing:
        return 'Syncing';
      case ClaritasSyncState.current:
        if (revision == null) {
          return 'Current';
        }
        return 'Current · revision $revision';
      case ClaritasSyncState.failed:
        return errorMessage == null
            ? 'Sync failed'
            : 'Sync failed · $errorMessage';
    }
  }

  @override
  Widget build(BuildContext context) {
    final Widget indicator;
    if (state == ClaritasSyncState.syncing) {
      indicator = const SizedBox.square(
        dimension: 16,
        child: CircularProgressIndicator(strokeWidth: 2),
      );
    } else {
      indicator = Icon(
        state == ClaritasSyncState.failed ? Icons.error_outline : Icons.sync,
        size: 18,
      );
    }

    return Semantics(
      container: true,
      label: 'Claritas sync status: $_statusLabel',
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          indicator,
          const SizedBox(width: 8),
          Flexible(child: Text(_statusLabel)),
        ],
      ),
    );
  }
}
