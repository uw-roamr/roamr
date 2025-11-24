idf_component_register(SRCS "foc_dual_motor.cpp"
                    INCLUDE_DIRS "."
                    REQUIRES nvs_flash bt simplefoc espressif__arduino-esp32 simplefoc_drivers)

target_compile_options(${COMPONENT_LIB} PRIVATE -Wno-error=missing-field-initializers -Wno-error=overloaded-virtual)
