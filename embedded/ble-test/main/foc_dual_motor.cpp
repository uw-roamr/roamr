#include <Arduino.h>
#include <SPI.h>
// #include "driver/gpio.h"
// #include "driver/spi_master.h"


#include <SimpleFOC.h>
#include <SimpleFOCDrivers.h>
#include "encoders/as5048a/MagneticSensorAS5048A.h"

constexpr int PIN_MOSI = 4;
constexpr int PIN_SCLK = 5;
constexpr int PIN_MISO = 6;
constexpr int PIN_CS1 = 7;
constexpr int PIN_CS2 = 16;

constexpr int PIN_DRIVER1_1 = 0;
constexpr int PIN_DRIVER1_2 = 1;
constexpr int PIN_DRIVER1_3 = 8;
constexpr int PIN_DRIVER1_EN = 10;

constexpr int PIN_DRIVER2_1 = 17;
constexpr int PIN_DRIVER2_2 = 15;
constexpr int PIN_DRIVER2_3 = 23;
constexpr int PIN_DRIVER2_EN = 22;

MagneticSensorAS5048A sensor1(PIN_CS1);
MagneticSensorAS5048A sensor2(PIN_CS2);


BLDCDriver3PWM driver1(PIN_DRIVER1_1, PIN_DRIVER1_2, PIN_DRIVER1_3, PIN_DRIVER1_EN);
BLDCDriver3PWM driver2(PIN_DRIVER2_1, PIN_DRIVER2_2, PIN_DRIVER2_3, PIN_DRIVER2_EN);
BLDCMotor motor1(7);
BLDCMotor motor2(7);
Commander command = Commander(Serial);
void doMotor(char* cmd) {command.motor(&motor1, cmd);}

void setup() {
  Serial.begin(115200);
  SPI.begin(PIN_SCLK, PIN_MISO, PIN_MOSI);

  sensor1.init();
  sensor2.init();
  motor1.linkSensor(&sensor1);
  motor2.linkSensor(&sensor2);

  driver1.voltage_power_supply = 12;
  driver2.voltage_power_supply = 12;
  driver1.voltage_limit = 12;
  driver2.voltage_limit = 12;
  if (!driver1.init()){
    Serial.println("Driver 1 failed");
    return;
  }
  if (!driver2.init()){
    Serial.println("Driver 2 failed");
    return;
  }
  motor1.linkDriver(&driver1);
  motor2.linkDriver(&driver2);

  motor1.torque_controller = TorqueControlType::voltage;
  motor2.torque_controller = TorqueControlType::voltage;
  motor1.controller = MotionControlType::torque;
  motor2.controller = MotionControlType::torque;

  motor1.voltage_sensor_align = 12.0f;
  motor2.voltage_sensor_align = 12.0f;
  if (!motor1.init()){
    Serial.println("Motor 1 failed");
    return;
  }
  if (!motor2.init()){
    Serial.println("Motor 2 failed");
    return;
  }

  if(!motor1.initFOC()){
    Serial.println("FOC 1 failed");
    return;
  }
  if(!motor2.initFOC()){
    Serial.println("FOC 1 failed");
    return;
  }

  motor1.target = 0.0; // Nm
  motor2.target = 0.0; // Nm

  command.add('M', doMotor, "Motor");
  Serial.println(F("Motor ready."));
  Serial.println(F("Set the target with command M:"));

}

void loop() {
  motor1.loopFOC();
  motor2.loopFOC();
  motor1.move();
  motor2.move();
  command.run();
}
