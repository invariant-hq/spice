Describe the OCaml project from Dune metadata: libraries, executables,
compilation units, dependencies, tests, and build context.

Use it before broad OCaml changes — adding modules, changing library
dependencies, reasoning about test targets — instead of inferring the
project shape from directory listings. It runs `dune describe` once and
normalizes the result; it does not start or depend on a Dune watch.
