      # The IR is what a reporter or a person reads to find out WHICH case failed on WHICH platform.
      - uses: actions/upload-artifact@v7
        if: failure()
        with:
          name: testing-ir@@SUFFIX|raw@@
          path: ${{ runner.temp }}/testing-ir.json
          if-no-files-found: ignore
          retention-days: 14
