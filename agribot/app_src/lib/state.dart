import 'dart:async';
import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'link.dart';

enum Net { ble, ap, sta }

const netNames = {Net.ble: 'Bluetooth', Net.ap: 'Hotspot AgriBot', Net.sta: 'Wi-Fi Router'};
const netCodes = {Net.ble: 'B', Net.ap: 'A', Net.sta: 'S'};

class Preset {
  final String name, emoji, tip;
  final int min, run, wait; // batas kering (%), lama siram (dtk), jeda (dtk)
  const Preset(this.name, this.emoji, this.min, this.run, this.wait, this.tip);
}

// Nilai awal - sesuaikan dengan debit pompa & ukuran pot saat uji.
const presets = [
  Preset('Cabai', '🌶️', 55, 5, 90, 'Suka tanah lembab tapi tidak tergenang. Hindari daun basah.'),
  Preset('Tomat', '🍅', 55, 6, 90, 'Kelembaban stabil mencegah buah pecah dan busuk ujung buah.'),
  Preset('Kangkung', '🥬', 70, 6, 60, 'Haus air: tanah harus selalu lembab.'),
  Preset('Selada', '🥗', 65, 4, 60, 'Akar dangkal: siram sering dengan volume kecil.'),
  Preset('Bayam', '🌿', 60, 4, 60, 'Jaga tanah lembab merata, jangan sampai kering total.'),
  Preset('Kemangi', '🍃', 55, 4, 90, 'Tanah lembab dengan drainase baik agar akar tidak busuk.'),
  Preset('Lidah Buaya', '🪴', 25, 4, 180, 'Sukulen: biarkan kering di antara penyiraman.'),
];

String presetEmoji(String n) => presets.firstWhere((p) => p.name == n, orElse: () => presets.first).emoji;

class Sched {
  bool en;
  int h, m, dur, days; // days: bit0=Minggu ... bit6=Sabtu
  Sched(this.en, this.h, this.m, this.dur, this.days);
}

class Sample {
  final int t, soil, hum;
  final double temp;
  Sample(this.t, this.soil, this.temp, this.hum);
}

class Ev {
  final int t, kind; // kind: 0 info, 1 siram, 2 peringatan
  final String text;
  Ev(this.t, this.text, this.kind);
}

int _i(String s, int d) => int.tryParse(s.trim()) ?? d;
int _now() => DateTime.now().millisecondsSinceEpoch ~/ 1000;

class AppState extends ChangeNotifier {
  late SharedPreferences _p;
  final _np = FlutterLocalNotificationsPlugin();

  Net net = Net.ble;
  String host = '', ssid = '', pass = '', plant = '';
  bool nWater = true, nPump = true, nConn = true, nDry = true;

  Link? _link;
  StreamSubscription<String>? _ls;
  Timer? _retry;
  bool connected = false, busy = false, _got = false, _want = false;
  int _retries = 0, _nid = 1, _lastSample = 0, _lastDry = 0;
  String status = 'Belum terhubung';

  int soil = 0, raw = 0, hum = 0, minSoil = 55, run = 5, wait = 60, remain = 0;
  double temp = -99;
  bool water = true, pump = false, auto = true, timeOk = false;
  String devNet = 'B';

  final sched = List.generate(4, (i) => Sched(false, 6 + i * 4, 0, 5, 127));
  final samples = <Sample>[];
  final events = <Ev>[];

  String get devNetName => netNames[Net.values.firstWhere((n) => netCodes[n] == devNet)]!;

  Future<void> init() async {
    _p = await SharedPreferences.getInstance();
    net = Net.values[_p.getInt('net') ?? 0];
    host = _p.getString('host') ?? '';
    ssid = _p.getString('ssid') ?? '';
    pass = _p.getString('pass') ?? '';
    plant = _p.getString('plant') ?? '';
    nWater = _p.getBool('nW') ?? true;
    nPump = _p.getBool('nP') ?? true;
    nConn = _p.getBool('nC') ?? true;
    nDry = _p.getBool('nD') ?? true;
    try {
      for (final e in jsonDecode(_p.getString('hist') ?? '[]') as List) {
        samples.add(Sample(e[0], e[1], (e[2] as num).toDouble(), e[3]));
      }
      for (final e in jsonDecode(_p.getString('ev') ?? '[]') as List) {
        events.add(Ev(e[0], e[1], e[2]));
      }
    } catch (_) {}
    await _np.initialize(const InitializationSettings(android: AndroidInitializationSettings('@mipmap/ic_launcher')));
    Permission.notification.request();
  }

