import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../core/auth/pkce_login.dart';

enum _Stage { choose, waiting, apiKey }

/// First-run sign-in: "Sign in with ChatGPT" (browser PKCE flow) or an
/// OpenAI API key. Follows the app theme; no app-specific colours.
class LoginScreen extends StatefulWidget {
  const LoginScreen({super.key, required this.createFlow, required this.onSignedIn, required this.onApiKey});

  final PkceLoginFlow Function() createFlow;
  final Future<void> Function() onSignedIn;
  final Future<void> Function(String key) onApiKey;

  @override
  State<LoginScreen> createState() => _LoginScreenState();
}

class _LoginScreenState extends State<LoginScreen> {
  _Stage _stage = _Stage.choose;
  PkceLoginFlow? _flow;
  Uri? _url;
  String? _error;
  bool _busy = false;
  final _key = TextEditingController();
  bool _showKey = false;

  @override
  void dispose() {
    _flow?.cancel();
    _key.dispose();
    super.dispose();
  }

  Future<void> _signIn() async {
    final flow = widget.createFlow();
    setState(() {
      _flow = flow;
      _error = null;
      _stage = _Stage.waiting;
    });
    try {
      final url = await flow.start();
      if (!mounted) return;
      setState(() => _url = url);
      await flow.result;
      if (!mounted) return;
      setState(() => _busy = true);
      await widget.onSignedIn();
    } on LoginException catch (e) {
      if (!mounted) return;
      if (e.kind == LoginFailure.alreadySignedIn) {
        await widget.onSignedIn();
        return;
      }
      setState(() {
        _stage = _Stage.choose;
        _error = e.kind == LoginFailure.cancelled ? null : e.message;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _stage = _Stage.choose;
        _error = 'Sign-in failed: $e';
      });
    } finally {
      if (identical(_flow, flow)) _flow = null;
    }
  }

  void _cancel() => _flow?.cancel();

