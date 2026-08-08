-- =============================================================================
-- demographics.sql
-- =============================================================================
-- PURPOSE: age_at_admission, gender  (features A1, A2 in feature_engineering_plan.md)
--
-- 24-HOUR BOUNDARY: not applicable. Demographics are STATIC — true independent
--   of intime — so there is no time filter in this file at all. Including one
--   here would be a no-op at best and a bug (accidentally filtering out valid
--   static rows) at worst. Absence of a time filter is itself a deliberate
--   design choice, not an oversight.
--
-- JOINS: patients (1 row per subject_id) --JOIN--> admissions (1 row per
--   hadm_id, needed only for admittime, to compute age-at-admission) -->
--   attached to the cohort via hadm_id. Both source tables are 1:1 on their
--   own keys (verified: 0 duplicate subject_id in patients, 0 duplicate
--   hadm_id in admissions), so this chain cannot fan out row counts — a stay
--   goes in, exactly one demographic row comes out.
--
-- AGGREGATION: none needed — this is a pure attribute lookup, not an
--   event-table rollup.
--
-- DUPLICATE PREVENTION: inherited from the 1:1 source tables (see JOINS
--   above). Still assert after this query:
--     SELECT stay_id, COUNT(*) FROM demographics_features
--     GROUP BY stay_id HAVING COUNT(*) > 1;   -- must be zero rows
-- =============================================================================

WITH cohort AS (
    SELECT stay_id, subject_id, hadm_id, intime
    FROM {{ cohort_selection }}          -- output of sql/cohort/cohort_selection.sql
)

, age_computed AS (
    -- MIMIC-IV date-shifts each patient's calendar, but anchor_age is only
    -- valid AT anchor_year. Age at THIS admission must be adjusted by the
    -- gap between the admission year and the anchor year, in the patient's
    -- own shifted timeline (which admittime already lives in).
    SELECT
        c.stay_id,
        p.gender,
        p.anchor_age + (EXTRACT(YEAR FROM a.admittime) - p.anchor_year) AS age_at_admission
    FROM cohort c
    JOIN patients p
        ON p.subject_id = c.subject_id
    JOIN admissions a
        ON a.hadm_id = c.hadm_id
)

SELECT
    stay_id,
    age_at_admission,
    gender
FROM age_computed;

-- VALIDATION HOOK: age_at_admission should fall in a clinically plausible
-- adult range (roughly 18-100). Values outside that range indicate a broken
-- anchor_year/admittime offset, not a real patient — see
-- docs/validation_strategy.md, "Age" section.
