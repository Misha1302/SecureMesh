import 'dart:convert';
import 'dart:math' as math;
import 'dart:typed_data';

// Little-endian, mono PCM16. Accept only the fixed WAV subset the recorder emits.
const voiceRate = 16000;
const voiceSeconds = 30;
const _maxData = voiceRate * 2 * voiceSeconds;

class VoiceSamples {
  final _bytes = BytesBuilder();
  final peaks = <double>[];
  int _lowByte = 0, _peak = 0;
  int _samplesInBin = 0;
  bool _needsHighByte = false;

  int get seconds => _bytes.length ~/ (voiceRate * 2);
  bool add(Uint8List chunk) {
    final left = _maxData - _bytes.length;
    final accepted = Uint8List.sublistView(
      chunk,
      0,
      math.min(left, chunk.length),
    );
    _bytes.add(accepted);
    for (final byte in accepted) {
      if (_needsHighByte) {
        final sample = (_lowByte | (byte << 8)).toSigned(16);
        _peak = math.max(_peak, sample.abs());
        if (++_samplesInBin == voiceRate ~/ 5) {
          peaks.add(_peak / 32768);
          _samplesInBin = _peak = 0;
        }
      } else {
        _lowByte = byte;
      }
      _needsHighByte = !_needsHighByte;
    }
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

/// Peak absolute amplitude in equal time intervals of a validated mono clip.
List<double> voicePeaks(Uint8List wav, {int bars = 36}) {
  voiceDuration(wav);
  final data = ByteData.sublistView(wav, 44);
  final samples = data.lengthInBytes ~/ 2;
  final count = bars.clamp(1, samples);
  final peaks = List<double>.filled(count, 0);
  for (var i = 0; i < samples; i++) {
    final bin = i * count ~/ samples;
    final amplitude = data.getInt16(i * 2, Endian.little).abs() / 32768;
    peaks[bin] = math.max(peaks[bin], amplitude);
  }
  return peaks;
}
