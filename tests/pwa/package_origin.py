"""Verify packaging binds displayed and effective API addresses to one HTTPS origin."""
import runpy
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
module = runpy.run_path(str(ROOT / 'scripts/package-pwa.py'))


class PackageOriginTests(unittest.TestCase):
    def test_custom_origin(self):
        files = {name: (module['SOURCE'] / name).read_bytes() for name in module['ASSETS']}
        original_worker = module['render_service_worker'](files)
        module['configure_api_origin'](files, 'https://api.example.org')
        self.assertIn(b'"https://api.example.org"', files['account.js'])
        self.assertEqual(files['index.html'].count(b'https://api.example.org'), 2)
        self.assertNotEqual(original_worker, module['render_service_worker'](files))

    def test_rejects_noncanonical_origins(self):
        for origin in ('http://example.org', 'https://host/path', 'https://user@host.org',
                       'https://host.org?x', "https://host.org\n", 'https://-bad.org',
                       'https://example.org:443', 'https://example.org\\@other.org'):
            with self.subTest(origin=origin), self.assertRaises(ValueError):
                module['configure_api_origin']({}, origin)


if __name__ == '__main__':
    unittest.main()
