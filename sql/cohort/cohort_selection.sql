-- =============================================================================
-- cohort_selection.sql
-- =============================================================================
-- PURPOSE
--   Defines the modeling cohort (exactly one row per stay_id) and the binary
--   label. This is the FIRST query that runs in the pipeline — every feature
--   domain query (sql/features/*.sql) LEFT JOINs onto this cohort's stay_id
--   list, never the other way around. That direction matters: it guarantees
--   the row count of the final feature table is always == the row count of
--   this cohort, no matter what happens downstream.
--
-- STATUS: pseudocode / design stage. Placeholders in {{ }} are resolved from
--   configs/cohort.yaml once EDA has run (see notes below) — not hardcoded
--   here, so the pipeline stays reproducible from config, not from memory.
-- =============================================================================

-- -----------------------------------------------------------------------------
-- STEP 1: Inclusion / exclusion filtering
-- -----------------------------------------------------------------------------
-- Design decisions made here (each is a deliberate leakage/validity choice,
-- not an arbitrary filter):
--
--   (a) Adult-only: anchor_age >= 18. MIMIC-IV demo is expected to already be
--       adult-only, but the filter is explicit rather than assumed, so the
--       pipeline doesn't silently break if that assumption is ever wrong.
--
--   (b) EXCLUDE stays with los < 1.0 (day). This is the single most important
--       cohort decision in this file. The prediction task is "does the first
--       24h predict a prolonged stay" — a stay that ends BEFORE the 24h mark
--       cannot fairly supply a 24h feature window: any lab/med events after
--       ICU outtime that still fall inside [intime, intime+24h) don't belong
--       to this ICU episode's clinical picture. Rather than truncate the
--       feature window per-row (which would make every stay's window a
--       different length and complicate every downstream join), we exclude
--       these stays from the cohort outright. Their outcome is trivially
--       "not prolonged" anyway, so excluding them costs no label diversity.
--
--   (c) Require non-null intime and a resolvable hadm_id / subject_id — a row
--       that can't anchor a time window or join to admissions/patients can't
--       be featurized at all.
--
--   (d) subject_id is deliberately KEPT (not dropped) in the cohort output,
--       even though it isn't a feature. Reason: 5 patients in this dataset
--       have multiple ICU stays. If those stays land on both sides of a
--       train/test split, the model can implicitly learn patient identity
--       instead of clinical signal — a patient-level leakage pattern distinct
--       from the time-based leakage this file otherwise guards against. This
--       column is what lets the modeling stage use a GROUP-AWARE split
--       (e.g. GroupKFold on subject_id) instead of a naive random split.

WITH eligible_stays AS (
    SELECT
        i.stay_id,
        i.subject_id,          -- kept for group-aware CV split, NOT a feature
        i.hadm_id,
        i.intime,               -- t0 — the anchor every feature domain filters against
        i.intime + INTERVAL '24 hours' AS feature_cutoff,
        i.los
    FROM icustays i
    JOIN patients p
        ON p.subject_id = i.subject_id
    WHERE p.anchor_age >= 18
      AND i.los >= 1.0
      AND i.intime IS NOT NULL
)

-- -----------------------------------------------------------------------------
-- STEP 2: Label derivation
-- -----------------------------------------------------------------------------
-- LOS_THRESHOLD_DAYS is NOT chosen here. Proposal principle: "selected
-- empirically from the observed LOS distribution rather than an arbitrary
-- cutoff." Concretely: this value is computed ONCE in the EDA notebook
-- (e.g. as the 75th percentile of los across eligible_stays), written into
-- configs/cohort.yaml, and only then substituted in here. It must NOT be
-- recomputed inside cross-validation folds — a threshold derived from the
-- full dataset (train+test together) and then used to LABEL that same data
-- is a target-leakage risk if it were also used as a FEATURE, but as a fixed
-- labeling rule decided once and frozen, it is safe — the risk to avoid is
-- letting the threshold silently drift between train/serve time.

, labeled_cohort AS (
    SELECT
        stay_id,
        subject_id,
        hadm_id,
        intime,
        feature_cutoff,
        los,
        CASE WHEN los > {{ LOS_THRESHOLD_DAYS }} THEN 1 ELSE 0 END AS prolonged_stay_label
    FROM eligible_stays
)

SELECT * FROM labeled_cohort;

-- -----------------------------------------------------------------------------
-- DUPLICATE PREVENTION CHECK (run immediately after this query, always)
-- -----------------------------------------------------------------------------
--   SELECT stay_id, COUNT(*) FROM labeled_cohort GROUP BY stay_id HAVING COUNT(*) > 1;
--   -- must return ZERO rows. icustays.stay_id is already unique at the source
--   -- (verified: 141 rows in, 141 distinct stay_id), and this query only adds
--   -- a 1:1 join to patients on subject_id, so no fan-out is expected — but
--   -- the assertion is cheap and belongs in tests/test_sql_cohort.py so a
--   -- future change to this file can't silently reintroduce duplication.
