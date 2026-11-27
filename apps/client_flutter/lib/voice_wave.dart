import 'dart:convert';
import 'dart:math' as math;
import 'dart:typed_data';

// Little-endian, mono PCM16. Accept only the fixed WAV subset the recorder emits.
const voiceRate = 16000;
const voiceSeconds = 30;
const _maxData = voiceRate * 2 * voiceSeconds;

class VoiceSamples {
  final _bytes = BytesBuilder();
  int get seconds => _bytes.length ~/ (voiceRate * 2);
  bool add(Uint8List chunk) {
    final left = _maxData - _bytes.length;
    _bytes.add(Uint8List.sublistView(chunk, 0, math.min(left, chunk.length)));
    return _bytes.length == _maxData;
  }

  Uint8List finish() {
    final raw = _bytes.takeBytes();
    final length = raw.length & ~1;
    if (length < 2) throw const FormatException('EMPTY_VOICE');
    final out = Uint8List(44 + length);
    final h = ByteData.sublistView(out);
    out.setAll(0, ascii.encode('RIFF'));
    h.setUint32(4, length + 36, Endian.little);
    out.setAll(8, ascii.encode('WAVEfmt '));
    h.setUint32(16, 16, Endian.little);
    h.setUint16(20, 1, Endian.little);
    h.setUint16(22, 1, Endian.little);
    h.setUint32(24, voiceRate, Endian.little);
    h.setUint32(28, voiceRate * 2, Endian.little);
    h.setUint16(32, 2, Endian.little);
    h.setUint16(34, 16, Endian.little);
    out.setAll(36, ascii.encode('data'));
    h.setUint32(40, length, Endian.little);
    out.setRange(44, out.length, raw);
    return out;
  }
}

Duration voiceDuration(Uint8List bytes) {
  final size = bytes.length - 44;
  if (size < 2 || size > _maxData || size.isOdd) {
    throw const FormatException('INVALID_VOICE');
  }
  final h = ByteData.sublistView(bytes);
  int u32(int at) => h.getUint32(at, Endian.little);
  int u16(int at) => h.getUint16(at, Endian.little);
  if (String.fromCharCodes(bytes, 0, 4) != 'RIFF' ||
      u32(4) != 36 + size ||
      String.fromCharCodes(bytes, 8, 16) != 'WAVEfmt ' ||
      u32(16) != 16 ||
      u16(20) != 1 ||
      u16(22) != 1 ||
      u32(24) != voiceRate ||
      u32(28) != voiceRate * 2 ||
      u16(32) != 2 ||
      u16(34) != 16 ||
      String.fromCharCodes(bytes, 36, 40) != 'data' ||
      u32(40) != size) {
    throw const FormatException('INVALID_VOICE');
  }
  return Duration(microseconds: size * 1000000 ~/ (voiceRate * 2));
}
