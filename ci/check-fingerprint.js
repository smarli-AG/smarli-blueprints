#!/usr/bin/env node
//
// check-fingerprint.js — did a settings fingerprint change without a new version?
//
// Called by ci/check-release.sh for every changed blueprint that exists on main:
//
//   node ci/check-fingerprint.js <file on main> <file now>
//
// WHY
//
//   A blueprint may hash its settings into a variable `schedule_fingerprint`
//   whose value starts with a version prefix, e.g. 'fp1:' (cover_DayNight.yaml,
//   see docs/cover-architecture.md). A stored fingerprint of another version is
//   accepted as matching, so a release never re-commands the fleet. That only
//   works if the version changes whenever the hash would change for an
//   UNEDITED automation: when the list of hashed variables changes, or when
//   the default of a hashed input changes. Forgetting the bump moves every
//   cover on that default at the moment the update lands.
//
// Same line-based approach and fixed indentation as check-blueprints.js
// (variables at 2 spaces, inputs at 8, input fields at 10). No dependencies.
//
// Exit 0: no fingerprint, unchanged, or a higher version. Exit 1: needs a bump.

'use strict';
const fs = require('fs');

const VAR = 'schedule_fingerprint';
const indentOf = (l) => l.match(/^ */)[0].length;

function extract(text) {
  const lines = text.replace(/\r/g, '').split('\n');
  const start = lines.findIndex((l) => l.startsWith(`  ${VAR}:`));
  if (start < 0) return null;
  let end = start + 1;
  while (end < lines.length && (lines[end].trim() === '' || indentOf(lines[end]) > 2)) end++;
  const block = lines.slice(start + 1, end).map((l) => l.trim()).filter((l) => l && !l.startsWith('#'));
  const version = (block.join(' ').match(/'(fp(\d+)):'/) || [])[2];

  // Variable -> input it is read from (`  name: !input input_name`).
  const source = {};
  for (const l of lines) {
    const m = l.match(/^ {2}(\w+): !input (\w+)\s*$/);
    if (m) source[m[1]] = m[2];
  }
  const listed = [...block.join(' ').matchAll(/'\w+':\s*([a-z_]\w*)/g)].map((m) => m[1]);

  // The `default:` of every input, as text: the line plus any deeper lines.
  const defaults = {};
  for (let i = 0; i < lines.length; i++) {
    const k = lines[i].match(/^ {8}(\w+):\s*(#.*)?$/);
    if (!k) continue;
    let j = i + 1;
    while (j < lines.length && (lines[j].trim() === '' || indentOf(lines[j]) > 8)) {
      if (indentOf(lines[j]) === 10 && /^\s*default:/.test(lines[j])) {
        const d = [lines[j].trim()];
        for (let n = j + 1; n < lines.length && (lines[n].trim() === '' || indentOf(lines[n]) > 10); n++) {
          if (lines[n].trim()) d.push(lines[n].trim());
        }
        defaults[k[1]] = d.join(' ');
      }
      j++;
    }
  }
  const listedDefaults = Object.fromEntries(listed.map((v) => [v, defaults[source[v]] ?? '(no default)']));
  return { version: version === undefined ? null : Number(version), block: block.join('\n'), listed, listedDefaults };
}

const [baseFile, newFile] = process.argv.slice(2);
const base = extract(fs.readFileSync(baseFile, 'utf8'));
const now = extract(fs.readFileSync(newFile, 'utf8'));

if (!now) process.exit(0);
if (now.version === null) {
  console.log(`${VAR} has no 'fpN:' version prefix`);
  process.exit(1);
}
if (!base) process.exit(0); // introduced in this change: nothing on main to compare with

const reasons = [];
if (base.block.replace(/'fp\d+:'/, '') !== now.block.replace(/'fp\d+:'/, '')) reasons.push('the hashed list changed');
for (const v of new Set([...base.listed, ...now.listed])) {
  if (base.listed.includes(v) && now.listed.includes(v) && base.listedDefaults[v] !== now.listedDefaults[v]) {
    reasons.push(`the default of "${v}" changed`);
  }
}
if (reasons.length === 0) process.exit(0);
if (base.version !== null && now.version > base.version) process.exit(0);

console.log(`${VAR}: ${reasons.join('; ')}, but the version is still fp${now.version}` +
  ` (main: fp${base.version}). Bump it to fp${(base.version ?? 0) + 1} — see docs/cover-architecture.md.`);
process.exit(1);
