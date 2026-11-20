// Fuzzes the deletion-vector / Puffin delete-file reader of the ducklake extension through the
// public scan path: a ducklake table whose delete file (written by ducklake itself) is replaced
// with the fuzz input, then scanned with SELECT. Reaches DuckLakeDeleteFilter ->
// DuckLakePuffinReader (footer + JSON blob metadata) -> DuckLakeDeletionVectorData::FromBlob ->
// Roaring64Map::readSafe.
//
// State kept across inputs on purpose: one DuckDB instance with the attached catalog (ATTACH is
// expensive). The catalog is never modified per input (only read); the delete file is fully
// rewritten by every input, so each result depends only on that input.
#include "fuzz_common.hpp"

using namespace ducklake_fuzz;

static duckdb::DuckDB *db;
static duckdb::Connection *con;
static std::string dv_path;

extern "C" int LLVMFuzzerInitialize(int *, char ***) {
	std::string dir = MakeScratchDir();
	db = new duckdb::DuckDB(nullptr);
	LoadExtensions(*db);
	con = new duckdb::Connection(*db);
	MustRun(*con, "SET threads=1");
	MustRun(*con, "ATTACH " + Quote("ducklake:" + dir + "/meta.db") + " AS l (DATA_PATH " + Quote(dir + "/data") +
	                  ", DATA_INLINING_ROW_LIMIT 0, WRITE_DELETION_VECTORS true)");
	MustRun(*con, "CREATE TABLE l.t AS SELECT range::INTEGER AS i FROM range(100)");
	MustRun(*con, "DELETE FROM l.t WHERE i % 7 = 0");
	auto res = con->Query("SELECT delete_file FROM ducklake_list_files('l', 't')");
	auto chunk = res->HasError() ? nullptr : res->FetchRaw();
	if (!chunk || chunk->size() != 1 || chunk->GetValue(0, 0).IsNull()) {
		fprintf(stderr, "no delete file: %s\n", res->HasError() ? res->GetError().c_str() : "");
		abort();
	}
	dv_path = chunk->GetValue(0, 0).ToString();
	Sandbox(*con, dir);
	return 0;
}

extern "C" int LLVMFuzzerTestOneInput(const uint8_t *data, size_t size) {
	WriteFile(dv_path, data, size);
	auto res = con->Query("SELECT count(*), sum(i) FROM l.t");
	(void)res;
	return 0;
}
