import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:hive_flutter/hive_flutter.dart';

import '../../../core/services/download_service.dart';
import '../../../providers/providers.dart';

/// Settings page for configuring the download server
class SettingsPage extends ConsumerStatefulWidget {
  const SettingsPage({super.key});

  @override
  ConsumerState<SettingsPage> createState() => _SettingsPageState();
}

class _SettingsPageState extends ConsumerState<SettingsPage> {
  late TextEditingController _serverUrlController;
  late TextEditingController _apiKeyController;
  VideoQuality _selectedQuality = VideoQuality.hd1080;
  bool _wifiOnly = true;
  bool _isTestingConnection = false;
  String? _connectionStatus;

  @override
  void initState() {
    super.initState();
    _loadSettings();
  }

  Future<void> _loadSettings() async {
    final box = await Hive.openBox('settings');
    final serverUrl = box.get(
      'serverUrl',
      defaultValue: 'http://192.168.0.13:8765',
    );
    final apiKey = box.get('apiKey', defaultValue: 'offline_yt_secret_2025');
    final qualityIndex = box.get('defaultQuality', defaultValue: 1);
    final wifiOnly = box.get('wifiOnly', defaultValue: true);

    _serverUrlController = TextEditingController(text: serverUrl);
    _apiKeyController = TextEditingController(text: apiKey);
    _selectedQuality = VideoQuality.values[qualityIndex];
    _wifiOnly = wifiOnly;

    // Apply settings to download service
    _applySettings();

    setState(() {});
  }

  void _applySettings() {
    final downloadService = ref.read(downloadServiceProvider);
    downloadService.updateConfig(
      DownloadServerConfig(
        serverUrl: _serverUrlController.text,
        apiKey: _apiKeyController.text,
        defaultQuality: _selectedQuality,
      ),
    );
  }

