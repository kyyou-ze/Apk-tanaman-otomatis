// AgriBot v2 - ESP32 DevKit V1
// 3 mode jaringan (hanya satu aktif, dipilih lewat aplikasi / tombol):
//   BLE = Bluetooth | AP = alat membuat WiFi "AgriBot-XXXX" (sandi agribot123) | STA = masuk WiFi router
// WAJIB di Arduino IDE: Tools > Partition Scheme > "Huge APP (3MB No OTA/1MB SPIFFS)"
// Library: "DHT sensor library" + "Adafruit Unified Sensor" (lainnya bawaan core ESP32)
#include <WiFi.h>
#include <WebServer.h>
#include <WiFiUdp.h>
#include <BLEDevice.h>
#include <BLEServer.h>
#include <BLEUtils.h>
#include <BLE2902.h>
#include <DHT.h>
#include <Preferences.h>
#include <sys/time.h>

// ---------- PIN ----------
#define PIN_SOIL   34
#define PIN_RELAY  26   // relay low trigger
#define PIN_FLOAT  27   // float switch ke GND
#define PIN_DHT    4
#define PIN_BUZZER 25
#define PIN_LED    2
#define PIN_BTN    13   // push button ke GND
#define DHTTYPE DHT11   // ganti DHT22 bila perlu

#define WATER_OK_LEVEL LOW          // LOW = air ada. Terbalik? ganti HIGH
#define MAX_PUMP_MS 60000UL
#define SKIP_IF_SOIL_ABOVE 85       // jadwal dilewati bila tanah sudah sebasah ini
#define AP_PASS "agribot123"

#define SVC_UUID  "a1b2c3d4-0001-4000-8000-00805f9b34fb"
#define DATA_UUID "a1b2c3d4-0002-4000-8000-00805f9b34fb"
#define CMD_UUID  "a1b2c3d4-0003-4000-8000-00805f9b34fb"

enum { NET_BLE = 0, NET_AP = 1, NET_STA = 2 };
struct Sched { uint8_t en, h, m, dur, days; };   // days: bit0=Minggu ... bit6=Sabtu

DHT dht(PIN_DHT, DHTTYPE);
Preferences prefs;
WebServer server(80);
WiFiUDP udp;
BLECharacteristic *dataChar;
bool bleConnected = false;

int netMode = NET_BLE, activeNet = NET_BLE;
String staSsid, staPass, apSsid;
long tzOff = 25200;                              // WIB, diperbarui dari HP
Sched sch[4];
int schedSend = 4;
long lastSchedKey = -1;
unsigned long restartAt = 0;

bool autoMode = true, pumpOn = false, sensorOk = true, hasRun = false;
int minSoil = 55, runSec = 5, waitSec = 60, rawDry = 3000, rawWet = 1300;
int soilPct = 0, rawSoil = 0, hum = 0;
float temp = -99;
unsigned long pumpStart = 0, pumpLimit = 0, lastRun = 0, lastSense = 0, lastBeep = 0;

void handleCmd(String s);

bool waterOk() { return digitalRead(PIN_FLOAT) == WATER_OK_LEVEL; }
bool timeOk() { return time(nullptr) > 1700000000; }

void beep(int n, int ms) {
  for (int i = 0; i < n; i++) { digitalWrite(PIN_BUZZER, HIGH); delay(ms); digitalWrite(PIN_BUZZER, LOW); delay(ms); }
}

void saveCfg() {
  prefs.putInt("min", minSoil); prefs.putInt("run", runSec); prefs.putInt("wait", waitSec);
  prefs.putInt("dry", rawDry); prefs.putInt("wet", rawWet); prefs.putBool("auto", autoMode);
}

void loadCfg() {
  prefs.begin("agribot", false);
  minSoil = prefs.getInt("min", 55); runSec = prefs.getInt("run", 5); waitSec = prefs.getInt("wait", 60);
  rawDry = prefs.getInt("dry", 3000); rawWet = prefs.getInt("wet", 1300); autoMode = prefs.getBool("auto", true);
  netMode = prefs.getInt("net", NET_BLE); staSsid = prefs.getString("ssid", ""); staPass = prefs.getString("pass", "");
  if (prefs.getBytesLength("sch") == sizeof(sch)) prefs.getBytes("sch", sch, sizeof(sch));
  else for (int i = 0; i < 4; i++) sch[i] = Sched{0, (uint8_t)(6 + i * 4), 0, 5, 127};
}

