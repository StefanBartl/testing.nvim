// Checks the machine contract testing-export/1 from the outside, the way a client (testing-desktop, testing-web)
// would meet it.
//
//   npm ci && node check.mjs            checks everything, writes nothing, exit 1 on any failure
//   node check.mjs --write              also regenerates schemas/testing-export/1/testing-export.d.ts
//
// What it proves:
//  1. the JSON Schema compiles in Ajv's strict mode (draft 2020-12: a mistake in the schema itself fails too), and
//     every golden document (TESTS/golden/testing-export-1/**/*.json, an export folder made by the Lua engine) is
//     valid against it; the Lua validator (lua/testing/export/schema.lua) checks the same files in the suite, so
//     the two must agree;
//  2. documents that break the contract are refused (a field nobody listed, a path in the export form, an export
//     form whose data classes were not asked, ...), so the schema is not just "accepts everything";
//  3. the TypeScript types generated from the schema are the committed ones, and none of them is `never[]` (what
//     the generator makes of a tuple).

import fs from "node:fs";
import path from "node:path";
import { fileURLToPath } from "node:url";
import Ajv2020 from "ajv/dist/2020.js";
import addFormats from "ajv-formats";
import { compile } from "json-schema-to-typescript";

const here = path.dirname(fileURLToPath(import.meta.url));
const repo = path.resolve(here, "..");
const schemaPath = path.join(
  repo,
  "schemas/testing-export/1/testing-export.schema.json",
);
const typesPath = path.join(
  repo,
  "schemas/testing-export/1/testing-export.d.ts",
);
const goldenDir = path.join(repo, "TESTS/golden/testing-export-1");
const write = process.argv.includes("--write");

let failures = 0;
const report = (ok, name, detail = "") => {
  if (!ok) failures += 1;
  console.log(`${ok ? "PASS" : "FAIL"}  ${name}${detail ? ": " + detail : ""}`);
};

const schema = JSON.parse(fs.readFileSync(schemaPath, "utf8"));

// ---- 1. the schema compiles (strict) and the goldens validate
const ajv = new Ajv2020({ strict: true, allErrors: true });
addFormats(ajv);
let validate;
try {
  validate = ajv.compile(schema);
  report(true, "schema compiles in strict mode (draft 2020-12)");
} catch (e) {
  report(false, "schema compiles in strict mode", e.message);
  process.exit(1);
}

/** Every .json below `dir`, as forward-slash paths relative to it, sorted. */
function walk(dir, prefix = "") {
  const out = [];
  for (const entry of fs.readdirSync(dir, { withFileTypes: true })) {
    const rel = prefix ? `${prefix}/${entry.name}` : entry.name;
    if (entry.isDirectory()) out.push(...walk(path.join(dir, entry.name), rel));
    else if (entry.name.endsWith(".json")) out.push(rel);
  }
  return out.sort();
}

const goldens = walk(goldenDir);
report(
  goldens.length >= 5,
  "golden documents found",
  `${goldens.length} files`,
);
// by kind: fleet, manifest, and each repo document by its directory name
const docs = {};
for (const file of goldens) {
  const doc = JSON.parse(fs.readFileSync(path.join(goldenDir, file), "utf8"));
  const name =
    doc.kind === "repo" ? `repo:${doc.repo && doc.repo.name}` : doc.kind;
  docs[name] = doc;
  const ok = validate(doc);
  report(
    ok,
    `golden ${file} (${doc.kind}, ${doc.form})`,
    ok
      ? ""
      : JSON.stringify(
          validate.errors
            .slice(0, 3)
            .map((e) => `${e.instancePath} ${e.message}`),
        ),
  );
}
for (const need of ["fleet", "manifest", "repo:beta.nvim"]) {
  report(need in docs, `golden document ${need} present`);
}

