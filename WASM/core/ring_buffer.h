#pragma once

#include <array>
#include <cstddef>
#include <utility>

namespace core {

template <typename T, size_t Capacity>
class RingBuffer {
 public:
  static_assert(Capacity > 0, "RingBuffer capacity must be > 0");

  constexpr size_t capacity() const noexcept { return Capacity; }
  size_t size() const noexcept { return size_; }
  bool empty() const noexcept { return size_ == 0; }
  bool full() const noexcept { return size_ == Capacity; }

  void clear() noexcept {
    size_ = 0;
    start_ = 0;
  }

  T& front() noexcept { return data_[start_]; }
  const T& front() const noexcept { return data_[start_]; }

  T& back() noexcept { return data_[index_of(size_ - 1)]; }
  const T& back() const noexcept { return data_[index_of(size_ - 1)]; }

  T& at(size_t i) noexcept { return data_[index_of(i)]; }
  const T& at(size_t i) const noexcept { return data_[index_of(i)]; }

  T& push_slot() noexcept {
    size_t idx = 0;
    if (size_ < Capacity) {
      idx = index_of(size_);
      size_ += 1;
    } else {
      start_ = index_of(1);
      idx = index_of(size_ - 1);
    }
    return data_[idx];
  }

  void push(const T& value) noexcept {
    T& slot = push_slot();
    slot = value;
  }

  void push(T&& value) noexcept {
    T& slot = push_slot();
    slot = std::move(value);
  }

  template <class... Args>
  T& emplace(Args&&... args) noexcept {
    T& slot = push_slot();
    slot = T(std::forward<Args>(args)...);
    return slot;
  }

 private:
  size_t index_of(size_t i) const noexcept { return (start_ + i) % Capacity; }

  std::array<T, Capacity> data_{};
  size_t start_ = 0;
  size_t size_ = 0;
};

}  // namespace core
