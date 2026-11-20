// Fuzzes the DuckLake REST catalog server's request handling (what `ducklake_rest_serve` exposes to
// remote clients): DuckLakeRESTServer::HandleRequest, the same entry the HTTP handler calls once
// httplib has matched the route. It parses the query parameters, the JSON body or a multipart/mixed
// body with Arrow IPC parts, and runs the endpoint against a served ducklake catalog.
//
// Input (text): the first line is the endpoint name (config, get_latest_snapshot, select,
// commit_transaction, ...). Then header lines until an empty line:
//   P <value>        a path parameter (e.g. the table id of /v1/tables/{table_id}/scan)
//   Q <key>=<value>  a query parameter
//   C <type>         the request Content-Type
//   A <type>         the Accept header
//   X <prefix>       the URL carries a catalog prefix
// Everything after the empty line is the request body. httplib does the socket and route matching;
// this harness starts no server and opens no socket.
//
// State: one DuckDB instance is kept (sandboxed once: files only under the scratch dir, no extension
// load/install, configuration locked). Each input gets a NEW ducklake catalog in a new scratch dir and
// a NEW DuckLakeRESTServer (its page plans are per-server); both are dropped after the input, so a
// commit_transaction in one input never reaches the next.
#include "fuzz_common.hpp"
#include "rest/ducklake_rest_api.hpp"
#include "rest/ducklake_rest_server.hpp"
#include <string>
#include <sys/stat.h>

using namespace ducklake_fuzz;

static std::string base_dir;
static unsigned long counter;
static duckdb::DuckDB *db;
static duckdb::Connection *con;

extern "C" int LLVMFuzzerInitialize(int *, char ***) {
	base_dir = MakeScratchDir();
	db = new duckdb::DuckDB(nullptr);
	LoadExtensions(*db);
	con = new duckdb::Connection(*db);
	MustRun(*con, "SET threads=1");
	// every input ATTACHes after the sandbox is on; without this, ATTACH reads ~/.duckdb/stored_secrets
	MustRun(*con, "SET allow_persistent_secrets=false");
	Sandbox(*con, base_dir);
	return 0;
}

static bool NextLine(const std::string &in, size_t &pos, std::string &line) {
	if (pos >= in.size()) {
		return false;
	}
	size_t nl = in.find('\n', pos);
	if (nl == std::string::npos) {
		nl = in.size();
	}
	line = in.substr(pos, nl - pos);
	pos = nl + 1;
	return true;
}

extern "C" int LLVMFuzzerTestOneInput(const uint8_t *data, size_t size) {
	std::string in(reinterpret_cast<const char *>(data), size);
	size_t pos = 0;
	std::string line;
	if (!NextLine(in, pos, line)) {
		return -1;
	}
	const duckdb::RESTRoute *route = nullptr;
	for (auto &r : duckdb::DuckLakeRESTAPI::GetRoutes()) {
		if (r.endpoint == line) {
			route = &r;
		}
	}
	if (!route) {
		return -1; // the harness format names an endpoint; httplib answers 404 for unknown paths
	}
	duckdb::vector<std::string> path_values;
	duckdb::vector<std::pair<std::string, std::string>> query;
	std::string content_type, accept, prefix;
	bool with_prefix = false;
	while (NextLine(in, pos, line) && !line.empty()) {
		if (line.size() < 2 || line[1] != ' ') {
			return -1;
		}
		std::string v = line.substr(2);
		switch (line[0]) {
		case 'P':
			path_values.push_back(v);
			break;
		case 'Q': {
			auto eq = v.find('=');
			query.emplace_back(v.substr(0, eq), eq == std::string::npos ? std::string() : v.substr(eq + 1));
			break;
		}
		case 'C':
			content_type = v;
			break;
		case 'A':
			accept = v;
			break;
		case 'X':
			with_prefix = true;
			prefix = v;
			break;
		default:
			return -1;
		}
	}
	std::string body = pos < in.size() ? in.substr(pos) : std::string();

	unsigned long n = counter++;
	std::string dir = base_dir + "/" + std::to_string(n);
	if (mkdir(dir.c_str(), 0700) != 0) {
		perror("mkdir");
		abort();
	}
	std::string cat = "c" + std::to_string(n);
	MustRun(*con, "ATTACH " + Quote("ducklake:" + dir + "/meta.db") + " AS " + cat + " (DATA_PATH " +
	                  Quote(dir + "/data") + ", DATA_INLINING_ROW_LIMIT 0)");
	MustRun(*con, "CREATE TABLE " + cat + ".t (i INTEGER, s VARCHAR)");
	MustRun(*con, "INSERT INTO " + cat + ".t VALUES (1, 'a'), (2, 'b'), (3, NULL)");
	MustRun(*con, "DELETE FROM " + cat + ".t WHERE i = 2");
	MustRun(*con, "CREATE VIEW " + cat + ".v AS SELECT i FROM " + cat + ".t");
	{
		duckdb::DuckLakeRESTServer server;
		server.AddCatalog(with_prefix ? prefix : std::string("lake"), db->instance, cat);
		std::string response, response_type;
		server.HandleRequest(*route, with_prefix ? duckdb::optional_ptr<const std::string>(&prefix) : nullptr,
		                     path_values, query, body, content_type, accept, response, response_type);
	}
	MustRun(*con, "DETACH " + cat);
	std::string cmd = "rm -rf " + Quote(dir);
	if (system(cmd.c_str()) != 0) {
		abort();
	}
	return 0;
}
