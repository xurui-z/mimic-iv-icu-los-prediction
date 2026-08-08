# SQL Feature Extraction Pipeline — Complete

Status date: 2026-08-05. Pipeline executed via `src/build_feature_table.py`,
output validated at `data/processed/feature_table.csv`.

## Feature Domains (5/5)

| # | Domain | SQL file | Table | Features |
|---|---|---|---|---|
| 1 | Demographics | `sql/features/demographics.sql` | `demographics_features` | `age_at_admission`, `gender` |
| 2 | Admission Context | `sql/features/admission_context.sql` | `admission_features` | `admission_type`, `insurance`, `weekend_admission`, `night_admission` |
| 3 | Comorbidities | `sql/features/comorbidities.sql` | `comorbidity_features` | `diabetes_flag`, `hypertension_flag`, `ckd_flag`, `heart_failure_flag`, `comorbidity_count` |
| 4 | Labs (first 24h) | `sql/features/labs_first24h.sql` | `lab_features` | `first_creatinine`, `first_wbc`, `first_hemoglobin` |
| 5 | Medications (first 24h) | `sql/features/medications_first24h.sql` | `medication_features` | `medication_count`, `antibiotic_flag`, `insulin_flag` |

Cohort + label: `sql/cohort/cohort_selection.sql` → `cohort` table (`stay_id`, `prolonged_stay_label`).

## Total Feature Count

**17 features** across 5 domains, plus `stay_id` (key) and `prolonged_stay_label`
(target) = **19 columns** in `data/processed/feature_table.csv`.

## Verified Output Shape

- 117 rows (140 raw ICU stays → 117 after the `los >= 1.0 day` cohort exclusion)
- 19 columns
- 0 missing values across all columns
- `stay_id` unique, no fully duplicated rows
- Label distribution: 86 negative (73.5%) / 31 positive (26.5%) at the
  provisional 5-day LOS threshold

## Frozen

**The SQL feature extraction pipeline is now frozen.**

**Future work will occur only in:**
- feature engineering
- modeling
- SHAP
- deployment

**No new raw features should be added.**
