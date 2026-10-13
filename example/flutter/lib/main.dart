import 'package:e2b/e2b.dart';
import 'package:flutter/material.dart';

void main() => runApp(const E2BExample());

/// Inject a client configured by the host application to enable sandbox creation.
/// Keep long-lived API keys on a trusted backend when distributing an app.
class E2BExample extends StatefulWidget {
  final E2BClient? client;
  const E2BExample({super.key, this.client});

  @override
  State<E2BExample> createState() => _E2BExampleState();
}

class _E2BExampleState extends State<E2BExample> {
  String _status = 'Ready';
  bool _busy = false;

  Future<void> _create() async {
    setState(() {
      _busy = true;
      _status = 'Creating sandbox';
    });
    try {
      final sandbox = await widget.client!.create();
      if (mounted) setState(() => _status = 'Sandbox: ${sandbox.sandboxId}');
    } catch (error) {
      if (mounted) setState(() => _status = 'Error: $error');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) => MaterialApp(
        home: Scaffold(
          appBar: AppBar(title: const Text('E2B Flutter')),
          body: Center(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(_status),
                ElevatedButton(
                  onPressed: widget.client == null || _busy ? null : _create,
                  child: const Text('Create sandbox'),
                ),
              ],
            ),
          ),
        ),
      );
}
