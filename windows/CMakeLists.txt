cmake_minimum_required(VERSION 3.14)
project(quiz_master2 LANGUAGES CXX)

# Flutter 3.47.9 / Dart 3.13.7 locked — see docs/decision-log.md #D-00.
set(BINARY_NAME "quiz_master2")
set(CMAKE_INSTALL_RPATH "$ORIGIN/lib")

cmake_policy(SET CMP0063 NEW)

# Use the C++17 standard.
set(CMAKE_CXX_STANDARD 17)
set(CMAKE_CXX_STANDARD_REQUIRED ON)

add_subdirectory(${CMAKE_CURRENT_SOURCE_DIR}/flutter)

add_subdirectory(${CMAKE_CURRENT_SOURCE_DIR}/runner)

# Generated plugin registrants are in the flutter directory.
