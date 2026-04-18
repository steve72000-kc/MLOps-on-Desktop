"""Unit tests for the workflow-side manifest renderer.

This file exercises the standalone script used by the Argo workflow sync path
to turn resolved MLflow deployment intent into a tenant-safe KServe
InferenceService manifest.

At a high level, these tests verify that the renderer:
- normalizes legacy runtime names to the current platform runtime
- injects platform-managed S3 defaults needed for model loading
- rejects manifests that target the custom runtime without the required
  modelClass label
"""

import importlib.util
import pathlib
import unittest


MODULE_PATH = pathlib.Path(__file__).resolve().parents[1] / "infra" / "argo-workflows" / "scripts" / "render_inferenceservice.py"
SPEC = importlib.util.spec_from_file_location("render_inferenceservice", MODULE_PATH)
MODULE = importlib.util.module_from_spec(SPEC)
assert SPEC.loader is not None
SPEC.loader.exec_module(MODULE)


class RenderInferenceServiceTests(unittest.TestCase):
    def test_render_manifest_rewrites_legacy_runtime_and_injects_s3_defaults(self) -> None:
        intent = {
            "metadata": {
                "name": "xgboost-synth-v1",
                "labels": {
                    "modelClass": "mlserver_xgboost.XGBoostModel",
                },
            },
            "spec": {
                "predictor": {
                    "model": {
                        "modelFormat": {"name": "xgboost", "version": "1"},
                        "runtime": MODULE.LEGACY_RUNTIME_NAME,
                        "storageUri": "s3://mlflow-ml-team-a/artifacts/model",
                    }
                }
            },
        }

        rendered = MODULE._render_manifest(
            intent=intent,
            tenant="ml-team-a",
            namespace="ml-team-a",
            registered_model="prod.ml-team-a.xgboost-synth",
            alias="champion",
            resolved_version="7",
            intent_hash="abc123",
            storage_secret_name="mlflow-s3-credentials",
        )

        self.assertEqual(rendered["apiVersion"], "serving.kserve.io/v1beta1")
        self.assertEqual(rendered["kind"], "InferenceService")
        self.assertEqual(rendered["metadata"]["namespace"], "ml-team-a")
        self.assertEqual(
            rendered["spec"]["predictor"]["model"]["runtime"],
            MODULE.CANONICAL_RUNTIME_NAME,
        )
        self.assertEqual(
            rendered["metadata"]["annotations"][MODULE.S3_STORAGE_SECRET_ANNOTATION],
            "mlflow-s3-credentials",
        )
        self.assertEqual(
            rendered["spec"]["predictor"]["serviceAccountName"],
            MODULE.S3_STORAGE_SERVICE_ACCOUNT,
        )
        self.assertEqual(rendered["metadata"]["labels"]["platform.ai-ml/tenant"], "ml-team-a")
        self.assertEqual(rendered["metadata"]["labels"]["platform.ai-ml/alias"], "champion")
        self.assertEqual(
            rendered["metadata"]["labels"][MODULE.NETWORK_ROLE_LABEL],
            MODULE.SERVING_RUNTIME_NETWORK_ROLE,
        )
        self.assertEqual(
            rendered["spec"]["predictor"]["labels"][MODULE.NETWORK_ROLE_LABEL],
            MODULE.SERVING_RUNTIME_NETWORK_ROLE,
        )
        self.assertEqual(
            rendered["spec"]["predictor"]["labels"][MODULE.TENANT_LABEL],
            "ml-team-a",
        )

    def test_render_manifest_requires_model_class_for_custom_runtime(self) -> None:
        intent = {
            "metadata": {
                "name": "xgboost-synth-v1",
                "labels": {},
            },
            "spec": {
                "predictor": {
                    "model": {
                        "modelFormat": {"name": "xgboost", "version": "1"},
                        "runtime": MODULE.CANONICAL_RUNTIME_NAME,
                        "storageUri": "s3://mlflow-ml-team-a/artifacts/model",
                    }
                }
            },
        }

        with self.assertRaises(ValueError):
            MODULE._render_manifest(
                intent=intent,
                tenant="ml-team-a",
                namespace="ml-team-a",
                registered_model="prod.ml-team-a.xgboost-synth",
                alias="champion",
                resolved_version="7",
                intent_hash="abc123",
                storage_secret_name="mlflow-s3-credentials",
            )


if __name__ == "__main__":
    unittest.main()
