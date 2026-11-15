// 测试固件自给自足（B10-2，P0-2）：test/fixtures/ 磁盘目录已删除，fresh clone
// 下测试仍须通过。本文件是唯一的固件来源：
// - EXIF 方向 JPEG ×4、加密 PDF：小文件（≤3640B），base64 内嵌，
//   与原磁盘固件逐字节相同（见 docs/ui-replication/B10-2-FIXTURES.md）；
// - photo.jpg：原 141420B 照片太大不内嵌，取方向 1 固件去掉 APP1
//   （Exif）段生成——400×300 真实 JPEG、无 EXIF、dart:ui 可解码；
//   各引用测试只验复制/大小/无 EXIF/可解码，不验原照片像素与尺寸；
// - slice-narrow PNG：dart:ui 现场画 500×120 白底黑条（与原夹具
//   同尺寸；b2 测试只量几何，不验像素）。
// 生成物一律写进各测试自己的临时目录，不写仓库。
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'dart:ui' as ui;

/// EXIF 方向固件（原 test/fixtures/exif-orientation-{1,3,6,8}.jpg，
/// 各 3640B）：400×300 白底、红块左上 (0..100, 0..100)、绿块右下
/// (300..400, 200..300)，大端 TIFF，Orientation 值在字节偏移 48..49
/// （p2 镜像测试就地改这两个字节改方向）。
Uint8List exifFixtureBytes(int orientation) {
  switch (orientation) {
    case 1:
      return base64Decode(_exif1B64);
    case 3:
      return base64Decode(_exif3B64);
    case 6:
      return base64Decode(_exif6B64);
    case 8:
      return base64Decode(_exif8B64);
    default:
      throw ArgumentError('no exif fixture for orientation $orientation');
  }
}

/// 加密 PDF 固件（原 test/fixtures/pdf-encrypted.pdf，1035B，密码 1234）。
Uint8List encryptedPdfFixtureBytes() => base64Decode(_pdfEncryptedB64);

/// “照片”固件：方向 1 固件去掉 APP1（Exif）段。400×300 真实 JPEG，
/// 无 EXIF（readJpegExifOrientation → null），dart:ui 可解码。
Uint8List photoFixtureBytes() => _stripExifApp1(exifFixtureBytes(1));

/// 逐段走 JPEG 标记复制，跳过含 "Exif\0\0" 的 APP1 段；到 SOS 后
/// 余下字节（含扫描数据与 EOI）原样复制。只处理本固件会出现的段
/// （APP0/APP1/DQT/SOF0/DHT，SOS 前无无长度标记）。
Uint8List _stripExifApp1(Uint8List jpeg) {
  final out = <int>[jpeg[0], jpeg[1]]; // SOI
  var pos = 2;
  while (pos + 4 <= jpeg.length) {
    if (jpeg[pos] != 0xFF) break;
    final marker = jpeg[pos + 1];
    if (marker == 0xDA) {
      // SOS：余下全部是扫描数据，原样复制。
      out.addAll(jpeg.sublist(pos));
      return Uint8List.fromList(out);
    }
    final len = (jpeg[pos + 2] << 8) | jpeg[pos + 3];
    if (len < 2 || pos + 2 + len > jpeg.length) break;
    final isExifApp1 = marker == 0xE1 &&
        len >= 8 &&
        jpeg[pos + 4] == 0x45 && // E
        jpeg[pos + 5] == 0x78 && // x
        jpeg[pos + 6] == 0x69 && // i
        jpeg[pos + 7] == 0x66 && // f
        jpeg[pos + 8] == 0 &&
        jpeg[pos + 9] == 0;
    if (!isExifApp1) out.addAll(jpeg.sublist(pos, pos + 2 + len));
    pos += 2 + len;
  }
  return Uint8List.fromList(out);
}

/// 生成窄切片 PNG（原 test/fixtures/slice-narrow-500x120.png）：
/// 500×120 白底 + 黑色“文字行”条（原夹具黑像素包围盒 x 16..470、
/// y 30..75）。须在 setUpAll（真实 zone）里调，testWidgets 体内
/// dart:ui 的 toImage 会挂起（见 p2_main_chain_test 注释）。
Future<Uint8List> narrowSlicePngBytes() async {
  final recorder = ui.PictureRecorder();
  final canvas = ui.Canvas(recorder);
  canvas.drawRect(
    const ui.Rect.fromLTWH(0, 0, 500, 120),
    ui.Paint()..color = const ui.Color(0xFFFFFFFF),
  );
  final black = ui.Paint()..color = const ui.Color(0xFF000000);
  canvas.drawRect(const ui.Rect.fromLTWH(16, 30, 455, 12), black);
  canvas.drawRect(const ui.Rect.fromLTWH(16, 50, 455, 12), black);
  canvas.drawRect(const ui.Rect.fromLTWH(16, 68, 265, 10), black);
  final img = await recorder.endRecording().toImage(500, 120);
  try {
    final data = await img.toByteData(format: ui.ImageByteFormat.png);
    return data!.buffer.asUint8List();
  } finally {
    img.dispose();
  }
}

/// 把固件字节写进目录，返回文件（供需要真实路径的调用方：导入、渲染）。
Future<File> writeFixtureFile(
    Directory dir, String name, Uint8List bytes) async {
  final file = File('${dir.path}/$name');
  await file.writeAsBytes(bytes);
  return file;
}