// ---- 2. documents that break the contract are refused
const mutate = (name, base, fn) => {
  if (!(base in docs)) {
    report(false, `refused: ${name}`, `no golden document ${base}`);
    return;
  }
  const copy = structuredClone(docs[base]);
  fn(copy);
  report(!validate(copy), `refused: ${name}`);
};
mutate("an unknown top-level field", "fleet", (d) => (d.surprise = 1));
mutate("an unknown row field", "fleet", (d) => (d.repos[0].surprise = 1));
mutate("root in the head of the export form", "fleet", (d) => (d.root = "/srv/repos"));
mutate(
  "root in a row of the export form",
  "fleet",
  (d) => (d.repos[0].root = "C:/repos/alpha.nvim"),
);
mutate(
  "root in the row of a repo document of the export form",
  "repo:beta.nvim",
  (d) => (d.repo.root = "/home/x/beta.nvim"),
);
mutate("a key without its hash", "fleet", (d) => (d.repos[0].key = "alpha.nvim"));
mutate(
  "a verdict outside the enum",
  "fleet",
  (d) => (d.repos[1].local.verdict = "purple"),
);
mutate(
  "a summary without a status",
  "fleet",
  (d) => delete d.repos[0].local.summary.pass,
);
mutate("a digest that is no hash", "fleet", (d) => (d.digest = "sha256:xyz"));
mutate(
  "a link that is not to GitHub",
  "fleet",
  (d) => (d.repos[0].ci_remote.run.url = "https://evil.example/x"),
);
mutate("a kind this version does not write", "fleet", (d) => (d.kind = "runs"));
mutate("a negative count", "fleet", (d) => (d.excluded = -1));
mutate("a row without counts", "fleet", (d) => delete d.repos[0].counts);
mutate("schema 2", "fleet", (d) => (d.schema = "testing-export/2"));
mutate(
  "an export-form fleet whose data classes were not asked",
  "fleet",
  (d) => (d.classes.checked = false),
);
mutate(
  "an export-form fleet without classes",
  "fleet",
  (d) => delete d.classes,
);
mutate(
  "a case with a status outside the enum",
  "repo:beta.nvim",
  (d) => (d.cases[0].status = "meh"),
);
mutate(
  "a repo document without cases_red",
  "repo:beta.nvim",
  (d) => delete d.cases_red,
);
mutate("a manifest in the local form", "manifest", (d) => (d.form = "local"));
mutate(
  "a manifest file outside the folder",
  "manifest",
  (d) => (d.files[0].path = "../x.json"),
);
mutate(
  "a manifest file whose sum is no sha256",
  "manifest",
  (d) => (d.files[0].sha256 = "abc"),
);
{
  // the local form may say the data classes were not asked: the rule is the export form's only
  const local = structuredClone(docs.fleet);
  local.form = "local";
  local.classes.checked = false;
  report(validate(local), "a local-form fleet with classes.checked false is valid");
}

// ---- 3. the generated TypeScript
const types = await compile(schema, "TestingExport", {
  additionalProperties: false,
  bannerComment:
    "/* Generated from schemas/testing-export/1/testing-export.schema.json by contract/check.mjs. Do not edit. */",
});
report(
  !/never\[\]/.test(types),
  "generated types contain no never[] (the generator's answer to a tuple)",
);
report(
  /kind: "fleet"/.test(types) &&
    /kind: "repo"/.test(types) &&
    /kind: "manifest"/.test(types),
  "generated types carry the kinds",
);
if (write) {
  fs.writeFileSync(typesPath, types);
  console.log(`wrote ${path.relative(repo, typesPath)}`);
} else {
  const committed = fs.existsSync(typesPath)
    ? fs.readFileSync(typesPath, "utf8")
    : "";
  report(
    committed === types,
    "generated types equal the committed ones",
    committed === types
      ? ""
      : "run `node check.mjs --write` and commit schemas/testing-export/1/testing-export.d.ts",
  );
}

console.log(
  failures === 0
    ? "\nall contract checks passed"
    : `\n${failures} contract check(s) FAILED`,
);
process.exit(failures === 0 ? 0 : 1);
