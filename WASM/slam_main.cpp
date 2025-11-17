#include <iostream>
#include <mutex>
#include <thread>

int main(){
    std::mutex m;
    int shared_data = 0;

    auto logSensor = [&m, &shared_data](){
        while(true){
            std::lock_guard<std::mutex> lk(m);
            std::cout << "Logging " << shared_data << std::endl;
        }
    };

    auto incrementData = [&m, &shared_data](){
        while(true){
            std::lock_guard<std::mutex> lk(m);
            ++shared_data;
        }
    };

    std::thread t1(logSensor);
    std::thread t2(incrementData);

    t1.join();
    t2.join();
}