cmake_minimum_required(VERSION 3.20)
project(cuCLARK LANGUAGES CXX CUDA)

set(CMAKE_CXX_STANDARD 17)
set(CMAKE_CXX_STANDARD_REQUIRED ON)

set(CMAKE_CUDA_STANDARD 14)
set(CMAKE_CUDA_STANDARD_REQUIRED ON)

# GPU architectures:
#   35=Kepler/K20  37=K80  50=Maxwell  52=GTX9xx  60=Pascal/P100
#   61=GTX10xx     70=Volta/V100  75=Turing/RTX20xx  80=Ampere/A100
#   86=RTX30xx     89=Ada/RTX40xx     90=Hopper/H100
if(NOT DEFINED CMAKE_CUDA_ARCHITECTURES)
    set(CMAKE_CUDA_ARCHITECTURES "35;50;52;60;61;70;75;80;86;89;90")
endif()

# CUDA toolkit (needed to expose cuda_runtime.h to C++ host files)
find_package(CUDAToolkit REQUIRED)

# OpenMP is optional: detected at configure time
find_package(OpenMP)

# Source files shared by both classifier variants
set(CUCLARK_SOURCES
    src/CuClarkDB.cu
    src/main.cc
    src/analyser.cc
    src/file.cc
    src/kmersConversion.cc
)

# ------------------------------------------------------------------
# cuCLARK — full variant (large hash table, 3 DB parts per device)
# ------------------------------------------------------------------
add_executable(cuCLARK ${CUCLARK_SOURCES})
target_include_directories(cuCLARK PRIVATE ${CUDAToolkit_INCLUDE_DIRS})
target_compile_options(cuCLARK PRIVATE
    $<$<COMPILE_LANGUAGE:CXX>:-O3>
    $<$<COMPILE_LANGUAGE:CUDA>:-O3>
)
if(OpenMP_CXX_FOUND)
    target_link_libraries(cuCLARK PRIVATE OpenMP::OpenMP_CXX)
    target_compile_options(cuCLARK PRIVATE
        $<$<COMPILE_LANGUAGE:CUDA>:-Xcompiler=-fopenmp>
    )
endif()

# ------------------------------------------------------------------
# cuCLARK-l — light variant (small hash table, 1 DB part per device)
# ------------------------------------------------------------------
add_executable(cuCLARK-l ${CUCLARK_SOURCES})
target_compile_definitions(cuCLARK-l PRIVATE CUCLARK_LIGHT)
target_include_directories(cuCLARK-l PRIVATE ${CUDAToolkit_INCLUDE_DIRS})
target_compile_options(cuCLARK-l PRIVATE
    $<$<COMPILE_LANGUAGE:CXX>:-O3>
    $<$<COMPILE_LANGUAGE:CUDA>:-O3>
)
if(OpenMP_CXX_FOUND)
    target_link_libraries(cuCLARK-l PRIVATE OpenMP::OpenMP_CXX)
    target_compile_options(cuCLARK-l PRIVATE
        $<$<COMPILE_LANGUAGE:CUDA>:-Xcompiler=-fopenmp>
    )
endif()

# ------------------------------------------------------------------
# Helper tools (host C++ only — no CUDA required)
# ------------------------------------------------------------------
add_executable(getTargetsDef src/getTargetsDef.cc src/file.cc)
target_compile_options(getTargetsDef PRIVATE -O3)

add_executable(getAccssnTaxID src/getAccssnTaxID.cc src/file.cc)
target_compile_options(getAccssnTaxID PRIVATE -O3)

add_executable(getfilesToTaxNodes src/getfilesToTaxNodes.cc src/file.cc)
target_compile_options(getfilesToTaxNodes PRIVATE -O3)

# ------------------------------------------------------------------
# Install — copies binaries to exe/ to preserve backward compatibility
# ------------------------------------------------------------------
install(TARGETS cuCLARK cuCLARK-l getTargetsDef getAccssnTaxID getfilesToTaxNodes
    RUNTIME DESTINATION exe
)
install(PROGRAMS scripts/cuclark DESTINATION bin)
