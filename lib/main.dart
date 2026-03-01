import 'dart:io';
import 'dart:typed_data';
import 'dart:async';
import 'package:share_plus/share_plus.dart';
import 'package:camera/camera.dart';
import 'package:flutter/material.dart';
import 'package:geocoding/geocoding.dart';
import 'package:geolocator/geolocator.dart';
import 'dart:ui' as ui;
import 'package:flutter/services.dart';
import 'package:intl/intl.dart';
import 'package:path_provider/path_provider.dart';
import 'package:photo_manager/photo_manager.dart';
import 'package:gal/gal.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();

  // ✅ 앱 자체 회전 잠금: 세로 고정
  await SystemChrome.setPreferredOrientations([
    DeviceOrientation.portraitUp,
  ]);

  final cams = await availableCameras();
  runApp(StampCamApp(cameras: cams));
}

class StampCamApp extends StatelessWidget {
  final List<CameraDescription> cameras;
  const StampCamApp({super.key, required this.cameras});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      debugShowCheckedModeBanner: false,
      theme: ThemeData(fontFamily: 'NotoSansKR', useMaterial3: true),
      home: CameraStampPage(cameras: cameras),
    );
  }
}

enum StampPosition { bottomLeft, bottomRight, topLeft, topRight }

class StampSettings {
  final String dateFormat; // yyyy. MM. dd
  final String timeFormat; // HH:mm
  final bool useAddress; // 주소 표시
  final bool useLatLng; // 위경도 표시
  final String template; // "{date} {time}\n{addr}"
  final StampPosition position;
  final int margin;
  final int fontSize;

  const StampSettings({
    required this.dateFormat,
    required this.timeFormat,
    required this.useAddress,
    required this.useLatLng,
    required this.template,
    required this.position,
    this.margin = 24,
    this.fontSize = 26,
  });

  StampSettings copyWith({
    String? dateFormat,
    String? timeFormat,
    bool? useAddress,
    bool? useLatLng,
    String? template,
    StampPosition? position,
    int? margin,
    int? fontSize,
  }) {
    return StampSettings(
      dateFormat: dateFormat ?? this.dateFormat,
      timeFormat: timeFormat ?? this.timeFormat,
      useAddress: useAddress ?? this.useAddress,
      useLatLng: useLatLng ?? this.useLatLng,
      template: template ?? this.template,
      position: position ?? this.position,
      margin: margin ?? this.margin,
      fontSize: fontSize ?? this.fontSize,
    );
  }
}

class CameraStampPage extends StatefulWidget {
  final List<CameraDescription> cameras;
  const CameraStampPage({super.key, required this.cameras});

  @override
  State<CameraStampPage> createState() => _CameraStampPageState();
}

