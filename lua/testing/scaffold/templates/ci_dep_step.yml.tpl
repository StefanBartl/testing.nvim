      # Checked out from the branch that only moves once the dependency's own CI is green.
      - uses: actions/checkout@v5
        with:
          repository: @@REPO|yaml@@
          path: @@PREFIX|raw@@@@NAME@@
          ref: ci-verified