const _exif1B64 =
  '/9j/4AAQSkZJRgABAQAAAQABAAD/4QAiRXhpZgAATU0AKgAAAAgAAQESAAMAAAABAAEAAAAAAAD/2wBDAAgGBgcGBQgHBwcJCQgK'
  'DBQNDAsLDBkSEw8UHRofHh0aHBwgJC4nICIsIxwcKDcpLDAxNDQ0Hyc5PTgyPC4zNDL/2wBDAQkJCQwLDBgNDRgyIRwhMjIyMjIy'
  'MjIyMjIyMjIyMjIyMjIyMjIyMjIyMjIyMjIyMjIyMjIyMjIyMjIyMjIyMjL/wAARCAEsAZADASIAAhEBAxEB/8QAHwAAAQUBAQEB'
  'AQEAAAAAAAAAAAECAwQFBgcICQoL/8QAtRAAAgEDAwIEAwUFBAQAAAF9AQIDAAQRBRIhMUEGE1FhByJxFDKBkaEII0KxwRVS0fAk'
  'M2JyggkKFhcYGRolJicoKSo0NTY3ODk6Q0RFRkdISUpTVFVWV1hZWmNkZWZnaGlqc3R1dnd4eXqDhIWGh4iJipKTlJWWl5iZmqKj'
  'pKWmp6ipqrKztLW2t7i5usLDxMXGx8jJytLT1NXW19jZ2uHi4+Tl5ufo6erx8vP09fb3+Pn6/8QAHwEAAwEBAQEBAQEBAQAAAAAA'
  'AAECAwQFBgcICQoL/8QAtREAAgECBAQDBAcFBAQAAQJ3AAECAxEEBSExBhJBUQdhcRMiMoEIFEKRobHBCSMzUvAVYnLRChYkNOEl'
  '8RcYGRomJygpKjU2Nzg5OkNERUZHSElKU1RVVldYWVpjZGVmZ2hpanN0dXZ3eHl6goOEhYaHiImKkpOUlZaXmJmaoqOkpaanqKmq'
  'srO0tba3uLm6wsPExcbHyMnK0tPU1dbX2Nna4uPk5ebn6Onq8vP09fb3+Pn6/9oADAMBAAIRAxEAPwDi6KKK+ZP3EKKKKACiiigA'
  'ooooAKKKKACiiigD1r4J/wDMc/7d/wD2pXrNeTfBP/mOf9u//tSvWa9zB/wI/P8AM/KuJP8AkaVf+3f/AElBRRRXUeGFFFFABRRR'
  'QAUUUUAFFFFABRRRQAUUUUAFFFFABRRRQAUUUUAFFFFABRRRQAUUUUAFFFFABRRRQAUUUUAFFFFABRRRQB8mUUUV8yfuIUUUUAFF'
  'FFABRRRQAUUUUAFFFFAHrXwT/wCY5/27/wDtSvWa8m+Cf/Mc/wC3f/2pXrNe5g/4Efn+Z+VcSf8AI0q/9u/+koKKKK6jwwooooAK'
  'KKKACiiigAooooAKKKKACiiigAooooAKKKKACiiigAooooAKKKKACiiigAooooAKKKKACiiigAooooAKKKKAPkyiiivmT9xCiiig'
  'AooooAKKKKACiiigAooooA9a+Cf/ADHP+3f/ANqV6zXk3wT/AOY5/wBu/wD7Ur1mvcwf8CPz/M/KuJP+RpV/7d/9JQUUUV1HhhRR'
  'RQAUUUUAFFFFABRRRQAUUUUAFFFFABRRRQAUUUUAFFFFABRRRQAUUUUAFFFFABRRRQAUUUUAFFFFABRRRQAUUUUAfJlFFFfMn7iF'
  'FFFABRRRQAUUUUAFFFFABRRRQB618E/+Y5/27/8AtSvWa8m+Cf8AzHP+3f8A9qV6zXuYP+BH5/mflXEn/I0q/wDbv/pKCiiiuo8M'
  'KKKKACiiigAooooAKKKKACiiigAooooAKKKKACiiigAooooAKKKKACiiigAooooAKKKKACiiigAooooAKKKKACiiigD5Mooor5k/'
  'cQooooAKKKKACiiigAooooAKKKKAPWvgn/zHP+3f/wBqV6zXk3wT/wCY5/27/wDtSvWa9zB/wI/P8z8q4k/5GlX/ALd/9JQUUUV1'
  'HhhRRRQAUUUUAFFFFABRRRQAUUUUAFFFFABRRRQAUUUUAFFFFABRRRQAUUUUAFFFFABRRRQAUUUUAFFFFABRRRQAUUUUAfJlFFFf'
  'Mn7iFFFFABRRRQAUUUUAFFFFABRRRQB618E/+Y5/27/+1K9Zryb4J/8AMc/7d/8A2pXrNe5g/wCBH5/mflXEn/I0q/8Abv8A6Sgo'
  'oorqPDCiiigAooooAKKKKACiiigAooooAKKKKACiiigAooooAKKKKACiiigAooooAKKKKACiiigAooooAKKKKACiiigAooooA8m/'
  '4Un/ANTD/wCSX/2yj/hSf/Uw/wDkl/8AbK9Zorl+p0P5fxZ7n+smaf8AP3/yWP8AkeTf8KT/AOph/wDJL/7ZR/wpP/qYf/JL/wC2'
  'V6zRR9Tofy/iw/1kzT/n7/5LH/I8m/4Un/1MP/kl/wDbKP8AhSf/AFMP/kl/9sr1mij6nQ/l/Fh/rJmn/P3/AMlj/keTf8KT/wCp'
  'h/8AJL/7ZR/wpP8A6mH/AMkv/tles0UfU6H8v4sP9ZM0/wCfv/ksf8jyb/hSf/Uw/wDkl/8AbKP+FJ/9TD/5Jf8A2yvWaKPqdD+X'
  '8WH+smaf8/f/ACWP+R5N/wAKT/6mH/yS/wDtlH/Ck/8AqYf/ACS/+2V6zRR9Tofy/iw/1kzT/n7/AOSx/wAjkvBPgn/hDvt3/Ew+'
  '1/avL/5Y+Xt27v8AaOc7v0rraKK6IQjCPLHY8rE4mriarrVneT3f4dAoooqjAKKKKACiiigAooooAKKKKACiiigAooooAKKKKACi'
  'iigAooooAKKKKACiiigAooooAKKKKACiiigAooooAKKKKACiiigAooooAKKKKACiiigAooooAKKKKACiiigAooooAKKKKACiiigA'
  'ooooAKKKKACiiigAooooAKKKKACiiigAooooAKKKKACiiigAooooAKKKKACiiigAooooAKKKKACiiigAooooAKKKKACiiigAoooo'
  'AKKKKACiiigAooooAKKKKACiiigAooooAKKKKACiiigAooooAKKKKACiiigAooooAKKKKACiiigAooooAKKKKACiiigAooooAKKK'
  'KACiiigAooooAKKKKACiiigAooooAKKKKACiiigAooooAKKKKACiiigAooooAKKKKACiiigAooooAKKKKACiiigAooooAKKKKACi'
  'iigAooooAKKKKACiiigAooooAKKKKACiiigAooooAKKKKACiiigAooooAKKKKACiiigAooooAKKKKACiiigAooooAKKKKACiiigA'
  'ooooAKKKKACiiigAooooAKKKKACiiigAooooAKKKKACiiigAooooAKKKKACiiigAooooAKKKKACiiigAooooAKKKKACiiigAoooo'
  'AKKKKACiiigAooooAKKKKACiiigAooooAKKKKACiiigAooooAKKKKACiiigAooooAKKKKACiiigAooooAKKKKACiiigAooooAKKK'
  'KACiiigAooooAKKKKACiiigAooooAKKKKACiiigAooooAKKKKACiiigAooooAKKKKACiiigAooooAKKKKACiiigAooooAKKKKACi'
  'iigAooooAKKKKACiivNfi1/zB/8Att/7JWGJrexpOpa9jnxeI+r0XVte3+dj0qivmqivL/tj+5+P/APG/t7/AKd/j/wD6Vor5qoo'
  '/tj+5+P/AAA/t7/p3+P/AAD6Vor5qoo/tj+5+P8AwA/t7/p3+P8AwD6Vor5qoo/tj+5+P/AD+3v+nf4/8A+laK+aqKP7Y/ufj/wA'
  '/t7/AKd/j/wD6Vor5qoo/tj+5+P/AAA/t7/p3+P/AAD6Vooor2z6EKKKKACiiigAooooAKKKKACiiigAooooAKKKKACiiigAoooo'
  'AKKKKACiiigAooooAKKKKACiiigAooooAKKKKACiiigArzX4tf8AMH/7bf8AslelV5r8Wv8AmD/9tv8A2SuLMf8AdpfL80edmv8A'
  'uc/l+aPNKKKK+XPjQooooAKKKKACiiigAooooAKKKKAPpWiiivtT9DCiiigAooooAKKKKACiiigAooooAKKKKACiiigAooooAKKK'
  'KACiiigAooooAKKKKACiiigAooooAKKKKACiiigAooooAK81+LX/ADB/+23/ALJXpVea/Fr/AJg//bb/ANkrizH/AHaXy/NHnZr/'
  'ALnP5fmjzSiiivlz40KKKKACiiigAooooAKKKKACiiigD6Vooor7U/QwooooAKKKKACiiigAooooAKKKKACiiigAooooAKKKKACi'
  'iigAooooAKKKKACiiigAooooAKKKKACiiigAooooAKKKKACvNfi1/wAwf/tt/wCyV6VXmvxa/wCYP/22/wDZK4sx/wB2l8vzR52a'
  '/wC5z+X5o80ooor5c+NCiiigAooooAKKKKACiiigAooooA+laKKK+1P0MKKKKACiiigAooooAKKKKACiiigAooooAKKKKACiiigA'
  'ooooAKKKKACiiigAooooAKKKKACiiigAooooAKKKKACiiigArzX4tf8AMH/7bf8AslelV5r8Wv8AmD/9tv8A2SuLMf8AdpfL80ed'
  'mv8Auc/l+aPNKKKK+XPjQooooAKKKKACiiigAooooAKKKKAPpWiiivtT9DCiiigAooooAKKKKACiiigAooooAKKKKACiiigAoooo'
  'AKKKKACiiigAooooAKKKKACiiigAooooAKKKKACiiigAooooAK81+LX/ADB/+23/ALJXpVea/Fr/AJg//bb/ANkrizH/AHaXy/NH'
  'nZr/ALnP5fmjzSiiivlz40KKKKACiiigAooooAKKKKACiiigD6Vooor7U/QwooooAKKKKACiiigAooooAKKKKACiiigAooooAKKK'
  'KACiiigAooooAKKKKACiiigAooooAKKKKACiiigAooooAKKKKACvNfi1/wAwf/tt/wCyV6VXmvxa/wCYP/22/wDZK4sx/wB2l8vz'
  'R52a/wC5z+X5o80ooor5c+NCiiigAooooAKKKKACiiigAooooA//2Q==';

