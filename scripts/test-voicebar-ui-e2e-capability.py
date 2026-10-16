#!/usr/bin/env python3
"""Source-only build guards; never invokes Swift, codesign, apps or lifecycle helpers."""
import os
import pathlib
import plistlib
import subprocess
import sys
import tempfile
import unittest


BUILD = pathlib.Path(__file__).resolve().parent.parent / 'flow-bar/build-app.sh'
RUNNER = BUILD.parent.parent / 'scripts/voicebar-ui-e2e.sh'


class PasteFeedbackMetadataTests(unittest.TestCase):
    """Execute only the runner's embedded metadata writer, never the shell runner."""

    old_outcomes = '''private enum VoicePasteOutcome: Equatable {
        case insertedAtCursor
        case pasted
        case failed(String)
    }
    '''
    feedback_outcomes = old_outcomes.replace('case failed(String)', '''case notInserted
        case unverified
        case partial
        case failed(String)''')
    old_copy = 'Partially inserted — full transcript kept in History.'
    p1e_copy = '''enum PasteRecoveryFeedback {
        static let notInserted = "Not pasted\\nIn History"
        static let unverified = "Unverified\\nIn History"
        static let partial = "Part pasted\\nHistory: full"
    }
    '''

    def metadata(self, state, presentation=''):
        block = RUNNER.read_text().split("<<'PYMETA'\n", 1)[1].split('\nPYMETA', 1)[0]
        with tempfile.TemporaryDirectory() as temp:
            repo = pathlib.Path(temp)
            ui = repo / 'flow-bar/Sources/VoiceBarUI'
            ui.mkdir(parents=True)
            (ui / 'VoiceState.swift').write_text(state)
            (ui / 'VoiceBarPresentation.swift').write_text(presentation)
            app = repo / 'VoiceBarQA.app'
            plist = app / 'Contents/Info.plist'
            plist.parent.mkdir(parents=True)
            original = {'VoiceBarUIE2EOnly': True,
                        'CFBundleIdentifier': 'com.voicelayer.voicebar.uie2e',
                        'UnrelatedMetadata': 'preserve me'}
            plist.write_bytes(plistlib.dumps(original))
            result = subprocess.run([sys.executable, '-', str(repo), str(app)], input=block,
                                    capture_output=True, text=True)
            self.assertEqual(result.returncode, 0, result.stderr)
            metadata = plistlib.loads(plist.read_bytes())
            self.assertEqual({key: metadata[key] for key in original}, original)
            return metadata['UIE2EPasteFeedback']

    def test_old_build_has_no_paste_feedback(self):
        self.assertIs(self.metadata(self.old_outcomes), False)

    def test_338_old_copy_has_paste_feedback(self):
        self.assertIs(self.metadata(self.feedback_outcomes + '\nlet copy = "' + self.old_copy + '"'), True)

    def test_p1e_enum_copy_has_paste_feedback(self):
        state = self.feedback_outcomes + '''
        func feedback() { showConfirmation(PasteRecoveryFeedback.partial, duration: 5.0) }
        '''
        self.assertIs(self.metadata(state, self.p1e_copy), True)

    def test_copy_changes_do_not_disable_outcome_capability(self):
        self.assertIs(self.metadata(self.feedback_outcomes), True)

    def test_comments_and_strings_cannot_supply_outcome_capability(self):
        decoy = self.feedback_outcomes + '\n' + self.old_copy
        for mention in ['// ' + decoy.replace('\n', '\n// '),
                        '/* ' + decoy + ' */',
                        'let example = """\n' + decoy + '\n"""',
                        'let example = "' + decoy.replace('\n', '\\n') + '"']:
            with self.subTest(mention=mention):
                self.assertIs(self.metadata(self.old_outcomes + '\n' + mention), False)

    def test_unrelated_enum_and_each_missing_outcome_are_unavailable(self):
        self.assertIs(self.metadata(self.old_outcomes + self.feedback_outcomes.replace(
            'VoicePasteOutcome', 'UnrelatedOutcome')), False)
        for name in ['notInserted', 'unverified', 'partial']:
            with self.subTest(missing=name):
                source = self.feedback_outcomes.replace('case ' + name, '// case ' + name)
                self.assertIs(self.metadata(source), False)

    def test_presentation_enum_alone_is_not_product_outcome_capability(self):
        self.assertIs(self.metadata(self.old_outcomes, self.p1e_copy), False)


class CapabilityTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.package = pathlib.Path(self.temp.name)
        self.ui = self.package / 'Sources/VoiceBarUI'
        self.ui.mkdir(parents=True)
        (self.ui / 'VoiceState.swift').write_text('public var showsSelectionBusyNote = false\n'
                                                'public enum SelectionReadFailure { case copyTimedOut }\n')
        (self.ui / 'VoiceBarPresentation.swift').write_text('public enum SelectionBusyReason: String { case busy }\n')

    def flags(self, **overrides):
        env = dict(os.environ, VOICEBAR_BUILD_APP_SOURCE_ONLY='1', VOICEBAR_QA_BUILD='0',
                   VOICEBAR_UIE2E_FOCUSED_338='0', VOICEBAR_REQUIRE_NOTARIZATION='0', VOICEBAR_RELEASE_ZIP='')
        env.update(overrides)
        return subprocess.run(['bash', '-c', 'source "$1"; PACKAGE_DIR=$2; configure_qa_swift_flags; '
                               'printf "%s\n" ${QA_SWIFT_FLAGS[@]+"${QA_SWIFT_FLAGS[@]}"}',
                               'guard-test', str(BUILD), str(self.package)],
                              capture_output=True, text=True, env=env)

    def test_default_full_needs_no_future_product_apis(self):
        (self.ui / 'VoiceState.swift').write_text('')
        result = self.flags(VOICEBAR_QA_BUILD='1')
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn('-DVOICEBAR_QA', result.stdout)
        self.assertNotIn('-DVOICEBAR_UIE2E_FOCUSED_338', result.stdout)

    def test_normal_release_flags_exclude_all_qa_defines(self):
        result = self.flags()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertNotIn('-DVOICEBAR_QA', result.stdout)
        self.assertNotIn('-DVOICEBAR_UIE2E_FOCUSED_338', result.stdout)

    def test_comments_and_string_mentions_cannot_supply_missing_product_apis(self):
        (self.ui / 'VoiceState.swift').write_text('// public var showsSelectionBusyNote = false\n'
                                                'let note = "var showsSelectionBusyNote"\n'
                                                '/* var showsSelectionBusyNote = false */\n'
                                                'enum Failure { case copyTimedOut }\n')
        result = self.flags(VOICEBAR_QA_BUILD='1', VOICEBAR_UIE2E_FOCUSED_338='1')
        self.assertNotEqual(result.returncode, 0)
        self.assertIn('showsSelectionBusyNote', result.stderr)

    def test_focused_compilation_adds_both_flags_only_with_qa(self):
        result = self.flags(VOICEBAR_QA_BUILD='1', VOICEBAR_UIE2E_FOCUSED_338='1')
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn('-DVOICEBAR_QA', result.stdout)
        self.assertIn('-DVOICEBAR_UIE2E_FOCUSED_338', result.stdout)
        result = self.flags(VOICEBAR_UIE2E_FOCUSED_338='1')
        self.assertNotEqual(result.returncode, 0)
        self.assertIn('requires VOICEBAR_QA_BUILD=1', result.stderr)

    def test_missing_each_product_api_refuses_focused_build(self):
        for filename, symbol in [('VoiceState.swift', 'showsSelectionBusyNote'),
                                 ('VoiceState.swift', 'copyTimedOut'),
                                 ('VoiceBarPresentation.swift', 'SelectionBusyReason')]:
            with self.subTest(symbol=symbol):
                path = self.ui / filename
                original = path.read_text()
                path.write_text(original.replace(symbol, 'unavailable'))
                result = self.flags(VOICEBAR_QA_BUILD='1', VOICEBAR_UIE2E_FOCUSED_338='1')
                path.write_text(original)
                self.assertNotEqual(result.returncode, 0)
                self.assertIn(symbol, result.stderr)

    def test_release_and_invalid_flags_refuse_before_any_build(self):
        for overrides, message in [(dict(VOICEBAR_REQUIRE_NOTARIZATION='1'), 'notarized release'),
                                   (dict(VOICEBAR_RELEASE_ZIP='/tmp/never.zip'), 'notarized release'),
                                   (dict(VOICEBAR_UIE2E_FOCUSED_338='yes'), 'must be 0 or 1')]:
            with self.subTest(overrides=overrides):
                result = self.flags(**dict(dict(VOICEBAR_QA_BUILD='1', VOICEBAR_UIE2E_FOCUSED_338='1'), **overrides))
                self.assertNotEqual(result.returncode, 0)
                self.assertIn(message, result.stderr)


if __name__ == '__main__':
    unittest.main()
