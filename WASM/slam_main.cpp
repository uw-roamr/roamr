#include <iostream>
#include <iomanip>
#include <mutex>
#include <thread>
#include <chrono>

#define WASM_IMPORT(A, B) __attribute__((__import_module__((A)), __import_name__((B))))
struct IMUData {
    double acc_timestamp;
    double acc_x, acc_y, acc_z;
    double gyro_timestamp;
    double gyro_x, gyro_y, gyro_z;
    // double mag_x, mag_y, mag_z; // unused, currently targeting indoor environments and simple fusion
};

WASM_IMPORT("host", "read_imu") void read_imu(IMUData* data);

constexpr int IMUIntervalMs = 10;
constexpr int logIntervalMs = 100;

int main(){
    //shared data
    std::mutex m;
    IMUData data;

//    auto refreshSensor = [&m, &data](){
//        while(true){
//
//        }
//    }

    auto logSensor = [&m, &data](){
        
        std::cout << std::fixed << std::setprecision(5);
        while(true){
            std::this_thread::sleep_for(std::chrono::milliseconds(IMUIntervalMs)); 
            std::lock_guard<std::mutex> lk(m);
 
            read_imu(&data);
            std::cout << "T:" << data.acc_timestamp << " acc:" << data.acc_x << "," << data.acc_y << "," << data.acc_z << std::endl
                      << "T:" << data.gyro_timestamp << " gyro:" << data.gyro_x << "," << data.gyro_y << "," << data.gyro_z <<
                      std::endl;
        }
    };

    auto incrementData = [&m, &data](){
        while(true){
            std::lock_guard<std::mutex> lk(m);
            // ++shared_data;
        }
    };

    std::thread t1(logSensor);
    std::thread t2(incrementData);

    t1.join();
    t2.join();
}
