cmake_minimum_required(VERSION 3.31)
project(statusbar-umbrella LANGUAGES CXX)

# Unified build of every exported statusbar-* package as one CMake project. Each
# package still builds standalone; this umbrella sets STATUSBAR_AGGREGATE_BUILD
# so the per-package aggregate targets, install/export rules and find_package()
# calls defer to the shared ones created here.
set(STATUSBAR_AGGREGATE_BUILD ON)
include(CTest)

# Project build-helper modules: define statusbar_register_{fuzz,coverage,
# clang_tidy}_targets() and the sanitizer/coverage/fuzzing options. These are
# project build logic, NOT compiler selection, so the project provides them
# itself rather than depending on a particular CMAKE_TOOLCHAIN_FILE to pull them
# in. (The bundled cmake/toolchain-clang.cmake also include()s them — it runs
# first, before project() — so the COMMAND guard makes this a no-op in that
# case, while still defining the helpers under any other toolchain.)
if(NOT COMMAND statusbar_register_fuzz_targets)
  list(APPEND CMAKE_MODULE_PATH "${CMAKE_CURRENT_SOURCE_DIR}/cmake")
  include(sanitizers)
  include(coverage)
  include(fuzzing)
  include(clang_tidy)
endif()

# Build every library and tool without C++ exceptions. The codebase routes all
# error paths through statusbar::throw_or_abort (which logs + std::terminate()s
# instead of throwing when exceptions are off), so this compiles cleanly. The
# aggregate test binary is excluded: its EXPECT_* assertions and a handful of
# throw-verification tests rely on exceptions and always run with them on.
option(ENABLE_NO_EXCEPTIONS
       "Build libraries and tools with -fno-exceptions (test binary excluded)"
       OFF)
if(ENABLE_NO_EXCEPTIONS)
  add_compile_options(-fno-exceptions)
endif()

# Hardened build: make STATUSBAR_ASSERT() emit a real runtime check that traps
# on a violated precondition, even in release. Defense in depth for production
# deployments that prefer fail-closed over the default release behaviour
# ([[assume]], i.e. undefined behaviour on a violated precondition). OFF by
# default; STATUSBAR_HARDENED is otherwise undefined.
option(
  ENABLE_HARDENING
  "Make STATUSBAR_ASSERT trap on violation in all builds (defense in depth)"
  OFF)
if(ENABLE_HARDENING)
  add_compile_definitions(STATUSBAR_HARDENED)
endif()

# PACKET_QDISC_BYPASS lowers stream-TX latency but makes egress INVISIBLE to
# local AF_PACKET capture on the sending host (it skips dev_queue_xmit_nit). ON
# by default. Turn OFF to build a "full local visibility" node (e.g. a Pi used
# as an on-box ATDECC controller/monitor): all TX then goes through the normal
# qdisc path so tcpdump/monitor/controller on the same host observe our own
# stream + control egress, and RawnetContext sockets are opened promiscuous.
option(
  ENABLE_PACKET_QDISC_BYPASS
  "Use PACKET_QDISC_BYPASS for opted-in TX sockets (OFF = all TX visible to local capture + promiscuous RX)"
  ON)
if(NOT ENABLE_PACKET_QDISC_BYPASS)
  add_compile_definitions(STATUSBAR_NO_QDISC_BYPASS)
endif()

define_property(
  GLOBAL
  PROPERTY STATUSBAR_TEST_FILES
  BRIEF_DOCS "test sources"
  FULL_DOCS "accumulated test sources")
set_property(GLOBAL PROPERTY STATUSBAR_TEST_FILES "")
define_property(
  GLOBAL
  PROPERTY STATUSBAR_INSTALL_TARGETS
  BRIEF_DOCS "install targets"
  FULL_DOCS "accumulated install targets")
set_property(GLOBAL PROPERTY STATUSBAR_INSTALL_TARGETS "")