const _exif3B64 =
  '/9j/4AAQSkZJRgABAQAAAQABAAD/4QAiRXhpZgAATU0AKgAAAAgAAQESAAMAAAABAAMAAAAAAAD/2wBDAAgGBgcGBQgHBwcJCQgK'
  'DBQNDAsLDBkSEw8UHRofHh0aHBwgJC4nICIsIxwcKDcpLDAxNDQ0Hyc5PTgyPC4zNDL/2wBDAQkJCQwLDBgNDRgyIRwhMjIyMjIy'
  'MjIyMjIyMjIyMjIyMjIyMjIyMjIyMjIyMjIyMjIyMjIyMjIyMjIyMjIyMjL/wAARCAEsAZADASIAAhEBAxEB/8QAHwAAAQUBAQEB'
  'AQEAAAAAAAAAAAECAwQFBgcICQoL/8QAtRAAAgEDAwIEAwUFBAQAAAF9AQIDAAQRBRIhMUEGE1FhByJxFDKBkaEII0KxwRVS0fAk'
  'M2JyggkKFhcYGRolJicoKSo0NTY3ODk6Q0RFRkdISUpTVFVWV1hZWmNkZWZnaGlqc3R1dnd4eXqDhIWGh4iJipKTlJWWl5iZmqKj'
  'pKWmp6ipqrKztLW2t7i5usLDxMXGx8jJytLT1NXW19jZ2uHi4+Tl5ufo6erx8vP09fb3+Pn6/8QAHwEAAwEBAQEBAQEBAQAAAAAA'
  'AAECAwQFBgcICQoL/8QAtREAAgECBAQDBAcFBAQAAQJ3AAECAxEEBSExBhJBUQdhcRMiMoEIFEKRobHBCSMzUvAVYnLRChYkNOEl'
  '8RcYGRomJygpKjU2Nzg5OkNERUZHSElKU1RVVldYWVpjZGVmZ2hpanN0dXZ3eHl6goOEhYaHiImKkpOUlZaXmJmaoqOkpaanqKmq'
  'srO0tba3uLm6wsPExcbHyMnK0tPU1dbX2Nna4uPk5ebn6Onq8vP09fb3+Pn6/9oADAMBAAIRAxEAPwDi6KKK+ZP3EKKKKACiiigA'
  'ooooAKKKKACiiigD1r4J/wDMc/7d/wD2pXrNeTfBP/mOf9u//tSvWa9zB/wI/P8AM/KuJP8AkaVf+3f/AElBRRRXUeGFFFFABRRR'
  'QAUUUUAFFFFABRRRQAUUUUAFFFFABRRRQAUUUUAFFFFABRRRQAUUUUAFFFFABRRRQAUUUUAFFFFABRRRQB8mUUUV8yfuIUUUUAFF'
  'FFABRRRQAUUUUAFFFFAHrXwT/wCY5/27/wDtSvWa8m+Cf/Mc/wC3f/2pXrNe5g/4Efn+Z+VcSf8AI0q/9u/+koKKKK6jwwooooAK'
  'KKKACiiigAooooAKKKKACiiigAooooAKKKKACiiigAooooAKKKKACiiigAooooAKKKKACiiigAooooAKKKKAPkyiiivmT9xCiiig'
  'AooooAKKKKACiiigAooooA9a+Cf/ADHP+3f/ANqV6zXk3wT/AOY5/wBu/wD7Ur1mvcwf8CPz/M/KuJP+RpV/7d/9JQUUUV1HhhRR'
  'RQAUUUUAFFFFABRRRQAUUUUAFFFFABRRRQAUUUUAFFFFABRRRQAUUUUAFFFFABRRRQAUUUUAFFFFABRRRQAUUUUAfJlFFFfMn7iF'
  'FFFABRRRQAUUUUAFFFFABRRRQB618E/+Y5/27/8AtSvWa8m+Cf8AzHP+3f8A9qV6zXuYP+BH5/mflXEn/I0q/wDbv/pKCiiiuo8M'
  'KKKKACiiigAooooAKKKKACiiigAooooAKKKKACiiigAooooAKKKKACiiigAooooAKKKKACiiigAooooAKKKKACiiigD5Mooor5k/'
  'cQooooAKKKKACiiigAooooAKKKKAPWvgn/zHP+3f/wBqV6zXk3wT/wCY5/27/wDtSvWa9zB/wI/P8z8q4k/5GlX/ALd/9JQUUUV1'
  'HhhRRRQAUUUUAFFFFABRRRQAUUUUAFFFFABRRRQAUUUUAFFFFABRRRQAUUUUAFFFFABRRRQAUUUUAFFFFABRRRQAUUUUAfJlFFFf'
  'Mn7iFFFFABRRRQAUUUUAFFFFABRRRQB618E/+Y5/27/+1K9Zryb4J/8AMc/7d/8A2pXrNe5g/wCBH5/mflXEn/I0q/8Abv8A6Sgo'
  'oorqPDCiiigAooooAKKKKACiiigAooooAKKKKACiiigAooooAKKKKACiiigAooooAKKKKACiiigAooooAKKKKACiiigAooooA8m/'
  '4Un/ANTD/wCSX/2yj/hSf/Uw/wDkl/8AbK9Zorl+p0P5fxZ7n+smaf8AP3/yWP8AkeTf8KT/AOph/wDJL/7ZR/wpP/qYf/JL/wC2'
  'V6zRR9Tofy/iw/1kzT/n7/5LH/I8m/4Un/1MP/kl/wDbKP8AhSf/AFMP/kl/9sr1mij6nQ/l/Fh/rJmn/P3/AMlj/keTf8KT/wCp'
  'h/8AJL/7ZR/wpP8A6mH/AMkv/tles0UfU6H8v4sP9ZM0/wCfv/ksf8jyb/hSf/Uw/wDkl/8AbKP+FJ/9TD/5Jf8A2yvWaKPqdD+X'
  '8WH+smaf8/f/ACWP+R5N/wAKT/6mH/yS/wDtlH/Ck/8AqYf/ACS/+2V6zRR9Tofy/iw/1kzT/n7/AOSx/wAjkvBPgn/hDvt3/Ew+'
  '1/avL/5Y+Xt27v8AaOc7v0rraKK6IQjCPLHY8rE4mriarrVneT3f4dAoooqjAKKKKACiiigAooooAKKKKACiiigAooooAKKKKACi'
  'iigAooooAKKKKACiiigAooooAKKKKACiiigAooooAKKKKACiiigAooooAKKKKACiiigAooooAKKKKACiiigAooooAKKKKACiiigA'
  'ooooAKKKKACiiigAooooAKKKKACiiigAooooAKKKKACiiigAooooAKKKKACiiigAooooAKKKKACiiigAooooAKKKKACiiigAoooo'
  'AKKKKACiiigAooooAKKKKACiiigAooooAKKKKACiiigAooooAKKKKACiiigAooooAKKKKACiiigAooooAKKKKACiiigAooooAKKK'
  'KACiiigAooooAKKKKACiiigAooooAKKKKACiiigAooooAKKKKACiiigAooooAKKKKACiiigAooooAKKKKACiiigAooooAKKKKACi'
  'iigAooooAKKKKACiiigAooooAKKKKACiiigAooooAKKKKACiiigAooooAKKKKACiiigAooooAKKKKACiiigAooooAKKKKACiiigA'
  'ooooAKKKKACiiigAooooAKKKKACiiigAooooAKKKKACiiigAooooAKKKKACiiigAooooAKKKKACiiigAooooAKKKKACiiigAoooo'
  'AKKKKACiiigAooooAKKKKACiiigAooooAKKKKACiiigAooooAKKKKACiiigAooooAKKKKACiiigAooooAKKKKACiiigAooooAKKK'
  'KACiiigAooooAKKKKACiiigAooooAKKKKACiiigAooooAKKKKACiiigAooooAKKKKACiiigAooooAKKKKACiiigAooooAKKKKACi'
  'iigAooooAKKKKACiivNfi1/zB/8Att/7JWGJrexpOpa9jnxeI+r0XVte3+dj0qivmqivL/tj+5+P/APG/t7/AKd/j/wD6Vor5qoo'
  '/tj+5+P/AAA/t7/p3+P/AAD6Vor5qoo/tj+5+P8AwA/t7/p3+P8AwD6Vor5qoo/tj+5+P/AD+3v+nf4/8A+laK+aqKP7Y/ufj/wA'
  '/t7/AKd/j/wD6Vor5qoo/tj+5+P/AAA/t7/p3+P/AAD6Vooor2z6EKKKKACiiigAooooAKKKKACiiigAooooAKKKKACiiigAoooo'
  'AKKKKACiiigAooooAKKKKACiiigAooooAKKKKACiiigArzX4tf8AMH/7bf8AslelV5r8Wv8AmD/9tv8A2SuLMf8AdpfL80edmv8A'
  'uc/l+aPNKKKK+XPjQooooAKKKKACiiigAooooAKKKKAPpWiiivtT9DCiiigAooooAKKKKACiiigAooooAKKKKACiiigAooooAKKK'
  'KACiiigAooooAKKKKACiiigAooooAKKKKACiiigAooooAK81+LX/ADB/+23/ALJXpVea/Fr/AJg//bb/ANkrizH/AHaXy/NHnZr/'
  'ALnP5fmjzSiiivlz40KKKKACiiigAooooAKKKKACiiigD6Vooor7U/QwooooAKKKKACiiigAooooAKKKKACiiigAooooAKKKKACi'
  'iigAooooAKKKKACiiigAooooAKKKKACiiigAooooAKKKKACvNfi1/wAwf/tt/wCyV6VXmvxa/wCYP/22/wDZK4sx/wB2l8vzR52a'
  '/wC5z+X5o80ooor5c+NCiiigAooooAKKKKACiiigAooooA+laKKK+1P0MKKKKACiiigAooooAKKKKACiiigAooooAKKKKACiiigA'
  'ooooAKKKKACiiigAooooAKKKKACiiigAooooAKKKKACiiigArzX4tf8AMH/7bf8AslelV5r8Wv8AmD/9tv8A2SuLMf8AdpfL80ed'
  'mv8Auc/l+aPNKKKK+XPjQooooAKKKKACiiigAooooAKKKKAPpWiiivtT9DCiiigAooooAKKKKACiiigAooooAKKKKACiiigAoooo'
  'AKKKKACiiigAooooAKKKKACiiigAooooAKKKKACiiigAooooAK81+LX/ADB/+23/ALJXpVea/Fr/AJg//bb/ANkrizH/AHaXy/NH'
  'nZr/ALnP5fmjzSiiivlz40KKKKACiiigAooooAKKKKACiiigD6Vooor7U/QwooooAKKKKACiiigAooooAKKKKACiiigAooooAKKK'
  'KACiiigAooooAKKKKACiiigAooooAKKKKACiiigAooooAKKKKACvNfi1/wAwf/tt/wCyV6VXmvxa/wCYP/22/wDZK4sx/wB2l8vz'
  'R52a/wC5z+X5o80ooor5c+NCiiigAooooAKKKKACiiigAooooA//2Q==';

