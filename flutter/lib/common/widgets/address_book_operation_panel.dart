import 'package:flutter/material.dart';

import '../../models/address_book_mutations.dart';

/// Recovery is independent of cached content and connection actions. Closing a
/// status message cannot erase journal evidence or grant write admission.
class AddressBookOperationPanel extends StatelessWidget {
  final bool ready;
  final bool busy;
  final String storageError;
  final String status;
  final List<PendingAddressBookOperation> pending;
  final Future<void> Function() onRefresh;
  final Future<void> Function(PendingAddressBookOperation) onRecover;
  final Future<void> Function(PendingAddressBookOperation, String) onReconcile;

  const AddressBookOperationPanel({
    super.key,
    required this.ready,
    required this.busy,
    required this.storageError,
    required this.status,
    required this.pending,
    required this.onRefresh,
    required this.onRecover,
    required this.onReconcile,
  });

  Future<void> _reconcile(
    BuildContext context,
    PendingAddressBookOperation operation,
  ) async {
    final confirmedId = await showDialog<String>(
      context: context,
      builder: (_) => _ReconcileOperationDialog(operation: operation),
    );
    if (confirmedId == operation.operationId) {
      await onReconcile(operation, confirmedId!);
    }
  }

  @override
  Widget build(BuildContext context) {
    if (ready &&
        !busy &&
        storageError.isEmpty &&
        status.isEmpty &&
        pending.isEmpty) {
      return const SizedBox.shrink();
    }
    return ConstrainedBox(
      constraints: BoxConstraints(
        maxHeight: MediaQuery.sizeOf(context).height * 0.35,
      ),
      child: SingleChildScrollView(
        child: Container(
          width: double.infinity,
          padding: const EdgeInsets.all(12),
          color: Theme.of(context).colorScheme.surfaceContainerHighest,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              if (busy)
                const Text(
                  'Address book operation in progress. Writes are disabled.',
                ),
              if (!ready && !busy && storageError.isEmpty)
                const Text(
                  'Check operation storage before editing the address book.',
                ),
              if (storageError.isNotEmpty) Text(storageError),
              if (status.isNotEmpty) Text(status),
              if (pending.isNotEmpty)
                const Text(
                  'An unresolved operation blocks new writes. Viewing and connecting remain available. '
                  'Look up its receipt using the original account and server; do not repeat the write.',
                ),
              for (final operation in pending) ...[
                SelectableText(operation.operationId),
                Wrap(
                  spacing: 8,
                  children: [
                    TextButton(
                      onPressed: busy ? null : () => onRecover(operation),
                      child: const Text('Look up receipt'),
                    ),
                    TextButton(
                      onPressed: busy
                          ? null
                          : () => _reconcile(context, operation),
                      child: const Text('Manual reconciliation'),
                    ),
                  ],
                ),
              ],
              if (!busy)
                TextButton(
                  onPressed: onRefresh,
                  child: const Text('Check operation storage'),
                ),
            ],
          ),
        ),
      ),
    );
  }
}

class _ReconcileOperationDialog extends StatefulWidget {
  final PendingAddressBookOperation operation;
  const _ReconcileOperationDialog({required this.operation});

  @override
  State<_ReconcileOperationDialog> createState() =>
      _ReconcileOperationDialogState();
}

class _ReconcileOperationDialogState extends State<_ReconcileOperationDialog> {
  final _controller = TextEditingController();
  var _verified = false;

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
    title: const Text('Manual operation reconciliation'),
    content: SingleChildScrollView(
      child: SizedBox(
        width: 440,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text(
              'First verify the original operation and resulting state on the original server and account. '
              'A missing receipt, expired retention, or failed connection does not prove that nothing changed. '
              'Clearing this record allows new writes and never retries the original operation.',
            ),
            const SizedBox(height: 12),
            SelectableText(widget.operation.operationId),
            TextField(
              key: const ValueKey('reconcile-operation-id'),
              controller: _controller,
              decoration: const InputDecoration(
                labelText: 'Enter the complete operation ID',
              ),
              onChanged: (_) => setState(() {}),
            ),
            CheckboxListTile(
              key: const ValueKey('reconcile-verified'),
              contentPadding: EdgeInsets.zero,
              title: const Text(
                'I verified the original state and resolved this operation manually.',
              ),
              value: _verified,
              onChanged: (value) => setState(() => _verified = value == true),
            ),
          ],
        ),
      ),
    ),
    actions: [
      TextButton(
        onPressed: () => Navigator.pop(context),
        child: const Text('Cancel'),
      ),
      TextButton(
        key: const ValueKey('reconcile-confirm'),
        onPressed: _verified && _controller.text == widget.operation.operationId
            ? () => Navigator.pop(context, _controller.text)
            : null,
        child: const Text('Clear reconciled record'),
      ),
    ],
  );
}
