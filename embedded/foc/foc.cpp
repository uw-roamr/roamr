#include <Arduino.h>
#include <SPI.h>
// #include "driver/gpio.h"
// #include "driver/spi_master.h"


#include <SimpleFOC.h>
#include <SimpleFOCDrivers.h>
#include "encoders/as5048a/MagneticSensorAS5048A.h"

#define PIN_MOSI  1
#define PIN_SCLK  2
#define PIN_MISO  3
#define PIN_CS    4

constexpr int PIN_DRIVER_1 = 5;
constexpr int PIN_DRIVER_2 = 20;
constexpr int PIN_DRIVER_3 = 32;
constexpr int PIN_EN = 33;


// spi_device_handle_t spi;

// void spi_init_as5048a()
// {
//   spi_bus_config_t buscfg = {};    // zero-init all fields
//   buscfg.miso_io_num     = PIN_MISO;
//   buscfg.mosi_io_num     = PIN_MOSI;
//   buscfg.sclk_io_num     = PIN_CLK;
//   buscfg.quadwp_io_num   = -1;
//   buscfg.quadhd_io_num   = -1;
//   buscfg.max_transfer_sz = 32;

//   spi_device_interface_config_t devcfg = {};  // zero-init all fields
//   devcfg.clock_speed_hz = 2 * 1000 * 1000;  // 2 MHz
//   devcfg.mode           = 1;                // SPI mode 1
//   devcfg.spics_io_num   = PIN_CS;
//   devcfg.queue_size     = 1;

//   spi_bus_initialize(SPI2_HOST, &buscfg, SPI_DMA_CH_AUTO);
//   spi_bus_add_device(SPI2_HOST, &devcfg, &spi);
// }

MagneticSensorAS5048A sensor1(PIN_CS);
BLDCDriver3PWM driver1(PIN_DRIVER_1, PIN_DRIVER_2, PIN_DRIVER_3, PIN_EN);
BLDCMotor motor1(7);
Commander command = Commander(Serial);
void doMotor(char* cmd) {command.motor(&motor1, cmd);}

void setup() {
  Serial.begin(115200);
  SPI.begin(PIN_SCLK, PIN_MISO, PIN_MOSI);

  sensor1.init();
  motor1.linkSensor(&sensor1);
  
  driver1.voltage_power_supply = 12;
  driver1.voltage_limit = 12;
  if (!driver1.init()){
    Serial.println("Driver failed");
    return;
  }
  motor1.linkDriver(&driver1);

  motor1.torque_controller = TorqueControlType::voltage;
  motor1.controller = MotionControlType::torque;

  motor1.voltage_sensor_align = 12.0f;
  if (!motor1.init()){
    Serial.println("Motor failed");
    return;
  }

  if(!motor1.initFOC()){
    Serial.println("FOC failed");
    return;
  }

  motor1.target = 0.5; // Nm  

  command.add('M', doMotor, "Motor");
  Serial.println(F("Motor ready."));
  Serial.println(F("Set the target with command M:"));

}

void loop() {
  motor1.loopFOC();
  motor1.move();
  command.run();
}