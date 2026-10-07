cmake_minimum_required(VERSION 3.20)
project(ollvm-pass)

set(LT_LLVM_INSTALL_DIR  "" CACHE PATH "/opt/homebrew/opt/llvm")


# Add the location of LLVMConfig.cmake to CMake search paths (so that
# find_package can locate it)
list(APPEND CMAKE_PREFIX_PATH "${LT_LLVM_INSTALL_DIR}/lib/cmake/llvm/")

find_package(LLVM REQUIRED CONFIG)
# 22 is the target: that is what current rustc and the packaged toolchains carry.
# 21 is accepted as well because Termux ships 21.1.8 and nothing newer -- the
# plugin builds there and passes the same gates (smoke-test.sh, 16-seed sweep),
# and the only way to run it on a phone is against the LLVM the phone has.
# Anything older is still refused: LLVM has no stable plugin ABI, so a plugin
# built for one major version cannot be loaded by another.
if("${LLVM_VERSION_MAJOR}" VERSION_LESS 21)
  message(FATAL_ERROR "Found LLVM ${LLVM_VERSION_MAJOR}, but Hikari needs LLVM 21 or above (22 is what rustc and the shipped packages use)")
endif()

list(APPEND CMAKE_MODULE_PATH "${LLVM_CMAKE_DIR}")
include(AddLLVM)

separate_arguments(LLVM_DEFINITIONS_LIST NATIVE_COMMAND ${LLVM_DEFINITIONS})
add_definitions(${LLVM_DEFINITIONS_LIST})
include_directories(${LLVM_INCLUDE_DIRS})

#===============================================================================
# 2. LLVM-TUTOR BUILD CONFIGURATION
#===============================================================================
# Use the same C++ standard as LLVM does
set(CMAKE_CXX_STANDARD 17 CACHE STRING "")

add_subdirectory(obfuscation)