# Satisfy each package's find_package(statusbar-<dep>) from the in-tree build:
# write an empty redirect config that find_package() resolves before searching
# anywhere else (the mechanism FetchContent uses).
foreach(_pkg statusbar-core statusbar-crypto statusbar-audio statusbar-avb)
  file(WRITE "${CMAKE_FIND_PACKAGE_REDIRECTS_DIR}/${_pkg}-config.cmake"
       "# satisfied in-tree by the statusbar-umbrella aggregate build\n")
endforeach()

# Shared aggregate targets — one each, replacing the per-package versions
# (guarded off when STATUSBAR_AGGREGATE_BUILD is set).
add_custom_target(run-all-benches)
add_library(statusbar INTERFACE)

# Exported packages, in dependency order.
add_subdirectory(core)
add_subdirectory(crypto)
add_subdirectory(audio)
add_subdirectory(avb)

# Populate the umbrella interface library once every module target exists.
# STATUSBAR_INSTALL_TARGETS accumulated every module's target, including tool
# executables — link only the library targets.
get_property(_all_targets GLOBAL PROPERTY STATUSBAR_INSTALL_TARGETS)
set(_lib_targets "")
foreach(_t ${_all_targets})
  if(TARGET ${_t})
    get_target_property(_t_type ${_t} TYPE)
    if(NOT _t_type STREQUAL "EXECUTABLE")
      list(APPEND _lib_targets ${_t})
    endif()
  endif()
endforeach()
if(_lib_targets)
  target_link_libraries(statusbar INTERFACE ${_lib_targets})
endif()

# Combined install — per-package install/export rules are deferred under
# STATUSBAR_AGGREGATE_BUILD, so `cmake --install` on this aggregate build
# installs every package's libraries, tools and headers under one prefix.
# Per-package find_package() configs and CPack archives are produced only by
# standalone package builds — build packages individually for those.
include(GNUInstallDirs)
install(
  TARGETS ${_all_targets}
  ARCHIVE DESTINATION ${CMAKE_INSTALL_LIBDIR} COMPONENT devel
  LIBRARY DESTINATION ${CMAKE_INSTALL_LIBDIR} COMPONENT runtime
  RUNTIME DESTINATION ${CMAKE_INSTALL_BINDIR} COMPONENT runtime)
foreach(_pkg statusbar-core statusbar-crypto statusbar-audio statusbar-avb)
  if(IS_DIRECTORY "${CMAKE_CURRENT_SOURCE_DIR}/${_pkg}/statusbar")
    install(
      DIRECTORY "${_pkg}/statusbar/"
      DESTINATION ${CMAKE_INSTALL_INCLUDEDIR}/statusbar
      COMPONENT devel
      FILES_MATCHING
      PATTERN "*.hpp"
      PATTERN "*.h")
  endif()
endforeach()

# Single aggregate test binary built from every package's test sources.
# create_test_sourcelist derives each test's entry-function name from its path;
# the test sources define that name relative to their own package root, so strip
# the leading statusbar-<pkg>/ component to match.
get_property(STATUSBAR_TEST_FILES_ABS GLOBAL PROPERTY STATUSBAR_TEST_FILES)
set(STATUSBAR_TEST_FILES "")
foreach(TEST_FILE_ABS ${STATUSBAR_TEST_FILES_ABS})
  file(RELATIVE_PATH TEST_FILE_REL "${PROJECT_SOURCE_DIR}" "${TEST_FILE_ABS}")
  string(REGEX REPLACE "^[^/]+/(.*)" "\\1" TEST_FILE_REL "${TEST_FILE_REL}")
  list(APPEND STATUSBAR_TEST_FILES "${TEST_FILE_REL}")