  // ---------- koneksi ----------
  Future<void> connect() async {
    _want = true;
    _retries = 0;
    await _connect();
  }

  Future<void> _connect() async {
    if (busy || connected) return;
    busy = true;
    status = net == Net.ble ? 'Mencari AgriBot via Bluetooth...' : 'Mencari AgriBot di jaringan...';
    notifyListeners();
    try {
      if (net == Net.ble) {
        await [Permission.bluetoothScan, Permission.bluetoothConnect, Permission.locationWhenInUse].request();
        final l = BleLink(_dropped);
        await l.open();
        _link = l;
      } else {
        String? h = await discoverHost();
        h ??= net == Net.ap ? '192.168.4.1' : (host.isEmpty ? null : host);
        if (h == null) throw 'AgriBot tidak ditemukan. Pastikan HP satu WiFi dengan alat atau isi IP manual di Setelan.';
        final l = HttpLink(h, _dropped);
        await l.open();
        _link = l;
      }
      _ls = _link!.lines.listen(_onLine);
      connected = true;
      _retries = 0;
      status = 'Terhubung';
      _ev('Terhubung via ${netNames[net]}', 0);
      await Future.delayed(const Duration(milliseconds: 400));
      final n = DateTime.now();
      await send('Z:${n.millisecondsSinceEpoch ~/ 1000},${n.timeZoneOffset.inSeconds}');
      await send('G:S');
    } catch (e) {
      status = e is String ? e : 'Gagal terhubung: $e';
      _scheduleRetry();
    } finally {
      busy = false;
      notifyListeners();
    }
  }

  void _scheduleRetry() {
    if (!_want || _retries >= 5) return;
    _retries++;
    _retry?.cancel();
    _retry = Timer(const Duration(seconds: 5), _connect);
  }

  void _dropped() {
    if (!connected) return;
    connected = false;
    _got = false;
    status = 'Koneksi terputus - mencoba lagi...';
    _ev('Koneksi terputus', 2);
    _notify('Koneksi terputus', 'AgriBot tidak lagi terhubung dengan HP.', nConn);
    _ls?.cancel();
    _link?.close();
    _link = null;
    _scheduleRetry();
    notifyListeners();
  }

  Future<void> disconnect({bool quiet = false}) async {
    _want = false;
    _retry?.cancel();
    await _ls?.cancel();
    await _link?.close();
    _link = null;
    if (connected && !quiet) _ev('Diputus oleh pengguna', 0);
    connected = false;
    _got = false;
    status = 'Belum terhubung';
    notifyListeners();
  }

  Future<void> send(String c) async {
    try {
      await _link?.send(c);
    } catch (_) {}
  }

  // ---------- data masuk ----------
  void _onLine(String l) {
    l = l.trim();
    if (l.startsWith('S:')) {
      final p = l.substring(2).split(',');
      final i = p.length == 6 ? _i(p[0], -1) : -1;
      if (i >= 0 && i < 4) {
        sched[i] = Sched(p[1] == '1', _i(p[2], 6), _i(p[3], 0), _i(p[4], 5), _i(p[5], 127));
        notifyListeners();
      }
      return;
    }
    final p = l.split(',');
    if (p.length < 10) return;
    final ow = water, op = pump;
    soil = _i(p[0], soil);
    raw = _i(p[1], raw);
    temp = double.tryParse(p[2]) ?? temp;
    hum = _i(p[3], hum);
    water = p[4] == '1';
    pump = p[5] == '1';
    auto = p[6] == 'A';
    minSoil = _i(p[7], minSoil);
    run = _i(p[8], run);
    wait = _i(p[9], wait);
    if (p.length >= 13) {
      devNet = p[10];
      timeOk = p[11] == '1';
      remain = _i(p[12], 0);
    }
    _track(ow, op);
    _got = true;
    notifyListeners();
  }

