local M={}

M.core_repository='https://github.com/radix-gnu-linux/radix-linux'
M.core_git=M.core_repository..'.git'
M.packages_repository='https://github.com/radix-gnu-linux/radix-packages.git'
M.radix_repository='https://github.com/radix-gnu-linux/radix.git'
M.desktop='kde'
M.kde_plasma='6.7.4'
M.kde_frameworks='6.28.0'
M.kernel='lts'
M.libc='glibc'
M.filesystem='ext2'
M.hostname='radix'
M.timezone='UTC'
M.locale='C.UTF-8'

return M
