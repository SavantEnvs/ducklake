# Included by CMake right after `project(ducklake)` (CMAKE_PROJECT_ducklake_INCLUDE, set by
# mayhem/build.sh): instruments ONLY the ducklake extension sources with the sanitizer, coverage and
# DWARF-3 flags. DuckDB itself (a pinned dependency) is compiled with its normal Release flags.
separate_arguments(_ducklake_fuzz_flags UNIX_COMMAND "$ENV{DUCKLAKE_FUZZ_FLAGS}")
add_compile_options(${_ducklake_fuzz_flags})
