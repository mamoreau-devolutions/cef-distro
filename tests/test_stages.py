import sys
from pathlib import Path
import unittest

sys.path.insert(0, str(Path(__file__).resolve().parent.parent / "scripts"))
import stages  # noqa: E402


class StagesTest(unittest.TestCase):
    def test_generated_workflow_is_current(self):
        self.assertEqual(stages.WORKFLOW.read_text(encoding="utf-8"), stages.render(),
                         "Run python scripts/stages.py to regenerate build-target.yml")


if __name__ == "__main__":
    unittest.main()
