#pragma GCC diagnostic push
#pragma GCC diagnostic ignored "-Wmissing-field-initializers"

#include "esp_log.h"
#include <stdarg.h>
#include <stdio.h>

// extern "C" void __wrap_esp_log_write(esp_log_level_t level, const char *tag,
//                                      const char *format, ...) {
//   va_list args;
//   va_start(args, format);
//   vprintf(format, args);
//   va_end(args);
// }

#include "encoders/as5048a/MagneticSensorAS5048A.h"
#include <Arduino.h>
#include <SPI.h>
#include <SimpleFOC.h>
#include <SimpleFOCDrivers.h>
#include "drivers/drv8316/drv8316.h"
#include "driver/gpio.h"
#include "freertos/task.h"

constexpr int PIN_MOSI = 11;
constexpr int PIN_SCLK = 12;
constexpr int PIN_MISO = 13;
constexpr int PIN_CS1 = 17;
constexpr int PIN_CS2 = 18;

constexpr int PIN_DRIVER1_1 = 41;
constexpr int PIN_DRIVER1_2 = 42;
constexpr int PIN_DRIVER1_3 = 45;
constexpr int PIN_DRIVER1_CS = 47;

constexpr int PIN_DRIVER2_1 = 38;
constexpr int PIN_DRIVER2_2 = 39;
constexpr int PIN_DRIVER2_3 = 40;
constexpr int PIN_DRIVER2_CS = 48;

SPISettings mySPISettings(1000000, MSBFIRST, SPI_MODE1);
MagneticSensorAS5048A sensor1(PIN_CS1, false, mySPISettings);
MagneticSensorAS5048A sensor2(PIN_CS2, false, mySPISettings);

DRV8316Driver3PWM driver1(PIN_DRIVER1_1, PIN_DRIVER1_2, PIN_DRIVER1_3, PIN_DRIVER1_CS);
DRV8316Driver3PWM driver2(PIN_DRIVER2_1, PIN_DRIVER2_2, PIN_DRIVER2_3, PIN_DRIVER2_CS);
BLDCMotor motor1(7);
BLDCMotor motor2(7);
Commander command = Commander(Serial);

void doMotor1(char *cmd) { command.motor(&motor1, cmd); }
void doMotor2(char *cmd) { command.motor(&motor2, cmd); }

bool init_success = false;
bool motor1_ready = false;
bool motor2_ready = false;

void setup() {
  Serial.begin(115200);

  pinMode(PIN_CS1, OUTPUT);
  digitalWrite(PIN_CS1, HIGH);
  pinMode(PIN_CS2, OUTPUT);
  digitalWrite(PIN_CS2, HIGH);

  SPI.begin(PIN_SCLK, PIN_MISO, PIN_MOSI);
  gpio_pullup_en((gpio_num_t)PIN_MISO);

  Serial.println("Hi from the start");
  // sensor1.init();
  // sensor2.init();
  // motor1.linkSensor(&sensor1);
  // motor2.linkSensor(&sensor2);

  // driver1.voltage_power_supply = 12;
  driver2.voltage_power_supply = 12;
  // driver1.voltage_limit = 12;
  driver2.voltage_limit = 12;
  // driver.init() calls spi->begin() internally with no pin args, which resets
  // to default ESP32 SPI pins. Restore our custom pins immediately after.
  // driver1.init(&SPI);
  driver2.init(&SPI);
  SPI.begin(PIN_SCLK, PIN_MISO, PIN_MOSI);
  gpio_pullup_en((gpio_num_t)PIN_MISO);

  // Disable buck before reading status or initializing motors.
  // Buck pins are floating, which causes BK_FLT at power-on. The DRV8316
  // holds gate drive disabled while any fault is latched, so this must happen
  // before motor.init() / initFOC() or the motor won't spin.
  // driver1.setSDOMode(DRV8316_SDOMode::SDOMode_PushPull);
  driver2.setSDOMode(DRV8316_SDOMode::SDOMode_PushPull);
  // driver1.setBuckPowerSequencingEnabled(false);
  driver2.setBuckPowerSequencingEnabled(false);
  delayMicroseconds(1);
  // driver1.setBuckEnabled(false);
  driver2.setBuckEnabled(false);
  delayMicroseconds(100);
  // for (int i = 0; i < 5 && (driver1.isBuckEnabled() || driver2.isBuckEnabled()); i++) {
  //   // Serial.printf("Buck still enabled, retry %d: drv1=%d drv2=%d\n",
  //   //               i + 1, driver1.isBuckEnabled(), driver2.isBuckEnabled());
  //   delayMicroseconds(500);
  //   // driver1.setBuckEnabled(false);
  //   driver2.setBuckEnabled(false);
  //   delayMicroseconds(100);
  // }
  // Serial.printf("Buck readback: drv1_en=%d drv2_en=%d drv1_ps=%d drv2_ps=%d (expect 0,0,0,0)\n",
  //   driver1.isBuckEnabled(), driver2.isBuckEnabled(),
  //   driver1.isBuckPowerSequencingEnabled(), driver2.isBuckPowerSequencingEnabled());
  // driver1.setOCPMode(DRV8316_OCPMode::ReportOnly);
  driver2.setOCPMode(DRV8316_OCPMode::ReportOnly);
  // driver1.clearFault();
  driver2.clearFault();
  delayMicroseconds(100);

  // DRV8316Status s1 = driver1.getStatus();
  DRV8316Status s2 = driver2.getStatus();
  // Serial.printf("DRV1: fault=%d ot=%d ocp=%d ovp=%d spi=%d bk=%d npor=%d vcp_uv=%d locked=%d pwm_mode=%d\n",
  //   s1.isFault(), s1.isOverTemperature(), s1.isOverCurrent(), s1.isOverVoltage(),
  //   s1.isSPIError(), s1.isBuckError(), s1.isPowerOnReset(), s1.isChargePumpUnderVoltage(),
  //   (int)driver1.isRegistersLocked(), (int)driver1.getPWMMode());
  // Serial.printf("DRV1 Status2: buck_uv=%d buck_ocp=%d\n", s1.isBuckUnderVoltage(), s1.isBuckOverCurrent());
  Serial.printf("DRV2: fault=%d ot=%d ocp=%d ovp=%d spi=%d bk=%d npor=%d vcp_uv=%d locked=%d pwm_mode=%d\n",
    s2.isFault(), s2.isOverTemperature(), s2.isOverCurrent(), s2.isOverVoltage(),
    s2.isSPIError(), s2.isBuckError(), s2.isPowerOnReset(), s2.isChargePumpUnderVoltage(),
    (int)driver2.isRegistersLocked(), (int)driver2.getPWMMode());
  Serial.printf("DRV2 Status2: buck_uv=%d buck_ocp=%d\n", s2.isBuckUnderVoltage(), s2.isBuckOverCurrent());

  Serial.println("ahhhh");
  // driver1.setPWMMode(DRV8316_PWMMode::PWM3_Mode);
  // driver2.setPWMMode(DRV8316_PWMMode::PWM3_Mode);
  // sensor1.update(); sensor2.update();
  // Serial.printf("Sensor1 angle: %.4f, Sensor2 angle: %.4f\n",
  //   sensor1.getAngle(), sensor2.getAngle());

  // motor1.linkDriver(&driver1);
  // motor2.linkDriver(&driver2);

  // motor1.torque_controller = TorqueControlType::voltage;
  // motor2.torque_controller = TorqueControlType::voltage;
  // motor1.controller = MotionControlType::torque;
  // motor2.controller = MotionControlType::torque;

  // motor1.voltage_sensor_align = 12.0f;
  // motor2.voltage_sensor_align = 12.0f;
  // motor1.useMonitoring(Serial);
  // motor2.useMonitoring(Serial);

  // bool m1_ready = motor1.init();
  // bool m2_ready = motor2.init();

  // if (!m1_ready)
  //   Serial.println("Motor 1 init failed");
  // if (!m2_ready)
  //   Serial.println("Motor 2 init failed");

  // _delay(500);

  // if (!motor1.initFOC()) {
  //   Serial.println("FOC 1 failed");
  //   m1_ready = false;
  // }
  // _delay(500);

  // if (!motor2.initFOC()) {
  //   Serial.println("FOC 2 failed");
  //   m2_ready = false;
  // }
  // motor1.enable();
  // motor2.enable();
  // motor1.target = 0.0;
  // motor2.target = 0.0;

  // command.add('A', doMotor1, "Motor1");
  // command.add('B', doMotor2, "Motor2");
  // Serial.println("Motor ready.");
  // delayMicroseconds(1000);
  driver2.clearFault();
  init_success = true;
  // motor1_ready = m1_ready;
  // motor2_ready = m2_ready;
}

