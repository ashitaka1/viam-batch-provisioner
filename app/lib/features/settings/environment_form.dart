import 'package:flutter/cupertino.dart' show CupertinoIcons;
import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:macos_ui/macos_ui.dart';

import '../../models/environment.dart';
import '../../providers/environment_providers.dart';

class EnvironmentForm extends ConsumerStatefulWidget {
  const EnvironmentForm({super.key, required this.environmentName});

  final String environmentName;

  @override
  ConsumerState<EnvironmentForm> createState() => _EnvironmentFormState();
}

class _EnvironmentFormState extends ConsumerState<EnvironmentForm> {
  late final TextEditingController _username;
  late final TextEditingController _password;
  late final TextEditingController _wifiSsid;
  late final TextEditingController _wifiPassword;
  late final TextEditingController _timezone;
  late final TextEditingController _sshKeyFile;
  late final TextEditingController _viamApiKeyId;
  late final TextEditingController _viamApiKey;
  late final TextEditingController _viamOrgId;
  late final TextEditingController _viamLocationId;
  late final TextEditingController _tailscaleAuthKey;
  String _provisionMode = 'os-only';
  bool _loaded = false;

  @override
  void initState() {
    super.initState();
    _username = TextEditingController(text: 'viam');
    _password = TextEditingController(text: 'checkmate');
    _wifiSsid = TextEditingController();
    _wifiPassword = TextEditingController();
    _timezone = TextEditingController(text: 'America/New_York');
    _sshKeyFile = TextEditingController(text: '~/.ssh/id_ed25519.pub');
    _viamApiKeyId = TextEditingController();
    _viamApiKey = TextEditingController();
    _viamOrgId = TextEditingController();
    _viamLocationId = TextEditingController();
    _tailscaleAuthKey = TextEditingController();
    _loadExisting();
  }

  Future<void> _loadExisting() async {
    final repo = ref.read(environmentRepositoryProvider);
    final env = await repo.loadEnvironment(widget.environmentName);
    if (!mounted) return;
    setState(() {
      _username.text = env.username;
      _password.text = env.password;
      _wifiSsid.text = env.wifiSsid;
      _wifiPassword.text = env.wifiPassword;
      _timezone.text = env.timezone;
      _sshKeyFile.text = env.sshPublicKeyFile;
      _provisionMode = env.provisionMode;
      _viamApiKeyId.text = env.viamApiKeyId;
      _viamApiKey.text = env.viamApiKey;
      _viamOrgId.text = env.viamOrgId;
      _viamLocationId.text = env.viamLocationId;
      _tailscaleAuthKey.text = env.tailscaleAuthKey;
      _loaded = true;
    });
  }

  @override
  void dispose() {
    _username.dispose();
    _password.dispose();
    _wifiSsid.dispose();
    _wifiPassword.dispose();
    _timezone.dispose();
    _sshKeyFile.dispose();
    _viamApiKeyId.dispose();
    _viamApiKey.dispose();
    _viamOrgId.dispose();
    _viamLocationId.dispose();
    _tailscaleAuthKey.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    final env = Environment(
      name: widget.environmentName,
      username: _username.text,
      password: _password.text,
      wifiSsid: _wifiSsid.text,
      wifiPassword: _wifiPassword.text,
      timezone: _timezone.text,
      sshPublicKeyFile: _sshKeyFile.text,
      provisionMode: _provisionMode,
      viamApiKeyId: _viamApiKeyId.text,
      viamApiKey: _viamApiKey.text,
      viamOrgId: _viamOrgId.text,
      viamLocationId: _viamLocationId.text,
      tailscaleAuthKey: _tailscaleAuthKey.text,
    );
    final repo = ref.read(environmentRepositoryProvider);
    await repo.saveEnvironment(env);
    await repo.setActiveEnvironment(env.name);
    if (mounted) Navigator.pop(context);
  }

  @override
  Widget build(BuildContext context) {
    final canvas = MacosTheme.of(context).canvasColor;
    final divider = MacosTheme.of(context).dividerColor;

    if (!_loaded) {
      return ColoredBox(
        color: canvas,
        child: const Center(child: ProgressCircle()),
      );
    }

    return ColoredBox(
      color: canvas,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
            decoration: BoxDecoration(
              border: Border(
                bottom: BorderSide(color: divider, width: 0.5),
              ),
            ),
            child: Row(
              children: [
                MacosIconButton(
                  icon: const MacosIcon(CupertinoIcons.chevron_left, size: 16),
                  onPressed: () => Navigator.pop(context),
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    widget.environmentName,
                    style: const TextStyle(
                      fontSize: 15,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ),
                PushButton(
                  controlSize: ControlSize.regular,
                  onPressed: _save,
                  child: const Text('Save'),
                ),
              ],
            ),
          ),
          Expanded(
            child: ListView(
              padding: const EdgeInsets.all(20),
              children: [
                _sectionHeader('OS Account'),
                _field('Username', _username),
                _field('Password', _password),
                _sectionHeader('Network'),
                _field('WiFi SSID', _wifiSsid,
                    placeholder: 'Leave blank to skip'),
                _field('WiFi Password', _wifiPassword),
                _field('Timezone', _timezone),
                _sectionHeader('SSH'),
                _field('Public Key File', _sshKeyFile),
                _sectionHeader('Viam Cloud'),
                _modeSelector(),
                if (_provisionMode == 'full') ...[
                  const SizedBox(height: 12),
                  _field('API Key ID', _viamApiKeyId),
                  _field('API Key', _viamApiKey),
                  _field('Org ID', _viamOrgId),
                  _field('Location ID', _viamLocationId),
                ],
                _sectionHeader('Tailscale'),
                _field('Auth Key', _tailscaleAuthKey,
                    placeholder: 'Leave blank to skip'),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _sectionHeader(String title) {
    return Padding(
      padding: const EdgeInsets.only(top: 24, bottom: 8),
      child: Text(
        title,
        style: const TextStyle(
          fontSize: 13,
          fontWeight: FontWeight.w600,
          color: MacosColors.secondaryLabelColor,
        ),
      ),
    );
  }

  Widget _field(
    String label,
    TextEditingController controller, {
    String? placeholder,
  }) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(label, style: const TextStyle(fontSize: 13)),
          const SizedBox(height: 4),
          MacosTextField(
            controller: controller,
            placeholder: placeholder,
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
          ),
        ],
      ),
    );
  }

  Widget _modeSelector() {
    const modes = ['os-only', 'agent', 'full'];
    const labels = {
      'os-only': 'OS Only',
      'agent': 'Agent',
      'full': 'Full',
    };
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        for (final mode in modes)
          Padding(
            padding: const EdgeInsets.only(right: 8),
            child: PushButton(
              controlSize: ControlSize.small,
              secondary: mode != _provisionMode,
              onPressed: mode == _provisionMode
                  ? null
                  : () => setState(() => _provisionMode = mode),
              child: Text(labels[mode]!),
            ),
          ),
      ],
    );
  }
}
