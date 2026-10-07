name: CI

on:
  push:
    branches: [main]
  pull_request:

jobs:
  tests:
    name: specs (${{ matrix.os }})
    runs-on: ${{ matrix.os }}
    # A hung spec must end the job, not hold the runner for the 6-hour default.
    timeout-minutes: 15
    strategy:
      # One platform failing must not cancel the others.
      fail-fast: false
      matrix:
        os: [ubuntu-latest, windows-latest, macos-latest]
    defaults:
      run:
        # One shell on all three platforms.
        shell: bash
    steps:
      - uses: actions/checkout@v5
@@DEP_STEPS|raw@@
      - uses: rhysd/action-setup-vim@v1
        with:
          neovim: true
          # Pinned, not `stable`: the version is part of every cache key, a moving one empties the cache
          # at every Neovim release. Move it on purpose (docs/CI-CACHE.md).
          version: v0.12.2
      # The result cache (docs/CI-CACHE.md). The key of this action is only the transport: every entry
      # carries its own full spec key and is checked against it when read, so a wrong restore can lower the
      # hit rate and never turn a result green. Pull requests only restore; only the main branch saves.
      - uses: actions/cache/restore@v4
        with:
          path: ${{ runner.temp }}/testing-cache
          key: testing-${{ runner.os }}-nvim0.12.2-${{ github.sha }}
          restore-keys: testing-${{ runner.os }}-nvim0.12.2-
      - name: Run the specs
        env:
          TESTING_CACHE_HOME: ${{ runner.temp }}/testing-cache
        run: |
          set -o pipefail
          bash scripts/test.sh --json "$RUNNER_TEMP/testing-ir.json" --cached 2>&1 | tee "$RUNNER_TEMP/test-output.log"
      - uses: actions/cache/save@v4
        if: success() && github.event_name == 'push' && github.ref == 'refs/heads/main'
        with:
          path: ${{ runner.temp }}/testing-cache
          key: testing-${{ runner.os }}-nvim0.12.2-${{ github.sha }}
      # The IR is what a reporter or a person reads to find out WHICH case failed on WHICH platform.
      - uses: actions/upload-artifact@v7
        if: failure()
        with:
          name: testing-ir-${{ matrix.os }}
          path: |
            ${{ runner.temp }}/testing-ir.json
            ${{ runner.temp }}/test-output.log
          if-no-files-found: ignore
          retention-days: 14
