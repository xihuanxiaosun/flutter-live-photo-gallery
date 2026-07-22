import 'package:flutter_test/flutter_test.dart';
import 'package:live_photo_gallery/live_photo_gallery.dart';

/// **公开门面** golden 测试。
///
/// 注意：Pigeon 迁移后，这里覆盖的 `toMap()` / `fromMap()` / `fromString()`
/// **已不再跨越 channel**——跨端数据由 pigeons/messages.dart 生成的类型承载。
/// 本文件的职责因此收窄为：把插件对调用方暴露的公开形状（map key、枚举字符串、
/// 防御式默认值）钉死，因为它们仍属于 1.0 的公开 API，调用方可能直接使用。
///
/// 真正跨端的手写转换器（MediaFilter._pg / PickerConfig._pg / AssetInput._pg /
/// MediaItem._fromPg / DownloadErrorCode._fromPg）由以下两处覆盖，改动 wire
/// 映射时看那里：
///   - Dart 侧：test/pigeon_boundary_test.dart
///   - Android 侧：android/src/test/kotlin/.../PigeonBoundaryTest.kt
void main() {
  group('PickerConfig.toMap 契约形状', () {
    test('默认配置产出完整且稳定的 key 集合', () {
      expect(const PickerConfig().toMap(), {
        'isDarkMode': false,
        'maxCount': 9,
        'enableVideo': true,
        'enableLivePhoto': true,
        'showRadio': true,
        'maxVideoCount': -1,
        'videoMaxDuration': 0.0,
        'filterConfig': 'all',
      });
    });

    test('cropConfig 为 null 时不出现在 map 中', () {
      expect(const PickerConfig().toMap().containsKey('cropConfig'), isFalse);
    });

    test('传入 cropConfig 时携带 aspectRatioX/Y', () {
      final map = const PickerConfig(
        cropConfig: CropConfig(aspectRatioX: 1, aspectRatioY: 1),
      ).toMap();
      expect(map['cropConfig'], {'aspectRatioX': 1.0, 'aspectRatioY': 1.0});
    });
  });

  group('MediaFilter 枚举字符串（必须与两端 native 对齐）', () {
    test('每个枚举值序列化为约定字符串', () {
      String filterOf(MediaFilter f) =>
          PickerConfig(filterConfig: f).toMap()['filterConfig'] as String;
      expect(filterOf(MediaFilter.all), 'all');
      expect(filterOf(MediaFilter.imageOnly), 'imageOnly');
      expect(filterOf(MediaFilter.videoOnly), 'videoOnly');
      expect(filterOf(MediaFilter.livePhotoOnly), 'livePhotoOnly');
    });
  });

  group('AssetInput.toMap 只序列化非空字段', () {
    test('local 资源', () {
      expect(const AssetInput(type: 'local', assetId: 'abc').toMap(), {
        'type': 'local',
        'assetId': 'abc',
      });
    });

    test('network livePhoto 资源', () {
      expect(
        const AssetInput(
          type: 'network',
          url: 'https://x/i.jpg',
          mediaType: 'livePhoto',
          videoUrl: 'https://x/v.mov',
        ).toMap(),
        {
          'type': 'network',
          'url': 'https://x/i.jpg',
          'mediaType': 'livePhoto',
          'videoUrl': 'https://x/v.mov',
        },
      );
    });
  });

  group('DownloadErrorCode.fromString 映射（对齐两端 errorCode 字符串）', () {
    test('已知码精确映射，未知/空回退 unknown', () {
      expect(DownloadErrorCode.fromString('PERMISSION_DENIED'),
          DownloadErrorCode.permissionDenied);
      expect(DownloadErrorCode.fromString('NETWORK_ERROR'),
          DownloadErrorCode.networkError);
      expect(DownloadErrorCode.fromString('SAVE_FAILED'),
          DownloadErrorCode.saveFailed);
      expect(DownloadErrorCode.fromString('INVALID_ARGS'),
          DownloadErrorCode.unknown);
      expect(DownloadErrorCode.fromString(null), DownloadErrorCode.unknown);
    });
  });

  group('MediaItem.fromMap 防御式解析', () {
    test('缺字段回退安全默认值', () {
      final item = MediaItem.fromMap(const {});
      expect(item.assetId, '');
      expect(item.mediaType, 'image');
      expect(item.thumbnailPath, '');
      expect(item.duration, isNull);
      expect(item.width, 0);
      expect(item.height, 0);
    });
  });
}
