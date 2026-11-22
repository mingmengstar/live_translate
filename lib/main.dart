import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:google_fonts/google_fonts.dart';
import 'src/models/app_state.dart';
import 'src/services/pipeline_service.dart';
import 'src/ui/dashboard_view.dart';

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  runApp(const LiveTranslateApp());
}

class LiveTranslateApp extends StatelessWidget {
  const LiveTranslateApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MultiProvider(
      providers: [
        ChangeNotifierProvider(create: (_) => AppState()),
        Provider<PipelineService>(
          create: (context) => PipelineService(context.read<AppState>()),
          dispose: (_, pipeline) => pipeline.dispose(),
        ),
      ],
      child: MaterialApp(
        title: '实时同传',
        debugShowCheckedModeBanner: false,
        theme: ThemeData(
          useMaterial3: true,
          colorSchemeSeed: const Color(0xFF6366F1), // Indigo
          brightness: Brightness.dark,
          textTheme: GoogleFonts.notoSansScTextTheme(),
          cardTheme: CardThemeData(
            elevation: 2,
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(16),
            ),
            margin: EdgeInsets.zero,
          ),
          elevatedButtonTheme: ElevatedButtonThemeData(
            style: ElevatedButton.styleFrom(
              elevation: 0,
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(12),
              ),
              padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 14),
            ),
          ),
          outlinedButtonTheme: OutlinedButtonThemeData(
            style: OutlinedButton.styleFrom(
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(12),
              ),
              padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 14),
            ),
          ),
          sliderTheme: SliderThemeData(
            trackHeight: 4,
            thumbShape: const RoundSliderThumbShape(enabledThumbRadius: 10),
            overlayShape: const RoundSliderOverlayShape(overlayRadius: 20),
          ),
        ),
        home: const _AppRoot(),
      ),
    );
  }
}

class _AppRoot extends StatefulWidget {
  const _AppRoot();

  @override
  State<_AppRoot> createState() => _AppRootState();
}

class _AppRootState extends State<_AppRoot> {
  late final PipelineService _pipeline;
  bool _initialized = false;

  @override
  void initState() {
    super.initState();
    _pipeline = context.read<PipelineService>();
    _initializePipeline();
  }

  Future<void> _initializePipeline() async {
    final ok = await _pipeline.initialize();
    if (mounted) {
      setState(() => _initialized = ok);
    }
  }

  @override
  Widget build(BuildContext context) {
    if (!_initialized) {
      return Scaffold(
        body: Center(
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              const CircularProgressIndicator(),
              const SizedBox(height: 24),
              Text(
                '正在初始化模型...',
                style: GoogleFonts.notoSansSc(fontSize: 16),
              ),
            ],
          ),
        ),
      );
    }

    return DashboardView(pipeline: _pipeline);
  }
}