void setPump(bool on, unsigned long limitMs) {
  if (on && !waterOk()) return;
  if (on && !pumpOn) { pumpStart = millis(); pumpLimit = limitMs; }
  if (!on && pumpOn) { lastRun = millis(); hasRun = true; }
  pumpOn = on;
  digitalWrite(PIN_RELAY, on ? LOW : HIGH);
  digitalWrite(PIN_LED, on ? HIGH : LOW);
}

String schedLine(int i) {
  char b[32];
  snprintf(b, sizeof(b), "S:%d,%d,%d,%d,%d,%d", i, sch[i].en, sch[i].h, sch[i].m, sch[i].dur, sch[i].days);
  return String(b);
}

String statusLine() {
  char b[96];
  unsigned long el = millis() - pumpStart;
  unsigned long rem = (pumpOn && pumpLimit > el) ? (pumpLimit - el) / 1000 : 0;
  snprintf(b, sizeof(b), "%d,%d,%.1f,%d,%d,%d,%c,%d,%d,%d,%c,%d,%lu",
           soilPct, rawSoil, temp, hum, waterOk() ? 1 : 0, pumpOn ? 1 : 0, autoMode ? 'A' : 'M',
           minSoil, runSec, waitSec, "BAS"[activeNet], timeOk() ? 1 : 0, rem);
  return String(b);
}

// ---------- BLE ----------
class SrvCb : public BLEServerCallbacks {
  void onConnect(BLEServer*) override { bleConnected = true; }
  void onDisconnect(BLEServer*) override { bleConnected = false; BLEDevice::startAdvertising(); }
};
class CmdCb : public BLECharacteristicCallbacks {
  void onWrite(BLECharacteristic *c) override { handleCmd(String(c->getValue().c_str())); }
};

void startBle() {
  BLEDevice::init("AgriBot");
  BLEDevice::setMTU(517);
  BLEServer *srv = BLEDevice::createServer();
  srv->setCallbacks(new SrvCb());
  BLEService *svc = srv->createService(SVC_UUID);
  dataChar = svc->createCharacteristic(DATA_UUID, BLECharacteristic::PROPERTY_READ | BLECharacteristic::PROPERTY_NOTIFY);
  dataChar->addDescriptor(new BLE2902());
  BLECharacteristic *cmd = svc->createCharacteristic(CMD_UUID, BLECharacteristic::PROPERTY_WRITE);
  cmd->setCallbacks(new CmdCb());
  svc->start();
  BLEAdvertising *adv = BLEDevice::getAdvertising();
  adv->addServiceUUID(SVC_UUID);
  adv->setScanResponse(true);
  BLEDevice::startAdvertising();
  activeNet = NET_BLE;
}

// ---------- WiFi (AP / STA) ----------
void startWeb() {
  server.on("/api/status", []() { server.send(200, "text/plain", statusLine()); });
  server.on("/api/sched", []() {
    String s;
    for (int i = 0; i < 4; i++) { s += schedLine(i); s += ';'; }
    server.send(200, "text/plain", s);
  });
  server.on("/api/cmd", []() { handleCmd(server.arg("c")); server.send(200, "text/plain", "OK"); });
  server.begin();
  udp.begin(4210);
}

void startAp() {
  WiFi.mode(WIFI_AP);
  WiFi.softAP(apSsid.c_str(), AP_PASS);
  activeNet = NET_AP;
  startWeb();
}

void startSta() {
  if (staSsid.length() == 0) { beep(3, 100); startAp(); return; }
  WiFi.mode(WIFI_STA);
  WiFi.begin(staSsid.c_str(), staPass.c_str());
  unsigned long t = millis();
  while (WiFi.status() != WL_CONNECTED && millis() - t < 15000) { delay(250); digitalWrite(PIN_LED, !digitalRead(PIN_LED)); }
  digitalWrite(PIN_LED, LOW);
  if (WiFi.status() == WL_CONNECTED) {
    activeNet = NET_STA;
    configTime(0, 0, "pool.ntp.org", "time.google.com");
    startWeb();
  } else {
    beep(3, 100);       // gagal -> cadangan: buat hotspot sendiri
    WiFi.disconnect(true);
    startAp();
  }
}

