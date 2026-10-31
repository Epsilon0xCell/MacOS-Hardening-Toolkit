"""Static and stub tests for the two generated scripts.

This host is Linux and neither script is run here: both re-run
themselves with sudo and change system state. What is verified is
bash syntax, the two fixed deviations from the privacy.sexy export
(the Gatekeeper version gate and the quarantine attribute loop),
checked by extracting the actual lines from security_enable.sh and
running them against stubbed inputs, plus the generator headers.
Real behavior on macOS is not claimed anywhere in this suite.
"""
import os
import re
import subprocess
import tempfile
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
PRIVACY = ROOT / "privacy-script.sh"
SECURITY = ROOT / "security_enable.sh"


def read(path):
    return path.read_text(encoding="utf-8", errors="replace")


class SyntaxAndHeaderTest(unittest.TestCase):
    def test_bash_syntax_both_scripts(self):
        for script in (PRIVACY, SECURITY):
            result = subprocess.run(["bash", "-n", str(script)], capture_output=True, text=True)
            self.assertEqual(result.returncode, 0, f"{script.name}: {result.stderr}")

    def test_generator_headers_present(self):
        self.assertIn("privacy.sexy - v0.13.7", read(PRIVACY).splitlines()[1])
        self.assertIn("privacy.sexy - v0.13.7", read(SECURITY).splitlines()[1])


class GatekeeperGateTest(unittest.TestCase):
    """Run the gate condition extracted from the file itself."""

    def condition(self):
        lines = read(SECURITY).splitlines()
        start = next(i for i, line in enumerate(lines) if line.startswith("if [[ $os_major_ver"))
        collected = []
        for line in lines[start:]:
            collected.append(line)
            if line.rstrip().endswith("]]; then"):
                break
        text = "\n".join(collected)
        text = text.replace("if [[", "").replace("]]; then", "").replace("\\\n", " ")
        return text.strip()

    def gate_says_unavailable(self, major, minor):
        cond = self.condition()
        script = (
            f"os_major_ver={major}\n"
            f"os_minor_ver={minor}\n"
            f"if [[ {cond} ]]; then echo unavailable; else echo run; fi\n"
        )
        result = subprocess.run(["bash", "-c", script], capture_output=True, text=True)
        self.assertEqual(result.returncode, 0, result.stderr)
        return result.stdout.strip() == "unavailable"

    def test_redundant_le_clause_is_gone(self):
        self.assertIn("$os_major_ver -lt 10", self.condition())
        self.assertNotIn("-le 10", self.condition())

    def test_versions_below_10_7_skip(self):
        self.assertTrue(self.gate_says_unavailable(9, 0))
        self.assertTrue(self.gate_says_unavailable(10, 6))

    def test_versions_from_10_7_run(self):
        self.assertFalse(self.gate_says_unavailable(10, 7))
        self.assertFalse(self.gate_says_unavailable(10, 15))
        self.assertFalse(self.gate_says_unavailable(11, 0))
        self.assertFalse(self.gate_says_unavailable(14, 2))


class QuarantineLoopTest(unittest.TestCase):
    """Run the find block extracted from the file against a stub xattr."""

    def extract_block(self):
        lines = read(SECURITY).splitlines()
        start = next(i for i, line in enumerate(lines) if line.startswith("find ~/Downloads"))
        collected = []
        for line in lines[start:]:
            collected.append(line)
            if line.rstrip().endswith("\\;"):
                break
        return "\n".join(collected) + "\n"

    def test_placeholder_quoting_is_gone(self):
        text = read(SECURITY)
        self.assertNotIn('file="{}"', text)
        self.assertIn('file="$1"', text)

    def test_quote_named_file_is_processed(self):
        with tempfile.TemporaryDirectory() as tmp:
            home = Path(tmp) / "home"
            downloads = home / "Downloads"
            downloads.mkdir(parents=True)
            (downloads / "normal.txt").write_text("x")
            (downloads / 'we"ird.txt').write_text("x")
            bindir = Path(tmp) / "bin"
            bindir.mkdir()
            log = Path(tmp) / "xattr.log"
            # The inner script uses [[ ]], which macOS sh accepts and
            # this host dash does not, so sh is pointed at bash here.
            # That is a host difference in the test rig, stated plainly.
            shim = bindir / "sh"
            shim.write_text('#!/bin/sh\nexec bash "$@"\n')
            shim.chmod(0o755)
            stub = bindir / "xattr"
            stub.write_text(
                '#!/bin/sh\n'
                'if [ "$1" = "-d" ]; then echo "deleted:$3" >> "$XATTR_LOG"; '
                'else echo "com.apple.quarantine"; fi\n'
            )
            stub.chmod(0o755)
            script = Path(tmp) / "block.sh"
            script.write_text(self.extract_block())
            env = dict(os.environ)
            env["HOME"] = str(home)
            env["PATH"] = f"{bindir}:{env['PATH']}"
            env["XATTR_LOG"] = str(log)
            result = subprocess.run(
                ["bash", str(script)], capture_output=True, text=True, env=env, timeout=20
            )
            self.assertEqual(result.returncode, 0, result.stderr)
            deleted = log.read_text() if log.exists() else ""
            self.assertIn("deleted:", deleted)
            self.assertIn("normal.txt", deleted)
            self.assertIn('we"ird.txt', deleted)


if __name__ == "__main__":
    unittest.main()
