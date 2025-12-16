/* Left ESP - updated for robust reconnect + dual motors
   - Keep pins, endpoints same as your working test code
   - Changed gateway to 10.77.49.233, added reconnect logic
*/

#include <WiFi.h>
#include <WebServer.h>

// ---------- CONFIG ----------
const char* ssid = "Redmi Note 9 Pro Max";
const char* password = "redmi@jai";

IPAddress LOCAL_IP(10, 77, 49, 146);   // Left ESP
IPAddress GATEWAY(10, 77, 49, 233);    // <-- set to actual hotspot gateway
IPAddress SUBNET(255, 255, 255, 0);

// LED pins
const int BLUE_PIN = 2;
const int RED_PIN  = 4;

// Motor pins
const int MOTOR1 = 5;
const int MOTOR2 = 18;

// blink timing
const unsigned long BLINK_INTERVAL_MS = 400;

WebServer server(80);

// runtime state
enum BlinkMode { STOPPED, BLUE_CONTINUOUS, ALT_RED_BLUE };
volatile BlinkMode mode = STOPPED;

unsigned long lastToggle = 0;
bool blueState = false;
bool redState = false;

void motorsOn() {
  digitalWrite(MOTOR1, HIGH);
  digitalWrite(MOTOR2, HIGH);
}
void motorsOff() {
  digitalWrite(MOTOR1, LOW);
  digitalWrite(MOTOR2, LOW);
}

// ---------- HTTP handlers ----------
void handleBlinkOnce() {
  digitalWrite(BLUE_PIN, HIGH);
  motorsOn();
  delay(300);
  digitalWrite(BLUE_PIN, LOW);
  motorsOff();
  server.send(200, "text/plain", "blinked");
}
void handleStartBlue() {
  mode = BLUE_CONTINUOUS;
  server.send(200, "text/plain", "startBlue");
}
void handleStartAlt() {
  mode = ALT_RED_BLUE;
  server.send(200, "text/plain", "startAlt");
}
void handleStopBlink() {
  mode = STOPPED;
  digitalWrite(BLUE_PIN, LOW);
  digitalWrite(RED_PIN, LOW);
  motorsOff();
  server.send(200, "text/plain", "stopped");
}
void handleRoot() {
  server.send(200, "text/plain", "ESP Blinker OK");
}

// ---------- setup & loop ----------
unsigned long lastWifiCheck = 0;
const unsigned long WIFI_CHECK_INTERVAL = 3000; // ms

void ensureWiFi() {
  // If disconnected, try to reconnect (non-blocking style)
  if (WiFi.status() != WL_CONNECTED) {
    Serial.print("WiFi not connected. Attempting reconnect...");
    // Try to (re)configure static IP - if it fails, fallback to DHCP
    WiFi.mode(WIFI_STA);
    WiFi.setAutoReconnect(true);
    // Attempt static config; if it fails we continue (WiFi.config returns bool)
    WiFi.config(LOCAL_IP, GATEWAY, SUBNET);
    WiFi.begin(ssid, password);
    unsigned long start = millis();
    while (WiFi.status() != WL_CONNECTED && millis() - start < 8000) {
      delay(250);
      Serial.print(".");
    }
    Serial.println();
    if (WiFi.status() == WL_CONNECTED) {
      Serial.print("Connected! IP: ");
      Serial.println(WiFi.localIP());
    } else {
      Serial.println("Reconnect attempt failed - will retry.");
    }
  }
}

void setup() {
  Serial.begin(115200);

  pinMode(BLUE_PIN, OUTPUT);
  pinMode(RED_PIN, OUTPUT);
  pinMode(MOTOR1, OUTPUT);
  pinMode(MOTOR2, OUTPUT);
  digitalWrite(BLUE_PIN, LOW);
  digitalWrite(RED_PIN, LOW);
  motorsOff();

  // set WiFi to station mode
  WiFi.mode(WIFI_STA);
  WiFi.setAutoReconnect(true);

  // try static IP (if hotspot uses different gateway, change GATEWAY accordingly)
  if (!WiFi.config(LOCAL_IP, GATEWAY, SUBNET)) {
    Serial.println("WiFi.config reported failure - device will try DHCP fallback.");
  }

  Serial.print("Connecting to hotspot...");
  WiFi.begin(ssid, password);
  unsigned long start = millis();
  while (WiFi.status() != WL_CONNECTED && millis() - start < 20000) {
    delay(400);
    Serial.print(".");
  }
  Serial.println();
  if (WiFi.status() == WL_CONNECTED) {
    Serial.print("Connected, IP: ");
    Serial.println(WiFi.localIP());
  } else {
    Serial.println("Initial connect failed (will keep trying in loop).");
  }

  // HTTP routes
  server.on("/", handleRoot);
  server.on("/blinkOnce", handleBlinkOnce);
  server.on("/startBlue", handleStartBlue);
  server.on("/startAlt", handleStartAlt);
  server.on("/stopBlink", handleStopBlink);
  server.begin();
  Serial.println("HTTP server started");
}

void loop() {
  // keep webserver responsive always
  server.handleClient();

  // periodically verify wifi and attempt reconnect if needed
  if (millis() - lastWifiCheck > WIFI_CHECK_INTERVAL) {
    lastWifiCheck = millis();
    ensureWiFi();
  }

  unsigned long now = millis();
  if (mode == BLUE_CONTINUOUS) {
    if (now - lastToggle >= BLINK_INTERVAL_MS) {
      lastToggle = now;
      blueState = !blueState;
      digitalWrite(BLUE_PIN, blueState ? HIGH : LOW);
      if (blueState) motorsOn(); else motorsOff();
      digitalWrite(RED_PIN, LOW);
    }
  } else if (mode == ALT_RED_BLUE) {
    if (now - lastToggle >= BLINK_INTERVAL_MS) {
      lastToggle = now;
      blueState = !blueState;
      redState = !redState;
      digitalWrite(BLUE_PIN, blueState ? HIGH : LOW);
      digitalWrite(RED_PIN, redState ? HIGH : LOW);
      if (blueState || redState) motorsOn(); else motorsOff();
    }
  } else {
    // stopped
    motorsOff();
  }
}