void udpLoop() {      // aplikasi mencari alat lewat broadcast "AGRIBOT?"
  int n = udp.parsePacket();
  if (n <= 0) return;
  char b[16] = {0};
  udp.read(b, n < 15 ? n : 15);
  if (strncmp(b, "AGRIBOT?", 8) != 0) return;
  IPAddress ip = (activeNet == NET_AP) ? WiFi.softAPIP() : WiFi.localIP();
  udp.beginPacket(udp.remoteIP(), udp.remotePort());
  udp.print("AGRIBOT," + ip.toString());
  udp.endPacket();
}

// ---------- Perintah ----------
// M:A/M:M mode | P:1/P:0 pompa | T:min,siram,jeda | K:D/K:W kalibrasi | S:i,en,h,m,dur,hari | G:S minta jadwal
// Z:epoch,offsetDetik sinkron jam | W:ssid<TAB>pass simpan WiFi | N:B/A/S ganti jaringan lalu restart
void handleCmd(String s) {
  s.trim();
  if (s == "M:A") autoMode = true;
  else if (s == "M:M") { autoMode = false; setPump(false, 0); }
  else if (s == "P:1") setPump(true, 30000UL);
  else if (s == "P:0") setPump(false, 0);
  else if (s == "K:D") rawDry = rawSoil;
  else if (s == "K:W") rawWet = rawSoil;
  else if (s.startsWith("T:")) {
    int a, b, c;
    if (sscanf(s.c_str() + 2, "%d,%d,%d", &a, &b, &c) == 3) {
      minSoil = constrain(a, 5, 95); runSec = constrain(b, 1, 30); waitSec = constrain(c, 10, 600);
    }
  } else if (s.startsWith("S:")) {
    int i, e, h, m, d, k;
    if (sscanf(s.c_str() + 2, "%d,%d,%d,%d,%d,%d", &i, &e, &h, &m, &d, &k) == 6 && i >= 0 && i < 4) {
      sch[i] = Sched{(uint8_t)(e ? 1 : 0), (uint8_t)constrain(h, 0, 23), (uint8_t)constrain(m, 0, 59),
                     (uint8_t)constrain(d, 1, 60), (uint8_t)(k & 127)};
      prefs.putBytes("sch", sch, sizeof(sch));
    }
    return;
  } else if (s == "G:S") { schedSend = 0; return; }
  else if (s.startsWith("Z:")) {
    long long e; long o;
    if (sscanf(s.c_str() + 2, "%lld,%ld", &e, &o) == 2) {
      struct timeval tv; tv.tv_sec = (time_t)e; tv.tv_usec = 0;
      settimeofday(&tv, NULL); tzOff = o;
    }
    return;
  } else if (s.startsWith("W:")) {
    String b = s.substring(2);
    int i = b.indexOf('\t');
    staSsid = (i < 0) ? b : b.substring(0, i);
    staPass = (i < 0) ? "" : b.substring(i + 1);
    prefs.putString("ssid", staSsid); prefs.putString("pass", staPass);
    return;
  } else if (s.startsWith("N:")) {
    char m = s.charAt(2);
    int v = (m == 'B') ? NET_BLE : (m == 'A') ? NET_AP : (m == 'S') ? NET_STA : -1;
    if (v >= 0) { prefs.putInt("net", v); restartAt = millis() + 800; }
    return;
  } else return;
  saveCfg();
}

// ---------- Sensor & kontrol ----------
void readSensors() {
  long sum = 0;
  for (int i = 0; i < 16; i++) { sum += analogRead(PIN_SOIL); delay(2); }
  rawSoil = sum / 16;
  sensorOk = rawSoil > 200 && rawSoil < 4000;
  soilPct = (rawDry == rawWet) ? 0 : constrain(map(rawSoil, rawDry, rawWet, 0, 100), 0, 100);
  float t = dht.readTemperature(), h = dht.readHumidity();
  if (!isnan(t)) temp = t;
  if (!isnan(h)) hum = (int)h;
}

