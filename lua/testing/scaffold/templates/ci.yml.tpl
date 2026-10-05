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
          version: stable
      - name: Run the specs
        run: |
          set -o pipefail
          bash scripts/test.sh --json "$RUNNER_TEMP/testing-ir.json" 2>&1 | tee "$RUNNER_TEMP/test-output.log"
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
