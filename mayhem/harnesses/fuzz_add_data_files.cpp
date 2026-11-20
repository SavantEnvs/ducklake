// Fuzzes ducklake_add_data_files: the input is written as a Parquet file and registered into ducklake
// tables of several column types (schema / field-id -> column mapping, footer stats -> ducklake
// stats), then the tables are scanned through the ducklake multi-file reader.
//
// State kept across inputs on purpose: one DuckDB instance with the attached catalog. Every input
// runs inside a transaction that is rolled back, so the catalog is unchanged between inputs; the
// Parquet file is fully rewritten by each input.
#include "fuzz_common.hpp"

using namespace ducklake_fuzz;

static duckdb::DuckDB *db;
static duckdb::Connection *con;
static std::string file_path;
static const char *tables[] = {"t_int", "t_mixed", "t_nested"};

extern "C" int LLVMFuzzerInitialize(int *, char ***) {
	std::string dir = MakeScratchDir();
	file_path = dir + "/input.parquet";
	db = new duckdb::DuckDB(nullptr);
	LoadExtensions(*db);
	con = new duckdb::Connection(*db);
	MustRun(*con, "SET threads=1");
	MustRun(*con, "ATTACH " + Quote("ducklake:" + dir + "/meta.db") + " AS l (DATA_PATH " + Quote(dir + "/data") + ")");
	MustRun(*con, "CREATE TABLE l.t_int (i INTEGER)");
	MustRun(*con, "CREATE TABLE l.t_mixed (i BIGINT, s VARCHAR, d DOUBLE, ts TIMESTAMP, b BOOLEAN, dec DECIMAL(18,3))");
	MustRun(*con, "CREATE TABLE l.t_nested (i INTEGER, st STRUCT(a INTEGER, b VARCHAR), li INTEGER[], m MAP(VARCHAR, INTEGER))");
	Sandbox(*con, dir);
	return 0;
}

extern "C" int LLVMFuzzerTestOneInput(const uint8_t *data, size_t size) {
	WriteFile(file_path, data, size);
	for (auto table : tables) {
		MustRun(*con, "BEGIN");
		auto add = con->Query("CALL ducklake_add_data_files('l', " + Quote(table) + ", " + Quote(file_path) +
		                      ", allow_missing => true, ignore_extra_columns => true)");
		if (!add->HasError()) {
			auto scan = con->Query(std::string("SELECT * FROM l.") + table);
			(void)scan;
		}
		con->Query("ROLLBACK");
	}
	return 0;
}
