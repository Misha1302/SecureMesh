import 'package:material_ui/material_ui.dart';

class ClientApp extends StatelessWidget {
  const ClientApp({super.key});
  @override
  Widget build(BuildContext context) => MaterialApp(
    title: 'SecureMesh',
    theme: ThemeData(
      colorScheme: ColorScheme.fromSeed(seedColor: const Color(0xFF16685B)),
    ),
    home: Scaffold(
      appBar: AppBar(title: const Text('SecureMesh')),
      body: SafeArea(
        child: Center(
          child: Padding(
            padding: const EdgeInsets.all(32),
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 560),
              child: const Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Icon(Icons.lock_outline, size: 40),
                  SizedBox(height: 24),
                  Text(
                    'Приватные чаты в браузере пока недоступны',
                    style: TextStyle(fontSize: 28),
                  ),
                  SizedBox(height: 16),
                  Text(
                    'Интеграция OpenMLS/WASM ещё не прошла проверку. Для переписки и каналов используйте приложение SecureMesh.',
                  ),
                  SizedBox(height: 16),
                  Text(
                    'Private chats are disabled until the browser crypto integration is verified. Use the SecureMesh app for messaging and channels.',
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    ),
  );
}
