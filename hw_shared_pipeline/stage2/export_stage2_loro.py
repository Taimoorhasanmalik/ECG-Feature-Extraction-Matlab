"""Exports leave-one-record-out Stage 2 weights for the end-to-end test.

For each of the 38 pool records, trains the shared-chain Stage 2 model on the
other 37 records (features already quantized, from stage2_shared_alldata.mat),
folds the scaler into one weight vector + bias, and quantizes with the same
fixed-point formats as the deployment export, so the MATLAB end-to-end test
can classify every record with a model that never saw it.

Modifies no existing file.
"""

from __future__ import annotations

import math
import sys
from pathlib import Path

import numpy as np
import scipy.io

HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE.parent.parent))
import vt_vf_expanded_cohort_feature_ranking_experiment as exp


def q(x, integer_bits, fraction_bits):
    scale = 2.0 ** fraction_bits
    return np.clip(np.fix(np.asarray(x, dtype=np.float64) * scale) / scale,
                   -(2.0 ** integer_bits), 2.0 ** integer_bits - 1.0 / scale)


def main():
    d = scipy.io.loadmat(HERE / "results" / "stage2_shared_alldata.mat")
    x = d["test_features_python"].astype(np.float64)
    y = d["test_true_label"].ravel().astype(int)
    rid = np.array([str(np.atleast_1d(r)[0]).strip() for r in d["test_record_id"].ravel()])
    records = sorted(set(rid))

    weights, biases = [], []
    for r in records:
        model = exp.make_model(1.0).fit(x[rid != r], y[rid != r])
        scaler, svm = model.named_steps["scaler"], model.named_steps["svm"]
        w = svm.coef_.ravel() / scaler.scale_
        weights.append(w)
        biases.append(float(svm.intercept_[0] - np.sum(w * scaler.mean_)))
    weights = np.array(weights)
    biases = np.array(biases)

    weight_int_bits = max(int(d["weight_integer_bits"].ravel()[0]),
                          int(math.ceil(math.log2(np.max(np.abs(weights)) + 2 ** -8))) + 1)
    bias_int_bits = max(int(d["bias_integer_bits"].ravel()[0]),
                        int(math.ceil(math.log2(np.max(np.abs(biases)) + 2 ** -8))) + 1)
    fraction_bits = 15 - weight_int_bits
    scipy.io.savemat(HERE / "results" / "stage2_shared_loro_weights.mat", dict(
        record_id=np.array(records, dtype=object),
        weight_q=q(weights, weight_int_bits, fraction_bits),
        bias_q=q(biases, bias_int_bits, fraction_bits).reshape(-1, 1),
        weight_integer_bits=weight_int_bits, bias_integer_bits=bias_int_bits,
        weight_fraction_bits=fraction_bits,
    ))
    print(f"{len(records)} LORO models, weights Q{weight_int_bits}.{fraction_bits}, bias Q{bias_int_bits}.{fraction_bits}")


if __name__ == "__main__":
    main()