void control() {
  unsigned long now = millis();
  if (pumpOn) {
    if (!waterOk() || now - pumpStart >= pumpLimit || now - pumpStart >= MAX_PUMP_MS) setPump(false, 0);
  } else if (autoMode && sensorOk && waterOk() && soilPct < minSoil &&
             (!hasRun || now - lastRun >= (unsigned long)waitSec * 1000UL)) {
    setPump(true, (unsigned long)runSec * 1000UL);
  }
}

void checkSched() {
  if (!timeOk()) return;
  time_t t = time(nullptr) + tzOff;
  struct tm tm; gmtime_r(&t, &tm);
  long key = (long)tm.tm_yday * 1440 + tm.tm_hour * 60 + tm.tm_min;
  if (key == lastSchedKey) return;                 // sekali per menit
  lastSchedKey = key;
  if (!autoMode || !sensorOk || soilPct >= SKIP_IF_SOIL_ABOVE) return;
  for (int i = 0; i < 4; i++) {
    if (sch[i].en && sch[i].h == tm.tm_hour && sch[i].m == tm.tm_min && ((sch[i].days >> tm.tm_wday) & 1)) {
      setPump(true, (unsigned long)sch[i].dur * 1000UL);
      break;
    }
  }
}

void alarms() {
  if (!waterOk()) {
    if (!pumpOn) digitalWrite(PIN_LED, (millis() / 500) % 2);
    if (millis() - lastBeep > 10000) { lastBeep = millis(); beep(2, 150); }
  } else if (!pumpOn) digitalWrite(PIN_LED, LOW);
}

// Singkat = ganti Auto/Manual | tahan 1-3 dtk = pompa | tahan >3 dtk = ganti jaringan (BLE>AP>STA)
void button() {
  static bool last = HIGH; static unsigned long t0 = 0;
  bool now = digitalRead(PIN_BTN);
  if (last == HIGH && now == LOW) t0 = millis();
  if (last == LOW && now == HIGH) {
    unsigned long d = millis() - t0;
    if (d > 50 && d < 800) { autoMode = !autoMode; if (!autoMode) setPump(false, 0); saveCfg(); beep(1, 60); }
    else if (d >= 800 && d < 3000) { setPump(!pumpOn, 30000UL); beep(1, 200); }
    else if (d >= 3000) { prefs.putInt("net", (netMode + 1) % 3); beep(3, 80); restartAt = millis() + 300; }
  }
  last = now;
}

void setup() {
  pinMode(PIN_RELAY, OUTPUT); digitalWrite(PIN_RELAY, HIGH);   // pompa OFF
  pinMode(PIN_BUZZER, OUTPUT); pinMode(PIN_LED, OUTPUT);
  pinMode(PIN_FLOAT, INPUT_PULLUP); pinMode(PIN_BTN, INPUT_PULLUP);
  analogReadResolution(12);
  analogSetPinAttenuation(PIN_SOIL, ADC_11db);
  dht.begin();
  loadCfg();
  char nm[24];
  snprintf(nm, sizeof(nm), "AgriBot-%04X", (uint16_t)(ESP.getEfuseMac() >> 32));
  apSsid = String(nm);

  if (netMode == NET_AP) startAp();
  else if (netMode == NET_STA) startSta();
  else startBle();

  readSensors();
  beep(activeNet + 1, 80);          // 1 bip=BLE, 2=AP, 3=STA
}

void loop() {
  button(); control(); alarms(); checkSched();
  if (millis() - lastSense >= 2000) {
    lastSense = millis();
    readSensors();
    if (activeNet == NET_BLE && bleConnected) {
      String l = statusLine();
      dataChar->setValue((uint8_t*)l.c_str(), l.length());
      dataChar->notify();
    }
  }
  if (activeNet == NET_BLE) {
    if (bleConnected && schedSend < 4) {            // kirim jadwal satu per satu lewat notify
      String l = schedLine(schedSend++);
      dataChar->setValue((uint8_t*)l.c_str(), l.length());
      dataChar->notify();
    }
  } else { server.handleClient(); udpLoop(); }
  if (restartAt && millis() > restartAt) ESP.restart();
  delay(20);
}