  Future<void> _saveSettings() async {
    final box = await Hive.openBox('settings');
    await box.put('serverUrl', _serverUrlController.text);
    await box.put('apiKey', _apiKeyController.text);
    await box.put('defaultQuality', _selectedQuality.index);
    await box.put('wifiOnly', _wifiOnly);

    _applySettings();

    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Configurações guardadas'),
          backgroundColor: Colors.green,
        ),
      );
    }
  }

  Future<void> _testConnection() async {
    setState(() {
      _isTestingConnection = true;
      _connectionStatus = null;
    });

    try {
      // Apply current settings first
      _applySettings();

      final downloadService = ref.read(downloadServiceProvider);
      final isAvailable = await downloadService.isServerAvailable();

      setState(() {
        _isTestingConnection = false;
        _connectionStatus = isAvailable
            ? '✅ Servidor disponível!'
            : '❌ Servidor não disponível';
      });
    } catch (e) {
      setState(() {
        _isTestingConnection = false;
        _connectionStatus = '❌ Erro: $e';
      });
    }
  }

  @override
  void dispose() {
    _serverUrlController.dispose();
    _apiKeyController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Configurações'),
        actions: [
          IconButton(
            icon: const Icon(Icons.save),
            onPressed: _saveSettings,
            tooltip: 'Guardar',
          ),
        ],
      ),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          // Server Section
          _buildSectionHeader('Servidor de Download'),
          const SizedBox(height: 8),

          Card(
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  TextField(
                    controller: _serverUrlController,
                    decoration: const InputDecoration(
                      labelText: 'URL do Servidor',
                      hintText: 'http://192.168.0.13:8765',
                      prefixIcon: Icon(Icons.dns),
                      helperText: 'IP do computador com o servidor yt-dlp',
                    ),
                  ),
                  const SizedBox(height: 16),
                  TextField(
                    controller: _apiKeyController,
                    decoration: const InputDecoration(
                      labelText: 'API Key',
                      prefixIcon: Icon(Icons.key),
                      helperText:
                          'Chave de autenticação (deve corresponder ao servidor)',
                    ),
                    obscureText: true,
                  ),
                  const SizedBox(height: 16),
                  Row(
                    children: [
                      Expanded(
                        child: ElevatedButton.icon(
                          onPressed: _isTestingConnection
                              ? null
                              : _testConnection,
                          icon: _isTestingConnection
                              ? const SizedBox(
                                  width: 20,
                                  height: 20,
                                  child: CircularProgressIndicator(
                                    strokeWidth: 2,
                                  ),
                                )
                              : const Icon(Icons.wifi_find),
                          label: Text(
                            _isTestingConnection
                                ? 'A testar...'
                                : 'Testar Conexão',
                          ),
                        ),
                      ),
                    ],
                  ),
                  if (_connectionStatus != null) ...[
                    const SizedBox(height: 12),
                    Text(
                      _connectionStatus!,
                      style: TextStyle(
                        color: _connectionStatus!.startsWith('✅')
                            ? Colors.green
                            : Colors.red,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                  ],
                ],
              ),
            ),
          ),

          const SizedBox(height: 24),

          // Quality Section
          _buildSectionHeader('Qualidade de Download'),
          const SizedBox(height: 8),

          Card(
            child: Column(
              children: VideoQuality.values.map((quality) {
                return RadioListTile<VideoQuality>(
                  title: Text(quality.displayName),
                  subtitle: Text(_getQualityDescription(quality)),
                  value: quality,
                  groupValue: _selectedQuality,
                  onChanged: (value) {
                    if (value != null) {
                      setState(() => _selectedQuality = value);
                    }
                  },
                );
              }).toList(),
            ),
          ),

          const SizedBox(height: 24),

          // Network Section
          _buildSectionHeader('Rede'),
          const SizedBox(height: 8),

          Card(
            child: SwitchListTile(
              title: const Text('Só descarregar por WiFi'),
              subtitle: Text(
                _wifiOnly
                    ? 'Downloads bloqueados em dados móveis'
                    : 'Downloads permitidos em dados móveis',
              ),
              value: _wifiOnly,
              onChanged: (value) {
                setState(() => _wifiOnly = value);
              },
              secondary: Icon(
                _wifiOnly ? Icons.wifi : Icons.signal_cellular_alt,
              ),
            ),
          ),

          const SizedBox(height: 24),

          // Info Section
          _buildSectionHeader('Informação'),
          const SizedBox(height: 8),

          Card(
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: const [
                  Text(
                    'Como configurar:',
                    style: TextStyle(fontWeight: FontWeight.bold),
                  ),
                  SizedBox(height: 8),
                  Text('1. No computador, navega para a pasta yt_server'),
                  SizedBox(height: 4),
                  Text('2. Corre: python server.py'),
                  SizedBox(height: 4),
                  Text('3. Anota o IP mostrado (Network URL)'),
                  SizedBox(height: 4),
                  Text('4. Cola esse IP aqui na URL do Servidor'),
                  SizedBox(height: 4),
                  Text('5. Testa a conexão e guarda'),
                  SizedBox(height: 16),
                  Text(
                    'Nota: O telemóvel e o PC devem estar na mesma rede WiFi.',
                    style: TextStyle(
                      fontStyle: FontStyle.italic,
                      color: Colors.grey,
                    ),
                  ),
                ],
              ),
            ),
          ),

          const SizedBox(height: 32),
        ],
      ),
    );
  }

  Widget _buildSectionHeader(String title) {
    return Text(
      title,
      style: const TextStyle(fontSize: 18, fontWeight: FontWeight.bold),
    );
  }

  String _getQualityDescription(VideoQuality quality) {
    switch (quality) {
      case VideoQuality.max:
        return 'Melhor qualidade disponível (4K se disponível)';
      case VideoQuality.hd1080:
        return 'Full HD - Bom equilíbrio qualidade/tamanho';
      case VideoQuality.hd720:
        return 'HD - Ficheiros mais pequenos';
      case VideoQuality.sd360:
        return 'Qualidade baixa - Para poupar espaço';
    }
  }
}