const _exif6B64 =
  '/9j/4AAQSkZJRgABAQAAAQABAAD/4QAiRXhpZgAATU0AKgAAAAgAAQESAAMAAAABAAYAAAAAAAD/2wBDAAgGBgcGBQgHBwcJCQgK'
  'DBQNDAsLDBkSEw8UHRofHh0aHBwgJC4nICIsIxwcKDcpLDAxNDQ0Hyc5PTgyPC4zNDL/2wBDAQkJCQwLDBgNDRgyIRwhMjIyMjIy'
  'MjIyMjIyMjIyMjIyMjIyMjIyMjIyMjIyMjIyMjIyMjIyMjIyMjIyMjIyMjL/wAARCAEsAZADASIAAhEBAxEB/8QAHwAAAQUBAQEB'
  'AQEAAAAAAAAAAAECAwQFBgcICQoL/8QAtRAAAgEDAwIEAwUFBAQAAAF9AQIDAAQRBRIhMUEGE1FhByJxFDKBkaEII0KxwRVS0fAk'
  'M2JyggkKFhcYGRolJicoKSo0NTY3ODk6Q0RFRkdISUpTVFVWV1hZWmNkZWZnaGlqc3R1dnd4eXqDhIWGh4iJipKTlJWWl5iZmqKj'
  'pKWmp6ipqrKztLW2t7i5usLDxMXGx8jJytLT1NXW19jZ2uHi4+Tl5ufo6erx8vP09fb3+Pn6/8QAHwEAAwEBAQEBAQEBAQAAAAAA'
  'AAECAwQFBgcICQoL/8QAtREAAgECBAQDBAcFBAQAAQJ3AAECAxEEBSExBhJBUQdhcRMiMoEIFEKRobHBCSMzUvAVYnLRChYkNOEl'
  '8RcYGRomJygpKjU2Nzg5OkNERUZHSElKU1RVVldYWVpjZGVmZ2hpanN0dXZ3eHl6goOEhYaHiImKkpOUlZaXmJmaoqOkpaanqKmq'
  'srO0tba3uLm6wsPExcbHyMnK0tPU1dbX2Nna4uPk5ebn6Onq8vP09fb3+Pn6/9oADAMBAAIRAxEAPwDi6KKK+ZP3EKKKKACiiigA'
  'ooooAKKKKACiiigD1r4J/wDMc/7d/wD2pXrNeTfBP/mOf9u//tSvWa9zB/wI/P8AM/KuJP8AkaVf+3f/AElBRRRXUeGFFFFABRRR'
  'QAUUUUAFFFFABRRRQAUUUUAFFFFABRRRQAUUUUAFFFFABRRRQAUUUUAFFFFABRRRQAUUUUAFFFFABRRRQB8mUUUV8yfuIUUUUAFF'
  'FFABRRRQAUUUUAFFFFAHrXwT/wCY5/27/wDtSvWa8m+Cf/Mc/wC3f/2pXrNe5g/4Efn+Z+VcSf8AI0q/9u/+koKKKK6jwwooooAK'
  'KKKACiiigAooooAKKKKACiiigAooooAKKKKACiiigAooooAKKKKACiiigAooooAKKKKACiiigAooooAKKKKAPkyiiivmT9xCiiig'
  'AooooAKKKKACiiigAooooA9a+Cf/ADHP+3f/ANqV6zXk3wT/AOY5/wBu/wD7Ur1mvcwf8CPz/M/KuJP+RpV/7d/9JQUUUV1HhhRR'
  'RQAUUUUAFFFFABRRRQAUUUUAFFFFABRRRQAUUUUAFFFFABRRRQAUUUUAFFFFABRRRQAUUUUAFFFFABRRRQAUUUUAfJlFFFfMn7iF'
  'FFFABRRRQAUUUUAFFFFABRRRQB618E/+Y5/27/8AtSvWa8m+Cf8AzHP+3f8A9qV6zXuYP+BH5/mflXEn/I0q/wDbv/pKCiiiuo8M'
  'KKKKACiiigAooooAKKKKACiiigAooooAKKKKACiiigAooooAKKKKACiiigAooooAKKKKACiiigAooooAKKKKACiiigD5Mooor5k/'
  'cQooooAKKKKACiiigAooooAKKKKAPWvgn/zHP+3f/wBqV6zXk3wT/wCY5/27/wDtSvWa9zB/wI/P8z8q4k/5GlX/ALd/9JQUUUV1'
  'HhhRRRQAUUUUAFFFFABRRRQAUUUUAFFFFABRRRQAUUUUAFFFFABRRRQAUUUUAFFFFABRRRQAUUUUAFFFFABRRRQAUUUUAfJlFFFf'
  'Mn7iFFFFABRRRQAUUUUAFFFFABRRRQB618E/+Y5/27/+1K9Zryb4J/8AMc/7d/8A2pXrNe5g/wCBH5/mflXEn/I0q/8Abv8A6Sgo'
  'oorqPDCiiigAooooAKKKKACiiigAooooAKKKKACiiigAooooAKKKKACiiigAooooAKKKKACiiigAooooAKKKKACiiigAooooA8m/'
  '4Un/ANTD/wCSX/2yj/hSf/Uw/wDkl/8AbK9Zorl+p0P5fxZ7n+smaf8AP3/yWP8AkeTf8KT/AOph/wDJL/7ZR/wpP/qYf/JL/wC2'
  'V6zRR9Tofy/iw/1kzT/n7/5LH/I8m/4Un/1MP/kl/wDbKP8AhSf/AFMP/kl/9sr1mij6nQ/l/Fh/rJmn/P3/AMlj/keTf8KT/wCp'
  'h/8AJL/7ZR/wpP8A6mH/AMkv/tles0UfU6H8v4sP9ZM0/wCfv/ksf8jyb/hSf/Uw/wDkl/8AbKP+FJ/9TD/5Jf8A2yvWaKPqdD+X'
  '8WH+smaf8/f/ACWP+R5N/wAKT/6mH/yS/wDtlH/Ck/8AqYf/ACS/+2V6zRR9Tofy/iw/1kzT/n7/AOSx/wAjkvBPgn/hDvt3/Ew+'
  '1/avL/5Y+Xt27v8AaOc7v0rraKK6IQjCPLHY8rE4mriarrVneT3f4dAoooqjAKKKKACiiigAooooAKKKKACiiigAooooAKKKKACi'
  'iigAooooAKKKKACiiigAooooAKKKKACiiigAooooAKKKKACiiigAooooAKKKKACiiigAooooAKKKKACiiigAooooAKKKKACiiigA'
  'ooooAKKKKACiiigAooooAKKKKACiiigAooooAKKKKACiiigAooooAKKKKACiiigAooooAKKKKACiiigAooooAKKKKACiiigAoooo'
  'AKKKKACiiigAooooAKKKKACiiigAooooAKKKKACiiigAooooAKKKKACiiigAooooAKKKKACiiigAooooAKKKKACiiigAooooAKKK'
  'KACiiigAooooAKKKKACiiigAooooAKKKKACiiigAooooAKKKKACiiigAooooAKKKKACiiigAooooAKKKKACiiigAooooAKKKKACi'
  'iigAooooAKKKKACiiigAooooAKKKKACiiigAooooAKKKKACiiigAooooAKKKKACiiigAooooAKKKKACiiigAooooAKKKKACiiigA'
  'ooooAKKKKACiiigAooooAKKKKACiiigAooooAKKKKACiiigAooooAKKKKACiiigAooooAKKKKACiiigAooooAKKKKACiiigAoooo'
  'AKKKKACiiigAooooAKKKKACiiigAooooAKKKKACiiigAooooAKKKKACiiigAooooAKKKKACiiigAooooAKKKKACiiigAooooAKKK'
  'KACiiigAooooAKKKKACiiigAooooAKKKKACiiigAooooAKKKKACiiigAooooAKKKKACiiigAooooAKKKKACiiigAooooAKKKKACi'
  'iigAooooAKKKKACiivNfi1/zB/8Att/7JWGJrexpOpa9jnxeI+r0XVte3+dj0qivmqivL/tj+5+P/APG/t7/AKd/j/wD6Vor5qoo'
  '/tj+5+P/AAA/t7/p3+P/AAD6Vor5qoo/tj+5+P8AwA/t7/p3+P8AwD6Vor5qoo/tj+5+P/AD+3v+nf4/8A+laK+aqKP7Y/ufj/wA'
  '/t7/AKd/j/wD6Vor5qoo/tj+5+P/AAA/t7/p3+P/AAD6Vooor2z6EKKKKACiiigAooooAKKKKACiiigAooooAKKKKACiiigAoooo'
  'AKKKKACiiigAooooAKKKKACiiigAooooAKKKKACiiigArzX4tf8AMH/7bf8AslelV5r8Wv8AmD/9tv8A2SuLMf8AdpfL80edmv8A'
  'uc/l+aPNKKKK+XPjQooooAKKKKACiiigAooooAKKKKAPpWiiivtT9DCiiigAooooAKKKKACiiigAooooAKKKKACiiigAooooAKKK'
  'KACiiigAooooAKKKKACiiigAooooAKKKKACiiigAooooAK81+LX/ADB/+23/ALJXpVea/Fr/AJg//bb/ANkrizH/AHaXy/NHnZr/'
  'ALnP5fmjzSiiivlz40KKKKACiiigAooooAKKKKACiiigD6Vooor7U/QwooooAKKKKACiiigAooooAKKKKACiiigAooooAKKKKACi'
  'iigAooooAKKKKACiiigAooooAKKKKACiiigAooooAKKKKACvNfi1/wAwf/tt/wCyV6VXmvxa/wCYP/22/wDZK4sx/wB2l8vzR52a'
  '/wC5z+X5o80ooor5c+NCiiigAooooAKKKKACiiigAooooA+laKKK+1P0MKKKKACiiigAooooAKKKKACiiigAooooAKKKKACiiigA'
  'ooooAKKKKACiiigAooooAKKKKACiiigAooooAKKKKACiiigArzX4tf8AMH/7bf8AslelV5r8Wv8AmD/9tv8A2SuLMf8AdpfL80ed'
  'mv8Auc/l+aPNKKKK+XPjQooooAKKKKACiiigAooooAKKKKAPpWiiivtT9DCiiigAooooAKKKKACiiigAooooAKKKKACiiigAoooo'
  'AKKKKACiiigAooooAKKKKACiiigAooooAKKKKACiiigAooooAK81+LX/ADB/+23/ALJXpVea/Fr/AJg//bb/ANkrizH/AHaXy/NH'
  'nZr/ALnP5fmjzSiiivlz40KKKKACiiigAooooAKKKKACiiigD6Vooor7U/QwooooAKKKKACiiigAooooAKKKKACiiigAooooAKKK'
  'KACiiigAooooAKKKKACiiigAooooAKKKKACiiigAooooAKKKKACvNfi1/wAwf/tt/wCyV6VXmvxa/wCYP/22/wDZK4sx/wB2l8vz'
  'R52a/wC5z+X5o80ooor5c+NCiiigAooooAKKKKACiiigAooooA//2Q==';

