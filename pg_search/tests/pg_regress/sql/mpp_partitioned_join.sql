-- =====================================================================
-- End-to-end MPP exercise on Partitioned JoinScan.
-- =====================================================================

CREATE EXTENSION IF NOT EXISTS pg_search;

SET paradedb.enable_aggregate_custom_scan TO on;
SET paradedb.enable_join_custom_scan TO on;

SET paradedb.mpp_worker_count TO 4;
SET max_parallel_workers_per_gather TO 4;
SET max_parallel_workers TO 8;
SET min_parallel_table_scan_size TO 0;
SET parallel_setup_cost TO 0;
SET parallel_tuple_cost TO 0;

-- Set boundaries for range partitioning
SET paradedb.range_partition_boundaries TO '50, 100, 150';
SET paradedb.enable_mpp TO on;

CREATE TABLE mpp_join_files (
    id SERIAL PRIMARY KEY,
    title TEXT,
    content TEXT
);
CREATE TABLE mpp_join_pages (
    id SERIAL PRIMARY KEY,
    file_id INTEGER,
    page_text TEXT,
    size_bytes INTEGER
);

INSERT INTO mpp_join_files (id, title, content)
SELECT g, 'file-' || g, 'Section ' || g || ' has content for testing'
FROM generate_series(1, 200) AS g;

INSERT INTO mpp_join_pages (id, file_id, page_text, size_bytes)
SELECT g, (g % 200) + 1,
       'Page text for page ' || g,
       (g * 17) % 4096
FROM generate_series(1, 1000) AS g;

CREATE INDEX mpp_join_files_idx ON mpp_join_files
USING bm25 (id, title, content)
WITH (
    key_field='id',
    partition_by='id',
    text_fields='{"title": {"fast": true}, "content": {}}'
);

CREATE INDEX mpp_join_pages_idx ON mpp_join_pages
USING bm25 (id, file_id, page_text, size_bytes)
WITH (
    key_field='id',
    partition_by='file_id',
    numeric_fields='{"file_id": {"fast": true}, "size_bytes": {"fast": true}}',
    text_fields='{"page_text": {}}'
);

ANALYZE mpp_join_files;
ANALYZE mpp_join_pages;


SET paradedb.enable_mpp TO on;

EXPLAIN (COSTS OFF, VERBOSE, TIMING OFF)
SELECT f.title, p.size_bytes
FROM mpp_join_files f JOIN mpp_join_pages p ON f.id = p.file_id
WHERE f.content @@@ 'Section'
ORDER BY f.title, p.size_bytes
LIMIT 10;

SELECT f.title, p.size_bytes
FROM mpp_join_files f JOIN mpp_join_pages p ON f.id = p.file_id
WHERE f.content @@@ 'Section'
ORDER BY f.title, p.size_bytes
LIMIT 10;


DROP TABLE mpp_join_pages;
DROP TABLE mpp_join_files;
