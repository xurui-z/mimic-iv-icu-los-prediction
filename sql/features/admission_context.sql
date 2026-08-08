-- =============================================================================
-- admission_context.sql
-- =============================================================================
-- PURPOSE: admission_type, insurance, weekend_admission, night_admission
--   (features B1-B4 in feature_engineering_plan.md)
--
-- 24-HOUR BOUNDARY: not applicable to admission_type/insurance (both are
--   fixed at the moment of admission, no event stream to window). For
--   weekend_admission/night_admission, the relevant instant is intime itself
--   — there's no window to filter, just a derivation FROM the anchor
--   timestamp, so "the boundary" here is really "which timestamp is t0" and
--   the answer is deliberately icustays.intime, not admissions.admittime.
--   Those two can differ (ED stay before ICU transfer) — intime is used
--   because it is the actual prediction anchor for this task, not the
--   broader hospitalization start.
--
-- JOINS: cohort --JOIN--> admissions on hadm_id. admissions.hadm_id is
--   unique at the source (verified: 276 rows, 276 distinct hadm_id), so this
--   is a safe 1:1 join — no fan-out possible.
--
-- AGGREGATION: none — attribute lookup + scalar derivation from intime,
--   same as demographics.sql.
--
-- DUPLICATE PREVENTION: guaranteed by the 1:1 join key, same reasoning as
--   demographics.sql. Assert row count == cohort row count after this query.
-- =============================================================================

WITH cohort AS (
    SELECT stay_id, hadm_id, intime
    FROM {{ cohort_selection }}
)

SELECT
    c.stay_id,
    a.admission_type,
    a.insurance,

    -- weekend_admission: Saturday/Sunday by ISO day-of-week on intime, not
    -- admittime — matches the prediction anchor, see header note above.
    CASE WHEN DAYOFWEEK(c.intime) IN (0, 6) THEN 1 ELSE 0 END AS weekend_admission,

    -- night_admission: 20:00-07:59 local (deidentified-shifted, but internally
    -- consistent) time. Boundary values chosen to bracket typical reduced
    -- overnight staffing hours; documented here so it's a visible, tunable
    -- assumption (candidate for configs/features.yaml) rather than a magic
    -- number buried in code.
    CASE WHEN EXTRACT(HOUR FROM c.intime) >= 20
           OR EXTRACT(HOUR FROM c.intime) < 8
         THEN 1 ELSE 0 END AS night_admission

FROM cohort c
JOIN admissions a
    ON a.hadm_id = c.hadm_id;

-- VALIDATION HOOK: admission_type category counts (post-join) should exactly
-- match admission_type counts in raw admissions.csv restricted to the same
-- hadm_id set — any drift indicates a silent join distortion. See
-- docs/validation_strategy.md.
