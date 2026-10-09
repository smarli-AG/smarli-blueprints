#!/usr/bin/env node
//
// check-blueprints.js — does every blueprint follow Readme.md?
//
// Called by ci/checks.sh (group "blueprints"). Runs on its own too:
//
//   node ci/check-blueprints.js                      # every automation/*.yaml
//   node ci/check-blueprints.js automation/foo.yaml  # only those files
//
// WHY LINE-BASED AND NOT A YAML PARSER
//
//   Most rules live in YAML comments (# optional:, # display_if:,
//   # translation:, the Partner Engine block), and every YAML parser drops
//   comments. HA's !input tag also breaks standard parsers. So this reads the
//   files line by line and relies on the fixed indentation every blueprint in
//   this repo uses (blueprint: 0, input: 2, sections 4, section input: 6,
//   inputs 8, input fields 10). A file with other indentation is reported, not
//   silently skipped.
//
// No dependencies on purpose: Node alone runs it, on a laptop and in CI.
//
// Every rule below quotes the Readme.md section it enforces. If a rule and
// Readme.md disagree, Readme.md wins and this file is wrong.
//
// TEST FIXTURES
//
//   A file whose name starts with "peTestFixture_" (peTestFixture_inputs.yaml,
//   peTestFixture_minimal.yaml) is a Partner Engine test fixture. It runs through every
//   rule, like a real blueprint. It may break a rule on purpose, but only by
//   naming that rule's ID in one line above "blueprint:":
//
//     # checks: allow annotation, version
//
//   Every problem with a listed ID is then ignored; everything else still
//   fails. An ID that matches no problem fails too, so the list cannot go
//   stale. Real blueprints cannot use "allow" at all. The IDs are the second
//   argument of every fail() call below.

'use strict';
const fs = require('fs');
const path = require('path');

const ROOT = path.resolve(__dirname, '..');
const REPO_URL = 'https://github.com/smarli-AG/smarli-blueprints/blob/main/automation/';
const LAST_DESCRIPTION_LINE = 'All input fields are required unless they are marked as ` (optional) `.';
const SECTION_ORDER = ['trigger_inputs', 'condition_inputs', 'action_inputs', 'custom_inputs'];
const PURPOSES = { Comfort: 'Komfort', Energy: 'Energie', Security: 'Sicherheit' };
const PE_REQUIRED = [
  'icon', 'name_en', 'name_de', 'subtitle_en', 'subtitle_de',
  'short_description_en', 'short_description_de', 'long_description_en', 'long_description_de',
  'purpose_en', 'purpose_de', 'keywords_en', 'keywords_de', 'events_en', 'events_de',
  'highlight', 'deploy',
];
// Nested trigger lists (`- triggers: !input ...`) need this HA version.
const NESTED_TRIGGERS_FLOOR = '2024.10.0';
// Partner Engine test fixtures — see TEST FIXTURES above.
const FIXTURE_PREFIX = 'peTestFixture_';

const indentOf = (l) => l.match(/^ */)[0].length;
const isBlank = (l) => l.trim() === '';
const unquote = (v) => v.trim().replace(/^"(.*)"$/, '$1').replace(/^'(.*)'$/, '$1');
const cmpVersion = (a, b) => {
  const pa = a.split('.').map(Number);
  const pb = b.split('.').map(Number);
  for (let i = 0; i < 3; i++) if (pa[i] !== pb[i]) return pa[i] - pb[i];
  return 0;
};

