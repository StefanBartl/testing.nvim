/* Generated from schemas/testing-export/1/testing-export.schema.json by contract/check.mjs. Do not edit. */

/**
 * The documents testing.nvim writes for an app or a web page: the fleet, one repository, the manifest of an export folder. The engine writes them, never the app (docs/OUTPUT-FORMATS.md). This schema describes exactly what this version writes (a field nobody listed is refused here); a READER ignores unknown fields, refuses a higher schema and treats a missing or null value as unknown, never as 0.
 */
export type TestingExport1 = Fleet | RepoDoc | Manifest;
export type Schema = "testing-export/1";
export type Plugin = "testing.nvim";
/**
 * local: for a process on this machine (the hub), it carries the absolute `root`; export: for a folder, a web page or a panel, no absolute path anywhere.
 */
export type Form = "local" | "export";
export type Time = string;
export type Rev = string;
export type Digest = string;
export type Capabilities = string[];
/**
 * Absolute path of this machine: only in the local form.
 */
export type Root = string;
/**
 * <basename>-<12 hex of sha256(basename, newline, root commit)>: the same for every clone of the repository wherever it lives; no path of this machine goes into it.
 */
export type Key = string;
/**
 * The checkout now. null: not a git checkout, or git could not be asked.
 */
export type Head = null | {
  sha: string | null;
  branch: TextOrNull;
  dirty: boolean | null;
};
export type TextOrNull = string | null;
/**
 * The last local result (last.json, merged over partial runs). null: no result recorded.
 */
export type Local = null | {
  run_id: TextOrNull;
  ts: TimeOrNull;
  verdict: "green" | "green-partial" | "red";
  summary: Summary;
  cases: Count;
  files: Count;
  partial: boolean;
  /**
   * Spec files whose result is outdated (changed, gone or without a result since).
   */
  stale: number;
  /**
   * The commit of the run when the last green record is this run; null: unknown.
   */
  commit: string | null;
};
export type TimeOrNull = Time | null;
export type Count = number;
export type LastGreen = null | {
  run_id: string;
  ts: Time;
  sha: TextOrNull;
};
/**
 * The last local pipeline run (ci.json of `testing ci`). null: none recorded.
 */
export type CiLocal = null | {
  verdict: "green" | "green-partial" | "red" | "error" | "infra";
  profile: TextOrNull;
  partial: boolean | null;
  commit: TextOrNull;
  tree: TextOrNull;
  dirty: boolean | null;
  first_red: TextOrNull;
  time: TimeOrNull;
};
/**
 * The latest GitHub Actions run of the CI workflow for the head of origin (testing ci remote), as of the document's generated_at. null: not asked; asked without a record of the adapter: state unknown with a note.
 */
export type CiRemote = null | {
  state: RemoteState;
  repo: TextOrNull;
  sha: TextOrNull;
  branch: TextOrNull;
  workflow: TextOrNull;
  os: {
    ubuntu: Cell;
    windows: Cell;
    macos: Cell;
  };
  run: null | {
    id: number | null;
    url: GithubUrl;
    status: TextOrNull;
    conclusion: TextOrNull;
    created_at: TextOrNull;
    updated_at: TextOrNull;
    event: TextOrNull;
    attempt: number | null;
  };
  note: TextOrNull;
};
export type RemoteState =
  | "failure"
  | "rejected"
  | "cancelled"
  | "unknown"
  | "waiting_runner"
  | "queued"
  | "running"
  | "success"
  | "skipped"
  | "no_run"
  | "no_github";
export type Cell = null | {
  state: RemoteState;
  url: GithubUrl;
  job: TextOrNull;
};
export type GithubUrl = string | null;
export type Counts = null | {
  fail: Count;
  flaky: Count;
};
/**
 * Whether the local results of this machine were read. false on the workstation (NVIM_MACHINE_ROLE=workstation), where nothing runs: local, last_green, ci_local and counts are then null (unknown); cases_red and cases_omitted stay integers of version 1 and are 0, which a client reads as unknown when local_read is false.
 */
export type LocalRead = boolean;
export type Status = "pass" | "fail" | "error" | "skip" | "xfail" | "xpass" | "timeout" | "crash";

export interface Fleet {
  schema: Schema;
  plugin: Plugin;
  kind: "fleet";
  form: Form;
  generated_at: Time;
  engine: Engine;
  rev: Rev;
  digest: Digest;
  capabilities: Capabilities;
  root?: Root;
  repos: Row[];
  /**
   * How many repositories were left out (vaults, excludes); their names are not in the document.
   */
  excluded: number;
  /**
   * The repositories left out by reason, never by name: selection (vaults, excludes), private and unclassified (the data classes of this device, fail-closed). null: the data classes were not asked (the local form, a document that stays on this machine; the export form always asks them). Capability data_classes.
   */
  excluded_by?: {
    selection: Count;
    private: number | null;
    unclassified: number | null;
  };
  /**
   * Whether the data classes were asked, and why nothing (or less) could be released: no areas.json on this device, an unusable one. Capability data_classes.
   */
  classes?: {
    checked: boolean;
    problem: TextOrNull;
  };
  local_read?: LocalRead;
  remote: RemoteInfo;
}
export interface Engine {
  version: string;
  git: string;
  nvim: string;
}
export interface Row {
  key: Key;
  name: string;
  root?: Root;
  head: Head;
  local: Local;
  last_green: LastGreen;
  ci_local: CiLocal;
  ci_remote: CiRemote;
  counts: Counts;
}
export interface Summary {
  pass: Count;
  fail: Count;
  error: Count;
  skip: Count;
  xfail: Count;
  xpass: Count;
  timeout: Count;
  crash: Count;
}
export interface RemoteInfo {
  asked: boolean;
  error: TextOrNull;
}
export interface RepoDoc {
  schema: Schema;
  plugin: Plugin;
  kind: "repo";
  form: Form;
  generated_at: Time;
  engine: Engine;
  rev: Rev;
  digest: Digest;
  capabilities: Capabilities;
  root?: Root;
  repo: Row;
  /**
   * The red cases of the last result (fail, error, timeout, crash, xpass), by file and line, redacted.
   */
  cases: Case[];
  /**
   * All red cases of the last result. An integer in every document of version 1: 0 when the local results were not read (local_read false, capability data_classes), which a client reads as unknown.
   */
  cases_red: number;
  /**
   * Red cases not listed because of the size limit (0 when the local results were not read).
   */
  cases_omitted: number;
  /**
   * Why a source of the state could not be used (redacted).
   */
  notes: string[];
  local_read?: LocalRead;
  remote: RemoteInfo;
}
export interface Case {
  id: string;
  file: string;
  line: number | null;
  status: Status;
  name: TextOrNull;
  describe: string[];
  duration_ms: number;
  flaky: boolean;
  message: TextOrNull;
  expected: TextOrNull;
  actual: TextOrNull;
  fails: Fail[];
  fails_total: number | null;
}
export interface Fail {
  line: number | null;
  msg: TextOrNull;
}
export interface Manifest {
  schema: Schema;
  plugin: Plugin;
  kind: "manifest";
  form: "export";
  generated_at: Time;
  engine: Engine;
  rev: Rev;
  digest: Digest;
  capabilities: Capabilities;
  files: File[];
}
export interface File {
  /**
   * Relative to the export folder, forward slashes.
   */
  path: string;
  sha256: string;
  bytes: Count;
}
