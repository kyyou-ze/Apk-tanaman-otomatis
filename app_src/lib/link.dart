import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:flutter_blue_plus/flutter_blue_plus.dart';
import 'package:http/http.dart' as http;

/// Satu antarmuka untuk semua mode: alat mengirim baris teks, aplikasi mengirim perintah teks.
abstract class Link {
  Stream<String> get lines;
  Future<void> send(String cmd);
  Future<void> close();
}

final _svc = Guid('a1b2c3d4-0001-4000-8000-00805f9b34fb');
final _dataG = Guid('a1b2c3d4-0002-4000-8000-00805f9b34fb');
final _cmdG = Guid('a1b2c3d4-0003-4000-8000-00805f9b34fb');

class BleLink implements Link {
  final void Function() onDrop;
  BleLink(this.onDrop);
  final _ctl = StreamController<String>.broadcast();
  BluetoothDevice? _dev;
  BluetoothCharacteristic? _cmd;
  StreamSubscription? _sub, _conn;

  @override
  Stream<String> get lines => _ctl.stream;

  Future<void> open() async {
    if (await FlutterBluePlus.adapterState.first != BluetoothAdapterState.on) {
      throw 'Bluetooth HP belum aktif. Nyalakan Bluetooth lalu coba lagi.';
    }
    final found = Completer<BluetoothDevice?>();
    final s = FlutterBluePlus.scanResults.listen((l) {
      if (l.isNotEmpty && !found.isCompleted) found.complete(l.first.device);
    });
    FlutterBluePlus.startScan(withServices: [_svc], timeout: const Duration(seconds: 10)).catchError((_) {});
    final d = await found.future.timeout(const Duration(seconds: 10), onTimeout: () => null);
    await FlutterBluePlus.stopScan();
    await s.cancel();
    if (d == null) throw 'AgriBot tidak ditemukan via Bluetooth. Pastikan alat menyala dan berada di mode Bluetooth.';
    await d.connect();
    _dev = d;
    _conn = d.connectionState.listen((st) {
      if (st == BluetoothConnectionState.disconnected) onDrop();
    });
    final svcs = await d.discoverServices();
    final svc = svcs.firstWhere((x) => x.uuid == _svc);
    for (final c in svc.characteristics) {
      if (c.uuid == _cmdG) _cmd = c;
      if (c.uuid == _dataG) {
        await c.setNotifyValue(true);
        _sub = c.onValueReceived.listen((v) => _ctl.add(utf8.decode(v, allowMalformed: true)));
      }
    }
  }

  @override
  Future<void> send(String cmd) async => _cmd?.write(utf8.encode(cmd));

  @override
  Future<void> close() async {
    await _conn?.cancel();
    await _sub?.cancel();
    try {
      await _dev?.disconnect();
    } catch (_) {}
    await _ctl.close();
  }
}

class HttpLink implements Link {
  final String host;
  final void Function() onDrop;
  HttpLink(this.host, this.onDrop);
  final _ctl = StreamController<String>.broadcast();
  Timer? _t;
  int _fail = 0;

  @override
  Stream<String> get lines => _ctl.stream;

  Uri _u(String p, [Map<String, String>? q]) => Uri.http(host, p, q);

  Future<void> open() async {
    try {
      await http.get(_u('/api/status')).timeout(const Duration(seconds: 3));
    } catch (_) {
      throw 'Tidak bisa menjangkau alat di $host. Pastikan HP satu WiFi dengan alat dan matikan data seluler.';
    }
    _t = Timer.periodic(const Duration(milliseconds: 1500), (_) => _poll());
    _poll();
  }

  Future<void> _poll() async {
    try {
      final r = await http.get(_u('/api/status')).timeout(const Duration(seconds: 2));
      if (r.statusCode == 200) {
        _fail = 0;
        if (!_ctl.isClosed) _ctl.add(r.body);
      }
    } catch (_) {
      if (++_fail >= 3) {
        _t?.cancel();
        onDrop();
      }
    }
  }

  @override
  Future<void> send(String c) async {
    if (c == 'G:S') {
      final r = await http.get(_u('/api/sched')).timeout(const Duration(seconds: 3));
      for (final l in r.body.split(';')) {
        if (l.isNotEmpty) _ctl.add(l);
      }
      return;
    }
    await http.get(_u('/api/cmd', {'c': c})).timeout(const Duration(seconds: 3));
  }

  @override
  Future<void> close() async {
    _t?.cancel();
    await _ctl.close();
  }
}

/// Cari alat di jaringan lewat UDP broadcast. Mengembalikan alamat IP atau null.
Future<String?> discoverHost() async {
  RawDatagramSocket? s;
  try {
    s = await RawDatagramSocket.bind(InternetAddress.anyIPv4, 0);
    s.broadcastEnabled = true;
    final c = Completer<String?>();
    s.listen((e) {
      if (e == RawSocketEvent.read) {
        final d = s!.receive();
        if (d == null) return;
        final m = utf8.decode(d.data, allowMalformed: true);
        if (m.startsWith('AGRIBOT,') && !c.isCompleted) c.complete(m.substring(8).trim());
      }
    });
    for (var i = 0; i < 3 && !c.isCompleted; i++) {
      s.send(utf8.encode('AGRIBOT?'), InternetAddress('255.255.255.255'), 4210);
      s.send(utf8.encode('AGRIBOT?'), InternetAddress('192.168.4.1'), 4210);
      await Future.delayed(const Duration(milliseconds: 700));
    }
    return await c.future.timeout(const Duration(milliseconds: 600), onTimeout: () => null);
  } catch (_) {
    return null;
  } finally {
    s?.close();
  }
}