class _CameraStampPageState extends State<CameraStampPage>
    with TickerProviderStateMixin, WidgetsBindingObserver {
  Widget _iosLikePreview(CameraController c) {
    // iPhone 사진 모드처럼 4:3 프레임(세로)로 잘라 보여주기
    // 화면이 너무 길게 꽉 차는 느낌을 줄이고 상/하단 여백이 생김
    const frameAspect = 3 / 4; // width / height

    final ps = c.value.previewSize;
    // previewSize는 landscape 기준인 경우가 많아서(가로/세로가 뒤집힘) swap해서 사용
    final childW = (ps?.height ?? 1080).toDouble();
    final childH = (ps?.width ?? 1920).toDouble();

    return Center(
      child: AspectRatio(
        aspectRatio: frameAspect,
        child: ClipRect(
          child: FittedBox(
            fit: BoxFit.cover,
            child: SizedBox(
              width: childW,
              height: childH,
              child: CameraPreview(c),
            ),
          ),
        ),
      ),
    );
  }

  CameraController? _controller;
  bool _ready = false;
  // 촬영 피드백(셔터 플래시 + 살짝 줌인)
  late final AnimationController _flashCtrl;
  late final Animation<double> _flashOpacity;

  late final AnimationController _zoomCtrl;
  late final Animation<double> _zoomScale;

  bool _isCapturing = false;
  // 플래시 모드(ON/OFF)
  FlashMode _flashMode = FlashMode.off;
  // 최근 저장 항목(앱 내 히스토리)
  SavedItem? _lastSaved;
  final List<SavedItem> _savedItems = <SavedItem>[];

  // 설정 시트에서 사용하는 템플릿 입력 컨트롤러(시트 열고 닫아도 유지)
  final TextEditingController _templateCtrl = TextEditingController();

  // “형식 정하기”는 나중에 설정 화면으로 빼면 됨
  StampSettings settings = const StampSettings(
    dateFormat: 'yyyy년 MM월 dd일',
    timeFormat: 'HH시 mm분',
    useAddress: true,
    useLatLng: false,
    template: '{date} {time}\n{addr}',
    position: StampPosition.bottomLeft,
    margin: 22,
    fontSize: 26,
  );

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _templateCtrl.text = settings.template;
    _flashCtrl = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 160),
      reverseDuration: const Duration(milliseconds: 260),
    );
    _flashOpacity = CurvedAnimation(parent: _flashCtrl, curve: Curves.easeOut);

    _zoomCtrl = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 180),
      reverseDuration: const Duration(milliseconds: 220),
    );
    _zoomScale = Tween<double>(
      begin: 1.0,
      end: 1.035,
    ).animate(CurvedAnimation(parent: _zoomCtrl, curve: Curves.easeOut));

    _init();
  }

  Future<void> _init() async {
    if (widget.cameras.isEmpty) {
      setState(() => _ready = false);
      return;
    }
    final cam = widget.cameras.first;
    final c = CameraController(cam, ResolutionPreset.high, enableAudio: false);
    await c.initialize();
    // ✅ 카메라 촬영 방향도 세로로 고정 (앱 UI 회전 잠금과 별개)
    try {
      await c.lockCaptureOrientation(DeviceOrientation.portraitUp);
    } catch (e) {
      debugPrint('lockCaptureOrientation failed: $e');
    }
    // ✅ 초기 플래시 상태 적용
    try {
      await c.setFlashMode(_flashMode);
    } catch (e) {
      debugPrint('setFlashMode failed: $e');
    }
    unawaited(_globalLocCache.warmUp());
    unawaited(_warmUpCamera(c));
    setState(() {
      _controller = c;
      _ready = true;
    });
  }

  Future<void> _toggleFlash() async {
    final c = _controller;
    if (c == null || !c.value.isInitialized) return;

    final next = (_flashMode == FlashMode.off) ? FlashMode.always : FlashMode.off;
    try {
      await c.setFlashMode(next);
      setState(() => _flashMode = next);
    } catch (e) {
      debugPrint('toggle flash failed: $e');
    }
  }

  void _openSettingsSheet() {
    final dateFormats = <String>[
      'yyyy년 MM월 dd일',
      'yyyy. MM. dd',
      'yyyy-MM-dd',
      'yy.MM.dd',
      'MM/dd/yyyy',
    ];
    final timeFormats = <String>['HH시 mm분', 'HH:mm', 'HH:mm:ss', 'a h:mm'];

    // 시트 열 때 현재 설정값을 반영
    _templateCtrl.text = settings.template;
    unawaited(_globalLocCache.warmUp());

    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      backgroundColor: Colors.transparent,
      builder: (ctx) {
        final bottomInset = MediaQuery.of(ctx).viewInsets.bottom;

        return StatefulBuilder(
          builder: (ctx, setSheetState) {
            void update(StampSettings next) {
              setState(() => settings = next);
              setSheetState(() {});
            }

            Widget sectionTitle(String text) => Padding(
              padding: const EdgeInsets.only(top: 18, bottom: 8),
              child: Text(
                text,
                style: const TextStyle(
                  fontSize: 13,
                  fontWeight: FontWeight.w700,
                  color: Color(0xFF6B7280),
                  letterSpacing: 0.2,
                ),
              ),
            );

            InputDecoration deco(String label, {String? helper}) =>
                InputDecoration(
                  labelText: label,
                  helperText: helper,
                  filled: true,
                  fillColor: const Color(0xFFF3F4F6),
                  border: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(14),
                    borderSide: BorderSide.none,
                  ),
                  contentPadding: const EdgeInsets.symmetric(
                    horizontal: 14,
                    vertical: 14,
                  ),
                );

            return SafeArea(
              child: Padding(
                padding: EdgeInsets.only(bottom: 12 + bottomInset),
                child: Container(
                  decoration: const BoxDecoration(
                    color: Colors.white,
                    borderRadius: BorderRadius.vertical(
                      top: Radius.circular(22),
                    ),
                  ),
                  child: Padding(
                    padding: const EdgeInsets.fromLTRB(16, 8, 16, 0),
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        // Header
                        Row(
                          children: [
                            const Expanded(
                              child: Text(
                                '스탬프 설정',
                                style: TextStyle(
                                  fontSize: 18,
                                  fontWeight: FontWeight.w800,
                                ),
                              ),
                            ),
                            TextButton(
                              onPressed: () {
                                // 간단 초기화(현재 기본값)
                                update(
                                  const StampSettings(
                                    dateFormat: 'yyyy년 MM월 dd일',
                                    timeFormat: 'HH시 mm분',
                                    useAddress: true,
                                    useLatLng: false,
                                    template: '{date} {time}\n{addr}',
                                    position: StampPosition.bottomLeft,
                                    margin: 22,
                                    fontSize: 26,
                                  ),
                                );
                                _templateCtrl.text = settings.template;
                              },
                              child: const Text('초기화'),
                            ),
                          ],
                        ),

                        Expanded(
                          child: ListView(
                            padding: const EdgeInsets.only(bottom: 12),
                            children: [
                              sectionTitle('형식'),
                              Row(
                                children: [
                                  Expanded(
                                    child: DropdownButtonFormField<String>(
                                      value: settings.dateFormat,
                                      decoration: deco('날짜 포맷'),
                                      items: dateFormats
                                          .map(
                                            (f) => DropdownMenuItem(
                                              value: f,
                                              child: Text(f),
                                            ),
                                          )
                                          .toList(),
                                      onChanged: (v) {
                                        if (v == null) return;
                                        update(
                                          settings.copyWith(dateFormat: v),
                                        );
                                      },
                                    ),
                                  ),
                                  const SizedBox(width: 12),
                                  Expanded(
                                    child: DropdownButtonFormField<String>(
                                      value: settings.timeFormat,
                                      decoration: deco('시간 포맷'),
                                      items: timeFormats
                                          .map(
                                            (f) => DropdownMenuItem(
                                              value: f,
                                              child: Text(f),
                                            ),
                                          )
                                          .toList(),
                                      onChanged: (v) {
                                        if (v == null) return;
                                        update(
                                          settings.copyWith(timeFormat: v),
                                        );
                                      },
                                    ),
                                  ),
                                ],
                              ),
                              sectionTitle('스탬프 위치'),
                              Container(
                                padding: const EdgeInsets.all(10),
                                decoration: BoxDecoration(
                                  color: const Color(0xFFF3F4F6),
                                  borderRadius: BorderRadius.circular(14),
                                ),
                                child: SegmentedButton<StampPosition>(
                                  showSelectedIcon: false,
                                  segments: const [
                                    ButtonSegment(
                                      value: StampPosition.topLeft,
                                      label: Text('좌상'),
                                    ),
                                    ButtonSegment(
                                      value: StampPosition.topRight,
                                      label: Text('우상'),
                                    ),
                                    ButtonSegment(
                                      value: StampPosition.bottomLeft,
                                      label: Text('좌하'),
                                    ),
                                    ButtonSegment(
                                      value: StampPosition.bottomRight,
                                      label: Text('우하'),
                                    ),
                                  ],
                                  selected: {settings.position},
                                  onSelectionChanged: (sel) {
                                    if (sel.isEmpty) return;
                                    update(
                                      settings.copyWith(position: sel.first),
                                    );
                                  },
                                ),
                              ),

                              sectionTitle('크기 / 여백'),
                              Container(
                                padding: const EdgeInsets.fromLTRB(
                                  12,
                                  12,
                                  12,
                                  4,
                                ),
                                decoration: BoxDecoration(
                                  color: const Color(0xFFF3F4F6),
                                  borderRadius: BorderRadius.circular(14),
                                ),
                                child: Column(
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  children: [
                                    Row(
                                      children: [
                                        const Expanded(
                                          child: Text(
                                            '글자 크기',
                                            style: TextStyle(
                                              fontWeight: FontWeight.w700,
                                            ),
                                          ),
                                        ),
                                        Container(
                                          padding: const EdgeInsets.symmetric(
                                            horizontal: 10,
                                            vertical: 6,
                                          ),
                                          decoration: BoxDecoration(
                                            color: Colors.white,
                                            borderRadius: BorderRadius.circular(
                                              999,
                                            ),
                                          ),
                                          child: Text(
                                            '${settings.fontSize}',
                                            style: const TextStyle(
                                              fontWeight: FontWeight.w700,
                                            ),
                                          ),
                                        ),
                                      ],
                                    ),
                                    Slider(
                                      value: settings.fontSize.toDouble(),
                                      min: 12,
                                      max: 48,
                                      divisions: 36,
                                      onChanged: (v) => update(
                                        settings.copyWith(fontSize: v.round()),
                                      ),
                                    ),
                                    const SizedBox(height: 6),
                                    Row(
                                      children: [
                                        const Expanded(
                                          child: Text(
                                            '여백(margin)',
                                            style: TextStyle(
                                              fontWeight: FontWeight.w700,
                                            ),
                                          ),
                                        ),
                                        Container(
                                          padding: const EdgeInsets.symmetric(
                                            horizontal: 10,
                                            vertical: 6,
                                          ),
                                          decoration: BoxDecoration(
                                            color: Colors.white,
                                            borderRadius: BorderRadius.circular(
                                              999,
                                            ),
                                          ),
                                          child: Text(
                                            '${settings.margin}',
                                            style: const TextStyle(
                                              fontWeight: FontWeight.w700,
                                            ),
                                          ),
                                        ),
                                      ],
                                    ),
                                    Slider(
                                      value: settings.margin.toDouble(),
                                      min: 0,
                                      max: 64,
                                      divisions: 64,
                                      onChanged: (v) => update(
                                        settings.copyWith(margin: v.round()),
                                      ),
                                    ),
                                  ],
                                ),
                              ),

                              sectionTitle('템플릿'),
                              TextField(
                                controller: _templateCtrl,
                                maxLines: 3,
                                decoration: deco(
                                  '템플릿',
                                  helper:
                                      '사용 가능: {date} {time} {addr} {lat} {lng}',
                                ),
                                onChanged: (v) =>
                                    update(settings.copyWith(template: v)),
                              ),

                              sectionTitle('미리보기'),
                              Container(
                                width: double.infinity,
                                padding: const EdgeInsets.all(14),
                                decoration: BoxDecoration(
                                  color: const Color(0xFF111827),
                                  borderRadius: BorderRadius.circular(14),
                                ),
                                child: Text(
                                  _previewText(settings),
                                  style: const TextStyle(
                                    fontFamily: 'NotoSansKR',
                                    color: Colors.white,
                                    fontWeight: FontWeight.w600,
                                    height: 1.2,
                                  ),
                                ),
                              ),
                            ],
                          ),
                        ),

                        // Footer
                        SizedBox(
                          width: double.infinity,
                          child: FilledButton(
                            onPressed: () {
                              // NOTE: dispose는 시트가 완전히 닫힌 뒤(whenComplete)에서 1회만 처리
                              Navigator.of(ctx).pop();
                            },
                            child: const Text('닫기'),
                          ),
                        ),
                        const SizedBox(height: 12),
                      ],
                    ),
                  ),
                ),
              ),
            );
          },
        );
      },
    );
  }

  static String _previewText(StampSettings s) {
    final sampleAddr = s.useAddress ? '서울특별시 강남구 역삼동' : '';
    final sampleLat = s.useLatLng ? '37.498000' : '';
    final sampleLng = s.useLatLng ? '127.027000' : '';
    final now = DateTime.now();
    final date = DateFormat(s.dateFormat).format(now);
    final time = DateFormat(s.timeFormat).format(now);

    var text = s.template
        .replaceAll('{date}', date)
        .replaceAll('{time}', time)
        .replaceAll('{addr}', sampleAddr)
        .replaceAll('{lat}', sampleLat)
        .replaceAll('{lng}', sampleLng);

    text = text
        .split('\n')
        .map((e) => e.trim())
        .where((e) => e.isNotEmpty)
        .join('\n');
    return text;
  }

