// Fuzzes the DuckLake REST client's response parsing: what the client reads back from a (possibly
// hostile) REST server. The input's first line is the response Content-Type, the rest is the body.
// A multipart/mixed body is split by RESTMultipart::Parse and every part is read as an Arrow IPC
// stream by RESTArrowIPC::Read (the client reads the table parts this way); any other body is read
// as one Arrow IPC stream. The arrays the reader returns are walked (children, buffers, lengths) as
// the client's Arrow scan would see them.
//
// No state is kept between inputs: both functions are static and allocate per call.
#include "duckdb.hpp"
#include "rest/ducklake_rest_arrow_ipc.hpp"
#include "rest/ducklake_rest_multipart.hpp"
#include <string>

static void Touch(const ArrowArray &a, int depth, volatile uint64_t &sink) {
	// The fields come straight from the fuzzed IPC header: add them as unsigned so the harness itself
	// cannot overflow (signed overflow here is a harness bug, not a ducklake one).
	sink += (uint64_t)a.length + (uint64_t)a.null_count + (uint64_t)a.offset + (uint64_t)a.n_buffers;
	if (depth > 64) {
		return;
	}
	for (int64_t i = 0; i < a.n_children; i++) {
		if (a.children && a.children[i]) {
			Touch(*a.children[i], depth + 1, sink);
		}
	}
}

static void ReadStream(const duckdb::shared_ptr<const std::string> &data, duckdb::idx_t offset, duckdb::idx_t size) {
	volatile uint64_t sink = 0;
	try {
		auto stream = duckdb::RESTArrowIPC::Read(data, offset, size);
		for (auto &batch : stream->batches) {
			Touch(batch, 0, sink);
		}
	} catch (std::exception &) {
	}
}

extern "C" int LLVMFuzzerTestOneInput(const uint8_t *data, size_t size) {
	std::string in(reinterpret_cast<const char *>(data), size);
	auto nl = in.find('\n');
	if (nl == std::string::npos) {
		return -1;
	}
	std::string content_type = in.substr(0, nl);
	auto body = duckdb::make_shared_ptr<const std::string>(in.substr(nl + 1));
	if (duckdb::RESTMultipart::IsMultipart(content_type)) {
		duckdb::vector<duckdb::RESTMultipartPart> parts;
		try {
			parts = duckdb::RESTMultipart::Parse(*body, content_type);
		} catch (std::exception &) {
			return 0;
		}
		for (auto &part : parts) {
			ReadStream(body, part.offset, part.size);
		}
	} else {
		ReadStream(body, 0, body->size());
	}
	return 0;
}
