cmake_minimum_required(VERSION 3.20)

set(TINYUSB_PATH "$ENV{TINYUSB_PATH}" CACHE PATH "Path to a TinyUSB checkout")
if (NOT TINYUSB_PATH)
  set(TINYUSB_PATH "${CMAKE_CURRENT_LIST_DIR}/../deps/tinyusb")
endif()

if (NOT EXISTS "${TINYUSB_PATH}/hw/bsp/family_support.cmake")
  message(FATAL_ERROR "TinyUSB not found. Set TINYUSB_PATH or run firmware/bootstrap.sh")
endif()

include(${TINYUSB_PATH}/hw/bsp/family_support.cmake)

set(LWIP ${TOP}/lib/lwip)
if (NOT EXISTS ${LWIP}/src)
  set(LWIP ${TINYUSB_LWIP_PATH})
endif()

if (NOT EXISTS ${LWIP}/src)
  family_example_missing_dependency(${PROJECT_NAME} "lib/lwip")
  return()
endif()

project(chica_servo2040_usbnet C CXX ASM)
set(CMAKE_C_STANDARD 11)
set(CMAKE_CXX_STANDARD 17)

family_initialize_project(${PROJECT_NAME} ${CMAKE_CURRENT_LIST_DIR})

set(ORIGINAL_FW_DIR "${CMAKE_CURRENT_LIST_DIR}")

include(${ORIGINAL_FW_DIR}/drivers/pwm/pwm.cmake)
include(${ORIGINAL_FW_DIR}/drivers/pwm/pwm_cluster.cmake)
include(${ORIGINAL_FW_DIR}/drivers/servo/servo.cmake)
include(${ORIGINAL_FW_DIR}/drivers/servo/servo_cluster.cmake)
include(${ORIGINAL_FW_DIR}/drivers/plasma/plasma.cmake)
include(${ORIGINAL_FW_DIR}/drivers/analog/analog.cmake)
include(${ORIGINAL_FW_DIR}/drivers/analogmux/analogmux.cmake)
include(${ORIGINAL_FW_DIR}/drivers/button/button.cmake)
include(${ORIGINAL_FW_DIR}/libraries/servo2040/servo2040.cmake)

add_executable(${PROJECT_NAME})

target_sources(${PROJECT_NAME} PUBLIC
  ${CMAKE_CURRENT_LIST_DIR}/src/main.cpp
  ${CMAKE_CURRENT_LIST_DIR}/src/usb_descriptors.c
)

target_include_directories(${PROJECT_NAME} PUBLIC
  ${CMAKE_CURRENT_LIST_DIR}/src
  ${ORIGINAL_FW_DIR}
  ${LWIP}/src/include
  ${LWIP}/src/include/ipv4
  ${LWIP}/src/include/lwip/apps
  ${TOP}/lib/networking
)

target_sources(${PROJECT_NAME} PUBLIC
  ${TOP}/lib/networking/dhserver.c
  ${TOP}/lib/networking/dnserver.c
  ${TOP}/lib/networking/rndis_reports.c
)

target_sources(${PROJECT_NAME} PUBLIC
  ${LWIP}/src/core/altcp.c
  ${LWIP}/src/core/altcp_alloc.c
  ${LWIP}/src/core/altcp_tcp.c
  ${LWIP}/src/core/def.c
  ${LWIP}/src/core/dns.c
  ${LWIP}/src/core/inet_chksum.c
  ${LWIP}/src/core/init.c
  ${LWIP}/src/core/ip.c
  ${LWIP}/src/core/mem.c
  ${LWIP}/src/core/memp.c
  ${LWIP}/src/core/netif.c
  ${LWIP}/src/core/pbuf.c
  ${LWIP}/src/core/raw.c
  ${LWIP}/src/core/stats.c
  ${LWIP}/src/core/sys.c
  ${LWIP}/src/core/tcp.c
  ${LWIP}/src/core/tcp_in.c
  ${LWIP}/src/core/tcp_out.c
  ${LWIP}/src/core/timeouts.c
  ${LWIP}/src/core/udp.c
  ${LWIP}/src/core/ipv4/autoip.c
  ${LWIP}/src/core/ipv4/dhcp.c
  ${LWIP}/src/core/ipv4/etharp.c
  ${LWIP}/src/core/ipv4/icmp.c
  ${LWIP}/src/core/ipv4/igmp.c
  ${LWIP}/src/core/ipv4/ip4.c
  ${LWIP}/src/core/ipv4/ip4_addr.c
  ${LWIP}/src/core/ipv4/ip4_frag.c
  ${LWIP}/src/netif/ethernet.c
  ${LWIP}/src/netif/slipif.c
)

target_link_libraries(${PROJECT_NAME} PUBLIC
  pico_stdlib
  servo2040
  analogmux
  analog
  button
)

if (CMAKE_C_COMPILER_ID STREQUAL "GNU")
  target_compile_options(${PROJECT_NAME} PUBLIC
    -Wno-error=null-dereference
    -Wno-error=conversion
    -Wno-error=sign-conversion
    -Wno-error=sign-compare
  )
endif()

family_configure_device_example(${PROJECT_NAME} noos)
