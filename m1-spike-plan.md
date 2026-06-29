# M1 Range Partitioning Spike Plan & Architecture

## Original Plan

### Step 1: Syntax and Configuration (`partition_by` option & GUC)

**Goal:** Add support for the `partition_by` option in `CREATE INDEX` and a new GUC for hardcoding boundaries.
**Tasks:**

- **Index Option:** Update `BM25IndexOptionsData` and `amoptions()` in `pg_search/src/postgres/options.rs` to accept the `partition_by` string. Parse it into a `Vec<FieldName>` and expose it on `BM25IndexOptions`. Pass this through to `ScanInfo` (if necessary).
- **GUC:** Add a new GUC (e.g., `paradedb.range_partition_boundaries`) in `pg_search/src/gucs.rs` that accepts a comma-separated list of integer boundaries (e.g., `'1000, 2000'`).

### Step 2: Execution Plan Range Partitioning & Boundary Enforcement

**Goal:** Hook into DataFusion's `RangePartitioning` and enforce the hardcoded boundaries on the scanner so the output data respects the partitioning invariants.
**Tasks:**

- **Construct Partitioning:** In `pg_search/src/scan/execution_plan.rs`, if `partition_by` is present, read the boundaries from the GUC. Construct `LexOrdering` and `SplitPoint`s, and wrap them in `Partitioning::Range`.
- **Update PlanProperties:** Apply this `RangePartitioning` to the `PlanProperties` of `PgSearchScanPlan` using `.with_partitioning()`.
- **Enforce Boundaries:** When setting up the `ScanState`s/partitions (whether in `create_eager_scan` or `create_throttled_scan`), we will inject a `RangeQuery` (or equivalent DataFusion pre-filter) into each partition's `Scanner`. Each partition will be strictly bounded by the `SplitPoint`s defined above, guaranteeing that it only emits records belonging to its designated range.

### Step 3: Regress Test Verification

**Goal:** Verify that MPP execution plans recognize the range partitioning and can execute joins locally without a `NetworkShuffleExec`.
**Tasks:**

- Identify an existing test in `pg_search/tests/pg_regress/sql/` that performs a distributed join (or create a small test if needed).
- Enable the partition boundary GUC and the `partition_by` index option for the tables involved.
- Verify through the `EXPLAIN` output that the plan changes appropriately (e.g., `HashJoinExec` executes directly on the `PgSearchScan` without `NetworkShuffleExec` in between).

---

## Resulting Architecture & Spike Workarounds

This spike successfully demonstrated that DataFusion can perform partitioned hash joins over co-partitioned `PgSearchScanPlan` inputs without injecting intermediate `RepartitionExec` or `NetworkShuffleExec` steps.

### Architecture

- **Schema & Options:** `partition_by` was added to `BM25IndexOptions` and passed into `ScanInfo`.
- **Mocking Boundaries:** A new `paradedb.range_partition_boundaries` GUC supplies the global split points for the test.
- **Physical Plan Partitioning:** `PgSearchScanPlan::new` constructs `Partitioning::Range` using the boundaries and column definitions from `partition_by`.
- **Partition Filters:** Because the underlying Tantivy data wasn't actually physically range-partitioned on disk, we created corresponding DataFusion `Expr` filters for each partition range (e.g. `col < 50`, `col >= 50 AND col < 100`). These are evaluated dynamically in `PgSearchScanPlan::execute` before executing the search, enforcing strict disjoint outputs for each parallel partition.

### Hacks and Workarounds

To produce a good plan for both serial/local execution and parallel MPP execution during the spike, several workarounds were applied:

1. **State Duplication & Disabling MPP Segment Stealing**
   - **Why:** Range partitioning implies distinct physical partitions. Because our index wasn't physically partitioned, we manually duplicated the `ScanState` $N$ times (where $N$ is the number of partitions).
   - **Hack:** For MPP worker compatibility, we disabled dynamic segment stealing (`parallel_state: None`) on the `ScanRecipe::Lazy` so each duplicated partition evaluates all segments locally under its own range filter, avoiding contention.

2. **Bypassing DataFusion `CollectLeft` Heuristics (Local non-MPP Join)**
   - **Why:** By default, DataFusion's join planner uses `PartitionMode::Auto` and inspects the left side's data size. For our small regression tests, it would prefer a `CollectLeft` (broadcast) join, hiding the co-partitioned join capabilities.
   - **Hack:** In `pg_search/src/postgres/customscan/joinscan/scan_state.rs`, we hardcoded `target_partitions = mpp_worker_count()` and disabled the auto-broadcast threshold (`hash_join_single_partition_threshold = 0`). This forced DataFusion to respect the `Partitioning::Range` distribution requirement, resulting in a `mode=Partitioned` `HashJoinExec`.

3. **Retaining `source_idx` for MPP Decoder Survival**
   - **Why:** During the `mpp` phase of the spike, setting `parallel_state = None` inadvertently erased the `source_idx` required by the physical codec (`decode_for_dispatch`). This caused MPP workers to incorrectly resolve the MVCC segment list for the right-hand table using the left-hand table's segment list, crashing the worker (`MvccSatisfies::ParallelWorker didn't load the correct segments`).
   - **Hack:** We modified `PgSearchScanPlan::new` to retain `source_idx`, but modified `PgSearchScanPlan::execute` to catch the `(parallel_state: None, source_idx: Some(idx))` tuple and fallback to `reader.search()` (disabling dynamic checkout but succeeding locally) rather than panicking. This allowed the MPP plan to be both correctly planned and successfully executed in tests.
