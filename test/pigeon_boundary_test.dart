import 'dart:async';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:live_photo_gallery/live_photo_gallery.dart';
import 'package:live_photo_gallery/src/messages.g.dart';

/// Pigeon 边界（wire）契约测试。
///
/// Pigeon 迁移后，跨端真正流动的不再是 `toMap()` / `fromMap()`，而是
/// lib/live_photo_gallery.dart 里手写的门面 ↔ 生成类型转换器：
///   MediaFilter._pg / PickerConfig._pg / AssetInput._pg /
///   MediaItem._fromPg / DownloadErrorCode._fromPg / _parseExportFormat
/// 这些转换器是本次迁移唯一的手工对齐点，一处笔误（例如把 videoOnly 映射成
/// PgMediaFilter.imageOnly）编译期无感、运行期直接选错媒体类型。
///
/// 因为它们是私有成员，本文件不去改动公开 API 来「开后门」，而是在
/// **真实的 pigeon channel 上挂 mock native**：调用公开方法 → 拦截并用生成的
/// codec 解码出 Pg* 对象 → 断言字段。这样同时覆盖了转换器 + 编解码路径，
/// 也保证生成类型不外泄到公开 API。
///
/// 对应的 native 侧同类测试见：
///   android/src/test/kotlin/com/newtrip/live_photo_gallery/PigeonBoundaryTest.kt
/// 公开门面（toMap/fromMap 等仍对调用方暴露的形状）见 test/contract_test.dart。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const String hostPrefix =
      'dev.flutter.pigeon.live_photo_gallery.LivePhotoGalleryHostApi.';
  const String flutterPrefix =
      'dev.flutter.pigeon.live_photo_gallery.LivePhotoGalleryFlutterApi.';
  const MessageCodec<Object?> codec =
      LivePhotoGalleryHostApi.pigeonChannelCodec;

  final TestDefaultBinaryMessenger messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;

  /// 最近一次被 mock native 接住的调用参数（已由 pigeon codec 解码）
  List<Object?> captured = const <Object?>[];

  /// 在真实 channel 上挂一个 mock native：记录入参并回复 [reply]。
  void mockHost(String method, {Object? reply}) {
    final channel =
        BasicMessageChannel<Object?>('$hostPrefix$method', codec);
    messenger.setMockDecodedMessageHandler<Object?>(channel,
        (Object? message) async {
      captured = (message as List<Object?>?) ?? const <Object?>[];
      return <Object?>[reply];
    });
  }

  void clearHost(String method) {
    final channel =
        BasicMessageChannel<Object?>('$hostPrefix$method', codec);
    messenger.setMockDecodedMessageHandler<Object?>(channel, null);
  }

  /// 模拟 native → Dart 的事件推送（走 LivePhotoGalleryFlutterApi 的真实 channel）
  Future<void> pushFlutterEvent(String method, List<Object?> args) {
    final completer = Completer<void>();
    ServicesBinding.instance.channelBuffers.push(
      '$flutterPrefix$method',
      codec.encodeMessage(args),
      (ByteData? _) => completer.complete(),
    );
    return completer.future;
  }

  /// 触发一次 pickAssets，返回 mock native 收到的 PgPickerConfig
  Future<PgPickerConfig> pgConfigOf(PickerConfig config) async {
    await LivePhotoGallery.pickAssets(config: config);
    return captured.single! as PgPickerConfig;
  }

  /// 触发一次 previewAssets，返回 mock native 收到的 PgPreviewRequest
  Future<PgPreviewRequest> pgRequestOf(List<AssetInput> assets) async {
    await LivePhotoGallery.previewAssets(assets: assets);
    return captured.single! as PgPreviewRequest;
  }

  setUp(() {
    captured = const <Object?>[];
    mockHost('pickAssets');
    mockHost('previewAssets');
    mockHost('exportAsset');
  });

  tearDown(() {
    clearHost('pickAssets');
    clearHost('previewAssets');
    clearHost('exportAsset');
  });

  // ──────────────────────────────────────────────────────────────────────────
  // PickerConfig._pg / MediaFilter._pg
  // ──────────────────────────────────────────────────────────────────────────

  group('PickerConfig._pg（公开配置 → PgPickerConfig）', () {
    test('默认配置逐字段过桥，cropConfig 为 null', () async {
      final pg = await pgConfigOf(const PickerConfig());
      expect(pg.isDarkMode, isFalse);
      expect(pg.maxCount, 9);
      expect(pg.enableVideo, isTrue);
      expect(pg.enableLivePhoto, isTrue);
      expect(pg.showRadio, isTrue);
      expect(pg.maxVideoCount, -1);
      expect(pg.videoMaxDuration, 0.0);
      expect(pg.filterConfig, PgMediaFilter.all);
      expect(pg.cropConfig, isNull);
    });

    test('全部非默认值逐字段过桥（含 cropConfig）', () async {
      final pg = await pgConfigOf(const PickerConfig(
        isDarkMode: true,
        maxCount: 3,
        enableVideo: false,
        enableLivePhoto: false,
        showRadio: false,
        maxVideoCount: 2,
        videoMaxDuration: 30.5,
        filterConfig: MediaFilter.videoOnly,
        cropConfig: CropConfig(aspectRatioX: 16, aspectRatioY: 9),
      ));
      expect(pg.isDarkMode, isTrue);
      expect(pg.maxCount, 3);
      expect(pg.enableVideo, isFalse);
      expect(pg.enableLivePhoto, isFalse);
      expect(pg.showRadio, isFalse);
      expect(pg.maxVideoCount, 2);
      expect(pg.videoMaxDuration, 30.5);
      expect(pg.filterConfig, PgMediaFilter.videoOnly);
      expect(pg.cropConfig?.aspectRatioX, 16.0);
      expect(pg.cropConfig?.aspectRatioY, 9.0);
    });
  });

  group('MediaFilter._pg（每个枚举值必须一一对应，不得串位）', () {
    test('all → PgMediaFilter.all', () async {
      final pg = await pgConfigOf(const PickerConfig(filterConfig: MediaFilter.all));
      expect(pg.filterConfig, PgMediaFilter.all);
    });

    test('imageOnly → PgMediaFilter.imageOnly', () async {
      final pg = await pgConfigOf(
          const PickerConfig(filterConfig: MediaFilter.imageOnly));
      expect(pg.filterConfig, PgMediaFilter.imageOnly);
    });

    test('videoOnly → PgMediaFilter.videoOnly', () async {
      final pg = await pgConfigOf(
          const PickerConfig(filterConfig: MediaFilter.videoOnly));
      expect(pg.filterConfig, PgMediaFilter.videoOnly);
    });

    test('livePhotoOnly → PgMediaFilter.livePhotoOnly', () async {
      final pg = await pgConfigOf(
          const PickerConfig(filterConfig: MediaFilter.livePhotoOnly));
      expect(pg.filterConfig, PgMediaFilter.livePhotoOnly);
    });

    test('公开枚举与传输枚举的取值个数一致（新增值时提醒同步）', () {
      expect(MediaFilter.values.length, PgMediaFilter.values.length);
    });
  });

  // ──────────────────────────────────────────────────────────────────────────
  // AssetInput._pg
  // ──────────────────────────────────────────────────────────────────────────

  group('AssetInput._pg（type / mediaType 归一化）', () {
    test('type 仅 "network" 判为网络源，其余（含非法值）按本地处理', () async {
      final request = await pgRequestOf(const [
        AssetInput(type: 'network', url: 'https://x/i.jpg'),
        AssetInput(type: 'local', assetId: 'a1'),
        AssetInput(type: 'NETWORK', assetId: 'a2'),
        AssetInput(type: '', assetId: 'a3'),
      ]);
      expect(
        request.assets.map((a) => a.type).toList(),
        const [
          PgAssetSource.network,
          PgAssetSource.local,
          PgAssetSource.local,
          PgAssetSource.local,
        ],
      );
    });

    test('mediaType：null 保持 null，未知字符串归一到 image', () async {
      final request = await pgRequestOf(const [
        AssetInput(type: 'local', assetId: 'a0'),
        AssetInput(type: 'local', assetId: 'a1', mediaType: 'image'),
        AssetInput(type: 'local', assetId: 'a2', mediaType: 'video'),
        AssetInput(type: 'local', assetId: 'a3', mediaType: 'livePhoto'),
        AssetInput(type: 'local', assetId: 'a4', mediaType: 'LivePhoto'),
        AssetInput(type: 'local', assetId: 'a5', mediaType: ''),
      ]);
      expect(
        request.assets.map((a) => a.mediaType).toList(),
        const [
          null,
          PgMediaType.image,
          PgMediaType.video,
          PgMediaType.livePhoto,
          PgMediaType.image,
          PgMediaType.image,
        ],
      );
    });

    test('其余字段原样过桥', () async {
      final request = await pgRequestOf(const [
        AssetInput(
          type: 'network',
          assetId: 'asset-1',
          url: 'https://x/i.jpg',
          mediaType: 'livePhoto',
          videoUrl: 'https://x/v.mov',
          duration: 2.5,
        ),
      ]);
      final asset = request.assets.single;
      expect(asset.assetId, 'asset-1');
      expect(asset.url, 'https://x/i.jpg');
      expect(asset.videoUrl, 'https://x/v.mov');
      expect(asset.duration, 2.5);
    });
  });

  group('previewAssets 请求体其余字段', () {
    test('initialIndex / sourceFrame / selectedAssetIds / 下载参数过桥', () async {
      await LivePhotoGallery.previewAssets(
        assets: const [AssetInput(type: 'local', assetId: 'a1')],
        initialIndex: 2,
        sourceFrame: const Rect.fromLTWH(1, 2, 3, 4),
        selectedAssetIds: const ['a1', 'a2'],
        showDownloadButton: true,
        saveAlbumName: '相册名',
      );
      final request = captured.single! as PgPreviewRequest;
      expect(request.initialIndex, 2);
      expect(request.sourceFrame.x, 1.0);
      expect(request.sourceFrame.y, 2.0);
      expect(request.sourceFrame.width, 3.0);
      expect(request.sourceFrame.height, 4.0);
      expect(request.selectedAssetIds, ['a1', 'a2']);
      expect(request.showDownloadButton, isTrue);
      expect(request.saveAlbumName, '相册名');
    });
  });

  // ──────────────────────────────────────────────────────────────────────────
  // MediaItem._fromPg
  // ──────────────────────────────────────────────────────────────────────────

  group('MediaItem._fromPg（PgMediaType → 公开字符串）', () {
    PgPickResult resultWith(List<PgMediaType> types) => PgPickResult(
          items: types
              .map((t) => PgMediaItem(
                    assetId: 'id-${t.name}',
                    mediaType: t,
                    thumbnailPath: '/tmp/${t.name}.jpg',
                    duration: t == PgMediaType.video ? 3.0 : null,
                    width: 100,
                    height: 200,
                  ))
              .toList(),
          isOriginalPhoto: true,
        );

    test('三种类型分别映射为 image / video / livePhoto', () async {
      mockHost('pickAssets',
          reply: resultWith(PgMediaType.values));
      final result = await LivePhotoGallery.pickAssets();
      expect(
        result!.items.map((i) => i.mediaType).toList(),
        const ['image', 'video', 'livePhoto'],
      );
      expect(result.isOriginalPhoto, isTrue);
    });

    test('其余字段原样还原', () async {
      mockHost('pickAssets', reply: resultWith(const [PgMediaType.video]));
      final item = (await LivePhotoGallery.pickAssets())!.items.single;
      expect(item.assetId, 'id-video');
      expect(item.thumbnailPath, '/tmp/video.jpg');
      expect(item.duration, 3.0);
      expect(item.width, 100);
      expect(item.height, 200);
    });

    test('native 返回 null（用户取消）时结果为 null', () async {
      mockHost('pickAssets');
      expect(await LivePhotoGallery.pickAssets(), isNull);
    });

    test('公开 mediaType 取值个数与传输枚举一致（新增值时提醒同步）', () {
      expect(PgMediaType.values.length, 3);
    });
  });

  // ──────────────────────────────────────────────────────────────────────────
  // DownloadErrorCode._fromPg（native → Dart 事件）
  // ──────────────────────────────────────────────────────────────────────────

  group('DownloadErrorCode._fromPg（PgDownloadErrorCode → 公开枚举）', () {
    setUp(() async {
      // 事件通道由 pickAssets / previewAssets 惰性注册，先触发一次
      await LivePhotoGallery.pickAssets();
    });

    Future<DownloadResult> emit(PgDownloadResultEvent event) async {
      final future = LivePhotoGallery.onDownloadResult.first;
      await pushFlutterEvent('onDownloadResult', <Object?>[event]);
      return future;
    }

    test('四个错误码逐一映射，errorCode 缺失回退 unknown', () async {
      const pairs = <(PgDownloadErrorCode?, DownloadErrorCode)>[
        (PgDownloadErrorCode.permissionDenied, DownloadErrorCode.permissionDenied),
        (PgDownloadErrorCode.networkError, DownloadErrorCode.networkError),
        (PgDownloadErrorCode.saveFailed, DownloadErrorCode.saveFailed),
        (PgDownloadErrorCode.unknown, DownloadErrorCode.unknown),
        (null, DownloadErrorCode.unknown),
      ];
      for (final (pg, expected) in pairs) {
        final result = await emit(PgDownloadResultEvent(
          url: 'https://x/i.jpg',
          success: false,
          errorCode: pg,
          errorMessage: '失败',
        ));
        expect(result, isA<DownloadFailure>());
        expect((result as DownloadFailure).errorCode, expected,
            reason: '$pg 应映射为 $expected');
        expect(result.url, 'https://x/i.jpg');
        expect(result.errorMessage, '失败');
      }
    });

    test('errorMessage 缺失时使用默认文案', () async {
      final result = await emit(PgDownloadResultEvent(
        url: 'https://x/i.jpg',
        success: false,
        errorCode: PgDownloadErrorCode.saveFailed,
      ));
      expect((result as DownloadFailure).errorMessage, '保存失败');
    });

    test('success 事件产出 DownloadSuccess 并带 assetId', () async {
      final result = await emit(PgDownloadResultEvent(
        url: 'https://x/i.jpg',
        success: true,
        assetId: 'content://media/1',
      ));
      expect(result, isA<DownloadSuccess>());
      expect((result as DownloadSuccess).assetId, 'content://media/1');
      expect(result.url, 'https://x/i.jpg');
    });

    test('onDownloadProgress / onMaxCountReached 事件过桥', () async {
      final progress = LivePhotoGallery.onDownloadProgress.first;
      await pushFlutterEvent(
          'onDownloadProgress', <Object?>['https://x/i.jpg', 0.42]);
      expect((await progress).url, 'https://x/i.jpg');
      expect((await progress).progress, 0.42);

      final maxCount = LivePhotoGallery.onMaxCountReached.first;
      await pushFlutterEvent('onMaxCountReached', <Object?>[9]);
      expect(await maxCount, 9);
    });
  });

  // ──────────────────────────────────────────────────────────────────────────
  // exportAsset 的 format 契约
  // ──────────────────────────────────────────────────────────────────────────

  group('exportAsset format → PgExportFormat', () {
    test('三个合法值分别映射', () async {
      for (final (raw, expected) in const <(String, PgExportFormat)>[
        ('image', PgExportFormat.image),
        ('video', PgExportFormat.video),
        ('livePhotoVideo', PgExportFormat.livePhotoVideo),
      ]) {
        await LivePhotoGallery.exportAsset(assetId: 'a1', format: raw);
        expect(captured, ['a1', expected]);
      }
    });

    test('非法 format 抛 INVALID_ARGS，且不会发出任何 native 调用', () async {
      for (final bad in const ['', 'Image', 'livephotovideo', 'gif']) {
        captured = const <Object?>[];
        await expectLater(
          () => LivePhotoGallery.exportAsset(assetId: 'a1', format: bad),
          throwsA(isA<LivePhotoException>()
              .having((e) => e.code, 'code', 'INVALID_ARGS')
              .having((e) => e.message, 'message', '不支持的媒体类型')),
        );
        expect(captured, isEmpty, reason: '"$bad" 不应到达 native');
      }
    });

    test('native 抛出的 PlatformException 转换为 LivePhotoException', () async {
      const channel = BasicMessageChannel<Object?>(
          '${hostPrefix}exportAsset', codec);
      messenger.setMockDecodedMessageHandler<Object?>(channel,
          (Object? message) async => <Object?>['EXPORT_FAILED', '导出失败', null]);
      await expectLater(
        () => LivePhotoGallery.exportAsset(assetId: 'a1', format: 'video'),
        throwsA(isA<LivePhotoException>()
            .having((e) => e.code, 'code', 'EXPORT_FAILED')
            .having((e) => e.message, 'message', '导出失败')),
      );
    });
  });
}
