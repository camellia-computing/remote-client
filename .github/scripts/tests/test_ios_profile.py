from __future__ import annotations

import hashlib
import importlib.util
import plistlib
import tempfile
import unittest
from datetime import UTC, datetime, timedelta
from pathlib import Path


MODULE_PATH = Path(__file__).resolve().parents[1] / "ios_profile.py"
SPEC = importlib.util.spec_from_file_location("ios_profile", MODULE_PATH)
assert SPEC and SPEC.loader
ios_profile = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(ios_profile)


class IosProfileTest(unittest.TestCase):
    bundle_id = "com.camellia.remote"
    team_id = "A1B2C3D4E5"
    certificate = b"test-only-certificate"
    certificate_sha256 = hashlib.sha256(certificate).hexdigest().upper()
    now = datetime(2026, 7, 28, tzinfo=UTC)

    def profile(self, method: str) -> dict:
        entitlements = {
            "application-identifier": f"{self.team_id}.{self.bundle_id}",
            "com.apple.developer.team-identifier": self.team_id,
            "get-task-allow": method == "debugging",
        }
        profile = {
            "UUID": "8f40aafd-bd69-4851-88fd-763e6a5e34d5",
            "Name": "Camellia Remote Test",
            "TeamIdentifier": [self.team_id],
            "Entitlements": entitlements,
            "ExpirationDate": self.now + timedelta(days=30),
            "DeveloperCertificates": [self.certificate],
        }
        if method in {"release-testing", "debugging"}:
            profile["ProvisionedDevices"] = ["test-device"]
        if method == "enterprise":
            profile["ProvisionsAllDevices"] = True
        return profile

    def validate(self, method: str, profile: dict | None = None) -> dict[str, str]:
        return ios_profile.validate_profile(
            profile or self.profile(method),
            bundle_id=self.bundle_id,
            team_id=self.team_id,
            export_method=method,
            certificate_sha256=self.certificate_sha256,
            now=self.now,
        )

    def test_accepts_each_supported_profile_type(self) -> None:
        for method in sorted(ios_profile.EXPORT_METHODS):
            with self.subTest(method=method):
                result = self.validate(method)
                self.assertEqual(
                    result["profile_uuid"], "8F40AAFD-BD69-4851-88FD-763E6A5E34D5"
                )

    def test_rejects_profile_type_mismatch(self) -> None:
        with self.assertRaisesRegex(ValueError, "profile type"):
            self.validate("app-store-connect", self.profile("debugging"))

    def test_rejects_expired_profile(self) -> None:
        profile = self.profile("app-store-connect")
        profile["ExpirationDate"] = self.now - timedelta(seconds=1)
        with self.assertRaisesRegex(ValueError, "expired"):
            self.validate("app-store-connect", profile)

    def test_rejects_wrong_bundle_and_certificate(self) -> None:
        profile = self.profile("app-store-connect")
        profile["Entitlements"]["application-identifier"] = f"{self.team_id}.invalid"
        with self.assertRaisesRegex(ValueError, "application-identifier"):
            self.validate("app-store-connect", profile)
        with self.assertRaisesRegex(ValueError, "not authorized"):
            ios_profile.validate_profile(
                self.profile("app-store-connect"),
                bundle_id=self.bundle_id,
                team_id=self.team_id,
                export_method="app-store-connect",
                certificate_sha256="A" * 64,
                now=self.now,
            )

    def test_writes_manual_export_options_and_environment(self) -> None:
        profile = self.validate("app-store-connect")
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            options_path = root / "ExportOptions.plist"
            environment_path = root / "profile.env"
            ios_profile.write_export_configuration(
                output=options_path,
                environment_output=environment_path,
                profile=profile,
                bundle_id=self.bundle_id,
                team_id=self.team_id,
                export_method="app-store-connect",
                signing_identity="Apple Distribution: Camellia Computing (A1B2C3D4E5)",
            )
            options = plistlib.loads(options_path.read_bytes())
            self.assertEqual(options["method"], "app-store-connect")
            self.assertEqual(options["signingStyle"], "manual")
            self.assertEqual(
                options["provisioningProfiles"][self.bundle_id],
                profile["profile_uuid"],
            )
            environment = environment_path.read_text(encoding="utf-8")
            self.assertIn(f"IOS_PROFILE_UUID={profile['profile_uuid']}\n", environment)
            self.assertIn(
                f"IOS_SIGNING_IDENTITY_SHA256={self.certificate_sha256}\n",
                environment,
            )

    def test_validates_signed_app_entitlements(self) -> None:
        info = {"CFBundleIdentifier": self.bundle_id}
        entitlements = {
            "application-identifier": f"{self.team_id}.{self.bundle_id}",
            "com.apple.developer.team-identifier": self.team_id,
            "get-task-allow": False,
        }
        ios_profile.validate_signed_app(
            info,
            entitlements,
            bundle_id=self.bundle_id,
            team_id=self.team_id,
            export_method="app-store-connect",
        )
        entitlements["get-task-allow"] = True
        with self.assertRaisesRegex(ValueError, "get-task-allow"):
            ios_profile.validate_signed_app(
                info,
                entitlements,
                bundle_id=self.bundle_id,
                team_id=self.team_id,
                export_method="app-store-connect",
            )


if __name__ == "__main__":
    unittest.main()