const _exif8B64 =
  '/9j/4AAQSkZJRgABAQAAAQABAAD/4QAiRXhpZgAATU0AKgAAAAgAAQESAAMAAAABAAgAAAAAAAD/2wBDAAgGBgcGBQgHBwcJCQgK'
  'DBQNDAsLDBkSEw8UHRofHh0aHBwgJC4nICIsIxwcKDcpLDAxNDQ0Hyc5PTgyPC4zNDL/2wBDAQkJCQwLDBgNDRgyIRwhMjIyMjIy'
  'MjIyMjIyMjIyMjIyMjIyMjIyMjIyMjIyMjIyMjIyMjIyMjIyMjIyMjIyMjL/wAARCAEsAZADASIAAhEBAxEB/8QAHwAAAQUBAQEB'
  'AQEAAAAAAAAAAAECAwQFBgcICQoL/8QAtRAAAgEDAwIEAwUFBAQAAAF9AQIDAAQRBRIhMUEGE1FhByJxFDKBkaEII0KxwRVS0fAk'
  'M2JyggkKFhcYGRolJicoKSo0NTY3ODk6Q0RFRkdISUpTVFVWV1hZWmNkZWZnaGlqc3R1dnd4eXqDhIWGh4iJipKTlJWWl5iZmqKj'
  'pKWmp6ipqrKztLW2t7i5usLDxMXGx8jJytLT1NXW19jZ2uHi4+Tl5ufo6erx8vP09fb3+Pn6/8QAHwEAAwEBAQEBAQEBAQAAAAAA'
  'AAECAwQFBgcICQoL/8QAtREAAgECBAQDBAcFBAQAAQJ3AAECAxEEBSExBhJBUQdhcRMiMoEIFEKRobHBCSMzUvAVYnLRChYkNOEl'
  '8RcYGRomJygpKjU2Nzg5OkNERUZHSElKU1RVVldYWVpjZGVmZ2hpanN0dXZ3eHl6goOEhYaHiImKkpOUlZaXmJmaoqOkpaanqKmq'
  'srO0tba3uLm6wsPExcbHyMnK0tPU1dbX2Nna4uPk5ebn6Onq8vP09fb3+Pn6/9oADAMBAAIRAxEAPwDi6KKK+ZP3EKKKKACiiigA'
  'ooooAKKKKACiiigD1r4J/wDMc/7d/wD2pXrNeTfBP/mOf9u//tSvWa9zB/wI/P8AM/KuJP8AkaVf+3f/AElBRRRXUeGFFFFABRRR'
  'QAUUUUAFFFFABRRRQAUUUUAFFFFABRRRQAUUUUAFFFFABRRRQAUUUUAFFFFABRRRQAUUUUAFFFFABRRRQB8mUUUV8yfuIUUUUAFF'
  'FFABRRRQAUUUUAFFFFAHrXwT/wCY5/27/wDtSvWa8m+Cf/Mc/wC3f/2pXrNe5g/4Efn+Z+VcSf8AI0q/9u/+koKKKK6jwwooooAK'
  'KKKACiiigAooooAKKKKACiiigAooooAKKKKACiiigAooooAKKKKACiiigAooooAKKKKACiiigAooooAKKKKAPkyiiivmT9xCiiig'
  'AooooAKKKKACiiigAooooA9a+Cf/ADHP+3f/ANqV6zXk3wT/AOY5/wBu/wD7Ur1mvcwf8CPz/M/KuJP+RpV/7d/9JQUUUV1HhhRR'
  'RQAUUUUAFFFFABRRRQAUUUUAFFFFABRRRQAUUUUAFFFFABRRRQAUUUUAFFFFABRRRQAUUUUAFFFFABRRRQAUUUUAfJlFFFfMn7iF'
  'FFFABRRRQAUUUUAFFFFABRRRQB618E/+Y5/27/8AtSvWa8m+Cf8AzHP+3f8A9qV6zXuYP+BH5/mflXEn/I0q/wDbv/pKCiiiuo8M'
  'KKKKACiiigAooooAKKKKACiiigAooooAKKKKACiiigAooooAKKKKACiiigAooooAKKKKACiiigAooooAKKKKACiiigD5Mooor5k/'
  'cQooooAKKKKACiiigAooooAKKKKAPWvgn/zHP+3f/wBqV6zXk3wT/wCY5/27/wDtSvWa9zB/wI/P8z8q4k/5GlX/ALd/9JQUUUV1'
  'HhhRRRQAUUUUAFFFFABRRRQAUUUUAFFFFABRRRQAUUUUAFFFFABRRRQAUUUUAFFFFABRRRQAUUUUAFFFFABRRRQAUUUUAfJlFFFf'
  'Mn7iFFFFABRRRQAUUUUAFFFFABRRRQB618E/+Y5/27/+1K9Zryb4J/8AMc/7d/8A2pXrNe5g/wCBH5/mflXEn/I0q/8Abv8A6Sgo'
  'oorqPDCiiigAooooAKKKKACiiigAooooAKKKKACiiigAooooAKKKKACiiigAooooAKKKKACiiigAooooAKKKKACiiigAooooA8m/'
  '4Un/ANTD/wCSX/2yj/hSf/Uw/wDkl/8AbK9Zorl+p0P5fxZ7n+smaf8AP3/yWP8AkeTf8KT/AOph/wDJL/7ZR/wpP/qYf/JL/wC2'
  'V6zRR9Tofy/iw/1kzT/n7/5LH/I8m/4Un/1MP/kl/wDbKP8AhSf/AFMP/kl/9sr1mij6nQ/l/Fh/rJmn/P3/AMlj/keTf8KT/wCp'
  'h/8AJL/7ZR/wpP8A6mH/AMkv/tles0UfU6H8v4sP9ZM0/wCfv/ksf8jyb/hSf/Uw/wDkl/8AbKP+FJ/9TD/5Jf8A2yvWaKPqdD+X'
  '8WH+smaf8/f/ACWP+R5N/wAKT/6mH/yS/wDtlH/Ck/8AqYf/ACS/+2V6zRR9Tofy/iw/1kzT/n7/AOSx/wAjkvBPgn/hDvt3/Ew+'
  '1/avL/5Y+Xt27v8AaOc7v0rraKK6IQjCPLHY8rE4mriarrVneT3f4dAoooqjAKKKKACiiigAooooAKKKKACiiigAooooAKKKKACi'
  'iigAooooAKKKKACiiigAooooAKKKKACiiigAooooAKKKKACiiigAooooAKKKKACiiigAooooAKKKKACiiigAooooAKKKKACiiigA'
  'ooooAKKKKACiiigAooooAKKKKACiiigAooooAKKKKACiiigAooooAKKKKACiiigAooooAKKKKACiiigAooooAKKKKACiiigAoooo'
  'AKKKKACiiigAooooAKKKKACiiigAooooAKKKKACiiigAooooAKKKKACiiigAooooAKKKKACiiigAooooAKKKKACiiigAooooAKKK'
  'KACiiigAooooAKKKKACiiigAooooAKKKKACiiigAooooAKKKKACiiigAooooAKKKKACiiigAooooAKKKKACiiigAooooAKKKKACi'
  'iigAooooAKKKKACiiigAooooAKKKKACiiigAooooAKKKKACiiigAooooAKKKKACiiigAooooAKKKKACiiigAooooAKKKKACiiigA'
  'ooooAKKKKACiiigAooooAKKKKACiiigAooooAKKKKACiiigAooooAKKKKACiiigAooooAKKKKACiiigAooooAKKKKACiiigAoooo'
  'AKKKKACiiigAooooAKKKKACiiigAooooAKKKKACiiigAooooAKKKKACiiigAooooAKKKKACiiigAooooAKKKKACiiigAooooAKKK'
  'KACiiigAooooAKKKKACiiigAooooAKKKKACiiigAooooAKKKKACiiigAooooAKKKKACiiigAooooAKKKKACiiigAooooAKKKKACi'
  'iigAooooAKKKKACiivNfi1/zB/8Att/7JWGJrexpOpa9jnxeI+r0XVte3+dj0qivmqivL/tj+5+P/APG/t7/AKd/j/wD6Vor5qoo'
  '/tj+5+P/AAA/t7/p3+P/AAD6Vor5qoo/tj+5+P8AwA/t7/p3+P8AwD6Vor5qoo/tj+5+P/AD+3v+nf4/8A+laK+aqKP7Y/ufj/wA'
  '/t7/AKd/j/wD6Vor5qoo/tj+5+P/AAA/t7/p3+P/AAD6Vooor2z6EKKKKACiiigAooooAKKKKACiiigAooooAKKKKACiiigAoooo'
  'AKKKKACiiigAooooAKKKKACiiigAooooAKKKKACiiigArzX4tf8AMH/7bf8AslelV5r8Wv8AmD/9tv8A2SuLMf8AdpfL80edmv8A'
  'uc/l+aPNKKKK+XPjQooooAKKKKACiiigAooooAKKKKAPpWiiivtT9DCiiigAooooAKKKKACiiigAooooAKKKKACiiigAooooAKKK'
  'KACiiigAooooAKKKKACiiigAooooAKKKKACiiigAooooAK81+LX/ADB/+23/ALJXpVea/Fr/AJg//bb/ANkrizH/AHaXy/NHnZr/'
  'ALnP5fmjzSiiivlz40KKKKACiiigAooooAKKKKACiiigD6Vooor7U/QwooooAKKKKACiiigAooooAKKKKACiiigAooooAKKKKACi'
  'iigAooooAKKKKACiiigAooooAKKKKACiiigAooooAKKKKACvNfi1/wAwf/tt/wCyV6VXmvxa/wCYP/22/wDZK4sx/wB2l8vzR52a'
  '/wC5z+X5o80ooor5c+NCiiigAooooAKKKKACiiigAooooA+laKKK+1P0MKKKKACiiigAooooAKKKKACiiigAooooAKKKKACiiigA'
  'ooooAKKKKACiiigAooooAKKKKACiiigAooooAKKKKACiiigArzX4tf8AMH/7bf8AslelV5r8Wv8AmD/9tv8A2SuLMf8AdpfL80ed'
  'mv8Auc/l+aPNKKKK+XPjQooooAKKKKACiiigAooooAKKKKAPpWiiivtT9DCiiigAooooAKKKKACiiigAooooAKKKKACiiigAoooo'
  'AKKKKACiiigAooooAKKKKACiiigAooooAKKKKACiiigAooooAK81+LX/ADB/+23/ALJXpVea/Fr/AJg//bb/ANkrizH/AHaXy/NH'
  'nZr/ALnP5fmjzSiiivlz40KKKKACiiigAooooAKKKKACiiigD6Vooor7U/QwooooAKKKKACiiigAooooAKKKKACiiigAooooAKKK'
  'KACiiigAooooAKKKKACiiigAooooAKKKKACiiigAooooAKKKKACvNfi1/wAwf/tt/wCyV6VXmvxa/wCYP/22/wDZK4sx/wB2l8vz'
  'R52a/wC5z+X5o80ooor5c+NCiiigAooooAKKKKACiiigAooooA//2Q==';

