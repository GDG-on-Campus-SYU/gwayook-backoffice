import assert from 'node:assert/strict';
import test from 'node:test';
import { selectTests } from './test-sql.mjs';

test('SQL selection uses only known top-level test filenames', () => {
  const available = ['voting.sql', 'privacy_controls.sql'];
  assert.deepEqual(selectTests([], available), ['privacy_controls.sql', 'voting.sql']);
  assert.deepEqual(selectTests(['voting.sql', 'voting.sql'], available), ['voting.sql']);
  for (const name of ['../fixtures/privacy-bootstrap.sql', '/tmp/test.sql', 'missing.sql', '--help', 'voting.sql;exit', 'voting.sql\n']) {
    assert.throws(() => selectTests([name], available), /Unknown SQL test/);
  }
  assert.throws(() => selectTests([], []), /No SQL tests/);
});