  Future<void> _submitKey() async {
    final k = _key.text.trim();
    if (k.isEmpty) return;
    setState(() => _busy = true);
    await widget.onApiKey(k);
    if (mounted) setState(() => _busy = false);
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final cs = theme.colorScheme;
    final dim = cs.onSurface.withValues(alpha: 0.62);
    return Scaffold(
      key: const ValueKey('login-screen'),
      backgroundColor: cs.surface,
      body: Center(
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(24),
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 380),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Text(
                  'Woi',
                  textAlign: TextAlign.center,
                  style: theme.textTheme.headlineMedium?.copyWith(fontWeight: FontWeight.w600, color: cs.onSurface),
                ),
                const SizedBox(height: 8),
                Text(
                  'Your voice-first notes assistant.\nSign in to start.',
                  textAlign: TextAlign.center,
                  style: theme.textTheme.bodyMedium?.copyWith(color: dim, height: 1.45),
                ),
                const SizedBox(height: 32),
                AnimatedSwitcher(
                  duration: const Duration(milliseconds: 180),
                  child: switch (_stage) {
                    _Stage.choose => _choose(theme),
                    _Stage.waiting => _waiting(theme),
                    _Stage.apiKey => _apiKeyForm(theme),
                  },
                ),
                if (_error != null) ...[
                  const SizedBox(height: 16),
                  Text(
                    _error!,
                    key: const ValueKey('login-error'),
                    textAlign: TextAlign.center,
                    style: theme.textTheme.bodySmall?.copyWith(color: cs.error),
                  ),
                ],
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _choose(ThemeData theme) {
    final cs = theme.colorScheme;
    return Column(
      key: const ValueKey('login-choose'),
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        FilledButton(
          key: const ValueKey('login-chatgpt'),
          style: FilledButton.styleFrom(
            minimumSize: const Size.fromHeight(48),
            backgroundColor: cs.onSurface,
            foregroundColor: cs.surface,
            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
          ),
          onPressed: _busy ? null : _signIn,
          child: const Text('Sign in with ChatGPT', style: TextStyle(fontSize: 15, fontWeight: FontWeight.w600)),
        ),
        const SizedBox(height: 12),
        OutlinedButton(
          key: const ValueKey('login-api-key'),
          style: OutlinedButton.styleFrom(
            minimumSize: const Size.fromHeight(48),
            foregroundColor: cs.onSurface,
            side: BorderSide(color: cs.onSurface.withValues(alpha: 0.2)),
            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
          ),
          onPressed: _busy ? null : () => setState(() => _stage = _Stage.apiKey),
          child: const Text('Use OpenAI API key', style: TextStyle(fontSize: 15)),
        ),
        const SizedBox(height: 18),
        Text(
          'Signing in opens your browser. Woi stores the login like the Codex CLI does (~/.codex/auth.json).',
          textAlign: TextAlign.center,
          style: theme.textTheme.bodySmall?.copyWith(color: cs.onSurface.withValues(alpha: 0.55), height: 1.4),
        ),
      ],
    );
  }

  Widget _waiting(ThemeData theme) {
    final cs = theme.colorScheme;
    final url = _url;
    return Column(
      key: const ValueKey('login-waiting'),
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const Center(child: SizedBox(width: 22, height: 22, child: CircularProgressIndicator(strokeWidth: 2.2))),
        const SizedBox(height: 16),
        Text(
          _busy ? 'Signed in. Starting…' : 'Finish signing in in your browser.',
          textAlign: TextAlign.center,
          style: theme.textTheme.bodyLarge?.copyWith(color: cs.onSurface),
        ),
        const SizedBox(height: 6),
        Text(
          'Waiting for the browser to return (up to ${kLoginTimeout.inMinutes} minutes).',
          textAlign: TextAlign.center,
          style: theme.textTheme.bodySmall?.copyWith(color: cs.onSurface.withValues(alpha: 0.6)),
        ),
        const SizedBox(height: 20),
        Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            if (url != null)
              TextButton.icon(
                key: const ValueKey('login-copy-url'),
                onPressed: () {
                  Clipboard.setData(ClipboardData(text: url.toString()));
                  ScaffoldMessenger.maybeOf(
                    context,
                  )?.showSnackBar(const SnackBar(content: Text('Sign-in link copied. Paste it into your browser.')));
                },
                icon: const Icon(Icons.link, size: 18),
                label: const Text('Copy link'),
              ),
            const SizedBox(width: 8),
            TextButton(
              key: const ValueKey('login-cancel'),
              onPressed: _busy ? null : _cancel,
              child: const Text('Cancel'),
            ),
          ],
        ),
      ],
    );
  }

  Widget _apiKeyForm(ThemeData theme) {
    final cs = theme.colorScheme;
    return Column(
      key: const ValueKey('login-key-form'),
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        TextField(
          key: const ValueKey('login-key-field'),
          controller: _key,
          autofocus: true,
          obscureText: !_showKey,
          enableSuggestions: false,
          autocorrect: false,
          onSubmitted: (_) => _submitKey(),
          decoration: InputDecoration(
            labelText: 'OpenAI API key',
            hintText: 'sk-…',
            border: const OutlineInputBorder(),
            suffixIcon: IconButton(
              tooltip: _showKey ? 'Hide' : 'Show',
              onPressed: () => setState(() => _showKey = !_showKey),
              icon: Icon(_showKey ? Icons.visibility_off_outlined : Icons.visibility_outlined, size: 20),
            ),
          ),
        ),
        const SizedBox(height: 14),
        FilledButton(
          key: const ValueKey('login-key-continue'),
          style: FilledButton.styleFrom(
            minimumSize: const Size.fromHeight(46),
            backgroundColor: cs.onSurface,
            foregroundColor: cs.surface,
            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
          ),
          onPressed: _busy ? null : _submitKey,
          child: const Text('Continue'),
        ),
        const SizedBox(height: 6),
        TextButton(
          onPressed: _busy ? null : () => setState(() => _stage = _Stage.choose),
          child: const Text('Back'),
        ),
      ],
    );
  }
}
