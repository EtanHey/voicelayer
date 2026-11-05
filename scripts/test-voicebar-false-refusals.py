#!/usr/bin/env python3
"""M1 stock-default/WindowServer regressions. Synthetic inputs; never drives live UI."""
import importlib.util
import json
import pathlib
import plistlib
import unittest

ROOT = pathlib.Path(__file__).resolve().parent


def load(name):
    spec = importlib.util.spec_from_file_location(name, ROOT / (name + '.py'))
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


class PureRefusals(unittest.TestCase):
    def test_stock_bare_table_and_actual_arrow_collisions(self):
        m = load('voicebar-ui-e2e-supervisor')
        table = plistlib.dumps({'AppleSymbolicHotKeys': {str(n): {'enabled': 1} for n in range(79, 83)}})
        for keys in m.SCENARIO_KEYSTROKES.values():
            self.assertEqual(m.symbolic_hotkey_collisions(table, keys), [])
        for number, code, mods in [(79, 123, ('control',)), (80, 124, ('control',)),
                                   (81, 123, ('control', 'shift')), (82, 124, ('control', 'shift'))]:
            for extra in [(), ('function',)]:
                self.assertEqual(m.symbolic_hotkey_collisions(table, [(None, code, mods + extra)]), [number])

    def test_unknown_and_malformed_bare_records_stay_unproven(self):
        m = load('voicebar-ui-e2e-supervisor')
        for entries in [{'99': {'enabled': 1}}, {'79': {'enabled': 1, 'value': {}}}, {'79': '{ enabled = 0; }'}]:
            with self.assertRaises(m.HotkeyCollision):
                m.symbolic_hotkey_collisions(plistlib.dumps({'AppleSymbolicHotKeys': entries}), [])
        custom = {'79': {'enabled': True, 'value': {'parameters': [97, 0, 1 << 20]}}}
        self.assertEqual(m.symbolic_hotkey_collisions(plistlib.dumps({'AppleSymbolicHotKeys': custom}),
            [('a', 0, ('command',))]), [79])

    def test_refused_and_excluded_rows_are_self_describing_without_titles(self):
        m = load('voicebar-ui-e2e-supervisor')
        row = dict(owner='WindowServer', pid=412, layer=24,
                   bounds=dict(X=0, Y=0, Width=1512, Height=33), alpha=1, onscreen=True,
                   source='system-owner', title='private title never retained')
        permission = m.permission_receipt(dict(axTrusted=True, prompts=[], modals=[row],
            inventoryErrors=[], excludedModalRows=[row]))
        for key in ['modals', 'excludedModalRows']:
            saved = permission[key][0]
            for field in ['owner', 'pid', 'layer', 'bounds', 'alpha', 'onscreen']:
                self.assertEqual(saved[field], row[field])
            self.assertIn('redacted', saved['title'])
        self.assertNotIn(row['title'], json.dumps(permission))
        error = dict(row, kind='ax-windows', reason='cannot-complete')
        saved = m.permission_receipt(dict(axTrusted=True, prompts=[], modals=[], inventoryErrors=[error]))['modals'][0]
        self.assertEqual(saved['layer'], 24)
        self.assertEqual(saved['bounds'], row['bounds'])


class NativeLayerRefusals(unittest.TestCase):
    def test_real_m1_rows_and_non_system_layer_negative_controls(self):
        g = load('test-voicebar-gatecap1')
        probe = g.FAKE_SOURCE + r'''
extension Fake { func isWindowServer(_ pid: Int32) -> Bool { pid == 412 } }
func excluded(_ inv: ModalInventory) -> [[String: Any]] {
    Mirror(reflecting: inv).children.first { $0.label == "excluded" }?.value as? [[String: Any]] ?? []
}
for level in [24, 25, 102, 1000, -2147483602, -2147483626] {
    let f = Fake()
    f.rows = [CGRow(id: 38, pid: 412, owner: "Window Server", layer: level,
        bounds: CGRect(x: 0, y: 0, width: 1512, height: 33), alpha: 1, title: "")]
    f.windowsByPid[412] = .failed("cannot-complete")
    let inv = modalInventory(f, qaPids: [])
    precondition(inv.modals.isEmpty && inv.errors.isEmpty, "stock WindowServer layer \(level) refused")
    precondition(!f.reads.contains("windows:412"), "never AX-query WindowServer system layers")
    let rows = excluded(inv)
    precondition(rows.count == 1 && rows[0]["layer"] as? Int == level)
    for key in ["owner", "pid", "layer", "bounds", "alpha", "onscreen"] { precondition(rows[0][key] != nil) }
}
for level in [0, 3, 8, 19, 42, -1] {
    let f = Fake(); f.rows = [row(38, 412, "Window Server", layer: level)]
    f.windowsByPid[412] = .absent
    let inv = modalInventory(f, qaPids: [])
    precondition(!inv.modals.isEmpty || !inv.errors.isEmpty, "unsafe WindowServer layer \(level) accepted")
    precondition(excluded(inv).isEmpty)
}
let lookalike = Fake(); lookalike.rows = [row(38, 413, "Window Server", layer: 24)]
lookalike.windowsByPid[413] = .failed("cannot-complete")
let inv = modalInventory(lookalike, qaPids: [])
precondition(!inv.errors.isEmpty && excluded(inv).isEmpty, "display name is not executable identity")
precondition(inv.errors[0]["layer"] as? Int == 24 && inv.errors[0]["bounds"] != nil)
print("PASS")
'''
        self.assertEqual(g.run_swift(self, g.MODALS_PRELUDE + g.block(g.PERMISSIONS, 'FOREIGN MODALS') + probe).strip(), 'PASS')


if __name__ == '__main__':
    unittest.main()
