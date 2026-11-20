// Fuzzes the ducklake catalog through SQL: the input is a SQL script run against a freshly attached
// ducklake catalog (catalog/schema/table/view entries, transactions and commit, time travel, the
// ducklake_* table functions, the metadata manager, view binding).
//
// Each input gets a NEW DuckDB instance and a new scratch directory (removed afterwards), so nothing
// carries over between inputs. The database is sandboxed before the script runs: file access only
// under the scratch dir, no extension install/load, configuration locked.
#include "fuzz_common.hpp"
#include <string>
#include <sys/stat.h>

using namespace ducklake_fuzz;

static std::string base_dir;
static unsigned long counter;

extern "C" int LLVMFuzzerInitialize(int *, char ***) {
	base_dir = MakeScratchDir();
	return 0;
}

extern "C" int LLVMFuzzerTestOneInput(const uint8_t *data, size_t size) {
	std::string dir = base_dir + "/" + std::to_string(counter++);
	if (mkdir(dir.c_str(), 0700) != 0) {
		perror("mkdir");
		abort();
	}
	std::string script(reinterpret_cast<const char *>(data), size);
	{
		duckdb::DuckDB db(nullptr);
		LoadExtensions(db);
		duckdb::Connection con(db);
		MustRun(con, "SET threads=1");
		MustRun(con, "ATTACH " + Quote("ducklake:" + dir + "/meta.db") + " AS l (DATA_PATH " + Quote(dir + "/data") + ")");
		MustRun(con, "USE l");
		Sandbox(con, dir);
		duckdb::vector<duckdb::unique_ptr<duckdb::SQLStatement>> statements;
		try {
			statements = con.ExtractStatements(script);
		} catch (std::exception &) {
			statements.clear();
		}
		for (auto &stmt : statements) {
			auto res = con.Query(std::move(stmt));
			(void)res;
		}
	}
	std::string cmd = "rm -rf " + Quote(dir);
	if (system(cmd.c_str()) != 0) {
		abort();
	}
	return 0;
}
