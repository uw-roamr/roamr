idf_component_register(SRCS "foc_dual_motor.cpp"
                    INCLUDE_DIRS "."
                    REQUIRES nvs_flash bt simplefoc espressif__arduino-esp32 simplefoc_drivers)

target_compile_options(${COMPONENT_LIB} PRIVATE
                       -Wno-error=missing-field-initializers
                       -Wno-error=overloaded-virtual
                       -Wno-error=comment)

# simplefoc currently has a non-exhaustive enum switch in Commander.cpp.
# Keep it as a warning, but don't fail the build.
idf_component_get_property(simplefoc_component_lib simplefoc COMPONENT_LIB)
target_compile_options(${simplefoc_component_lib} PRIVATE
                       -Wno-error=switch
                       -Wno-error=comment
                       -Wno-error=overloaded-virtual)

# simplefoc_drivers includes simplefoc headers; apply the same warning policy.
idf_component_get_property(simplefoc_drivers_component_lib simplefoc_drivers COMPONENT_LIB)
target_compile_options(${simplefoc_drivers_component_lib} PRIVATE
                       -Wno-error=switch
                       -Wno-error=comment
                       -Wno-error=overloaded-virtual)