Future<void> _takeAndStampAndSave() async {
    final c = _controller;
    if (c == null || !c.value.isInitialized) return;
    if (_isCapturing) return;

    setState(() => _isCapturing = true);
    unawaited(_playCaptureFeedback());

    try {
      // 1) 촬영
      final x = await c.takePicture();
      final rawFile = File(x.path);

      // 2) 날짜/위치 텍스트 만들기
      final stamp = await _buildStampText(settings);

      // 3) 합성 (Canvas로 렌더링: 한글 100% 지원)
      final outDir = await getApplicationDocumentsDirectory();
      final stampedFile = await _stampWithCanvas(
        original: rawFile,
        stampText: stamp.text,
        s: settings,
        outDir: outDir,
        captureOrientation: c.value.deviceOrientation,
      );

      // 4) 갤러리 저장(권한 요청 포함)
      // ✅ Gal이 권한 흐름을 직접 처리함(ANDROID 13+에서 PhotoManager.isAuth 체크로 막히는 케이스 방지)
      bool canSave = false;
      try {
        canSave = await Gal.hasAccess() || await Gal.requestAccess();
      } catch (e) {
        debugPrint('Gal permission error: $e');
        canSave = false;
      }

      if (!canSave) {
        setState(() => _isCapturing = false);
        return; // 권한 없으면 저장 시도 안 함
      }

      try {
        await _saveToGallery(stampedFile);
      } catch (e, st) {
        debugPrint('Save to gallery failed: $e\n$st');
        // 저장 실패 시에도 앱 문서폴더에 파일은 남아있음
        setState(() => _isCapturing = false);
        return;
      }

      setState(() {
        final item = SavedItem(
          path: stampedFile.path,
          assetId: null,
          createdAt: DateTime.now(),
        );
        _savedItems.add(item);
        // 최근 50장만 유지
        if (_savedItems.length > 50) {
          _savedItems.removeRange(0, _savedItems.length - 50);
        }
        _lastSaved = _savedItems.isEmpty ? null : _savedItems.last;
      });

      if (!mounted) return;
      // 저장 완료 토스트/스낵바는 표시하지 않음
    } finally {
      if (mounted) {
        setState(() => _isCapturing = false);
      } else {
        _isCapturing = false;
      }
    }
  }

  Future<void> _deleteSavedAt(int index) async {
    if (index < 0 || index >= _savedItems.length) return;
    final item = _savedItems[index];

    // 1) Photo library(가능하면)에서 삭제
    if (item.assetId != null) {
      try {
        await PhotoManager.editor.deleteWithIds([item.assetId!]);
      } catch (_) {
        // iOS 정책/권한/SDK 버전에 따라 실패할 수 있음 (로컬 파일만 정리)
      }
    }

    // 2) 앱 문서 폴더의 파일 삭제
    try {
      final f = File(item.path);
      if (await f.exists()) {
        await f.delete();
      }
    } catch (_) {}

    setState(() {
      _savedItems.removeAt(index);
      _lastSaved = _savedItems.isEmpty ? null : _savedItems.last;
    });
  }

  Future<void> _deleteLastSaved() async {
    if (_savedItems.isEmpty) return;
    await _deleteSavedAt(_savedItems.length - 1);
  }

  Future<void> _playCaptureFeedback() async {
    // 햅틱(업무용: 과하지 않게)
    try {
      await HapticFeedback.mediumImpact();
    } catch (_) {}

    // 셔터 플래시 + 살짝 줌인
    try {
      // 동시에 시작
      final f = _flashCtrl
          .forward(from: 0)
          .then((_) => _flashCtrl.reverse(from: 1));
      final z = _zoomCtrl
          .forward(from: 0)
          .then((_) => _zoomCtrl.reverse(from: 1));
      await Future.wait([f, z]);
    } catch (_) {}
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _flashCtrl.dispose();
    _zoomCtrl.dispose();

    // ✅ 잠금 해제 후 dispose (안전)
    try {
      _controller?.unlockCaptureOrientation();
    } catch (_) {}
    _controller?.dispose();

    _templateCtrl.dispose();
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) async {
    if (state == AppLifecycleState.paused) {
      try {
        await _controller?.dispose();
      } catch (_) {}
      _controller = null;
    } else if (state == AppLifecycleState.resumed) {
      if (_controller == null) {
        await _init();
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final c = _controller;
    if (c == null || !c.value.isInitialized) {
      return const Scaffold(
        body: Center(child: CircularProgressIndicator()),
      );
    }
    return Scaffold(
      body: Stack(
        children: [
          const Positioned.fill(child: ColoredBox(color: Colors.black)),
          Positioned.fill(
            child: ScaleTransition(
              scale: _zoomScale,
              alignment: Alignment.center,
              child: _iosLikePreview(c),
            ),
          ),
          // 상단 비네팅(업무용 톤 + 버튼 가독성)
          Positioned(
            top: 0,
            left: 0,
            child: SafeArea(
              child: Padding(
                padding: const EdgeInsets.only(top: 10, left: 14),
                child: ClipRRect(
                  borderRadius: BorderRadius.circular(999),
                  child: BackdropFilter(
                    filter: ui.ImageFilter.blur(sigmaX: 10, sigmaY: 10),
                    child: Material(
                      color: const Color(0x44000000),
                      child: InkWell(
                        onTap: _toggleFlash,
                        child: Padding(
                          padding: const EdgeInsets.all(12),
                          child: Icon(
                            _flashMode == FlashMode.off
                                ? Icons.flash_off
                                : Icons.flash_on,
                            color: Colors.white,
                          ),
                        ),
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ),
          Positioned(
            left: 0,
            right: 0,
            top: 0,
            height: 140,
            child: IgnorePointer(
              child: Container(
                decoration: const BoxDecoration(
                  gradient: LinearGradient(
                    begin: Alignment.topCenter,
                    end: Alignment.bottomCenter,
                    colors: [Color(0x99000000), Color(0x00000000)],
                  ),
                ),
              ),
            ),
          ),

          // 셔터 딤(업무용: 하얀 번쩍임 대신 살짝 어두워졌다가 복귀)
          Positioned.fill(
            child: IgnorePointer(
              child: AnimatedBuilder(
                animation: _flashOpacity,
                builder: (context, _) {
                  final o = (0.18 * _flashOpacity.value).clamp(0.0, 0.18);
                  return Container(color: Colors.black.withOpacity(o));
                },
              ),
            ),
          ),
          Positioned(
            top: 0,
            right: 0,
            child: SafeArea(
              child: Padding(
                padding: const EdgeInsets.only(top: 10, right: 14),
                child: ClipRRect(
                  borderRadius: BorderRadius.circular(999),
                  child: BackdropFilter(
                    filter: ui.ImageFilter.blur(sigmaX: 10, sigmaY: 10),
                    child: Material(
                      color: const Color(0x44000000),
                      child: InkWell(
                        onTap: () {
                          // 리플 먼저 그려지고 시트가 뜨게(체감 렉 완화)
                          Future.microtask(_openSettingsSheet);
                        },
                        child: const Padding(
                          padding: EdgeInsets.all(12),
                          child: Icon(Icons.tune, color: Colors.white),
                        ),
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ),
          Positioned(
            left: 0,
            right: 0,
            bottom: 24,
            child: SafeArea(
              top: false,
              child: SizedBox(
                height: 72,
                child: Stack(
                  children: [
                    // 왼쪽: 최근 저장 썸네일(컴팩트) + 수량 배지
                    Align(
                      alignment: Alignment.centerLeft,
                      child: Padding(
                        padding: const EdgeInsets.only(left: 16),
                        child: ClipRRect(
                          borderRadius: BorderRadius.circular(18),
                          child: BackdropFilter(
                            filter: ui.ImageFilter.blur(sigmaX: 12, sigmaY: 12),
                            child: Container(
                              padding: const EdgeInsets.all(8),
                              decoration: const BoxDecoration(
                                color: Colors.transparent,
                              ),
                              child: Stack(
                                clipBehavior: Clip.none,
                                children: [
                                  GestureDetector(
                                    onTap: (_savedItems.isEmpty)
                                        ? null
                                        : () {
                                            Navigator.of(context).push(
                                              MaterialPageRoute(
                                                builder: (_) =>
                                                    SavedGalleryPage(
                                                      items:
                                                          List<SavedItem>.from(
                                                            _savedItems,
                                                          ),
                                                      initialIndex:
                                                          _savedItems.length -
                                                          1,
                                                      onDelete: (i) async =>
                                                          _deleteSavedAt(i),
                                                    ),
                                              ),
                                            );
                                          },
                                    child: ClipRRect(
                                      borderRadius: BorderRadius.circular(14),
                                      child: Container(
                                        width: 64,
                                        height: 64,
                                        color: const Color(0x22000000),
                                        child: _lastSaved?.path == null
                                            ? const Icon(
                                                Icons.photo,
                                                color: Colors.white70,
                                              )
                                            : Image.file(
                                                File(_lastSaved!.path),
                                                fit: BoxFit.cover,
                                              ),
                                      ),
                                    ),
                                  ),

                                  // 수량 배지: 박스 오른쪽 위로 이동
                                  if (_savedItems.isNotEmpty)
                                    Positioned(
                                      top: -6,
                                      right: -6,
                                      child: Container(
                                        padding: const EdgeInsets.symmetric(
                                          horizontal: 10,
                                          vertical: 6,
                                        ),
                                        decoration: BoxDecoration(
                                          color: const Color(0xB3000000),
                                          borderRadius: BorderRadius.circular(
                                            999,
                                          ),
                                          border: Border.all(
                                            color: const Color(0x26FFFFFF),
                                          ),
                                        ),
                                        child: Text(
                                          '${_savedItems.length}',
                                          style: const TextStyle(
                                            color: Colors.white,
                                            fontSize: 12,
                                            fontFamily: 'NotoSansKR',
                                            fontWeight: FontWeight.w700,
                                          ),
                                        ),
                                      ),
                                    ),
                                ],
                              ),
                            ),
                          ),
                        ),
                      ),
                    ),

                    // 가운데: 카메라 버튼
                    Align(
                      alignment: Alignment.center,
                      child: GestureDetector(
                        onTap: _takeAndStampAndSave,
                        child: Container(
                          width: 72,
                          height: 72,
                          decoration: const BoxDecoration(
                            shape: BoxShape.circle,
                            color: Colors.white,
                          ),
                          child: Center(
                            child: Container(
                              width: 56,
                              height: 56,
                              decoration: BoxDecoration(
                                shape: BoxShape.circle,
                                color: Colors.white,
                              ),
                              child: const Icon(
                                Icons.camera_alt,
                                color: Colors.black87,
                              ),
                            ),
                          ),
                        ),
                      ),
                    ),

                    // 오른쪽: 균형 맞춤용 빈 공간(향후 버튼 추가 가능)
                    const Align(
                      alignment: Alignment.centerRight,
                      child: Padding(
                        padding: EdgeInsets.only(right: 16),
                        child: SizedBox(width: 80, height: 72),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }

  Future<void> _warmUpCamera(CameraController c) async {
    // ✅ 촬영 없이 카메라 파이프라인만 깨우기(사용자 모르게 워밍업)
    try {
      if (!c.value.isInitialized) return;
      if (c.value.isStreamingImages) return;

      // 잠깐 스트림 열었다 닫으면 첫 촬영 지연이 완화되는 경우가 많음
      await c.startImageStream((_) {});
      await Future.delayed(const Duration(milliseconds: 220));
      await c.stopImageStream();
    } catch (_) {
      // 일부 기기에서 스트림 실패해도 무시
      try {
        if (c.value.isStreamingImages) {
          await c.stopImageStream();
        }
      } catch (_) {}
    }
  }
}

class _GlobalLocCache {
  Position? pos;
  String? addr;
  DateTime? at;
  bool _warming = false;

  bool isFresh() {
    final t = at;
    if (t == null) return false;
    return DateTime.now().difference(t) <= const Duration(seconds: 30);
  }

  Future<void> warmUp() async {
    if (_warming) return;
    if (isFresh()) return;

    _warming = true;
    try {
      final serviceEnabled = await Geolocator.isLocationServiceEnabled();
      if (!serviceEnabled) return;

      var perm = await Geolocator.checkPermission();
      if (perm == LocationPermission.denied) {
        perm = await Geolocator.requestPermission();
      }
      if (perm == LocationPermission.denied ||
          perm == LocationPermission.deniedForever) {
        return;
      }

      final p = await Geolocator.getCurrentPosition(
        desiredAccuracy: LocationAccuracy.high,
      );
      pos = p;

      // 역지오코딩(주소)은 특히 무거움 → 실패해도 무시
      try {
        final placemarks = await placemarkFromCoordinates(
          p.latitude,
          p.longitude,
        );
        if (placemarks.isNotEmpty) {
          final pm = placemarks.first;
          final parts = <String?>[
            pm.administrativeArea,
            pm.subAdministrativeArea,
            pm.locality,
            pm.subLocality,
            pm.thoroughfare,
            pm.subThoroughfare,
          ];
          addr = parts
              .where((e) => e != null && e!.trim().isNotEmpty)
              .map((e) => e!.trim())
              .fold<List<String>>([], (acc, v) {
                if (acc.isEmpty || acc.last != v) acc.add(v);
                return acc;
              })
              .join(' ');
        }
      } catch (_) {}

      at = DateTime.now();
    } catch (_) {
      // ignore
    } finally {
      _warming = false;
    }
  }
}

final _globalLocCache = _GlobalLocCache();

/// =======================
/// (A)(B)(C) 날짜/위치/주소 만들기
/// =======================
class StampResult {
  final String text;
  final double? lat;
  final double? lng;
  final String? addr;
  const StampResult(this.text, {this.lat, this.lng, this.addr});
}

Future<StampResult> _buildStampText(StampSettings s) async {
  final now = DateTime.now();
  final date = DateFormat(s.dateFormat).format(now);
  final time = DateFormat(s.timeFormat).format(now);

  double? lat;
  double? lng;
  String? addr;

  // ✅ 1) 캐시가 있으면 즉시 사용(빠르게 반환)
  if (_globalLocCache.isFresh()) {
    final p = _globalLocCache.pos;
    if (p != null) {
      lat = p.latitude;
      lng = p.longitude;
    }
    addr = _globalLocCache.addr;
  }

  // ✅ 2) 캐시가 없거나 오래됐으면, 최대 700ms만 기다리고 바로 진행(렉 방지)
  if ((s.useAddress || s.useLatLng) && !_globalLocCache.isFresh()) {
    try {
      await _globalLocCache.warmUp().timeout(const Duration(milliseconds: 700));
      final p = _globalLocCache.pos;
      if (p != null) {
        lat = p.latitude;
        lng = p.longitude;
      }
      addr = _globalLocCache.addr;
    } catch (_) {
      // 이번 촬영은 빠르게, 백그라운드로 계속 갱신
      unawaited(_globalLocCache.warmUp());
    }
  }

  final latStr = (s.useLatLng && lat != null) ? lat.toStringAsFixed(6) : '';
  final lngStr = (s.useLatLng && lng != null) ? lng.toStringAsFixed(6) : '';
  final addrStr = (s.useAddress && addr != null) ? addr! : '';

  var text = s.template
      .replaceAll('{date}', date)
      .replaceAll('{time}', time)
      .replaceAll('{addr}', addrStr)
      .replaceAll('{lat}', latStr)
      .replaceAll('{lng}', lngStr);

  // 빈 줄 정리
  text = text
      .split('\n')
      .map((e) => e.trim())
      .where((e) => e.isNotEmpty)
      .join('\n');

  return StampResult(text, lat: lat, lng: lng, addr: addr);
}

/// =======================
/// (D) 이미지 합성(Canvas: 반투명 박스 + 텍스트, 한글 100% 지원)
/// =======================
Future<File> _stampWithCanvas({
  required File original,
  required String stampText,
  required StampSettings s,
  required Directory outDir,
  DeviceOrientation? captureOrientation,
}) async {
  final bytes = await original.readAsBytes();

  // 1) 파일 -> ui.Image 디코딩
  final uiImage = await _decodeUiImage(bytes);

  // ✅ EXIF orientation 반영 (가로/세로 촬영 시 스탬프 위치가 사진과 일치하도록)
  // ⚠️ 일부 Android/Flutter 조합에서는 instantiateImageCodec 디코더가 이미 EXIF 회전을 적용해
  //     uiImage가 "정방향"으로 넘어오는 경우가 있습니다.
  //     이 상태에서 우리가 다시 회전(베이크)하면 결과가 무조건 뒤집혀 보이는(이중회전) 문제가 납니다.
  final orientation = _readJpegExifOrientation(bytes);

  // ✅ EXIF orientation 처리
  // 로그에서 orient=6인데 uiImage가 이미 720x1280(세로)로 디코딩되고 있음.
  // 즉, instantiateImageCodec가 이미 EXIF 회전을 적용한 상태.
  // 이런 경우 우리가 다시 90도 회전하면 무조건 가로로 뒤집힘.

  int effectiveOrientation = orientation;

  // EXIF가 90도 회전(6/8)인데,
  // 디코딩된 이미지가 이미 세로라면 → 추가 회전 스킵
  if ((orientation == 6 || orientation == 8) &&
      uiImage.height > uiImage.width) {
    effectiveOrientation = 1;
  }

  final tf = _orientationToTransform(
    effectiveOrientation,
    uiImage.width,
    uiImage.height,
  );

  // 기본 캔버스 크기(EXIF 베이크 기준)
  int canvasW = tf.w;
  int canvasH = tf.h;

  // 캡처 방향이 landscape인데 effectiveOrientation==1(=이미 portrait로 디코딩됨)인 경우,
  // 최종 출력만 landscape로 맞추기 위해 캔버스 크기를 swap
  final cap = captureOrientation;
  final wantLandscape = cap == DeviceOrientation.landscapeLeft ||
      cap == DeviceOrientation.landscapeRight;
  if (effectiveOrientation == 1 && wantLandscape) {
    canvasW = uiImage.height;
    canvasH = uiImage.width;
  }
  debugPrint(
      'STAMP orient=$orientation eff=$effectiveOrientation ui=${uiImage.width}x${uiImage.height} out=${canvasW}x${canvasH} cap=$captureOrientation');

  // 2) 캔버스에 원본 + 오버레이 렌더링
  final recorder = ui.PictureRecorder();
  final canvas = ui.Canvas(recorder);
  final paint = ui.Paint();

  // 원본 그리기(정방향으로 베이크)
  // NOTE:
  // - 일부 기기에서는 디코더가 이미 EXIF를 적용해 uiImage가 portrait(예: 720x1280)로 들어오고,
  //   EXIF는 계속 6으로 찍히는(캡처 방향 잠금 영향) 케이스가 있습니다.
  // - 이때 effectiveOrientation==1로 베이크 회전을 스킵하므로 결과는 항상 portrait가 됩니다.
  // - 사용자가 폰을 가로로 들고 찍었을 때는, 최종 출력만 추가로 90도 회전해 landscape로 맞춥니다.

  if (effectiveOrientation == 1) {
    if (!wantLandscape) {
      if (DeviceOrientation.portraitDown == cap) {
        // 뒤집힌 세로(180도 회전)
        canvas.translate(canvasW.toDouble(), canvasH.toDouble());
        canvas.rotate(3.141592653589793);
        canvas.drawImage(uiImage, ui.Offset.zero, paint);
        canvas.rotate(-3.141592653589793);
        canvas.translate(-canvasW.toDouble(), -canvasH.toDouble());
      } else {
        canvas.drawImage(uiImage, ui.Offset.zero, paint);
      }
    } else {
      // uiImage가 portrait일 것을 가정(대부분 720x1280). 최종 출력은 landscape(1280x720).
      // landscapeLeft/right에 따라 회전 방향을 다르게 적용
      final radians = (cap == DeviceOrientation.landscapeLeft)
          ? -1.5707963267948966
          : 1.5707963267948966;

      // canvasW/canvasH는 현재 tf에서 산출된 값(보통 portrait). 여기서 landscape로 다시 계산.
      final outW = uiImage.height;
      final outH = uiImage.width;

      // 캔버스가 outW/outH로 만들어져야 하므로, picture.toImage에서도 canvasW/canvasH가 맞아야 합니다.
      // 이를 위해 아래에서 canvasW/canvasH를 재정의할 수 없으니,
      // 현재 구현에서는 'portrait 캔버스'에 그리는 대신, 이 블록을 타기 전에
      // tf/canvasW/canvasH 계산을 landscape에 맞추도록 수정합니다.
      // (아래 3)에서 canvasW/canvasH 계산을 보정합니다.)

      if (radians > 0) {
        // rotate 90 CW
        canvas.translate(outW.toDouble(), 0);
        canvas.rotate(radians);
        canvas.drawImage(uiImage, ui.Offset.zero, paint);
        canvas.rotate(-radians);
        canvas.translate(-outW.toDouble(), 0);
      } else {
        // rotate -90
        canvas.translate(0, outH.toDouble());
        canvas.rotate(radians);
        canvas.drawImage(uiImage, ui.Offset.zero, paint);
        canvas.rotate(-radians);
        canvas.translate(0, -outH.toDouble());
      }
    }
  } else if (effectiveOrientation == 3) {
    canvas.translate(canvasW.toDouble(), canvasH.toDouble());
    canvas.rotate(3.141592653589793);
    canvas.drawImage(uiImage, ui.Offset.zero, paint);
    canvas.rotate(-3.141592653589793);
    canvas.translate(-canvasW.toDouble(), -canvasH.toDouble());
  } else if (effectiveOrientation == 6) {
    // rotate 90 CW
    canvas.translate(canvasW.toDouble(), 0);
    canvas.rotate(1.5707963267948966);
    canvas.drawImage(uiImage, ui.Offset.zero, paint);
    canvas.rotate(-1.5707963267948966);
    canvas.translate(-canvasW.toDouble(), 0);
  } else if (effectiveOrientation == 8) {
    // rotate 270 CW (or -90)
    canvas.translate(0, canvasH.toDouble());
    canvas.rotate(-1.5707963267948966);
    canvas.drawImage(uiImage, ui.Offset.zero, paint);
    canvas.rotate(1.5707963267948966);
    canvas.translate(0, -canvasH.toDouble());
  } else {
    canvas.drawImage(uiImage, ui.Offset.zero, paint);
  }

  // 텍스트 구성
  // 1) 시간은 최상단에 크게
  // 2) 날짜는 그 아래
  // 3) 나머지는 주소/위경도
  final lines = stampText.split('\n');

  String timeLine = '';
  String dateLine = '';
  final extraLines = <String>[];

  bool _looksLikeTimeLine(String s) {
    final t = s.trim();
    if (t.isEmpty) return false;
    // 19:06, 19:06:12
    final colon = RegExp(r'^\d{1,2}:\d{2}(:\d{2})?$');
    // 19시 06분, 19시06분, 19시 06분 12초(옵션)
    final kor = RegExp(r'^\d{1,2}\s*시(\s*\d{1,2}\s*분)?(\s*\d{1,2}\s*초)?$');
    return colon.hasMatch(t) || kor.hasMatch(t);
  }

  ({String date, String time}) _splitDateTimeInSameLine(String line) {
    final t = line.trim();
    if (t.isEmpty) return (date: '', time: '');

    // "yyyy년 ... 19시 06분" 처럼 한 줄에 섞여있을 때: 뒤쪽의 "HH시..분"을 time으로 분리
    final korFind = RegExp(r'(\d{1,2}\s*시(\s*\d{1,2}\s*분)?(\s*\d{1,2}\s*초)?)\s*$');
    final m1 = korFind.firstMatch(t);
    if (m1 != null) {
      final time = m1.group(1)!.trim();
      final date = t.substring(0, m1.start).trim();
      return (date: date, time: time);
    }

    // "yyyy-MM-dd 19:06" or "yyyy. MM. dd 19:06:12" 등: 뒤쪽 HH:mm(:ss) 분리
    final colonFind = RegExp(r'(\d{1,2}:\d{2}(:\d{2})?)\s*$');
    final m2 = colonFind.firstMatch(t);
    if (m2 != null) {
      final time = m2.group(1)!.trim();
      final date = t.substring(0, m2.start).trim();
      return (date: date, time: time);
    }

    // fallback: 공백 토큰 마지막을 시간으로 가정(기존 로직)
    final parts = t.split(RegExp(r'\s+'));
    if (parts.length >= 2) {
      return (date: parts.sublist(0, parts.length - 1).join(' '), time: parts.last);
    }
    return (date: '', time: t);
  }

  if (lines.isNotEmpty) {
    // 1) 첫 줄에서 date/time 섞여있으면 분리
    final first = lines.first;
    final split = _splitDateTimeInSameLine(first);
    dateLine = split.date;
    timeLine = split.time;

    // 2) 첫 줄이 "시간만" 이거나, 분리가 애매해서 timeLine이 비정상(예: '06분')이면
    //    전체 라인 중에서 시간 라인을 다시 찾아서 올림
    final timeIsTooShort = timeLine.trim().isNotEmpty &&
        !timeLine.trim().contains(':') &&
        !timeLine.trim().contains('시') &&
        timeLine.trim().length <= 3;

    if (_looksLikeTimeLine(first) || timeIsTooShort) {
      // first가 시간만이면 dateLine 비워두고, date는 나머지에서 찾도록
      if (_looksLikeTimeLine(first)) {
        timeLine = first.trim();
        dateLine = '';
      }
    }

    // 3) 나머지 라인들을 돌면서:
    //    - 시간 라인 발견 시 timeLine이 비었거나(혹은 너무 짧으면) 교체
    //    - 날짜 라인 후보를 dateLine이 비었을 때 채움
    for (int i = 1; i < lines.length; i++) {
      final ln = lines[i].trim();
      if (ln.isEmpty) continue;

      if (_looksLikeTimeLine(ln)) {
        // timeLine이 비었거나 이상한 경우(예: 06분)면 교체
        final badTime = timeLine.trim().isEmpty ||
            timeIsTooShort ||
            (timeLine.trim().endsWith('분') && !timeLine.trim().contains('시') && !timeLine.trim().contains(':'));
        if (badTime) {
          timeLine = ln;
          continue; // 시간 라인은 extra에 넣지 않음
        }
      }

      // dateLine이 비어있고, 이 라인이 "시간 라인"이 아니면 날짜 후보로 채움(첫 번째 비시간 라인)
      if (dateLine.trim().isEmpty && !_looksLikeTimeLine(ln)) {
        dateLine = ln;
        continue; // 날짜 라인도 extra에 넣지 않음
      }

      extraLines.add(ln);
    }

    // 4) first 라인에서 dateLine/timeLine 둘 다 뽑았는데, dateLine이 비어있고 first가 날짜처럼 보이면 dateLine로 채움
    if (dateLine.trim().isEmpty && !_looksLikeTimeLine(first.trim())) {
      // first가 날짜/기타 라인이라면 dateLine로
      dateLine = first.trim();
      // 그리고 timeLine이 first에서만 나와서 dateLine에 섞였던 경우를 위해 재분리 1회 더 시도
      final reSplit = _splitDateTimeInSameLine(dateLine);
      if (reSplit.time.trim().isNotEmpty && !_looksLikeTimeLine(timeLine)) {
        dateLine = reSplit.date;
        timeLine = reSplit.time;
      }
    }
  }

  final timeStyle = TextStyle(
    color: Colors.white,
    // 디지털 시계 느낌: 모노스페이스 우선, 없으면 시스템 폰트로 폴백
    fontFamily: 'RobotoMono',
    fontFamilyFallback: const ['Courier', 'monospace', 'NotoSansKR'],
    fontSize: (s.fontSize + 16).toDouble(),
    fontWeight: FontWeight.w900,
    height: 1.0,
    letterSpacing: 1.2,
  );

  final dateStyle = TextStyle(
    color: Colors.white,
    fontFamily: 'NotoSansKR',
    fontSize: (s.fontSize - 2).clamp(12, 40).toDouble(),
    fontWeight: FontWeight.w600,
    height: 1.15,
  );

  final bodyStyle = TextStyle(
    color: Colors.white,
    fontFamily: 'NotoSansKR',
    fontSize: (s.fontSize - 4).clamp(12, 36).toDouble(),
    fontWeight: FontWeight.w500,
    height: 1.2,
  );

  final timeOutlineStyle = timeStyle.copyWith(
    foreground: (ui.Paint()
      ..style = ui.PaintingStyle.stroke
      ..strokeWidth = 3.6
      ..color = const Color(0xCC000000)),
  );

  final dateOutlineStyle = dateStyle.copyWith(
    foreground: (ui.Paint()
      ..style = ui.PaintingStyle.stroke
      ..strokeWidth = 2.6
      ..color = const Color(0xCC000000)),
  );

  final bodyOutlineStyle = bodyStyle.copyWith(
    foreground: (ui.Paint()
      ..style = ui.PaintingStyle.stroke
      ..strokeWidth = 2.2
      ..color = const Color(0xCC000000)),
  );

  final timeOutlineTp = TextPainter(
    text: TextSpan(text: timeLine, style: timeOutlineStyle),
    textDirection: ui.TextDirection.ltr,
    maxLines: 1,
    ellipsis: '…',
  );
  final timeTp = TextPainter(
    text: TextSpan(text: timeLine, style: timeStyle),
    textDirection: ui.TextDirection.ltr,
    maxLines: 1,
    ellipsis: '…',
  );

  final dateOutlineTp = TextPainter(
    text: TextSpan(text: dateLine, style: dateOutlineStyle),
    textDirection: ui.TextDirection.ltr,
    maxLines: 1,
    ellipsis: '…',
  );
  final dateTp = TextPainter(
    text: TextSpan(text: dateLine, style: dateStyle),
    textDirection: ui.TextDirection.ltr,
    maxLines: 1,
    ellipsis: '…',
  );

  final bodyText = extraLines.join('\n');

  final bodyOutlineTp = TextPainter(
    text: TextSpan(text: bodyText, style: bodyOutlineStyle),
    textDirection: ui.TextDirection.ltr,
    maxLines: extraLines.isEmpty ? null : extraLines.length,
  );
  final bodyTp = TextPainter(
    text: TextSpan(text: bodyText, style: bodyStyle),
    textDirection: ui.TextDirection.ltr,
    maxLines: extraLines.isEmpty ? null : extraLines.length,
  );

  // 박스 최대 폭(좌우 마진 고려)
  final maxBoxWidth = (canvasW.toDouble() - (s.margin * 2)).clamp(
    160.0,
    canvasW.toDouble(),
  );

  // 텍스트 레이아웃(최대 폭 안에서 줄바꿈)
  const hPad = 16.0;
  const vPad = 12.0;
  timeOutlineTp.layout(maxWidth: maxBoxWidth - (hPad * 2));
  timeTp.layout(maxWidth: maxBoxWidth - (hPad * 2));
  dateOutlineTp.layout(maxWidth: maxBoxWidth - (hPad * 2));
  dateTp.layout(maxWidth: maxBoxWidth - (hPad * 2));
  bodyOutlineTp.layout(maxWidth: maxBoxWidth - (hPad * 2));
  bodyTp.layout(maxWidth: maxBoxWidth - (hPad * 2));

  // ======= 시간 박스 + 본문 박스(날짜/주소) 분리 계산 =======
  const timeHPad = 16.0;
  const timeVPad = 10.0;

  const bodyHPad = 16.0;
  const bodyVPad = 10.0;

  const boxGap = 10.0; // 시간박스와 본문박스 사이 간격

  final hasTime = timeLine.trim().isNotEmpty;
  final hasDate = dateLine.trim().isNotEmpty;
  final hasBody = extraLines.isNotEmpty;

  // 시간 박스 콘텐츠 크기
  final timeContentW = hasTime ? timeTp.width : 0.0;
  final timeContentH = hasTime ? timeTp.height : 0.0;

  // 본문 박스 콘텐츠 크기(날짜/주소만)
  final bodyContentW = [
    hasDate ? dateTp.width : 0.0,
    hasBody ? bodyTp.width : 0.0,
  ].fold<double>(0, (m, v) => v > m ? v : m);

  double bodyContentH = 0.0;
  if (hasDate) {
    bodyContentH += dateTp.height;
    if (hasBody) bodyContentH += 6;
  }
  if (hasBody) {
    bodyContentH += bodyTp.height;
  }

  // timeBox / bodyBox 크기(패딩 포함)
  final timeBoxW = (timeContentW + (timeHPad * 2)).clamp(160.0, maxBoxWidth);
  final timeBoxH = hasTime ? (timeContentH + (timeVPad * 2)) : 0.0;

  final bodyBoxW = (bodyContentW + (bodyHPad * 2)).clamp(200.0, maxBoxWidth);
  final bodyBoxH = (bodyContentH + (bodyVPad * 2)).clamp(90.0, canvasH.toDouble());

  // 위치 계산(시간 박스 + 본문 박스)
  final m = s.margin.toDouble();

  // 시간 박스(upper) + 본문 박스(lower)를 항상 "세로로 쌓기"
  // topLeft/topRight: timeBox가 위, bodyBox가 아래
  // bottomLeft/bottomRight: bodyBox가 아래, timeBox가 그 위
  final hasTimeBox = hasTime && timeBoxH > 0;

  // 수평 정렬: 본문 박스를 기준으로 잡고, 시간 박스는 같은 좌측/우측에 맞춤
  double bodyX, bodyY;
  double timeX, timeY;

  final stackGap = hasTimeBox ? boxGap : 0.0;

  switch (s.position) {
    case StampPosition.bottomLeft:
      bodyX = m;
      bodyY = canvasH - bodyBoxH - m;

      timeX = m;
      timeY = bodyY - (hasTimeBox ? (timeBoxH + stackGap) : 0.0);
      break;

    case StampPosition.bottomRight:
      bodyX = canvasW - bodyBoxW - m;
      bodyY = canvasH - bodyBoxH - m;

      timeX = canvasW - timeBoxW - m;
      timeY = bodyY - (hasTimeBox ? (timeBoxH + stackGap) : 0.0);
      break;

    case StampPosition.topLeft:
      timeX = m;
      timeY = m;

      bodyX = m;
      bodyY = timeY + (hasTimeBox ? (timeBoxH + stackGap) : 0.0);
      break;

    case StampPosition.topRight:
      timeX = canvasW - timeBoxW - m;
      timeY = m;

      bodyX = canvasW - bodyBoxW - m;
      bodyY = timeY + (hasTimeBox ? (timeBoxH + stackGap) : 0.0);
      break;
  }

  // ======= (1) 시간 박스(별도) =======
  const radius = ui.Radius.circular(14);
  const corner = ui.Radius.circular(14);

  if (hasTimeBox) {
    final timeRect = ui.Rect.fromLTWH(timeX, timeY, timeBoxW, timeBoxH);
    final timeRRect = ui.RRect.fromRectAndRadius(timeRect, corner);

    // shadow
    final timeShadowPath = ui.Path()..addRRect(timeRRect);
    canvas.drawShadow(timeShadowPath, const Color(0x66000000), 7.0, false);

    // background (시간 박스는 살짝 다른 톤)
    final timeBg = ui.Paint()..color = const Color(0xCC111827); // 네이비/딥톤
    canvas.drawRRect(timeRRect, timeBg);

    // border
    final timeBorder = ui.Paint()
      ..color = const Color(0x33FFFFFF)
      ..style = ui.PaintingStyle.stroke
      ..strokeWidth = 1.0;
    canvas.drawRRect(timeRRect, timeBorder);

    // time text
    final tX = timeX + timeHPad;
    final tY = timeY + timeVPad;
    timeOutlineTp.paint(canvas, ui.Offset(tX, tY));
    timeTp.paint(canvas, ui.Offset(tX, tY));
  }

  // ======= (2) 본문 박스(날짜/주소) =======
  final bodyRect = ui.Rect.fromLTWH(bodyX, bodyY, bodyBoxW, bodyBoxH);
  final bodyRRect = ui.RRect.fromRectAndRadius(bodyRect, corner);

  // shadow
  final bodyShadowPath = ui.Path()..addRRect(bodyRRect);
  canvas.drawShadow(bodyShadowPath, const Color(0x66000000), 7.0, false);

  // background (본문 박스)
  final bodyBg = ui.Paint()..color = const Color(0xB3000000);
  canvas.drawRRect(bodyRRect, bodyBg);

  // border
  final bodyBorder = ui.Paint()
    ..color = const Color(0x26FFFFFF)
    ..style = ui.PaintingStyle.stroke
    ..strokeWidth = 1.0;
  canvas.drawRRect(bodyRRect, bodyBorder);

  // body text
  double cursorY = bodyY + bodyVPad;
  final textX = bodyX + bodyHPad;

  if (hasDate) {
    dateOutlineTp.paint(canvas, ui.Offset(textX, cursorY));
    dateTp.paint(canvas, ui.Offset(textX, cursorY));
    cursorY += dateTp.height + 6;
  }
  if (hasBody) {
    bodyOutlineTp.paint(canvas, ui.Offset(textX, cursorY));
    bodyTp.paint(canvas, ui.Offset(textX, cursorY));
  }

  // 3) 렌더 결과 -> PNG 바이트
  final picture = recorder.endRecording();
  final outImage = await picture.toImage(canvasW, canvasH);
  final byteData = await outImage.toByteData(format: ui.ImageByteFormat.png);
  if (byteData == null) {
    throw Exception('PNG 인코딩 실패');
  }

  final pngBytes = byteData.buffer.asUint8List();

  // 4) 파일로 저장
  final outName = 'STAMP_${DateTime.now().millisecondsSinceEpoch}.png';
  final outFile = File('${outDir.path}/$outName');
  await outFile.writeAsBytes(pngBytes, flush: true);
  return outFile;
}

Future<ui.Image> _decodeUiImage(Uint8List bytes) async {
  final codec = await ui.instantiateImageCodec(bytes);
  final frame = await codec.getNextFrame();
  return frame.image;
}

// =======================
// EXIF Orientation reader (minimal, no dependencies)
// =======================
int _readJpegExifOrientation(Uint8List bytes) {
  // Returns EXIF orientation (1,3,6,8) or 1 if unknown.
  // Minimal JPEG/EXIF parser: looks for APP1 "Exif" and tag 0x0112.
  try {
    if (bytes.length < 4) return 1;
    // JPEG SOI 0xFFD8
    if (!(bytes[0] == 0xFF && bytes[1] == 0xD8)) return 1;

    int i = 2;
    while (i + 4 < bytes.length) {
      if (bytes[i] != 0xFF) {
        i++;
        continue;
      }
      final marker = bytes[i + 1];
      // EOI or SOS
      if (marker == 0xD9 || marker == 0xDA) break;

      final len = (bytes[i + 2] << 8) | bytes[i + 3];
      if (len < 2) break;

      // APP1
      if (marker == 0xE1 && i + 2 + len <= bytes.length) {
        final start = i + 4; // payload start
        // "Exif\0\0"
        if (start + 6 <= bytes.length &&
            bytes[start] == 0x45 &&
            bytes[start + 1] == 0x78 &&
            bytes[start + 2] == 0x69 &&
            bytes[start + 3] == 0x66 &&
            bytes[start + 4] == 0x00 &&
            bytes[start + 5] == 0x00) {
          final tiff = start + 6;
          if (tiff + 8 > bytes.length) return 1;

          final little = (bytes[tiff] == 0x49 && bytes[tiff + 1] == 0x49);
          int rd16(int off) => little
              ? (bytes[off] | (bytes[off + 1] << 8))
              : ((bytes[off] << 8) | bytes[off + 1]);
          int rd32(int off) => little
              ? (bytes[off] |
                  (bytes[off + 1] << 8) |
                  (bytes[off + 2] << 16) |
                  (bytes[off + 3] << 24))
              : ((bytes[off] << 24) |
                  (bytes[off + 1] << 16) |
                  (bytes[off + 2] << 8) |
                  bytes[off + 3]);

          // 0x002A check is optional
          final ifd0Offset = rd32(tiff + 4);
          final ifd0 = tiff + ifd0Offset;
          if (ifd0 + 2 > bytes.length) return 1;

          final numEntries = rd16(ifd0);
          int e = ifd0 + 2;
          for (int n = 0; n < numEntries; n++) {
            if (e + 12 > bytes.length) break;
            final tag = rd16(e);
            if (tag == 0x0112) {
              final type = rd16(e + 2);
              final count = rd32(e + 4);
              if (type == 3 && count == 1) {
                final val = rd16(e + 8);
                if (val == 3 || val == 6 || val == 8 || val == 1) return val;
              } else {
                // value stored at offset
                final valueOffset = rd32(e + 8);
                final valPos = tiff + valueOffset;
                if (valPos + 2 <= bytes.length) {
                  final val = rd16(valPos);
                  if (val == 3 || val == 6 || val == 8 || val == 1) return val;
                }
              }
              return 1;
            }
            e += 12;
          }
        }
      }

      i += 2 + len;
    }
  } catch (_) {}
  return 1;
}

({int w, int h, bool rotated90, double radians}) _orientationToTransform(
  int orientation,
  int srcW,
  int srcH,
) {
  // Returns output width/height (baked orientation) and radians.
  // 1: normal, 3: 180, 6: 90 CW, 8: 270 CW
  switch (orientation) {
    case 3:
      return (w: srcW, h: srcH, rotated90: false, radians: 3.141592653589793);
    case 6:
      return (w: srcH, h: srcW, rotated90: true, radians: 1.5707963267948966);
    case 8:
      return (w: srcH, h: srcW, rotated90: true, radians: -1.5707963267948966);
    default:
      return (w: srcW, h: srcH, rotated90: false, radians: 0.0);
  }
}

/// =======================
/// (E) 갤러리 저장
/// =======================
Future<void> _saveToGallery(File file) async {
  await Gal.putImage(file.path);
}

class SavedItem {
  final String path;
  final String? assetId;
  final DateTime createdAt;
  const SavedItem({
    required this.path,
    required this.assetId,
    required this.createdAt,
  });
}

class SavedGalleryPage extends StatefulWidget {
  final List<SavedItem> items;
  final int initialIndex;
  final Future<void> Function(int index)? onDelete;

  const SavedGalleryPage({
    super.key,
    required this.items,
    required this.initialIndex,
    this.onDelete,
  });

  @override
  State<SavedGalleryPage> createState() => _SavedGalleryPageState();
}

class _SavedGalleryPageState extends State<SavedGalleryPage> {
  late final PageController _pc;
  late int _index;

  @override
  void initState() {
    super.initState();
    _index = widget.initialIndex.clamp(0, widget.items.length - 1);
    _pc = PageController(initialPage: _index);
  }

  @override
  void dispose() {
    _pc.dispose();
    super.dispose();
  }

  Future<void> _deleteCurrent() async {
    if (widget.items.isEmpty) return;
    final idx = _index;

    // 상위에서 실제 삭제 처리
    if (widget.onDelete != null) {
      await widget.onDelete!(idx);
    }

    if (!mounted) return;
    // 페이지가 줄어들 수 있으니 닫거나 인덱스 보정
    if (Navigator.of(context).canPop()) {
      Navigator.of(context).pop();
    }
  }

  @override
  Widget build(BuildContext context) {
    final total = widget.items.length;

    return Scaffold(
      backgroundColor: Colors.black,
      appBar: AppBar(
        backgroundColor: Colors.black,
        foregroundColor: Colors.white,
        title: Text(
          '${_index + 1} / $total',
          style: const TextStyle(fontFamily: 'NotoSansKR'),
        ),
        actions: [
          if (total > 0)
            IconButton(
              tooltip: '공유',
              icon: const Icon(Icons.ios_share),
              onPressed: () async {
                try {
                  final item = widget.items[_index];

                  // 1) 가능하면 갤러리 Asset 기반으로 파일을 얻어서 공유(iOS에서 안정적인 경우가 많음)
                  File? shareFile;
                  if (item.assetId != null) {
                    try {
                      final asset = await AssetEntity.fromId(item.assetId!);
                      shareFile = await asset?.originFile ?? await asset?.file;
                    } catch (_) {
                      // ignore
                    }
                  }

                  // 2) fallback: 앱 문서 경로
                  shareFile ??= File(item.path);
                  if (!await shareFile.exists()) return;

                  // iPad에서도 안정적으로 뜨게 origin 지정
                  final box = context.findRenderObject() as RenderBox?;
                  final origin = box != null
                      ? (box.localToGlobal(Offset.zero) & box.size)
                      : null;

                  await Share.shareXFiles([
                    XFile(shareFile.path),
                  ], sharePositionOrigin: origin);
                } catch (_) {}
              },
            ),

          if (widget.onDelete != null && total > 0)
            IconButton(
              tooltip: '삭제',
              onPressed: _deleteCurrent,
              icon: const Icon(Icons.delete_outline),
            ),
        ],
      ),
      body: GestureDetector(
        behavior: HitTestBehavior.translucent,
        onVerticalDragEnd: (details) {
          // 아래로 빠르게 스와이프하면 닫기(카메라로 복귀)
          final v = details.primaryVelocity ?? 0;
          if (v > 900) {
            Navigator.of(context).maybePop();
          }
        },
        child: PageView.builder(
          controller: _pc,
          itemCount: total,
          onPageChanged: (i) => setState(() => _index = i),
          itemBuilder: (ctx, i) {
            final path = widget.items[i].path;
            return Center(
              child: InteractiveViewer(
                minScale: 1.0,
                maxScale: 4.0,
                child: Image.file(
                  File(path),
                  fit: BoxFit.contain,
                  filterQuality: FilterQuality.high,
                ),
              ),
            );
          },
        ),
      ),
    );
  }
}