void loop() {
  if (!init_success){
    Serial.printf("Did not init successfully");
    return;
  }
  // if (motor1_ready) {
  // motor1.loopFOC();
  // motor1.move();
  // // }
  // // if (motor2_ready) {
  // motor2.loopFOC();
  // motor2.move();
  // // }
  // command.run();

  static uint32_t last_print = 0;
  if (millis() - last_print > 1000) {
    last_print = millis();
    // Serial.printf("M1: Target=%.2f V, Vel=%.2f | M2: Target=%.2f V, Vel=%.2f | Status: %d/%d\n",
    //               motor1.target, motor1.shaft_velocity, motor2.target,
    //               motor2.shaft_velocity, motor1_ready, motor2_ready);

    // sensor1.update(); sensor2.update();
    // Serial.printf("Sensor1 angle: %.4f, Sensor2 angle: %.4f\n", sensor1.getAngle(), sensor2.getAngle());

    // driver1.clearFault();
    // driver2.clearFault();
    delayMicroseconds(100);
    // DRV8316Status s1 = driver1.getStatus();
    DRV8316Status s2 = driver2.getStatus();
    // Serial.printf("DRV1: fault=%d ot=%d ocp=%d ovp=%d spi=%d bk=%d npor=%d vcp_uv=%d locked=%d pwm_mode=%d\n",
    //   s1.isFault(), s1.isOverTemperature(), s1.isOverCurrent(), s1.isOverVoltage(),
    //   s1.isSPIError(), s1.isBuckError(), s1.isPowerOnReset(), s1.isChargePumpUnderVoltage(),
    //   (int)driver1.isRegistersLocked(), (int)driver1.getPWMMode());
    // Serial.printf("DRV1 Status2: buck_uv=%d buck_ocp=%d\n",
    //   s1.isBuckUnderVoltage(), s1.isBuckOverCurrent());
    Serial.printf("DRV2: fault=%d ot=%d ocp=%d ovp=%d spi=%d bk=%d npor=%d vcp_uv=%d locked=%d pwm_mode=%d\n\n",
      s2.isFault(), s2.isOverTemperature(), s2.isOverCurrent(), s2.isOverVoltage(),
      s2.isSPIError(), s2.isBuckError(), s2.isPowerOnReset(), s2.isChargePumpUnderVoltage(),
      (int)driver2.isRegistersLocked(), (int)driver2.getPWMMode());
    Serial.printf("DRV2 Status2: buck_uv=%d buck_ocp=%d\n\n",
      s2.isBuckUnderVoltage(), s2.isBuckOverCurrent());

  }
}

extern "C" void app_main() {
  initArduino();
  setup();
  while (true) {
    loop();
    vTaskDelay(1);
  }
}
