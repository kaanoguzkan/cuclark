#ifndef CUDA_UTILS_HH
#define CUDA_UTILS_HH

#include <cuda_runtime.h>
#include <cstdio>
#include <cstdlib>
#include <utility>

#define CUDA_CHECK(call) do { \
    cudaError_t err = (call); \
    if (err != cudaSuccess) { \
        std::fprintf(stderr, "CUDA error at %s:%d: %s\n", \
                     __FILE__, __LINE__, cudaGetErrorString(err)); \
        std::exit(EXIT_FAILURE); \
    } \
} while(0)

template <typename T>
class CudaDevicePtr {
    T* m_ptr = nullptr;
    int m_device = -1;
    size_t m_count = 0;
public:
    CudaDevicePtr() = default;

    explicit CudaDevicePtr(size_t count) : m_count(count) {
        CUDA_CHECK(cudaGetDevice(&m_device));
        CUDA_CHECK(cudaMalloc(&m_ptr, count * sizeof(T)));
    }

    CudaDevicePtr(size_t count, int device) : m_count(count), m_device(device) {
        CUDA_CHECK(cudaSetDevice(device));
        CUDA_CHECK(cudaMalloc(&m_ptr, count * sizeof(T)));
    }

    ~CudaDevicePtr() { reset(); }

    CudaDevicePtr(const CudaDevicePtr&) = delete;
    CudaDevicePtr& operator=(const CudaDevicePtr&) = delete;

    CudaDevicePtr(CudaDevicePtr&& other) noexcept
        : m_ptr(other.m_ptr), m_device(other.m_device), m_count(other.m_count) {
        other.m_ptr = nullptr;
        other.m_device = -1;
        other.m_count = 0;
    }

    CudaDevicePtr& operator=(CudaDevicePtr&& other) noexcept {
        if (this != &other) {
            reset();
            m_ptr = other.m_ptr;
            m_device = other.m_device;
            m_count = other.m_count;
            other.m_ptr = nullptr;
            other.m_device = -1;
            other.m_count = 0;
        }
        return *this;
    }

    void reset() {
        if (m_ptr) {
            int currentDevice;
            cudaGetDevice(&currentDevice);
            if (m_device >= 0 && currentDevice != m_device)
                cudaSetDevice(m_device);
            cudaFree(m_ptr);
            if (m_device >= 0 && currentDevice != m_device)
                cudaSetDevice(currentDevice);
            m_ptr = nullptr;
            m_device = -1;
            m_count = 0;
        }
    }

    void allocate(size_t count) {
        reset();
        m_count = count;
        CUDA_CHECK(cudaGetDevice(&m_device));
        CUDA_CHECK(cudaMalloc(&m_ptr, count * sizeof(T)));
    }

    void allocate(size_t count, int device) {
        reset();
        m_count = count;
        m_device = device;
        CUDA_CHECK(cudaSetDevice(device));
        CUDA_CHECK(cudaMalloc(&m_ptr, count * sizeof(T)));
    }

    T* get() const { return m_ptr; }
    T* release() { T* p = m_ptr; m_ptr = nullptr; m_device = -1; m_count = 0; return p; }
    size_t count() const { return m_count; }
    int device() const { return m_device; }
    explicit operator bool() const { return m_ptr != nullptr; }
};

template <typename T>
class CudaPinnedPtr {
    T* m_ptr = nullptr;
    size_t m_count = 0;
public:
    CudaPinnedPtr() = default;

    explicit CudaPinnedPtr(size_t count) : m_count(count) {
        CUDA_CHECK(cudaMallocHost(&m_ptr, count * sizeof(T)));
    }

    ~CudaPinnedPtr() { reset(); }

    CudaPinnedPtr(const CudaPinnedPtr&) = delete;
    CudaPinnedPtr& operator=(const CudaPinnedPtr&) = delete;

    CudaPinnedPtr(CudaPinnedPtr&& other) noexcept
        : m_ptr(other.m_ptr), m_count(other.m_count) {
        other.m_ptr = nullptr;
        other.m_count = 0;
    }

    CudaPinnedPtr& operator=(CudaPinnedPtr&& other) noexcept {
        if (this != &other) {
            reset();
            m_ptr = other.m_ptr;
            m_count = other.m_count;
            other.m_ptr = nullptr;
            other.m_count = 0;
        }
        return *this;
    }

    void reset() {
        if (m_ptr) {
            cudaFreeHost(m_ptr);
            m_ptr = nullptr;
            m_count = 0;
        }
    }

    void allocate(size_t count) {
        reset();
        m_count = count;
        CUDA_CHECK(cudaMallocHost(&m_ptr, count * sizeof(T)));
    }

    T* get() const { return m_ptr; }
    T* release() { T* p = m_ptr; m_ptr = nullptr; m_count = 0; return p; }
    size_t count() const { return m_count; }
    explicit operator bool() const { return m_ptr != nullptr; }
};

class CudaEvent {
    cudaEvent_t m_event = nullptr;
public:
    CudaEvent() = default;

    explicit CudaEvent(unsigned int flags) {
        CUDA_CHECK(cudaEventCreateWithFlags(&m_event, flags));
    }

    ~CudaEvent() { reset(); }

    CudaEvent(const CudaEvent&) = delete;
    CudaEvent& operator=(const CudaEvent&) = delete;

    CudaEvent(CudaEvent&& other) noexcept : m_event(other.m_event) {
        other.m_event = nullptr;
    }

    CudaEvent& operator=(CudaEvent&& other) noexcept {
        if (this != &other) {
            reset();
            m_event = other.m_event;
            other.m_event = nullptr;
        }
        return *this;
    }

    void reset() {
        if (m_event) {
            cudaEventDestroy(m_event);
            m_event = nullptr;
        }
    }

    void create(unsigned int flags) {
        reset();
        CUDA_CHECK(cudaEventCreateWithFlags(&m_event, flags));
    }

    cudaEvent_t get() const { return m_event; }
    explicit operator bool() const { return m_event != nullptr; }
};

#endif
