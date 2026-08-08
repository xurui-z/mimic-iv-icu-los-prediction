-- =============================================================================
-- comorbidities.sql
-- =============================================================================
-- PURPOSE: diabetes_flag, hypertension_flag, ckd_flag, heart_failure_flag,
--   comorbidity_count  (features C1-C5 in feature_engineering_plan.md)
--
-- 24-HOUR BOUNDARY: NOT a timestamp filter — diagnoses_icd has no charttime
--   at all. The "boundary" enforced here is a CONTENT restriction instead:
--   only ICD prefixes for conditions that are chronic BY DEFINITION are
--   matched (diabetes, hypertension, CKD, heart failure). Acute/complication
--   codes (sepsis, AKI, etc.) are deliberately never matched, anywhere in
--   this file, because those could have originated during the stay itself —
--   see the leakage caveat in docs/data_dictionary.md §4. This is the
--   substitute for a time filter when the source table doesn't carry time.
--
-- JOINS: cohort --JOIN--> diagnoses_icd on hadm_id. Unlike admissions/
--   patients, diagnoses_icd is NOT 1:1 on hadm_id — one hospitalization has
--   many diagnosis rows (verified: 4,507 diagnosis rows across 276
--   admissions, ~16 rows/admission on average). A naive join here WOULD fan
--   out the cohort's row count. That fan-out is intentional at this
--   intermediate step (it's needed to inspect every code) and is REMOVED by
--   the aggregation step below before this file's final SELECT.
--
-- AGGREGATION: GROUP BY stay_id with MAX() over each boolean match. MAX() on
--   a 0/1 flag is the standard "was this true for ANY row in the group"
--   pattern — it collapses the fanned-out per-diagnosis-row grain back down
--   to one row per stay_id, which is what turns the necessary fan-out above
--   into a safe final output.
--
-- DUPLICATE PREVENTION: the GROUP BY stay_id in the final aggregation is
--   what guarantees one row per stay — but it only works if EVERY non-key
--   column is wrapped in an aggregate function. A bare, non-aggregated
--   column in a GROUP BY query is the classic way this silently breaks
--   (some SQL engines allow it and return an arbitrary row per group instead
--   of erroring) — worth an explicit lint/test, not just a one-time read.
-- =============================================================================

WITH cohort AS (
    SELECT stay_id, hadm_id
    FROM {{ cohort_selection }}
)

-- Intentional fan-out: one row per (stay_id, diagnosis code). This is the
-- "many rows per stay" intermediate grain flagged above.
, cohort_diagnoses AS (
    SELECT
        c.stay_id,
        d.icd_code,
        d.icd_version
    FROM cohort c
    JOIN diagnoses_icd d
        ON d.hadm_id = c.hadm_id
)

-- Curated, version-aware prefix matching. Both ICD-9 and ICD-10 branches are
-- required — profiling confirmed this cohort's diagnoses are split roughly
-- evenly (2,313 ICD-10 rows / 2,193 ICD-9 rows), so matching only one
-- coding system would silently miss ~half the population's diagnoses.
-- Prefix lists below are a v1 starting point — to be validated against the
-- actual icd_code values present in this cohort (see
-- docs/validation_strategy.md, "Diagnosis" section) before being trusted.
, flagged AS (
    SELECT
        stay_id,

        MAX(CASE
            WHEN icd_version = 10 AND (icd_code LIKE 'E10%' OR icd_code LIKE 'E11%' OR icd_code LIKE 'E13%') THEN 1
            WHEN icd_version = 9  AND icd_code LIKE '250%' THEN 1
            ELSE 0
        END) AS diabetes_flag,

        MAX(CASE
            WHEN icd_version = 10 AND icd_code BETWEEN 'I10' AND 'I159' THEN 1
            WHEN icd_version = 9  AND icd_code BETWEEN '401' AND '405' THEN 1
            ELSE 0
        END) AS hypertension_flag,

        MAX(CASE
            WHEN icd_version = 10 AND icd_code LIKE 'N18%' THEN 1
            WHEN icd_version = 9  AND icd_code LIKE '585%' THEN 1
            ELSE 0
        END) AS ckd_flag,

        MAX(CASE
            WHEN icd_version = 10 AND icd_code LIKE 'I50%' THEN 1
            WHEN icd_version = 9  AND icd_code LIKE '428%' THEN 1
            ELSE 0
        END) AS heart_failure_flag

    FROM cohort_diagnoses
    GROUP BY stay_id
)

-- Final step: LEFT JOIN back onto the FULL cohort, not just `flagged`.
-- Reason: a stay with ZERO matching diagnosis rows never appears in
-- `flagged` at all (it has no group), so an INNER JOIN here would silently
-- DROP that stay from the output entirely rather than correctly recording
-- all-zero flags for it. This is the same "INNER JOIN silently shrinks the
-- cohort" trap called out in docs/validation_strategy.md.
SELECT
    c.stay_id,
    COALESCE(f.diabetes_flag, 0)       AS diabetes_flag,
    COALESCE(f.hypertension_flag, 0)   AS hypertension_flag,
    COALESCE(f.ckd_flag, 0)            AS ckd_flag,
    COALESCE(f.heart_failure_flag, 0)  AS heart_failure_flag,
    COALESCE(f.diabetes_flag, 0)
      + COALESCE(f.hypertension_flag, 0)
      + COALESCE(f.ckd_flag, 0)
      + COALESCE(f.heart_failure_flag, 0) AS comorbidity_count
FROM cohort c
LEFT JOIN flagged f
    ON f.stay_id = c.stay_id;

-- VALIDATION HOOK: SELECT stay_id, COUNT(*) FROM <this output> GROUP BY
-- stay_id HAVING COUNT(*) > 1  must be zero rows. Also spot-check: pull the
-- raw icd_code list for ~10 stays flagged diabetes_flag=1 and manually
-- confirm a matching code is really present. See
-- docs/validation_strategy.md, "Diagnosis" section.
