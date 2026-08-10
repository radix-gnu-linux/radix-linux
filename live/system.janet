(system-configuration
  :hostname "radix-live"
  :timezone "UTC"
  :locale "C.UTF-8"
  :init-system :radix-rescue
  :libc :glibc
  :kernel "base/linux-lts"
  :packages [
    "base/busybox"
    "base/lua"]
  :boot-image true
  :file-systems {}
  :services []
  :bootloader {:type :none}
  :keep-generations 3)
