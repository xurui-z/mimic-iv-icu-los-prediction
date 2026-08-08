-- =============================================================================
-- labs_first24h.sql
-- =============================================================================
-- PURPOSE: first_creatinine, first_wbc, first_hemoglobin
--   (features D1-D3 in feature_engineering_plan.md)
--
-- 24-HOUR BOUNDARY: filter labevents.charttime to
--   [intime, intime + 24h). charttime = specimen COLLECTION time, which is
--   the timestamp actually used here. Note this is a deliberately documented
--   simplification, not an oversight: storetime (when the result posts to
--   the chart, always >= charttime) is when the value is truly knowable to a
--   clinician or a real-time model. A specimen collected at hour 23 might
--   not result until hour 27, so filtering on charttime alone is mildly
--   optimistic. The stricter variant (swap charttime -> storetime in the
--   WHERE clause below) is one line to change and is called out as a
--   sensitivity check in docs/data_dictionary.md and the model card.
--
-- JOINS: this is the one file in the project where the join key is NOT
--   hadm_id. Profiling found 28,420 / 107,728 labevents rows (26%) have a
--   NULL hadm_id — labs drawn before the admission record was linked (e.g.
--   in the ED). An INNER JOIN on hadm_id would silently discard a quarter of
--   all lab rows, including some of the clinically earliest and most
--   predictive ones. Instead, this file joins on subject_id AND bounds the
--   match with the charttime window itself — the 24h window anchored on
--   THIS specific stay's intime is narrow enough that it cannot accidentally
--   pull in a lab from a different hospitalization of the same subject
--   unless two of that patient's encounters genuinely overlap in time (a
--   real data anomaly worth its own check, not a join bug).
--
-- AGGREGATION: for each (stay_id, itemid), take the row with the EARLIEST
--   charttime — "first" lab value in the window, matching the feature
--   definition. Implemented as a ROW_NUMBER() window per (stay_id, itemid)
--   ordered by charttime ASC, then filtering to rn = 1. NOT MIN(valuenum) —
--   that would return the lowest lab VALUE, not the first lab in TIME, which
--   is a different (and wrong) thing.
--
-- DUPLICATE PREVENTION: two separate mechanisms working together —
--   (1) valuenum IS NOT NULL filters out the 12,481 rows (11.6%) with
--       non-numeric/qualitative results BEFORE ranking, so a null-valued row
--       can never win the "first" ranking by accident.
--   (2) ROW_NUMBER() ... ORDER BY charttime ASC — if two rows for the same
--       (stay_id, itemid) share the exact same charttime (duplicate/repeat
--       draw logged twice), ROW_NUMBER() still picks exactly one
--       deterministically (add labevent_id as a tiebreaker in ORDER BY for
--       full determinism), rather than RANK()/DENSE_RANK() which could
--       return two "rank 1" rows and reintroduce a duplicate.
-- =============================================================================

WITH cohort AS (
    SELECT stay_id, subject_id, intime, feature_cutoff
    FROM {{ cohort_selection }}
)

-- Verified itemids (empirically confirmed against value/unit/reference-range
-- plausibility in this dataset — see docs/data_dictionary.md §5 gap note on
-- the missing d_labitems.csv dictionary table):
--   50912 = Creatinine   (mg/dL, ref ~0.5-1.2)
--   51301 = WBC          (K/uL,  ref ~4-11)
--   51222 = Hemoglobin   (g/dL,  ref ~13.7-18)
, relevant_labs AS (
    SELECT
        c.stay_id,
        l.itemid,
        l.charttime,
        l.valuenum,
        l.labevent_id
    FROM cohort c
    JOIN labevents l
        ON l.subject_id = c.subject_id
       AND l.charttime >= c.intime
       AND l.charttime <  c.feature_cutoff
    WHERE l.itemid IN (50912, 51301, 51222)
      AND l.valuenum IS NOT NULL
)

, ranked AS (
    SELECT
        stay_id,
        itemid,
        valuenum,
        ROW_NUMBER() OVER (
            PARTITION BY stay_id, itemid
            ORDER BY charttime ASC, labevent_id ASC   -- deterministic tiebreak
        ) AS rn
    FROM relevant_labs
)

, first_values AS (
    SELECT stay_id, itemid, valuenum
    FROM ranked
    WHERE rn = 1
)

-- Pivot long -> wide: one row per stay_id, one column per lab. LEFT JOIN
-- from the FULL cohort (not from first_values) so stays with zero labs in
-- the window still appear, with NULLs the missing-value strategy then
-- resolves (see feature_engineering_plan.md D1-D3: missing indicator +
-- training-median imputation, NOT done in SQL).
SELECT
    c.stay_id,
    creat.valuenum AS first_creatinine,
    wbc.valuenum   AS first_wbc,
    hgb.valuenum   AS first_hemoglobin
FROM cohort c
LEFT JOIN first_values creat ON creat.stay_id = c.stay_id AND creat.itemid = 50912
LEFT JOIN first_values wbc   ON wbc.stay_id   = c.stay_id AND wbc.itemid   = 51301
LEFT JOIN first_values hgb   ON hgb.stay_id   = c.stay_id AND hgb.itemid   = 51222;

-- VALIDATION HOOK: (a) row count of this output must equal cohort row count
-- exactly (each LEFT JOIN above is itemid-scoped 1:1 by construction of
-- first_values, so no fan-out is possible — assert it anyway); (b) every
-- first_creatinine/wbc/hemoglobin value must fall within a wide but
-- physiologically plausible bound; (c) no charttime used above should ever
-- fall outside [intime, feature_cutoff) — assert this directly against
-- relevant_labs, not just trust the WHERE clause. See
-- docs/validation_strategy.md, "Labs" section.
