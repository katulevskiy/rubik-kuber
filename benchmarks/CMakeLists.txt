cmake_minimum_required(VERSION 3.16)
project(rubik_hw_bench CXX)

set(CMAKE_CXX_STANDARD 17)
set(CMAKE_CXX_STANDARD_REQUIRED ON)

# Optimisation flags
add_compile_options(-O2 -Wall -Wextra
                    -Wno-unused-parameter
                    -Wno-missing-field-initializers)

# ── Include paths ─────────────────────────────────────────────────────────────
# QNN SDK headers ship in multiple subdirs
set(QNN_INC_DIRS
    /usr/include        # top-level: QnnInterface.h, QnnTypes.h, QnnOpDef.h …
    /usr/include/HTP    # QnnHtpGraph.h, QnnHtpContext.h …
    /usr/include/DSP    # QnnDspBackend.h …
)

include_directories(
    src
    /usr/include/CL   # OpenCL headers
    ${QNN_INC_DIRS}
)

# ── Source files ──────────────────────────────────────────────────────────────
set(SOURCES
    src/main.cpp
    src/dmabuf.cpp
    src/ocl_bench.cpp
    src/qnn_runner.cpp
    src/vpu_codec.cpp
    src/fastrpc_probe.cpp
)

add_executable(hw_bench ${SOURCES})

# ── Link libraries ────────────────────────────────────────────────────────────
target_link_libraries(hw_bench
    # OpenCL ICD loader (dlopen's ICDs at runtime: POCL + Adreno if registered)
    OpenCL
    # DL for QNN dynamic backend loading and FastRPC userspace lib probing
    dl
    # Pthreads (needed by some QNN backends)
    pthread
)

# ── Find OpenCL ───────────────────────────────────────────────────────────────
find_package(OpenCL REQUIRED)
target_link_libraries(hw_bench OpenCL::OpenCL dl pthread)

# ── Install ───────────────────────────────────────────────────────────────────
install(TARGETS hw_bench RUNTIME DESTINATION bin)
