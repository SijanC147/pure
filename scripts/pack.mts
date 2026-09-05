import {copyFileSync, mkdirSync, mkdtempSync, readFileSync, rmSync, writeFileSync} from 'node:fs';
import {tmpdir} from 'node:os';
import {dirname, join, resolve} from 'node:path';
import {fileURLToPath} from 'node:url';
import {spawnSync} from 'node:child_process';

/** Pack regular autoload files in an isolated tree, preserving checkout links. */
const main = (): void => {
	const args = process.argv.slice(2);
	if (args.length !== 0 && (args.length !== 2 || args[0] !== '--pack-destination')) {
		throw new Error('Usage: npm run package:pack -- [--pack-destination DIRECTORY]');
	}
	const root = resolve(dirname(fileURLToPath(import.meta.url)), '..');
	const destination = resolve(args[1] ?? process.cwd());
	mkdirSync(destination, {recursive: true});
	const stage = mkdtempSync(join(tmpdir(), 'pure-pack-'));
	try {
		const manifest = JSON.parse(readFileSync(join(root, 'package.json'), 'utf8'));
		// Development entrypoints are not part of the installed package contract.
		for (const name of Object.keys(manifest.scripts)) {
			if (name === 'prepack' || name === 'postpack' || name === 'package:pack' || name.startsWith('test')) {
				delete manifest.scripts[name];
			}
		}
		writeFileSync(join(stage, 'package.json'), `${JSON.stringify(manifest, null, '\t')}\n`);
		for (const name of ['pure.zsh', 'async.zsh', 'readme.md', 'license']) {
			copyFileSync(join(root, name), join(stage, name));
		}
		copyFileSync(join(root, 'pure.zsh'), join(stage, 'prompt_pure_setup'));
		copyFileSync(join(root, 'async.zsh'), join(stage, 'async'));
		const result = spawnSync('npm', ['pack', '--ignore-scripts', '--pack-destination', destination], {
			cwd: stage,
			stdio: 'inherit',
		});
		if (result.error) throw result.error;
		if (result.status !== 0) throw new Error(`npm pack exited with ${result.status}`);
	} finally {
		// This invocation created the directory; it contains only staged copies.
		rmSync(stage, {recursive: true, force: true});
	}
};

main();
