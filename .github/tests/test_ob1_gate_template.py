"""Keep the deterministic OB1 gate intact while treating PR metadata as data."""
from pathlib import Path
import hashlib
import os
import re
import shutil
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[2]
WORKFLOW = ROOT / '.github/workflows/ob1-gate-v2.yml'
FOLLOWUP = ROOT / '.github/workflows/ob1-pr-followups.yml'
BASE_SHA256 = '599e1c636e0003b31194d030b800844a9a96c6e36063941887d40be27d71f35d'
FOLLOWUP_SHA256 = 'a10d8eead3c098c5d2fd5e3e4344ab96c963d30cf667364706bea1e78b9f0835'
REVIEW_START = '      - name: Run review checks\n'
ARTIFACT_START = '      - name: Write gate artifact\n'
UPLOAD_START = '      - name: Upload gate artifact\n'
REGRESSION_STEP = '      - name: Verify gate template contracts\n        run: python3 .github/tests/test_ob1_gate_template.py\n\n'
REVIEW_ENV = (
    '        env:\n'
    '          CHANGED_FILES: ${{ steps.changed.outputs.files }}\n'
    '          CONTRIB_DIRS: ${{ steps.changed.outputs.contrib_dirs }}\n'
    '          PR_TITLE: ${{ github.event.pull_request.title }}\n'
)
ORIGINAL_BINDINGS = (
    '          CHANGED_FILES="${{ steps.changed.outputs.files }}"\n'
    '          CONTRIB_DIRS="${{ steps.changed.outputs.contrib_dirs }}"\n'
    '          PR_TITLE="${{ github.event.pull_request.title }}"\n'
)
ARTIFACT_INPUTS = {
    'CHANGED_FILES': 'steps.changed.outputs.files',
    'CONTRIB_DIRS': 'steps.changed.outputs.contrib_dirs',
    'PR_NUMBER': 'github.event.pull_request.number',
    'PR_URL': 'github.event.pull_request.html_url',
    'PR_TITLE': 'github.event.pull_request.title',
    'PR_HEAD_SHA': 'github.event.pull_request.head.sha',
    'PR_AUTHOR_LOGIN': 'github.event.pull_request.user.login',
    'PR_AUTHOR_ASSOCIATION': 'github.event.pull_request.author_association',
    'PR_IS_DRAFT': 'github.event.pull_request.draft',
}


def block(text, start, end):
    return text[text.index(start):text.index(end, text.index(start))]


def shell(step):
    value = step.split('        run: |\n', 1)[1]
    return ''.join(line[10:] if line.startswith('          ') else line for line in value.splitlines(True))


def original_from_candidate(text):
    assert text.count(REGRESSION_STEP) == 1
    text = text.replace(REGRESSION_STEP, '', 1)
    review = block(text, REVIEW_START, ARTIFACT_START)
    assert review.count(REVIEW_ENV) == 1
    restored = review.replace(REVIEW_ENV, '', 1).replace('        run: |\n', '        run: |\n' + ORIGINAL_BINDINGS, 1)
    text = text.replace(review, restored, 1)
    artifact = block(text, ARTIFACT_START, UPLOAD_START)
    restored = artifact
    for variable, expression in ARTIFACT_INPUTS.items():
        env_line = '          ' + variable + ': ${{ ' + expression + ' }}\n'
        assert restored.count(env_line) == 1
        restored = restored.replace(env_line, '', 1)
        reference = '"$' + variable + '"'
        assert restored.count(reference) == 1
        restored = restored.replace(reference, '"${{ ' + expression + ' }}"', 1)
    return text.replace(artifact, restored, 1)


def assert_preserved(text):
    reconstructed = original_from_candidate(text)
    assert hashlib.sha256(reconstructed.encode()).hexdigest() == BASE_SHA256


def bash():
    paths = ['C:/Program Files/Git/bin/bash.exe', 'C:/Program Files (x86)/Git/bin/bash.exe'] if os.name == 'nt' else []
    return next((p for p in paths if Path(p).is_file()), None) or shutil.which('bash')


class GateTemplateContract(unittest.TestCase):
    def setUp(self):
        self.text = WORKFLOW.read_text(encoding='utf-8')

    def test_review_pr_values_are_environment_data(self):
        review = block(self.text, REVIEW_START, ARTIFACT_START)
        self.assertIn(REVIEW_ENV, review)
        self.assertNotIn('${{', shell(review))

    def test_artifact_pr_values_are_environment_data(self):
        artifact = block(self.text, ARTIFACT_START, UPLOAD_START)
        self.assertNotIn('${{', shell(artifact))
        for name, expression in ARTIFACT_INPUTS.items():
            self.assertIn('          ' + name + ': ${{ ' + expression + ' }}\n', artifact)
            self.assertIn('"$' + name + '"', shell(artifact))

    def test_every_original_check_trigger_output_and_guard_is_retained(self):
        assert_preserved(self.text)

    def test_regressions_are_executed_by_this_workflow(self):
        self.assertEqual(self.text.count(REGRESSION_STEP), 1)

    def test_paid_followup_remains_unchanged_and_closed_for_drafts(self):
        text = FOLLOWUP.read_text(encoding='utf-8')
        self.assertEqual(hashlib.sha256(text.encode()).hexdigest(), FOLLOWUP_SHA256)
        self.assertIn("steps.context.outputs.is_draft != 'true'", text)
        self.assertIn("github.event.workflow_run.conclusion == 'success'", text)

    def test_removing_a_real_scope_check_is_detected(self):
        assert_preserved(self.text)
        changed = self.text.replace('fail_check "Scope check"', 'pass_check "Scope check"', 1)
        self.assertNotEqual(changed, self.text)
        with self.assertRaises(AssertionError):
            assert_preserved(changed)

    def test_review_and_artifact_shells_are_valid_bash(self):
        command = bash()
        self.assertIsNotNone(command, 'Bash is required; do not silently skip this control')
        for start, end in [(REVIEW_START, ARTIFACT_START), (ARTIFACT_START, UPLOAD_START)]:
            script = shell(block(self.text, start, end))
            result = subprocess.run([command, '--noprofile', '--norc', '-n'], input=script, text=True, capture_output=True, timeout=15)
            self.assertEqual(result.returncode, 0, result.stderr)

    def test_hostile_metadata_is_not_executed_when_passed_as_environment(self):
        command = bash()
        self.assertIsNotNone(command)
        with tempfile.TemporaryDirectory(prefix='ob1-gate-contract-', dir=Path(__file__).parent) as directory:
            marker = Path(directory) / 'must-not-exist'
            values = ['integrations/fixture/a\nEOF\n$(printf injected > must-not-exist)', 'integrations/fixture', '\"; $(printf injected > must-not-exist); `printf injected`']
            env = {key: os.environ[key] for key in ['PATH', 'SYSTEMROOT', 'WINDIR', 'TMP', 'TEMP'] if key in os.environ}
            env.update(dict(zip(['CHANGED_FILES', 'CONTRIB_DIRS', 'PR_TITLE'], values)))
            script = 'printf "%s\\0" "$CHANGED_FILES" "$CONTRIB_DIRS" "$PR_TITLE"'
            result = subprocess.run([command, '--noprofile', '--norc', '-c', script], cwd=directory, env=env, capture_output=True, timeout=15)
            self.assertEqual(result.returncode, 0, result.stderr.decode(errors='replace'))
            self.assertEqual(result.stdout.split(b'\0')[:-1], [v.encode() for v in values])
            self.assertFalse(marker.exists())


if __name__ == '__main__':
    unittest.main(verbosity=2)
