# mimic-iv-icu-los-prediction
# Early Prediction of Prolonged ICU Length of Stay Using MIMIC-IV

```
MIMIC-IV Tables → SQL Cohort/Feature Extraction → Leakage-Safe Preprocessing
     → LogReg / Random Forest / XGBoost → SHAP → Clinical Interpretation
```

## Overview

End-to-end, leakage-conscious ML pipeline predicting whether an ICU stay will be **prolonged
(≥5 days)** using only data available in the **first 24 hours** of admission. Built on the public
MIMIC-IV Demo dataset. The goal is to demonstrate a reproducible, leakage-free clinical data
science workflow — not to chase a high AUC on 100 demo patients.

## Problem Statement

Binary classification: given only information knowable at or within 24 hours of ICU admission
(`t0 = intime`), predict whether the stay will last ≥ 5 days. No feature crosses the 24-hour
boundary — enforced at the SQL level, not just conceptually.

## Dataset

- **Source:** [MIMIC-IV Clinical Database Demo v2.2](https://physionet.org/content/mimic-iv-demo/2.2/) (~100 patients, 140 raw ICU stays)
- **Cohort:** 140 → **117 ICU stays** (adult-only, LOS ≥ 1 day)
- **Features:** 17, across 5 domains — demographics, admission context, comorbidities, first-24h
  labs, first-24h medications
- **Target:** `prolonged_stay_label` — 26.5% positive (31/117), threshold set at the empirical
  75th percentile of observed LOS

## Methodology

### 1. Cohort Selection
Unit of analysis is `stay_id` (not `subject_id` — patients can have multiple ICU stays).
Inclusion: adult, LOS ≥ 1 day. Anchor timestamp: `icustays.intime`.

### 2. Feature Engineering
Each of the 5 feature domains built as an independent SQL module, then joined 1:1 onto the
cohort. One-hot encoding for categoricals; comorbidities kept as 4 individual flags rather than
a collapsed count (VIF < 2.0 either way — retained for per-condition SHAP attribution).

### 3. Leakage Prevention
Every raw column classified by time availability and leakage risk before use
(`docs/data_dictionary.md`). Labs joined on `subject_id` + time window, not `hadm_id` (26% null).
Diagnosis codes limited to chronic, present-by-definition conditions only. Scaling fit on the
training fold only, inside a `sklearn` `Pipeline`.

### 4. Modeling
Logistic Regression, Random Forest, XGBoost. Stratified 80/20 split (93/24) + 5-fold stratified
CV. No hyperparameter tuning (93 training rows is too small to tune safely). Model selected by CV
mean ROC-AUC, not single test-set score.

### 5. Interpretability
SHAP `TreeExplainer` on the selected Random Forest — global feature importance, dependence plots,
and local case-level explanations.

## Results

| Model | Test ROC-AUC | 5-fold CV ROC-AUC |
|---|---|---|
| Logistic Regression | 0.593 | 0.441 ± 0.141 |
| **Random Forest** ⭐ | 0.593 | **0.537 ± 0.083** |
| XGBoost | 0.481 | 0.533 ± 0.082 |

Random Forest selected (highest CV mean; margin over XGBoost is within noise). ROC-AUC in the
0.48–0.59 range is close to chance — consistent with EDA finding no feature correlated with the
target beyond r≈0.21, and expected at n=117. See [Limitations](#limitations).

## SHAP Analysis

Top features by mean |SHAP value|: medication count, heart failure, age, Medicare insurance,
creatinine, hypertension, CKD.

- Chronic comorbidity burden (heart failure, hypertension, CKD) drives predictions.
- Medication count has a **nonlinear** effect — risk rises then falls at the highest counts.
- **Medicare insurance likely proxies for age**, not an independent driver — flagged as a
  fairness consideration.

Full plots: `reports/modeling_summary.md`.

## Limitations

- **Demo dataset** (~100 patients), not full MIMIC-IV — a workflow demonstration, not a
  clinically validated model.
- **Small sample** (117 stays, 31 positive) — CV mean±std is the reliable number, not any single
  test-set metric.
- **17 features only** — no vitals, SOFA/APACHE scores, or fluid balance yet.
- **Binary LOS threshold** discards exact-duration information.

## Project Structure

```
sql/            SQL feature extraction pipeline
notebooks/      EDA → feature engineering → modeling
models/         trained model + comparison table
reports/        EDA & modeling write-ups, figures
docs/           data dictionary, validation strategy
app/            Streamlit demo
```

## Reproducibility

```bash
# 1. Download MIMIC-IV Demo v2.2 from PhysioNet into data/raw/
# 2. pip install -r requirements.txt
# 3. Run SQL pipeline (DuckDB) → data/processed/feature_table.csv
# 4. Run notebooks in order:
notebooks/01_EDA.ipynb → 02_feature_engineering.ipynb → 03_modeling.ipynb
# 5. streamlit run app/app.py
```

Data files are gitignored per MIMIC-IV's data-use terms — only regeneration code is committed.

## Disclaimer

Educational/portfolio project. Not clinically validated. Not for clinical use.