const _pdfEncryptedB64 =
  'JVBERi0xLjQKJeLjz9MKMSAwIG9iago8PAovUHJvZHVjZXIgPGM1YzI1MjcyNDA+Cj4+CmVuZG9iagoyIDAgb2JqCjw8Ci9UeXBl'
  'IC9QYWdlcwovQ291bnQgMQovS2lkcyBbIDQgMCBSIF0KPj4KZW5kb2JqCjMgMCBvYmoKPDwKL1R5cGUgL0NhdGFsb2cKL1BhZ2Vz'
  'IDIgMCBSCj4+CmVuZG9iago0IDAgb2JqCjw8Ci9UeXBlIC9QYWdlCi9NZWRpYUJveCBbIDAgMCA2MTIgNzkyIF0KL1Jlc291cmNl'
  'cyA8PAovRm9udCA8PAovRjEgNSAwIFIKPj4KPj4KL0NvbnRlbnRzIDYgMCBSCi9QYXJlbnQgMiAwIFIKPj4KZW5kb2JqCjUgMCBv'
  'YmoKPDwKL1R5cGUgL0ZvbnQKL1N1YnR5cGUgL1R5cGUxCi9CYXNlRm9udCAvSGVsdmV0aWNhCj4+CmVuZG9iago2IDAgb2JqCjw8'
  'Ci9MZW5ndGggNzcKPj4Kc3RyZWFtCtMSEVOXu5GDARtki+x5B1eZWfDhxD20fZDdyXfmW+ohISLO9A7fG/V2GJfb1e6x7nZFP50/'
  'PLQqZasrzZ8OUVrHpxrNQadVWwlN5eYBCmVuZHN0cmVhbQplbmRvYmoKNyAwIG9iago8PAovViAyCi9SIDMKL0xlbmd0aCAxMjgK'
  'L1AgNDI5NDk2NzI5MgovRmlsdGVyIC9TdGFuZGFyZAovTyA8NGZlMmQ1MTk4OGY5MDM4OGU3NGU1NDU4NDEyNWNlMTQyYmUwZGUy'
  'NGM2YjBkMzc3NDZlMDc1Yjg5MTc1NjY3MT4KL1UgPGYwMDEwNzE5MmQ5NjBjN2I4NjJjZGE4ZmVhNWYzYWIyMjhiZjRlNWU0ZTc1'
  'OGE0MTY0MDA0ZTU2ZmZmYTAxMDg+Cj4+CmVuZG9iagp4cmVmCjAgOAowMDAwMDAwMDAwIDY1NTM1IGYgCjAwMDAwMDAwMTUgMDAw'
  'MDAgbiAKMDAwMDAwMDA1OSAwMDAwMCBuIAowMDAwMDAwMTE4IDAwMDAwIG4gCjAwMDAwMDAxNjcgMDAwMDAgbiAKMDAwMDAwMDI5'
  'NSAwMDAwMCBuIAowMDAwMDAwMzY1IDAwMDAwIG4gCjAwMDAwMDA0OTIgMDAwMDAgbiAKdHJhaWxlcgo8PAovU2l6ZSA4Ci9Sb290'
  'IDMgMCBSCi9JbmZvIDEgMCBSCi9JRCBbIDwxYTgxNTcyMGQwMmYwNmE3NzM1MWQwNDE3MGU3N2VlNT4gPDFhODE1NzIwZDAyZjA2'
  'YTc3MzUxZDA0MTcwZTc3ZWU1PiBdCi9FbmNyeXB0IDcgMCBSCj4+CnN0YXJ0eHJlZgo3MDcKJSVFT0YK';