  void _track(bool ow, bool op) {
    if (!_got) {
      if (!water) {
        _ev('Tangki air habis', 2);
        _notify('Tangki air habis', 'Isi tangki agar penyiraman bisa berjalan.', nWater);
      }
    } else {
      if (ow && !water) {
        _ev('Tangki air habis', 2);
        _notify('Tangki air habis', 'Isi tangki agar penyiraman bisa berjalan.', nWater);
      }
      if (!ow && water) _ev('Tangki terisi kembali', 0);
      if (!op && pump) _ev(auto ? 'Penyiraman dimulai (otomatis)' : 'Penyiraman dimulai (manual)', 1);
      if (op && !pump) {
        _ev('Penyiraman selesai', 1);
        _notify('Penyiraman selesai', 'Kelembaban tanah sekarang $soil%.', nPump);
      }
    }
    final now = _now();
    if (!auto && !pump && soil < minSoil - 10 && now - _lastDry > 3600) {
      _lastDry = now;
      _notify('Tanah kering', 'Kelembaban $soil%. Mode manual aktif - siram sekarang?', nDry);
    }
    if (now - _lastSample >= 30) {
      _lastSample = now;
      samples.add(Sample(now, soil, temp, hum));
      if (samples.length > 2000) samples.removeAt(0);
      _p.setString('hist', jsonEncode(samples.map((s) => [s.t, s.soil, s.temp, s.hum]).toList()));
    }
  }

  void _ev(String t, int k) {
    events.insert(0, Ev(_now(), t, k));
    if (events.length > 100) events.removeLast();
    _p.setString('ev', jsonEncode(events.map((e) => [e.t, e.text, e.kind]).toList()));
  }

  void _notify(String t, String b, bool on) {
    if (!on) return;
    _np.show(
      _nid++,
      t,
      b,
      const NotificationDetails(
        android: AndroidNotificationDetails('agribot', 'Peringatan AgriBot',
            importance: Importance.high, priority: Priority.high),
      ),
    );
  }

  // ---------- aksi ----------
  Future<void> setAuto(bool a) => send(a ? 'M:A' : 'M:M');
  Future<void> togglePump() => send(pump ? 'P:0' : 'P:1');
  Future<void> tune(int m, int r, int w) => send('T:$m,$r,$w');
  Future<void> calibrate(bool dry) => send(dry ? 'K:D' : 'K:W');

  Future<void> applyPreset(Preset p) {
    plant = p.name;
    _p.setString('plant', p.name);
    notifyListeners();
    return tune(p.min, p.run, p.wait);
  }

  Future<void> pushSched(int i) {
    final s = sched[i];
    notifyListeners();
    return send('S:$i,${s.en ? 1 : 0},${s.h},${s.m},${s.dur},${s.days}');
  }

  void setNet(Net n) {
    net = n;
    _p.setInt('net', n.index);
    notifyListeners();
  }

  void saveWifi(String s, String pw, String h) {
    ssid = s;
    pass = pw;
    host = h;
    _p.setString('ssid', s);
    _p.setString('pass', pw);
    _p.setString('host', h);
    notifyListeners();
  }

  /// Minta alat pindah jaringan (alat restart), lalu putus dari sisi aplikasi.
  Future<void> switchNet(Net n) async {
    if (n == Net.sta && ssid.isNotEmpty) await send('W:$ssid\t$pass');
    await send('N:${netCodes[n]}');
    await Future.delayed(const Duration(milliseconds: 600));
    await disconnect(quiet: true);
    setNet(n);
    _ev('Pindah ke mode ${netNames[n]}', 0);
    status = 'Alat restart ke mode ${netNames[n]}. ${n == Net.ble ? '' : 'Sambungkan HP ke WiFi yang sesuai, '}lalu tekan Hubungkan.';
    notifyListeners();
  }

  void setNotif({bool? w, bool? p, bool? c, bool? d}) {
    nWater = w ?? nWater;
    nPump = p ?? nPump;
    nConn = c ?? nConn;
    nDry = d ?? nDry;
    _p.setBool('nW', nWater);
    _p.setBool('nP', nPump);
    _p.setBool('nC', nConn);
    _p.setBool('nD', nDry);
    notifyListeners();
  }

  void clearHistory() {
    samples.clear();
    events.clear();
    _p.remove('hist');
    _p.remove('ev');
    notifyListeners();
  }
}
