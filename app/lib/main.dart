import 'package:flutter/material.dart';

import 'ui/preview_screen.dart';

void main() {
  runApp(const VdodtorApp());
}

class VdodtorApp extends StatelessWidget {
  const VdodtorApp({super.key});

  @override
  Widget build(BuildContext context) => MaterialApp(
        title: 'vdodtor',
        debugShowCheckedModeBanner: false,
        theme: ThemeData(
          colorScheme: ColorScheme.fromSeed(
              seedColor: const Color(0xFF4C8DF6), brightness: Brightness.dark),
          useMaterial3: true,
        ),
        home: const PreviewScreen(),
      );
}
