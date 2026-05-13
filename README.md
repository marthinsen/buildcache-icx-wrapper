# BuildCache Wrappers for Intel Compilers
These wrappers enable the use of Intel compilers with [BuildCache](https://gitlab.com/bits-n-bites/buildcache), a great tool that speeds up builds by caching compilation results.

The following compilers are supported:
- **icx** — Intel C++ compiler
- **ifx** — Intel Fortran compiler

# Usage
Copy the desired wrapper script(s) to the `lua` folder inside your BuildCache directory (e.g. `~/.buildcache/lua/`). BuildCache automatically searches that location for Lua wrappers, so no further configuration is needed.
