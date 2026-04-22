import 'package:flutter_test/flutter_test.dart';
import 'package:live_photo_gallery/live_photo_gallery.dart';

void main() {
  test('AssetInput serializes optional fields safely', () {
    const input = AssetInput(
      type: 'network',
      url: 'https://example.com/image.jpg',
      mediaType: 'image',
      duration: 1.5,
    );

    expect(input.toMap(), {
      'type': 'network',
      'url': 'https://example.com/image.jpg',
      'mediaType': 'image',
      'duration': 1.5,
    });
  });

  test('MediaItem deserializes numeric values defensively', () {
    final item = MediaItem.fromMap({
      'assetId': 'asset-1',
      'mediaType': 'video',
      'thumbnailPath': '/tmp/thumb.jpg',
      'duration': 2,
      'width': 1080,
      'height': 1920,
    });

    expect(item.assetId, 'asset-1');
    expect(item.mediaType, 'video');
    expect(item.thumbnailPath, '/tmp/thumb.jpg');
    expect(item.duration, 2.0);
    expect(item.width, 1080);
    expect(item.height, 1920);
  });

  test('PickerConfig exposes business defaults', () {
    const config = PickerConfig();

    expect(config.maxCount, 9);
    expect(config.enableVideo, isTrue);
    expect(config.enableLivePhoto, isTrue);
    expect(config.showRadio, isTrue);
    expect(config.isDarkMode, isFalse);
  });

  test('PickerConfig rejects invalid constraints', () {
    expect(
      () => PickerConfig(maxCount: 0),
      throwsA(isA<AssertionError>()),
    );
    expect(
      () => PickerConfig(maxVideoCount: 0),
      throwsA(isA<AssertionError>()),
    );
    expect(
      () => PickerConfig(videoMaxDuration: -1),
      throwsA(isA<AssertionError>()),
    );
  });
}