endforeach()
list(SORT STATUSBAR_TEST_FILES)
if(STATUSBAR_TEST_FILES AND NOT ENABLE_NO_EXCEPTIONS)
  create_test_sourcelist(STATUSBAR_TEST_SOURCES statusbar_test.cpp
                         ${STATUSBAR_TEST_FILES})
  add_executable(statusbar_test ${CMAKE_CURRENT_BINARY_DIR}/statusbar_test.cpp
                                ${STATUSBAR_TEST_FILES_ABS})
  target_link_libraries(statusbar_test PRIVATE statusbar)
  foreach(TEST_FILE ${STATUSBAR_TEST_FILES})
    string(REPLACE ".cpp" "" TEST_NAME "${TEST_FILE}")
    add_test(NAME ${TEST_NAME} COMMAND statusbar_test ${TEST_NAME})
  endforeach()
  add_test(NAME statusbar_all_test COMMAND statusbar_test -A)
  statusbar_register_coverage_targets(statusbar_test)
endif()

# Auto-discovering fuzz-smoke / fuzz-all targets (no-op unless ENABLE_FUZZING).
statusbar_register_fuzz_targets()

# Python crypto cross-validation target. Registered here (rather than from
# crypto/CMakeLists.txt) because avtp_crypto_tool is declared by avb, which is
# add_subdirectory()'d after crypto.
find_program(UV uv)
if(UV
   AND EXISTS
       ${CMAKE_CURRENT_SOURCE_DIR}/crypto/python/crypto/statusbar_crypto_test.py
   AND TARGET avtp_crypto_tool)
  set(_pycrypto "${CMAKE_CURRENT_SOURCE_DIR}/crypto/python/crypto")
  add_custom_target(
    python-crypto-tests
    COMMAND ${UV} run ${_pycrypto}/statusbar_crypto_test.py
    COMMAND ${UV} run ${_pycrypto}/avtp_crypto_cross_check.py --build-dir
            ${CMAKE_BINARY_DIR}
    DEPENDS avtp_crypto_tool
    COMMENT
      "Python crypto self-tests + cross-check against C++ avtp_crypto_tool"
    VERBATIM USES_TERMINAL)
endif()

# clang-tidy aggregate target (no-op unless clang-tidy is on PATH).
statusbar_register_clang_tidy_target()

# docs-sm: regenerate per-state-machine Markdown + SVG diagrams in each
# submodule's docs/sm/ tree. Each SM gets one .md (transition table) and one
# .svg (rendered from DOT via graphviz). Writes into the source tree
# (intentional — these are committed alongside the SM definitions).
set(_sm_render ${CMAKE_SOURCE_DIR}/cmake/sm-docs-render.sh)
add_custom_target(
  docs-sm
  COMMAND ${_sm_render} $<TARGET_FILE:atdecc_sm_tool>
          ${CMAKE_SOURCE_DIR}/avb/docs/sm/atdecc
  COMMAND ${_sm_render} $<TARGET_FILE:avtp_sm_tool>
          ${CMAKE_SOURCE_DIR}/avb/docs/sm/avtp
  COMMAND ${_sm_render} $<TARGET_FILE:gptp_sm_tool>
          ${CMAKE_SOURCE_DIR}/avb/docs/sm/gptp
  COMMAND ${_sm_render} $<TARGET_FILE:srp_sm_tool>
          ${CMAKE_SOURCE_DIR}/avb/docs/sm/srp
  COMMAND ${_sm_render} $<TARGET_FILE:nanoavb_supervisor_sm_tool>
          ${CMAKE_SOURCE_DIR}/avb/docs/sm/nanoavb
  COMMAND ${_sm_render} $<TARGET_FILE:stun_sm_tool>
          ${CMAKE_SOURCE_DIR}/avb/docs/sm/stun
  DEPENDS atdecc_sm_tool avtp_sm_tool gptp_sm_tool srp_sm_tool
          nanoavb_supervisor_sm_tool stun_sm_tool
  COMMENT
    "Regenerating per-SM Markdown + SVG across all submodules (needs graphviz)"
  VERBATIM USES_TERMINAL)
