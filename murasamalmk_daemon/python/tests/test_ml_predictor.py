"""Unit tests for ml_predictor.py (Murasamalmk ML sidecar).

Covers: telemetry parsing (valid/corrupt/non-object), feature extraction
defaults, untrained/trained prediction paths, sliding-window cap, and the
atomic prediction-file write contract.
"""
from __future__ import annotations

import json
import os

import ml_predictor as mlp
import numpy as np
import pytest

# ---------------------------------------------------------------- helpers

VALID_TELEMETRY = {
    "memory": {
        "free_mb": 1024.0,
        "wired_mb": 8192.0,
        "pressure_level": 3,
        "velocity_mb_s": 120.5,
    },
    "thrashing": {"pageins_per_sec": 300, "decomp_per_sec": 5000},
    "active_app": {"pid": 4242},
}


@pytest.fixture()
def tmp_telemetry(tmp_path):
    p = tmp_path / "telemetry.json"
    p.write_text(json.dumps(VALID_TELEMETRY))
    return str(p)


# -------------------------------------------------------- parse_telemetry

def test_parse_telemetry_valid(tmp_telemetry):
    data = mlp.parse_telemetry(tmp_telemetry)
    assert data is not None
    assert data["memory"]["free_mb"] == 1024.0


def test_parse_telemetry_missing_file_returns_none(tmp_path):
    assert mlp.parse_telemetry(str(tmp_path / "nope.json")) is None


def test_parse_telemetry_corrupt_json_returns_none(tmp_path):
    p = tmp_path / "bad.json"
    p.write_text("{not valid json!!")
    assert mlp.parse_telemetry(str(p)) is None


def test_parse_telemetry_non_object_json_returns_none(tmp_path):
    """Valid JSON that is not an object must be rejected, not crash later."""
    p = tmp_path / "list.json"
    p.write_text("[1, 2, 3]")
    assert mlp.parse_telemetry(str(p)) is None


# ------------------------------------------------------ extract_features

def test_extract_features_full_data():
    feats = mlp.extract_features(VALID_TELEMETRY)
    assert feats == [1024.0, 8192.0, 3.0, 120.5, 300.0, 5000.0]


def test_extract_features_defaults_on_missing_keys():
    feats = mlp.extract_features({})
    assert feats == [2048.0, 4096.0, 1.0, 0.0, 0.0, 0.0]


# --------------------------------------------------- OnlineMemoryPredictor

def test_untrained_predictor_falls_back_to_current_level():
    pred = mlp.OnlineMemoryPredictor()
    level, risk = pred.predict_next([100.0, 200.0, 4.0, 0.0, 0.0, 0.0])
    assert level == 4
    assert risk == "low"


def test_add_sample_caps_history_at_500():
    pred = mlp.OnlineMemoryPredictor()
    for i in range(600):
        pred.add_sample([float(i)] * 6, (i % 5) + 1)
    assert len(pred.features_history) == mlp.HISTORY_MAX_LEN
    assert len(pred.labels_history) == mlp.HISTORY_MAX_LEN


def test_predictor_becomes_trained_after_10_samples():
    pred = mlp.OnlineMemoryPredictor()
    assert not pred.is_trained
    for i in range(12):
        pred.add_sample([100.0 + i, 4096.0, 2.0, 0.0, 0.0, 0.0], (i % 5) + 1)
    assert pred.is_trained
    level, risk = pred.predict_next([110.0, 4096.0, 2.0, 0.0, 0.0, 0.0])
    assert isinstance(level, int) and 1 <= level <= 5
    assert risk in ("low", "high")


def test_trained_predictor_survives_degenerate_input():
    """Murphy's Law: NaN features must not crash -- falls back to current."""
    pred = mlp.OnlineMemoryPredictor()
    for i in range(12):
        pred.add_sample([float(i), 4096.0, float((i % 5) + 1), 0, 0, 0], (i % 5) + 1)
    level, risk = pred.predict_next(
        [float("nan"), 4096.0, 3.0, 0.0, 0.0, 0.0]
    )
    assert level == 3 and risk == "low"


# --------------------------------------------------------- write_prediction

def test_write_prediction_atomic_content(tmp_path):
    target = tmp_path / "ml_prediction.txt"
    mlp.write_prediction(str(target), 5, "high", 999)
    text = target.read_text()
    assert "predicted_pressure:5\n" in text
    assert "risk_level:high\n" in text
    assert "target_pid:999\n" in text
    # Atomic rename contract: no leftover temp file.
    assert not os.path.exists(str(target) + ".tmp")


def test_write_prediction_overwrites_previous(tmp_path):
    target = tmp_path / "ml_prediction.txt"
    mlp.write_prediction(str(target), 2, "low", 1)
    mlp.write_prediction(str(target), 4, "high", 7)
    assert "predicted_pressure:4" in target.read_text()


# ------------------------------------------------------------ model shape

def test_model_classes_are_pressure_levels_1_to_5():
    pred = mlp.OnlineMemoryPredictor()
    assert np.array_equal(pred.classes, np.array([1, 2, 3, 4, 5]))


def test_high_risk_threshold_via_probability_mass():
    """probs[3:] sums classes {4,5}; verify threshold logic on a stubbed model."""
    pred = mlp.OnlineMemoryPredictor()

    class StubModel:
        def predict(self, X):
            return np.array([3])

        def predict_proba(self, X):
            # classes 1..5 -> mass 0.5 on class 4 => sum(probs[3:]) = 0.5 > 0.4
            return np.array([[0.1, 0.1, 0.3, 0.5, 0.0]])

    pred.model = StubModel()  # type: ignore[assignment]
    pred.is_trained = True
    level, risk = pred.predict_next([1.0, 1.0, 1.0, 0.0, 0.0, 0.0])
    assert level == 3 and risk == "high"


def test_module_constants_are_wired_paths():
    assert mlp.TELEMETRY_PATH.endswith("EARU_data.dat")
    assert mlp.PREDICTION_PATH.endswith("ml_prediction.txt")
    assert mlp.HISTORY_MAX_LEN == 500
