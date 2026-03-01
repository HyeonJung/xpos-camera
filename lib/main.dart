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

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
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
    with TickerProviderStateMixin {
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
    unawaited(_globalLocCache.warmUp());
    unawaited(_warmUpCamera(c));
    setState(() {
      _controller = c;
      _ready = true;
    });
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

                              sectionTitle('표시 항목'),
                              Container(
                                decoration: BoxDecoration(
                                  color: const Color(0xFFF3F4F6),
                                  borderRadius: BorderRadius.circular(14),
                                ),
                                child: Column(
                                  children: [
                                    SwitchListTile(
                                      contentPadding:
                                          const EdgeInsets.symmetric(
                                            horizontal: 10,
                                          ),
                                      title: const Text(
                                        '주소 표시',
                                        style: TextStyle(
                                          fontWeight: FontWeight.w600,
                                        ),
                                      ),
                                      subtitle: const Text(
                                        '도로명/번지 등 가능한 만큼 포함',
                                      ),
                                      value: settings.useAddress,
                                      onChanged: (v) => update(
                                        settings.copyWith(useAddress: v),
                                      ),
                                    ),
                                    const Divider(height: 1),
                                    SwitchListTile(
                                      contentPadding:
                                          const EdgeInsets.symmetric(
                                            horizontal: 10,
                                          ),
                                      title: const Text(
                                        '위/경도 표시',
                                        style: TextStyle(
                                          fontWeight: FontWeight.w600,
                                        ),
                                      ),
                                      subtitle: const Text('정밀 좌표를 함께 기록'),
                                      value: settings.useLatLng,
                                      onChanged: (v) => update(
                                        settings.copyWith(useLatLng: v),
                                      ),
                                    ),
                                  ],
                                ),
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
      );

      // 4) 갤러리 저장(권한 요청 포함)
      final asset = await _saveToGallery(stampedFile);

      setState(() {
        final item = SavedItem(
          path: stampedFile.path,
          assetId: asset?.id,
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
    _flashCtrl.dispose();
    _zoomCtrl.dispose();
    _controller?.dispose();
    _templateCtrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (!_ready) {
      return const Scaffold(
        body: Center(child: Text('카메라 준비 실패(시뮬레이터/권한 이슈일 수 있음)')),
      );
    }

    final c = _controller!;
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
}) async {
  final bytes = await original.readAsBytes();

  // 1) 파일 -> ui.Image 디코딩
  final uiImage = await _decodeUiImage(bytes);

  // 2) 캔버스에 원본 + 오버레이 렌더링
  final recorder = ui.PictureRecorder();
  final canvas = ui.Canvas(recorder);
  final paint = ui.Paint();

  // 원본 그리기
  canvas.drawImage(uiImage, ui.Offset.zero, paint);

  // 텍스트 구성 (1줄: 날짜/시간, 2줄+: 주소/위경도)
  final lines = stampText.split('\n');
  final titleLine = lines.isNotEmpty ? lines.first : '';
  final bodyLines = lines.length >= 2 ? lines.sublist(1) : <String>[];

  final titleStyle = TextStyle(
    color: Colors.white,
    fontFamily: 'NotoSansKR',
    fontSize: (s.fontSize + 2).toDouble(),
    fontWeight: FontWeight.w700,
    height: 1.1,
    letterSpacing: 0.2,
  );
  final bodyStyle = TextStyle(
    color: Colors.white,
    fontFamily: 'NotoSansKR',
    fontSize: (s.fontSize - 2).clamp(12, 40).toDouble(),
    fontWeight: FontWeight.w500,
    height: 1.2,
  );

  // ✅ 선명도/가독성: 텍스트 외곽선(스트로크) + 본문/타이틀 채움
  final titleOutlineStyle = titleStyle.copyWith(
    foreground: (ui.Paint()
      ..style = ui.PaintingStyle.stroke
      ..strokeWidth = 3.0
      ..color = const Color(0xCC000000)),
  );
  final bodyOutlineStyle = bodyStyle.copyWith(
    foreground: (ui.Paint()
      ..style = ui.PaintingStyle.stroke
      ..strokeWidth = 2.6
      ..color = const Color(0xCC000000)),
  );

  final titleOutlineTp = TextPainter(
    text: TextSpan(text: titleLine, style: titleOutlineStyle),
    textDirection: ui.TextDirection.ltr,
    maxLines: 1,
    ellipsis: '…',
  );
  final titleTp = TextPainter(
    text: TextSpan(text: titleLine, style: titleStyle),
    textDirection: ui.TextDirection.ltr,
    maxLines: 1,
    ellipsis: '…',
  );

  final bodyText = bodyLines.join('\n');
  final bodyOutlineTp = TextPainter(
    text: TextSpan(text: bodyText, style: bodyOutlineStyle),
    textDirection: ui.TextDirection.ltr,
    maxLines: bodyLines.isEmpty ? null : bodyLines.length,
  );
  final bodyTp = TextPainter(
    text: TextSpan(text: bodyText, style: bodyStyle),
    textDirection: ui.TextDirection.ltr,
    maxLines: bodyLines.isEmpty ? null : bodyLines.length,
  );

  // 박스 최대 폭(좌우 마진 고려)
  final maxBoxWidth = (uiImage.width.toDouble() - (s.margin * 2)).clamp(
    160.0,
    uiImage.width.toDouble(),
  );
  const hPad = 16.0;
  const vPad = 12.0;
  const innerGap = 4.0;

  // 텍스트 레이아웃(최대 폭 안에서 줄바꿈)
  titleOutlineTp.layout(maxWidth: maxBoxWidth - (hPad * 2));
  titleTp.layout(maxWidth: maxBoxWidth - (hPad * 2));
  bodyOutlineTp.layout(maxWidth: maxBoxWidth - (hPad * 2));
  bodyTp.layout(maxWidth: maxBoxWidth - (hPad * 2));

  final contentW = [
    titleTp.width,
    bodyTp.width,
  ].fold<double>(0, (m, v) => v > m ? v : m);
  final contentH =
      titleTp.height + (bodyLines.isEmpty ? 0 : (innerGap + bodyTp.height));

  final boxW = (contentW + (hPad * 2)).clamp(200.0, maxBoxWidth);
  final boxH = contentH + (vPad * 2);

  // 위치 계산
  final m = s.margin.toDouble();
  double x, y;
  switch (s.position) {
    case StampPosition.bottomLeft:
      x = m;
      y = uiImage.height - boxH - m;
      break;
    case StampPosition.bottomRight:
      x = uiImage.width - boxW - m;
      y = uiImage.height - boxH - m;
      break;
    case StampPosition.topLeft:
      x = m;
      y = m;
      break;
    case StampPosition.topRight:
      x = uiImage.width - boxW - m;
      y = m;
      break;
  }

  // 박스(클린 패널: 그라디언트/장식 제거, 업무용 톤)
  final radius = const ui.Radius.circular(14);
  final rect = ui.Rect.fromLTWH(x, y, boxW, boxH);
  final rrect = ui.RRect.fromRectAndRadius(rect, radius);

  // Soft shadow
  final shadowPath = ui.Path()..addRRect(rrect);
  canvas.drawShadow(shadowPath, const Color(0x66000000), 7.0, false);

  // Solid translucent background
  final bgPaint = ui.Paint()..color = const Color(0xB3000000);
  canvas.drawRRect(rrect, bgPaint);

  // Hairline border
  final borderPaint = ui.Paint()
    ..color = const Color(0x26FFFFFF)
    ..style = ui.PaintingStyle.stroke
    ..strokeWidth = 1.0;
  canvas.drawRRect(rrect, borderPaint);

  // 텍스트 그리기 (패딩)
  final textX = x + 16;
  final textY = y + 12;
  // outline -> fill (선명도 개선)
  titleOutlineTp.paint(canvas, ui.Offset(textX, textY));
  titleTp.paint(canvas, ui.Offset(textX, textY));
  if (bodyLines.isNotEmpty) {
    final by = textY + titleTp.height + 6;
    bodyOutlineTp.paint(canvas, ui.Offset(textX, by));
    bodyTp.paint(canvas, ui.Offset(textX, by));
  }

  // 3) 렌더 결과 -> PNG 바이트
  final picture = recorder.endRecording();
  final outImage = await picture.toImage(uiImage.width, uiImage.height);
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

/// =======================
/// (E) 갤러리 저장
/// =======================
Future<AssetEntity?> _saveToGallery(File file) async {
  final perm = await PhotoManager.requestPermissionExtend();
  if (!perm.isAuth) {
    throw Exception('사진 권한 필요');
  }
  try {
    return await PhotoManager.editor.saveImageWithPath(file.path);
  } catch (_) {
    // 저장은 됐지만 엔티티를 못 받는 경우 대비
    return null;
  }
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
