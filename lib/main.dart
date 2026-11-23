import 'package:flutter/material.dart';
import 'database/app_database.dart';
import 'screens/home_screen.dart';

late AppDatabase globalDb;

void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  globalDb = AppDatabase();
  runApp(const MyTuckiiApp());
}

class MyTuckiiApp extends StatelessWidget {
  const MyTuckiiApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: '隨手存',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        useMaterial3: true,
        colorSchemeSeed: const Color(0xFFF5B041),
        brightness: Brightness.light,
      ),
      darkTheme: ThemeData(
        useMaterial3: true,
        colorSchemeSeed: const Color(0xFFF5B041),
        brightness: Brightness.dark,
      ),
      themeMode: ThemeMode.system,
      home: HomeScreen(db: globalDb),
    );
  }
}
