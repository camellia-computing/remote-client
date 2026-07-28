from __future__ import annotations

import importlib.util
from pathlib import Path
import sys
import unittest


SCRIPT_PATH = Path(__file__).parents[1] / "validate_source_provenance.py"
SPEC = importlib.util.spec_from_file_location("validate_source_provenance", SCRIPT_PATH)
assert SPEC is not None and SPEC.loader is not None
PROVENANCE = importlib.util.module_from_spec(SPEC)
sys.modules[SPEC.name] = PROVENANCE
SPEC.loader.exec_module(PROVENANCE)

REPOSITORY = Path(__file__).resolve().parents[3]
COMMIT = "a" * 40


def document(commit: object = COMMIT) -> dict[str, object]:
    return {
        "schema_version": 1,
        "protocol_repository": PROVENANCE.PROTOCOL_REPOSITORY,
        "protocol_source_commit": commit,
    }


class SourceProvenanceTests(unittest.TestCase):
    def test_repository_matches_checked_out_protocol(self) -> None:
        PROVENANCE.validate_repository(REPOSITORY)

    def test_accepts_exact_canonical_source(self) -> None:
        PROVENANCE.validate_document(document(), COMMIT)

    def test_rejects_malformed_or_stale_source(self) -> None:
        cases = (
            ({**document(), "schema_version": 2}, COMMIT),
            ({**document(), "protocol_repository": "https://example.invalid/protocol"}, COMMIT),
            (document("2daff94"), COMMIT),
            (document(), "0" * 40),
        )
        for provenance, actual_commit in cases:
            with self.subTest(provenance=provenance, actual_commit=actual_commit):
                with self.assertRaises(PROVENANCE.ProvenanceError):
                    PROVENANCE.validate_document(provenance, actual_commit)


if __name__ == "__main__":
    unittest.main()