function checkFile(rel) {
  const lines = fs.readFileSync(path.resolve(ROOT, rel), 'utf8').split(/\r?\n/);
  const problems = [];
  const fail = (idx, rule, msg) => problems.push({ line: idx + 1, rule, msg });
  const find = (re, from = 0) => {
    for (let i = from; i < lines.length; i++) if (re.test(lines[i])) return i;
    return -1;
  };

  // --- Release notes (Readme: "Release notes") ---------------------------
  let newest = null;
  const rn = find(/^# ! RELEASE NOTES\s*$/);
  if (rn < 0) {
    fail(0, "release-notes", 'no "# ! RELEASE NOTES" header');
  } else {
    let prev = null;
    let entry = null;
    for (let i = rn + 1; i < lines.length && lines[i].startsWith('##'); i++) {
      const e = lines[i].match(/^## (\d+\.\d+\.\d+) \| (\d{4}-\d{2}-\d{2})\s*$/);
      if (e) {
        if (entry && entry.changes === 0) fail(entry.idx, "release-notes", `release ${entry.version} lists no changes`);
        if (Number.isNaN(Date.parse(e[2]))) fail(i, "release-notes", `"${e[2]}" is not a valid date`);
        if (prev && cmpVersion(e[1], prev) >= 0) fail(i, "release-notes", `release ${e[1]} is not lower than ${prev} above it — newest first`);
        if (!newest) newest = e[1];
        prev = e[1];
        entry = { idx: i, version: e[1], changes: 0 };
      } else if (/^## - \S/.test(lines[i]) && entry) {
        entry.changes++;
      } else {
        fail(i, "release-notes", 'release notes line is neither "## X.Y.Z | YYYY-MM-DD" nor "## - change"');
      }
    }
    if (entry && entry.changes === 0) fail(entry.idx, "release-notes", `release ${entry.version} lists no changes`);
    if (!newest) fail(rn, "release-notes", 'release notes have no "## X.Y.Z | YYYY-MM-DD" entry');
  }

  // --- Partner Engine block (Readme: "Partner Engine metadata block") ----
  const bp = find(/^blueprint:\s*$/);
  if (bp < 0) {
    fail(0, "structure", 'no top-level "blueprint:" key');
    return problems;
  }
  const pe = {};
  const peLine = {};
  for (let i = 0; i < bp; i++) {
    const m = lines[i].match(/^# (\w+):\s*(.*)$/);
    if (m) { pe[m[1]] = m[2]; peLine[m[1]] = i; }
  }
  for (const k of PE_REQUIRED) if (!(k in pe)) fail(bp, "partner-engine-field", `Partner Engine field "${k}" is missing`);
  if ('icon' in pe && unquote(pe.icon).startsWith('mdi:')) fail(peLine.icon, "partner-engine-value", 'Partner Engine icon must not have the "mdi:" prefix');
  if ('purpose_en' in pe) {
    const en = unquote(pe.purpose_en);
    if (!(en in PURPOSES)) fail(peLine.purpose_en, "partner-engine-value", `purpose_en "${en}" is not one of ${Object.keys(PURPOSES).join(', ')}`);
    else if ('purpose_de' in pe && unquote(pe.purpose_de) !== PURPOSES[en]) fail(peLine.purpose_de, "partner-engine-value", `purpose_de must be "${PURPOSES[en]}" to match purpose_en "${en}"`);
  }
  for (const k of ['highlight', 'deploy', 'is_smart_button']) {
    if (k in pe && !/^(true|false)$/.test(pe[k].trim())) fail(peLine[k], "partner-engine-value", `${k} must be true or false`);
  }
  // Readme: is_smart_button only for blueprints whose whole job is scene activation (the scene_* family).
  if (pe.is_smart_button && pe.is_smart_button.trim() === 'true' && !path.basename(rel).startsWith('scene_')) {
    fail(peLine.is_smart_button, "partner-engine-value", 'is_smart_button is only for the scene_* family (pure scene activation from a button)');
  }
  for (const lang of ['en', 'de']) {
    const key = `long_description_${lang}`;
    if (!(key in pe)) continue;
    let found = 0;
    for (let i = peLine[key] + 1; i < bp && /^#( {3}|\s*$)/.test(lines[i]); i++) {
      const v = lines[i].match(/^#\s+_Version (.+?)_\s*$/);
      if (!v) continue;
      found++;
      if (newest && v[1] !== newest) fail(i, "version", `${key} says version "${v[1]}", release notes say ${newest} — version only, no date`);
    }
    if (!found) fail(peLine[key], "version", `${key} has no "_Version X.Y.Z_" line`);
  }

  // --- Blueprint metadata (Readme: "Blueprint metadata") -----------------
  const desc = find(/^ {2}description:\s*[>|]-?\s*$/, bp);
  if (desc < 0) {
    fail(bp, "description", 'blueprint.description is missing or is not a block scalar (description: >)');
  } else {
    const body = [];
    for (let i = desc + 1; i < lines.length && (isBlank(lines[i]) || indentOf(lines[i]) >= 4); i++) body.push(i);
    const text = body.filter((i) => !isBlank(lines[i]));
    if (!text.length || !/^#\s+\S/.test(lines[text[0]].trim())) fail(desc, "description", 'blueprint.description must start with a Markdown H1 ("# <emoji> <name>")');
    const vLines = body.filter((i) => /^\*Version /.test(lines[i].trim()));
    if (!vLines.length) fail(desc, "version", 'blueprint.description has no "*Version X.Y.Z*" line');
    for (const idx of vLines) {
      const v = lines[idx].trim().match(/^\*Version (.+?)\*$/);
      const value = v ? v[1] : lines[idx].trim();
      if (newest && value !== newest) fail(idx, "version", `blueprint.description says version "${value}", release notes say ${newest} — version only, no date`);
    }
    if (text.length && lines[text[text.length - 1]].trim() !== LAST_DESCRIPTION_LINE) {
      fail(text[text.length - 1], "description", `blueprint.description must end with: ${LAST_DESCRIPTION_LINE}`);
    }
  }

  const author = find(/^ {2}author:/, bp);
  if (author < 0) fail(bp, "author", 'blueprint.author is missing');
  else {
    const a = lines[author].replace(/^ {2}author:\s*/, '').trim();
    if (!/^\S.*\s\[smarli\. AG\]$/.test(a) || a.startsWith('your-github-user')) fail(author, "author", 'author must be the actual person, followed by "[smarli. AG]"');
  }

  const src = find(/^ {2}source_url:/, bp);
  const expectedUrl = REPO_URL + path.basename(rel).replace(/ /g, '%20');
  if (src < 0) fail(bp, "source-url", 'blueprint.source_url is missing');
  else if (lines[src].replace(/^ {2}source_url:\s*/, '').trim() !== expectedUrl) fail(src, "source-url", `source_url must be ${expectedUrl}`);

  const minV = find(/^ {4}min_version:/, bp);
  const usesNested = find(/^\s*- triggers: !input /) >= 0;
  if (minV < 0) fail(bp, "min-version", 'homeassistant.min_version is missing');
  else if (usesNested) {
    const m = lines[minV].match(/min_version:\s*"?(\d+\.\d+\.\d+)/);
    if (!m || cmpVersion(m[1], NESTED_TRIGGERS_FLOOR) < 0) fail(minV, "min-version", `nested trigger lists need min_version >= ${NESTED_TRIGGERS_FLOOR}`);
  }

  // Readme: "Automation body" — merge custom triggers as a nested list.
  for (let i = 0; i < lines.length; i++) {
    if (/^\s*- !input custom_\w*triggers\b/.test(lines[i])) fail(i, "custom-triggers", 'merge custom triggers with "- triggers: !input ...", not "- !input ..."');
  }
  // Readme: "Variables translation" — variables: is always present.
  if (find(/^variables:/) < 0) fail(bp, "variables", 'top-level "variables:" is missing (use "variables: {}" when empty)');

  // --- Inputs (Readme: "Input sections", "Per-input frontend annotations") --
  const inputRoot = find(/^ {2}input:\s*$/, bp);
  if (inputRoot < 0) {
    fail(bp, "input-sections", 'blueprint.input is missing');
    return problems;
  }
  let end = inputRoot + 1;
  while (end < lines.length && (isBlank(lines[end]) || indentOf(lines[end]) > 2)) end++;

  const sections = [];
  for (let i = inputRoot + 1; i < end; i++) {
    const s = lines[i].match(/^ {4}([\w-]+):/);
    if (!s) continue;
    let sEnd = i + 1;
    while (sEnd < end && (isBlank(lines[sEnd]) || indentOf(lines[sEnd]) > 4)) sEnd++;
    sections.push({ name: s[1], start: i, end: sEnd });
  }
  const names = sections.map((s) => s.name);
  for (const s of sections) if (!SECTION_ORDER.includes(s.name)) fail(s.start, "input-sections", `unknown input section "${s.name}" — use ${SECTION_ORDER.join(', ')}`);
  const known = names.filter((n) => SECTION_ORDER.includes(n));
  if (known.join() !== SECTION_ORDER.filter((n) => known.includes(n)).join()) fail(inputRoot, "input-sections", `input sections are out of order — use ${SECTION_ORDER.join(', ')}`);
  if (!names.includes('custom_inputs')) fail(inputRoot, "input-sections", 'the Danger Zone section "custom_inputs" is missing');

  for (const sec of sections) {
    const danger = sec.name === 'custom_inputs';
    if (danger) {
      const block = lines.slice(sec.start, sec.end).join('\n');
      if (!/^ {6}name: "DANGER ZONE: Additional Custom Inputs"\s*$/m.test(block)) fail(sec.start, "danger-zone", 'Danger Zone name must be "DANGER ZONE: Additional Custom Inputs"');
      if (!/^ {6}collapsed: true\s*$/m.test(block)) fail(sec.start, "danger-zone", 'Danger Zone must have "collapsed: true"');
    }
    const secInput = lines.slice(sec.start, sec.end).findIndex((l) => /^ {6}input:/.test(l));
    if (secInput < 0) continue; // Readme: a section may have no input: at all.

    for (let i = sec.start + secInput + 1; i < sec.end; i++) {
      const k = lines[i].match(/^ {8}([\w-]+):\s*(#.*)?$/);
      if (!k) {
        if (!isBlank(lines[i]) && indentOf(lines[i]) < 10 && !lines[i].trim().startsWith('#')) fail(i, "input-sections", 'unexpected indentation inside an input section — expected inputs at 8 spaces');
        continue;
      }
      let iEnd = i + 1;
      while (iEnd < sec.end && (isBlank(lines[iEnd]) || indentOf(lines[iEnd]) > 8)) iEnd++;
      checkInput(k[1], i, iEnd, danger);
      i = iEnd - 1;
    }
  }

  function checkInput(name, start, stop, danger) {
    const field = (re) => {
      for (let i = start + 1; i < stop; i++) if (indentOf(lines[i]) === 10 && re.test(lines[i])) return i;
      return -1;
    };
    const opt = field(/^\s*# optional:/);
    const disp = field(/^\s*# display_if:/);
    const tr = field(/^\s*# translation:/);
    const hasDefault = field(/^\s*default:/) >= 0;
    const hasDescription = field(/^\s*description:/) >= 0;

    if (danger) {
      // Readme: "Danger Zone" — no annotations, and every custom input defaults to [].
      if (opt >= 0 || disp >= 0 || tr >= 0) fail(start, "danger-zone", `Danger Zone input "${name}" must not carry optional/display_if/translation annotations`);
      if (!hasDefault) fail(start, "danger-zone", `Danger Zone input "${name}" needs a default (default: [])`);
      return;
    }

    let optional = null;
    let displayIf = null;
    if (opt < 0) fail(start, "annotation", `input "${name}" has no "# optional:" annotation`);
    else {
      optional = lines[opt].replace(/^\s*# optional:\s*/, '').trim();
      if (!/^(true|false)$/.test(optional)) fail(opt, "annotation", `input "${name}": optional must be true or false, not "${optional}"`);
    }
    if (disp < 0) fail(start, "annotation", `input "${name}" has no "# display_if:" annotation`);
    else {
      displayIf = lines[disp].replace(/^\s*# display_if:\s*/, '').trim();
      if (!displayIf) fail(disp, "annotation", `input "${name}": display_if is empty`);
    }

    // Readme: "Optional vs. display_if" — a value nobody may enter must come from a default.
    // Home Assistant treats an input without a default as required, so an input that is
    // Partner-Engine-optional, or hidden by display_if, would leave the automation unsavable.
    if (!hasDefault && (optional === 'true' || (displayIf !== null && displayIf !== 'true'))) {
      const why = optional === 'true' ? 'optional: true' : `display_if: ${displayIf}`;
      fail(start, "default", `input "${name}" has ${why} but no default — Home Assistant would reject the automation when no value is given`);
    }

    if (tr < 0) fail(start, "translation", `input "${name}" has no "# translation:" block`);
    else {
      const have = {};
      let group = null;
      for (let i = tr + 1; i < stop && /^ {10}#\s{3,}\S/.test(lines[i]); i++) {
        const g = lines[i].match(/^ {10}# {3}(\w+):\s*$/);
        const l = lines[i].match(/^ {10}# {5}(en|de):\s*\S/);
        if (g) group = g[1];
        else if (l && group) have[`${group}.${l[1]}`] = true;
      }
      const need = ['name.en', 'name.de'];
      if (hasDescription) need.push('description.en', 'description.de');
      const missing = need.filter((n) => !have[n]);
      if (missing.length) fail(tr, "translation", `input "${name}" translation is missing ${missing.join(', ')}`);
    }

    // Readme: "Select option translations".
    for (let i = start + 1; i < stop; i++) {
      const lab = lines[i].match(/^(\s*)- label:/);
      if (!lab) continue;
      const inner = lab[1].length + 2;
      let j = i + 1;
      while (j < stop && isBlank(lines[j])) j++;
      if (j >= stop || indentOf(lines[j]) !== inner || !/^\s*# translation:/.test(lines[j])) {
        fail(i, "translation", `input "${name}": select option has no "# translation:" right below its label`);
        continue;
      }
      const block = [];
      for (let t = j + 1; t < stop && /^\s*#\s{3,}\S/.test(lines[t]); t++) block.push(lines[t]);
      for (const lang of ['en', 'de']) {
        if (!block.some((b) => new RegExp(`^\\s*#\\s+${lang}:\\s*\\S`).test(b))) fail(j, "translation", `input "${name}": select option translation is missing label.${lang}`);
      }
    }
  }

  return problems;
}

// --- Main -----------------------------------------------------------------
let files = process.argv.slice(2);
if (!files.length) {
  files = fs.readdirSync(path.join(ROOT, 'automation'))
    .filter((f) => f.endsWith('.yaml'))
    .sort()
    .map((f) => `automation/${f}`);
}

const SOURCE = fs.readFileSync(__filename, 'utf8');
const RULE_IDS = new Set([...SOURCE.matchAll(/fail\([^,]+, "([a-z-]+)", /g)].map((m) => m[1]));

// Applies the "# checks: allow ..." line of a test fixture. See TEST FIXTURES above.
function applyAllow(rel, problems) {
  const lines = fs.readFileSync(path.resolve(ROOT, rel), 'utf8').split(/\r?\n/);
  const bp = lines.findIndex((l) => /^blueprint:\s*$/.test(l));
  const idx = lines.slice(0, bp < 0 ? lines.length : bp).findIndex((l) => /^# checks: allow\b/.test(l));
  if (idx < 0) return problems;
  const fixture = path.basename(rel).startsWith(FIXTURE_PREFIX);
  if (!fixture) return [...problems, { line: idx + 1, rule: 'allow', msg: `"# checks: allow" is only for test fixtures (file name starting with "${FIXTURE_PREFIX}")` }];
  const allowed = lines[idx].replace(/^# checks: allow\s*/, '').split(',').map((s) => s.trim()).filter(Boolean);
  const out = problems.filter((p) => !allowed.includes(p.rule));
  for (const id of allowed) {
    if (!RULE_IDS.has(id)) out.push({ line: idx + 1, rule: 'allow', msg: `"${id}" is not a rule ID — known: ${[...RULE_IDS].sort().join(', ')}` });
    else if (!problems.some((p) => p.rule === id)) out.push({ line: idx + 1, rule: 'allow', msg: `"${id}" is allowed but nothing breaks it any more — remove it` });
  }
  return out;
}

let total = 0;
for (const rel of files) {
  const problems = applyAllow(rel, checkFile(rel));
  total += problems.length;
  for (const p of problems) console.log(`${rel}:${p.line}: [${p.rule}] ${p.msg}`);
}
console.log(total ? `${total} problem(s) in ${files.length} blueprint(s)` : `${files.length} blueprint(s) checked, no problems`);
process.exit(total ? 1 : 0);
