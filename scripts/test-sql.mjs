import { readdirSync } from 'node:fs';
import { spawnSync } from 'node:child_process';
import { dirname, join, resolve } from 'node:path';
import { fileURLToPath } from 'node:url';

const root = dirname(dirname(fileURLToPath(import.meta.url)));
// Supabase PostgreSQL 17.11.0.018; keep SQL runtime reproducible across local and CI.
const image = 'public.ecr.aws/supabase/postgres@sha256:7c31363a3f7434ff14945f1b8a4880e6eca8b362e197e88b87c476c77aa3cf8c';

export function selectTests(requested, available) {
  const names = requested.length ? requested : available;
  for (const name of names) {
    if (!/^[a-z][a-z0-9_]*\.sql$/.test(name) || !available.includes(name)) {
      throw new Error(`Unknown SQL test: ${name}`);
    }
  }
  if (!names.length) throw new Error('No SQL tests found');
  return [...new Set(names)].sort();
}

if (process.argv[1] && resolve(process.argv[1]) === fileURLToPath(import.meta.url)) {
  try {
    const tests = selectTests(process.argv.slice(2), readdirSync(join(root, 'supabase/tests')).filter(name => name.endsWith('.sql')));
    const result = spawnSync('docker', [
      'run', '--rm', '--network', 'none', '--read-only', '--user', '100:101',
      '--cap-drop', 'ALL', '--security-opt', 'no-new-privileges',
      '--cpus', '1', '--memory', '1g', '--pids-limit', '128',
      '--ulimit', 'nofile=1024:1024', '--ulimit', 'fsize=268435456:268435456',
      '--tmpfs', '/scratch:rw,nosuid,uid=100,gid=101,size=768m',
      '--mount', `type=bind,source=${join(root, 'supabase')},target=/source,readonly`,
      '--mount', `type=bind,source=${join(root, 'scripts/test-sql.sh')},target=/run-tests.sh,readonly`,
      '--entrypoint', '/usr/bin/env', image,
      '-i', 'PATH=/nix/var/nix/profiles/default/bin:/usr/bin:/bin',
      'HOME=/scratch/home', 'TMPDIR=/scratch/tmp', 'LANG=C.UTF-8',
      'timeout', '-k', '5', '300', 'sh', '/run-tests.sh', ...tests,
    ], { stdio: 'inherit', windowsHide: true });
    if (result.error) throw result.error;
    process.exitCode = result.status ?? 1;
  } catch (error) {
    console.error(error.message);
    process.exitCode = 1;
  }
}
