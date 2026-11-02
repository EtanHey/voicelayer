import unittest

from tlc_result import valid_result


class TlcResultTests(unittest.TestCase):
    config = 'SPECIFICATION Spec\nPROPERTY CancellationFinishes\n'

    def test_legacy_unnamed_temporal_counterexample(self):
        self.assertTrue(valid_result(13, 'Temporal properties were violated.', 'CancellationFinishes', self.config))

    def test_nightly_named_temporal_counterexample(self):
        self.assertTrue(valid_result(13, 'Temporal property CancellationFinishes was violated.', 'CancellationFinishes', self.config))

    def test_named_temporal_mismatch_is_rejected_even_with_legacy_summary(self):
        text = 'Temporal property AnotherProperty was violated.\nTemporal properties were violated.'
        self.assertFalse(valid_result(13, text, 'CancellationFinishes', self.config))

    def test_mixed_named_temporal_properties_are_rejected(self):
        text = 'Temporal property CancellationFinishes was violated.\nTemporal property AnotherProperty was violated.'
        self.assertFalse(valid_result(13, text, 'CancellationFinishes', self.config))

    def test_legacy_temporal_requires_exactly_the_expected_config_property(self):
        for config in ['PROPERTY AnotherProperty\n', self.config + 'PROPERTY AnotherProperty\n']:
            with self.subTest(config=config):
                self.assertFalse(valid_result(13, 'Temporal properties were violated.', 'CancellationFinishes', config))

    def test_named_temporal_requires_the_expected_config_property(self):
        self.assertFalse(valid_result(13, 'Temporal property CancellationFinishes was violated.', 'CancellationFinishes', 'PROPERTY AnotherProperty\n'))

    def test_action_property_counterexample(self):
        self.assertTrue(valid_result(13, 'Action property ReadySelectionIsNoop is violated', 'ReadySelectionIsNoop', 'PROPERTY ReadySelectionIsNoop\n'))

    def test_wrong_action_property_is_rejected(self):
        self.assertFalse(valid_result(13, 'Action property AnotherProperty is violated\nTemporal properties were violated.', 'CancellationFinishes', self.config))

    def test_invariant_counterexample(self):
        self.assertTrue(valid_result(12, 'Invariant OneModel is violated', 'OneModel', 'INVARIANT OneModel\n'))

    def test_wrong_invariant_is_rejected(self):
        self.assertFalse(valid_result(12, 'Invariant AnotherInvariant is violated', 'OneModel', 'INVARIANT OneModel\n'))

    def test_errors_and_passing_mutants_are_rejected(self):
        for code in [0, 1, 124, 255]:
            with self.subTest(code=code):
                self.assertFalse(valid_result(code, 'Temporal property CancellationFinishes was violated.', 'CancellationFinishes', self.config))

    def test_fixed_success_requires_the_tlc_success_marker(self):
        self.assertTrue(valid_result(0, 'No error has been found.', None, self.config))
        self.assertFalse(valid_result(0, 'Parsing error', None, self.config))


if __name__ == '__main__':
    unittest.main()
