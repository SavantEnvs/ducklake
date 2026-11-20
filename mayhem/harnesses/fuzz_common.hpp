// Shared helpers for the ducklake fuzz harnesses: a private scratch dir under $TMPDIR and a
// "run this SQL, abort with the error if it fails" helper for the fixed setup statements.
#pragma once
#include "duckdb.hpp"
#include "core_functions_extension.hpp"
#include "ducklake_extension.hpp"
#include "json_extension.hpp"
#include "parquet_extension.hpp"
#include <cstdio>
#include <cstdlib>
#include <string>
#include <unistd.h>

namespace ducklake_fuzz {

inline std::string MakeScratchDir() {
	const char *tmp = getenv("TMPDIR");
	std::string tmpl = std::string(tmp && *tmp ? tmp : "/tmp") + "/ducklake-fuzz-XXXXXX";
	if (!mkdtemp(&tmpl[0])) {
		perror("mkdtemp");
		abort();
	}
	return tmpl;
}

// Registers the statically linked extensions in a new database (the harness links the same static
// libraries as the duckdb shell, but has no shell to load them).
inline void LoadExtensions(duckdb::DuckDB &db) {
	db.LoadStaticExtension<duckdb::CoreFunctionsExtension>();
	db.LoadStaticExtension<duckdb::ParquetExtension>();
	db.LoadStaticExtension<duckdb::JsonExtension>();
	db.LoadStaticExtension<duckdb::DucklakeExtension>();
}

// Setup statements are fixed; one failing means the harness itself is broken.
inline void MustRun(duckdb::Connection &con, const std::string &sql) {
	auto res = con.Query(sql);
	if (res->HasError()) {
		fprintf(stderr, "setup failed: %s\n  %s\n", sql.c_str(), res->GetError().c_str());
		abort();
	}
}

// SQL string literal with single quotes doubled.
inline std::string Quote(const std::string &s) {
	std::string out = "'";
	for (char c : s) {
		out += c;
		if (c == '\'') {
			out += '\'';
		}
	}
	return out + "'";
}

inline void WriteFile(const std::string &path, const uint8_t *data, size_t size) {
	FILE *f = fopen(path.c_str(), "wb");
	if (!f) {
		perror(path.c_str());
		abort();
	}
	if (size && fwrite(data, 1, size, f) != size) {
		perror("fwrite");
		abort();
	}
	fclose(f);
}

// Locks the database down so fuzzed SQL can only touch files under `dir` and cannot change settings,
// load or install extensions. DuckDB's memory_limit is capped well under the 2 GB libFuzzer RSS limit so
// bogus sizes in fuzzed files make DuckDB refuse the allocation (an error) instead of an OOM.
inline void Sandbox(duckdb::Connection &con, const std::string &dir) {
	MustRun(con, "SET memory_limit='1GB'");
	MustRun(con, "SET autoinstall_known_extensions=false");
	MustRun(con, "SET autoload_known_extensions=false");
	MustRun(con, "SET allowed_directories=[" + Quote(dir + "/") + "]");
	MustRun(con, "SET enable_external_access=false");
	MustRun(con, "SET lock_configuration=true");
}

} // namespace ducklake_fuzz
