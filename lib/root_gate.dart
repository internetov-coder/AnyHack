import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'root_shell.dart';

// стартовый экран: без root в приложение не пускаем
class RootGate extends StatefulWidget {
  const RootGate({super.key, required this.onGranted});

  final VoidCallback onGranted;

  @override
  State<RootGate> createState() => _RootGateState();
}

class _RootGateState extends State<RootGate> {
  bool _checking = true;
  String? _error;

  @override
  void initState() {
    super.initState();
    _check();
  }

  Future<void> _check() async {
    setState(() {
      _checking = true;
      _error = null;
    });
    final ok = await RootShell.instance.probeSu();
    if (!mounted) return;
    if (ok) {
      widget.onGranted();
    } else {
      setState(() {
        _checking = false;
        _error = 'root не выдан';
      });
    }
  }

  void _exit() {
    SystemNavigator.pop();
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;

    return Scaffold(
      body: SafeArea(
        child: Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 420),
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 32),
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Container(
                    padding: const EdgeInsets.all(22),
                    decoration: BoxDecoration(
                      color: scheme.primaryContainer,
                      shape: BoxShape.circle,
                    ),
                    child: Icon(Icons.security,
                        size: 56, color: scheme.onPrimaryContainer),
                  ),
                  const SizedBox(height: 28),
                  Text('AnyHack',
                      style: Theme.of(context)
                          .textTheme
                          .displaySmall
                          ?.copyWith(fontWeight: FontWeight.w700)),
                  const SizedBox(height: 8),
                  Text(
                    'Нужен root-доступ',
                    style: Theme.of(context)
                        .textTheme
                        .titleLarge
                        ?.copyWith(color: scheme.primary),
                  ),
                  const SizedBox(height: 14),
                  Text(
                    'мониторинг, герцовка и ик-пульт работают через root. '
                    'выдайте доступ в kernelSU и нажмите «повторить»',
                    textAlign: TextAlign.center,
                    style: Theme.of(context)
                        .textTheme
                        .bodyMedium
                        ?.copyWith(color: scheme.outline),
                  ),
                  const SizedBox(height: 18),
                  if (_error != null)
                    Text(
                      _error!,
                      style: TextStyle(color: scheme.error),
                    ),
                  const SizedBox(height: 26),
                  if (_checking)
                    Column(
                      children: [
                        const CircularProgressIndicator(),
                        const SizedBox(height: 14),
                        Text('запрос root…',
                            style: Theme.of(context).textTheme.bodySmall),
                      ],
                    )
                  else
                    Row(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        FilledButton.icon(
                          onPressed: _check,
                          icon: const Icon(Icons.refresh),
                          label: const Text('Повторить'),
                        ),
                        const SizedBox(width: 12),
                        OutlinedButton(
                          onPressed: _exit,
                          child: const Text('Выход'),
                        ),
                      ],
                    ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}
